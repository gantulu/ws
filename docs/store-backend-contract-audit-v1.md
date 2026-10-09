# Store Mobile V1 — Backend Contract Audit V1

- Repository: `gantulu/ws`
- Implementation branch: `feat/store-mobile-v1-app`
- Supabase project inspected: `oszqantvugvbvydlizix` (project name: `No signal`)
- Audit date: 2026-10-09
- Status: **BLOCKED FOR FRONTEND-BACKEND INTEGRATION**
- Scope: read-only inspection of product, order, payment, tracking, grants/RLS, and the active ASRI Duitku sandbox function.
- Safety: no database writes, migrations, Edge Function deployments, secret reads, or production changes were made.

## 1. Executive decision

The frontend build and browser smoke tests have passed on CI, but the current backend does not yet provide a complete store contract. Do not connect checkout to the current payment function until order creation, customer identity, item/fulfilment data, and the payment transaction upsert contract are resolved.

## 2. Verified product contract

### Existing table: `public.asri_products`

Observed columns include:

- Identity/catalog: `id`, `sku`, `slug`, `name`, `description`, `category`, `brand`
- Price/stock: `price` (bigint), `compare_at_price` (bigint), `currency`, `stock_quantity`
- Variants/media: `images` (text[]), `colors` (jsonb), `sizes` (jsonb)
- Publication: `is_active`, `is_featured`, `metadata`, timestamps

Constraints include unique SKU and slug, IDR currency, non-negative price/stock, and compare-at-price not below price.

- RLS is enabled.
- The only observed policy permits `SELECT` for `anon` and `authenticated` when `is_active = true`.
- Explicit `SELECT` grants exist for `anon` and `authenticated`.
- Live row count at audit time: **0 total / 0 active products**.

**Implication:** the current UI's four sample products cannot be replaced with live catalogue data until product records are populated. With the current table empty, the real catalogue should show an intentional empty state rather than silently fall back to demo items.

## 3. Verified order/payment schema

### `public.asri_payment_orders`

Key fields: `id`, unique `merchant_order_id`, nullable `user_id`, positive `amount` (bigint), IDR `currency`, `status`, `payment_method`, `product_details` (text), customer email/phone/VA name, callback/return URL, provider reference/payment URL/VA/QR/app URL, provider status fields, failure reason, expiry/payment timestamps.

Allowed statuses: `draft`, `pending`, `paid`, `failed`, `cancelled`, `expired`, `creation_failed`.

- RLS is enabled, with no client-facing policies.
- Observed table grants for this payment table are service-role only.
- Live row count at audit time: **0**.
- `user_id` has no observed foreign-key constraint.
- `product_details` is free text, not normalized order items.
- There are no shipping address, courier, tracking number, fulfilment status, or shipment event fields in this table.

### Related tables

- `asri_payment_transactions`: payment provider/reference/method, amount/fee, status, settlement data and raw provider response. RLS enabled; service-role table grants only; zero rows.
- `asri_payment_callbacks`: callback payload, signature validation, processing status, and event fingerprint. RLS enabled; service-role table grants only; zero rows. A partial unique index exists on non-null `event_fingerprint`.
- `asri_payment_status_history`: payment status transitions and source. RLS enabled; service-role table grants only; zero rows.

These tables represent payment state, not a complete online-store order or shipment domain.

## 4. Active Edge Function contract

Active function: `asri-duitku-sandbox`, version 4, `verify_jwt = false`, fixed to Duitku sandbox host.

Routes confirmed in source:

- `GET /health`: reports configuration readiness as booleans.
- `POST /payment-methods`: requires the current custom phone/password authentication plus an amount.
- `POST /create`: requires custom phone/password authentication, `merchantOrderId`, and `paymentMethod`. It loads an existing `asri_payment_orders` row, verifies ownership and `status = 'draft'`, and derives the amount from the stored order.
- `POST /status`: requires custom phone/password authentication and `merchantOrderId`; it checks the provider and returns payment status.
- `POST /callback`: validates the Duitku HMAC signature, records callback details, and updates payment state/history.

### Contract gaps and risks

