# Store Backend Contract V2 — Design Proposal

- Repository: `gantulu/ws`
- Design branch: `feat/store-mobile-v1-app`
- Version: Store Backend Contract V2 — Draft 1
- Date: 2026-10-09
- Status: **PROPOSAL FOR REVIEW — NOT APPROVED FOR IMPLEMENTATION**
- Workflow: AUDIT → RECOMMEND → DESIGN → APPROVE → IMPLEMENT → VERIFY
- Scope: guest checkout, product/order contract, Duitku sandbox payments, and customer-safe tracking.
- Safety boundary: no database migration, Edge Function deployment, secret access, production configuration change, or change to `main` is authorized by this document.

## 1. Recommendation

Use guest checkout with scoped opaque access tokens as the baseline proposal. Do not reproduce the existing phone/password comparison in `asri-duitku-sandbox`. Keep all payment/order writes server-side and preserve the current public read-only policy for active products.

This is a design proposal only. The schema and endpoint contracts below require review and approval before implementation.

## 2. Current blockers from the V1 audit

1. `public.asri_products` had 0 rows and 0 active products at audit time.
2. No draft store-order creation endpoint was found in the active `asri-duitku-sandbox` function.
3. The existing payment create route expects a pre-existing `asri_payment_orders` row in `draft` state.
4. Existing payment routes use a custom phone/password pattern that compares the submitted password directly to the stored `public.users.password` value. Do not use this as the store's production identity contract.
5. Existing payment tables are service-role-only and should remain inaccessible to anonymous client table queries.
6. The current backend has no verified customer-facing fulfilment/shipment timeline contract.
7. Callback upsert conflict-target behavior and stale status response need controlled sandbox verification.

See [Backend Contract Audit V1](store-backend-contract-audit-v1.md) for the observed contract and evidence.

## 3. Proposed domain model

### 3.1 `public.asri_store_orders` — order header

Proposed fields:
- `id uuid primary key`
- `order_number text unique not null` — customer-visible, non-secret identifier
- `status text not null` — constrained to documented order lifecycle values
- `payment_status text not null` — derived from payment state, not shipment state
- `customer_name text not null`
- `customer_phone text not null`
- `customer_email text null`
- `shipping_recipient text not null`
- `shipping_phone text not null`
- `shipping_address_line text not null`
- `shipping_district text null`
- `shipping_city text not null`
- `shipping_province text not null`
- `shipping_postal_code text not null`
- `shipping_notes text null`
- `shipping_method text not null`
- `shipping_cost bigint not null check (shipping_cost >= 0)`
- `subtotal bigint not null check (subtotal >= 0)`
- `total_amount bigint not null check (total_amount >= 0)`
- `currency text not null check (currency = 'IDR')`
- `created_at timestamptz not null`
- `updated_at timestamptz not null`

Rules:
- The server computes all monetary fields. Never accept a client-supplied unit price, subtotal, shipping cost, discount, or total as authoritative.
- Store a snapshot of recipient and shipping details on the order so later profile/product edits do not rewrite historical orders.
- Order status and payment status are separate state dimensions. A successful payment does not imply the order has shipped.
- Exact order lifecycle values and stock-reservation policy must be finalized before migration.

### 3.2 `public.asri_store_order_items` — immutable item snapshot

Proposed fields:
- `id uuid primary key`
- `order_id uuid not null references asri_store_orders(id)`
- `product_id uuid null references asri_products(id) on delete set null`
- `sku_snapshot text not null`
- `product_name_snapshot text not null`
- `variant_snapshot jsonb not null default '{}'`
- `unit_price bigint not null check (unit_price >= 0)`
- `quantity integer not null check (quantity > 0)`
- `line_total bigint not null check (line_total >= 0)`
- `created_at timestamptz not null`

Rules:
- Persist the SKU/name/variant/price snapshots used for checkout.
- Re-read each product from the database at order creation; require it to be active and validate stock and selected variants.
- Define whether stock is reserved at draft creation or decremented after successful payment. Do not implement until the chosen policy and concurrent-purchase behavior are approved.
- The server computes `line_total = unit_price × quantity` and verifies safe integer/range constraints.

### 3.3 Payment relationship

Recommended approach: keep `asri_payment_orders`, `asri_payment_transactions`, `asri_payment_callbacks`, and `asri_payment_status_history` server-only. Add a nullable `store_order_id` relationship to `asri_payment_orders` only after reviewing existing constraints and consumers.

- A store order may have multiple payment attempts, each with a unique `merchant_order_id`.
- Each attempt uses the authoritative `total_amount` from the store order.
- Payment attempts and provider transactions must not be used as a substitute for normalized order items or fulfilment records.
- Existing records and legacy functions must remain compatible; use a forward-only migration plan.
- Callback handling must be idempotent and must validate provider signatures before changing state.

### 3.4 `public.asri_store_shipments` — fulfilment snapshot

