# Store Mobile V1 — Locked Specification

- Repository: `gantulu/ws`
- Version: `Store Mobile V1`
- Status: **SPECIFICATION LOCKED — IMPLEMENTATION NOT STARTED**
- Target: mobile-only online store
- Workflow: `AUDIT → RECOMMEND → APPROVE → IMPLEMENT → VERIFY`

## 1. Scope

V1 defines four customer-facing pages:
1. `ProductPage` — product catalog.
2. `ProductDetailPage` — details for one product.
3. `CheckoutPage` — customer/shipping details, order summary, and payment initiation.
4. `TrackingPage` — order/payment/shipping status and status history.

This document locks the initial page structure and boundaries. It does not assert that frontend code, routes, or integrations already exist.

## 2. Routes

| Route | Page | Responsibility |
|---|---|---|
| `/products` | `ProductPage` | Browse products, search, filter by category, open a product |
| `/products/:slug` | `ProductDetailPage` | Product images, description, price, stock, variants, quantity, buy action |
| `/checkout` | `CheckoutPage` | Recipient details, address, shipping option/cost, order summary, total, payment method and payment initiation |
| `/tracking/:orderId` | `TrackingPage` | Order identifier, payment status, shipping status, status timeline |

## 3. Proposed source tree

```text
src/
├── App.jsx
├── components/
│   ├── AppHeader.jsx
│   ├── BottomNavigation.jsx
│   ├── ProductCard.jsx
│   ├── QuantitySelector.jsx
│   ├── OrderSummary.jsx
│   └── StatusTimeline.jsx
├── pages/
│   ├── ProductPage.jsx
│   ├── ProductDetailPage.jsx
│   ├── CheckoutPage.jsx
│   └── TrackingPage.jsx
├── data/
│   └── products.js
└── styles/
    └── index.css
```

This is a proposed tree, not a report of files currently present. Adapt only after repository audit and approval.

## 4. Page requirements

### ProductPage
- Display active products with image, name, and price.
- Provide basic search and category filtering.
- Product selection navigates to `/products/:slug`.
- Show a clear loading, empty, and error state when connected to a backend.

### ProductDetailPage
- Display product images, name, description, price, available stock, and supported variants.
- Allow quantity and available variant selection.
- Prevent quantities above available stock.
- Provide a clear action to proceed to checkout.

### CheckoutPage
- Collect and validate recipient name, phone, and delivery address.
- Show selected items, quantities, item subtotal, shipping cost, and final total.
- Do not trust a client-provided price or total; the backend must recalculate authoritative amounts.
- Display payment state and provide a safe retry/return path for pending or failed payment.
- Do not expose secret keys or privileged credentials in frontend code.

### TrackingPage
- Show order identifier, order status, payment status, and shipping status separately when applicable.
- Render status history from backend records; do not invent carrier scans or statuses.
- Handle unknown order IDs and unavailable tracking data without leaking another customer's data.

## 5. Mobile UI constraints

- Mobile-first layout; content width target up to approximately 500 px.
- Touch-friendly controls, readable text, and visible form validation.
- Bottom navigation may be used for primary browsing navigation; checkout and tracking must also work from direct links.
- Tailwind CSS is the proposed styling approach, subject to audit of the existing project stack.

## 6. Integration and safety boundaries

- Product catalog integration may use `public.asri_products` only after verifying schema, access policies, and repository/backend wiring.
- Duitku work must remain in sandbox until end-to-end tests pass and production is explicitly approved.
- Do not modify the legacy `duitku` Edge Function as part of this V1 specification.
- Do not introduce Supabase Auth unless explicitly approved.
- Custom authentication must not compare or store plaintext passwords; audit and design a secure compatible approach before implementation.
- Never commit credentials, API keys, tokens, or secret values.
- Preserve legacy tables until their consumers and migration path are mapped.
- No database, Edge Function, production configuration, or application implementation changes are authorized by this specification alone.

## 7. Acceptance criteria for implementation

- All four routes render correctly on mobile layouts.
- Navigation between product list, product detail, checkout, and tracking works.
- Product and checkout totals are sourced/recalculated by trusted backend logic.
- Loading, empty, validation, error, and pending-payment states are represented.
- Tracking data is scoped to the authorized order/customer.
- Sandbox payment creation, callback signature verification, idempotency, and status updates are tested before claiming payment integration complete.
- No secrets are committed and no unrelated legacy integration is changed.
- Verification results are reported with evidence; untested behavior is clearly marked.

## 8. Repository audit baseline

Initial inspection of `gantulu/ws` on `main` found only `README.md`. The README references `docs/duitku-v1.2-remediation.md`, but that path was not present in the inspected repository tree. No application source, package manifest, tests, or existing UI routes were found in that tree.

Audit status: **initial repository inventory complete; application integration audit still required**. Do not begin implementation until the relevant ASRI application repository and current backend contracts are audited and recommendations approved.