1. **No draft-order creation endpoint was found in the active ASRI sandbox function.** The payment-create route explicitly expects a trusted draft order to exist already. The frontend currently has no supported way to create that draft.
2. **Identity contract mismatch:** the current frontend has no authentication flow, while payment-methods/create/status require `phone` and `password`. The function reads `public.users` and compares the stored `password` value directly. This is not an acceptable password-storage/authentication contract for a production store. Do not send these credentials from the current UI or build a new integration around plaintext password comparison.
3. **CORS is fixed to `https://asricollection.online`.** Confirm the actual frontend origin before browser integration; do not widen CORS indiscriminately.
4. **Potential payment transaction upsert blocker:** callback code uses `upsert(..., { onConflict: "provider,provider_reference" })`. The current unique index on those fields is partial (`WHERE provider_reference IS NOT NULL`). PostgreSQL conflict-target inference may not use that partial index without a matching predicate. This must be proven in a controlled sandbox test and resolved before accepting callback processing as verified.
5. Callback stores `paymentCode` into the transaction's `payment_method` field. Confirm the Duitku callback field semantics; payment code and payment method should not be conflated.
6. The status-check handler updates an order status but returns the pre-update `order.status` value from its initial read. Verify and correct the response contract before using it in the UI.
7. Callback maps `resultCode = "00"` to paid and `"01"` to failed; other result codes are treated as pending. Explicitly define and test the supported result-code set.
8. The legacy `duitku` and `duitku-callback` functions are separate. Do not change or redirect the legacy `duitku` function as part of Store Mobile V1 without a separate audit and approval.

## 5. Tracking contract

Current backend exposes payment status and payment status history, but no verified store-order lookup endpoint that returns an order summary and fulfilment timeline. No ASRI order-item, shipping-address, fulfilment, courier, tracking-number, or shipment-event tables were found in the inspected ASRI payment schema.

The frontend's `/tracking/:orderId` route remains a **demo-only local UI**. Do not pass arbitrary order IDs to a direct table query or expose payment records to the anonymous client. A future tracking endpoint must enforce order ownership or use a high-entropy, scoped tracking token and return only safe customer-visible fields.

## 6. Security and Data API notes

- Payment tables have RLS enabled, no public policies, and observed table grants only for `service_role`; preserve this boundary.
- `asri_products` is the exception intended for public read-only catalogue access, limited to active rows.
- Supabase's published changelog states that explicit grants are required for newly created public tables as the Data API auto-exposure change rolls out to existing projects on **2026-10-30**. Any future store tables must deliberately define grants and RLS; payment/order tables should remain server-only. See [Supabase changelog: tables not exposed to Data and GraphQL API automatically](https://supabase.com/changelog/45329-breaking-change-tables-not-exposed-to-data-and-graphql-api-automatically).
- The project-wide security advisor also reports unrelated legacy findings. They are not remediated here because this audit is read-only and the store task must not modify unrelated or legacy functions.

## 7. Recommended implementation sequence (approval required before backend changes)

1. **Lock customer identity model:** guest checkout with an opaque tracking token, or a separately reviewed custom-auth/session design. Do not use plaintext password comparison as the store's production authentication contract.
2. **Define the store-order domain:** normalized order header, order items snapshotting SKU/name/unit price/quantity, shipping address snapshot, shipping method/cost, authoritative subtotal/discount/shipping/total, and fulfilment/shipment events.
3. **Define server-side order creation:** accept only product IDs/slugs, quantities, customer/shipping inputs, and an allowed payment method. Server reads current active products/prices/stock, validates quantities, calculates totals, creates the draft order atomically, and returns a public order reference/token.
4. **Connect payment creation to the persisted draft:** retain the existing server-side amount lookup, but first resolve identity/ownership and the partial-index upsert concern in sandbox. Never accept client-submitted totals as authoritative.
5. **Define tracking API:** return order state, payment state, shipment state/history, and customer-safe details after verifying owner/token.
6. **Sandbox E2E verification:** create draft -> payment inquiry -> valid callback -> duplicate callback -> invalid signature -> status reconciliation -> tracking query. Record evidence before any production approval.

## 8. Final readiness

**Frontend:** build and browser smoke-test CI passed for the tested revision; the UI is still demo-data-only.

**Backend integration:** **BLOCKED** until steps 1–5 are agreed, the callback upsert contract is verified in sandbox, and real product data is populated. No backend contract or production resource was changed by this audit.