Proposed fields:
- `id uuid primary key`
- `order_id uuid not null references asri_store_orders(id)`
- `carrier_code text null`
- `carrier_name text null`
- `tracking_number text null`
- `status text not null`
- `shipped_at timestamptz null`
- `delivered_at timestamptz null`
- `created_at timestamptz not null`
- `updated_at timestamptz not null`

### 3.5 `public.asri_store_shipment_events` — tracking timeline

Proposed fields:
- `id uuid primary key`
- `shipment_id uuid not null references asri_store_shipments(id)`
- `status text not null`
- `description text not null`
- `location text null`
- `event_at timestamptz not null`
- `source text not null`
- `created_at timestamptz not null`

Rules:
- Never invent carrier scans, delivery timestamps, or shipment events.
- Distinguish internal fulfilment events from verified carrier events using `source`.
- If shipping integration is not configured, return an explicit untracked/not-shipped state.

### 3.6 `public.asri_store_order_access_tokens` — guest access

Proposed fields:
- `id uuid primary key`
- `order_id uuid not null references asri_store_orders(id)`
- `token_hash text unique not null`
- `scope text not null` — e.g. `tracking:read` or `payment:create`
- `expires_at timestamptz not null`
- `revoked_at timestamptz null`
- `created_at timestamptz not null`

Security requirements:
- Generate cryptographically random tokens on the server; use separate tokens/scopes for tracking reads and payment initiation.
- Return raw token material only once at issuance. Persist only a cryptographic hash of the token.
- Tracking token proposal: expiry configurable, initially 90 days; revocable. Payment-initiation token proposal: short expiry, initially 30 minutes. These are proposed defaults, not locked requirements.
- Send tokens in POST request bodies, not URL query strings or paths. The frontend must not log tokens; set an appropriate `Referrer-Policy` and avoid third-party scripts on the tracking page.
- Apply rate limiting, generic unauthorized responses, expiry/revocation checks, and constant-time comparison where applicable.
- Tracking responses must return only customer-safe fields. Do not return full shipping address, internal notes, callback payloads, provider raw responses, secrets, or another customer's data.
- A bearer tracking token grants access to its specific order only; it is not an authentication session.

## 4. Proposed API contract

Base path is illustrative: `/functions/v1/store-v2`. Exact routing convention may change during implementation without changing the logical contract.

### 4.1 Product catalogue

**Read:** Supabase Data API using the public anon key, restricted by the existing RLS policy to active products.

- Query only required public columns.
- Do not expose payment tables or privileged credentials.
- Show explicit loading, error, and empty states.
- Do not fall back to hardcoded demo products when live mode is enabled.

### 4.2 `POST /orders` — create guest order

Request (illustrative):
```json
{
  "customer": {
    "name": "Customer name",
    "phone": "08xxxxxxxxxx",
    "email": null
  },
  "shipping": {
    "recipient": "Recipient name",
    "phone": "08xxxxxxxxxx",
    "addressLine": "Street and number",
    "district": null,
    "city": "City",
    "province": "Province",
    "postalCode": "00000",
    "notes": null,
    "method": "configured-method"
  },
  "items": [
    {
      "productId": "uuid",
      "quantity": 1,
      "variant": {}
    }
  ],
  "idempotencyKey": "client-generated-random-key"
}
```

Server responsibilities:
1. Validate payload shape, lengths, phone/address formats, quantity limits, and idempotency key.
2. Re-read active products, price, stock, and valid variants.
3. Calculate subtotal, configured shipping cost, and final total on the server.
4. Create order header, item snapshots, payment draft, and scoped access tokens consistently; roll back the entire operation if any required insert fails.
5. Return the order number, server-calculated totals, payment options or next-step hint, and raw scoped tokens only at issuance.
6. Never return database service credentials or provider secrets.

Response (illustrative):
```json
{
  "order": {
    "orderNumber": "display-id",
    "currency": "IDR",
    "subtotal": 100000,
    "shippingCost": 15000,
    "totalAmount": 115000,
    "status": "pending_payment",
    "paymentStatus": "pending"
  },
  "access": {
    "trackingToken": "returned-once",
    "paymentToken": "returned-once",
    "expiresAt": "ISO-8601 timestamp"
  }
}
```

The example is a shape illustration, not a real order or a fixed ID/amount.

### 4.3 `POST /orders/{orderNumber}/payments` — create payment attempt

Request:
```json
{
  "paymentToken": "opaque-token",
  "paymentMethod": "provider-supported-method",
  "idempotencyKey": "unique-attempt-key"
}
```

Server responsibilities:
- Validate token scope, expiry, revocation, and order binding.
- Load the order and authoritative total from the database; ignore any client-supplied amount.
- Check that the order is in a payable state.
- Create or return the existing attempt for the same idempotency key.
- Call Duitku sandbox from the server, persist provider identifiers and response fields that are safe to store, and return only the payment instructions/URLs needed by the client.
- Handle timeouts without blindly creating duplicate charges; reconcile by merchant order ID/status before retrying.

### 4.4 `POST /payments/status` — refresh payment status

Request:
```json
{
  "paymentToken": "opaque-token",
  "merchantOrderId": "server-issued-id"
}
```

- Verify token scope and that the payment attempt belongs to the associated order.
- Reconcile with the provider only from server-side code.
- Return the canonical status after the update has committed, not a stale pre-update value.
- Do not accept arbitrary order IDs as authorization.

### 4.5 `POST /tracking` — retrieve customer-visible tracking

Request:
```json
{
  "trackingToken": "opaque-token"
}
```

Response (illustrative):
```json
{
  "order": {
    "orderNumber": "display-id",
    "createdAt": "ISO-8601 timestamp",
    "status": "processing",
    "paymentStatus": "paid",
    "totalAmount": 115000,
    "currency": "IDR"
  },
  "items": [],
  "shipment": {
    "status": "not_shipped",
    "carrierName": null,
    "trackingNumber": null,
    "events": []
  }
}
```

- Return only the order associated with the validated token.
- Mask personal fields; do not return full street address or internal payment/provider data.
- If no shipment exists, return a truthful not-shipped state and an empty event list.
- Return generic unauthorized/not-found errors to reduce order enumeration.

## 5. Required server-side transaction and access controls

- Prefer a single database transaction (for example, a carefully reviewed RPC invoked by the Edge Function) for order header + item snapshots + payment draft + token hashes. Never implement a multi-insert sequence that can leave a half-created order.
- Review function privileges and RLS explicitly. New tables must not inherit accidental public access.
- Client roles should not receive direct write access to order, payment, token, callback, or shipment tables.
- Keep Duitku signing credentials and Supabase service-role credentials server-side only.
- Validate callback signatures before persistence/state mutation; make duplicate callbacks safe.
- Use explicit status transition rules and immutable audit/history records.
- Add rate limits and abuse monitoring for order creation, payment initiation, status refresh, and tracking.
- Do not store raw access tokens in database logs, application logs, analytics, or error messages.

## 6. Required fixes and sandbox verification before live UI integration

1. Resolve and test the partial unique-index conflict-target behavior used by callback upsert. Ensure duplicate callbacks are idempotent.
2. Fix/test status-check response consistency so it returns the canonical post-update status.
3. Confirm Duitku callback field semantics; do not map payment code to payment method without evidence.
4. Define supported callback result codes and test paid, failed, pending, expired/cancelled, malformed signature, duplicate event, and out-of-order event cases.
5. Confirm exact allowed frontend origin(s) and keep CORS restrictive.
6. Confirm payment retry behavior and provider reconciliation after timeout.
7. Verify server-side total calculation, concurrent stock behavior, idempotent order creation, and idempotent payment attempts.
8. Verify expired/revoked/wrong-scope token denial and ensure tracking cannot enumerate or read another order.
9. Populate a controlled sandbox catalogue fixture and test empty catalogue behavior separately.
10. Confirm the existing legacy `duitku` and `duitku-callback` functions are untouched.

## 7. Proposed implementation phases after approval

- **V2-A — Contract lock:** approve order lifecycle, shipping pricing, stock policy, token expiry, and payment retry policy.
- **V2-B — Schema migration draft:** write migration files on the feature branch only; review SQL, constraints, grants, RLS, indexes, rollback/forward-only approach. Do not apply to a live project yet.
- **V2-C — Server implementation:** create order/payment/tracking endpoints on an isolated sandbox path, preserve current function versions, and keep production credentials untouched.
- **V2-D — Automated verification:** unit/integration tests plus Duitku sandbox end-to-end tests for order creation, payment creation, callback idempotency, status reconciliation, and tracking access controls.
- **V2-E — Frontend adapter:** only after the contract and sandbox tests pass, replace demo data with API calls behind an explicit integration boundary and loading/empty/error states.
- **V2-F — Release review:** verify build and browser tests, review diffs, check secrets and RLS/grants, and obtain explicit release approval. No automatic production cutover.

## 8. Decisions required before implementation

1. **Guest identity:** approve guest checkout with opaque scoped tokens, or request a separately designed identity/session model.
2. **Shipping calculation:** fixed/configured rates, courier API quote, or manually configured shipping method.
3. **Stock policy:** reserve/decrement at order creation, reserve for a limited period, or decrement only after confirmed payment.
4. **Tracking-token lifetime:** approve proposed 90-day tracking token and 30-minute payment token, or specify alternatives.
5. **Payment retry:** allow a new attempt after a failed/expired attempt, with each attempt uniquely identified and provider reconciliation before retry.

Until these decisions are locked, no backend schema or Edge Function changes should be applied.

## 9. Acceptance criteria

- A guest can create an order without creating a password account.
- Server totals and item snapshots are authoritative.
- A repeated idempotency key does not create duplicate orders or duplicate payment attempts.
- Payment state and fulfilment state are separate.
- Callback verification and replay handling pass controlled sandbox tests.
- Tracking token is scoped, expiring, revocable, and cannot read another order.
- Payment/order/shipment tables remain inaccessible to anonymous direct reads/writes.
- Empty product catalogue is displayed honestly.
- No secret, production deployment, or legacy function is changed without explicit approval.
- CI build and browser tests pass on the exact final commit, and evidence is linked from the implementation log.
