# Store Backend V2 — Implementation Plan for Review

- Repository: `gantulu/ws`
- Branch: `feat/store-mobile-v1-app`
- Design: Store Backend Contract V2 Draft 2
- Status: **PLAN ONLY — IMPLEMENTATION NOT AUTHORIZED**
- Approved contract decisions: guest checkout with scoped opaque tokens; separated order/payment/shipment states; server-configured fixed shipping rates; atomic stock reservation for 15 minutes; tracking token 90 days; payment token 30 minutes; retry only after confirmed failure/expiry and provider reconciliation.
- No database changes, Edge Function changes, frontend live integration, or deployment have been made as part of this plan.

## 1. Scope boundary

Included in the planned V2 implementation:
- New store-order domain tables and constraints.
- Fixed shipping-rate configuration managed server-side.
- Atomic stock reservation and release lifecycle.
- Hashed, scoped, expiring guest access tokens.
- Store-order creation, payment-attempt, payment-status, and tracking endpoints.
- Duitku sandbox callback/idempotency fixes and automated verification.
- Frontend integration only after backend contract and sandbox tests pass.

Explicitly excluded:
- Changes to `main` or production cutover.
- Modifying legacy `duitku` / `duitku-callback` functions.
- Reproducing phone/password comparison against `public.users.password`.
- Exposing payment, order, token, callback, or shipment tables to direct anonymous table queries.
- Refunds, courier API rate quoting, variant-level stock accounting, customer accounts, and unrelated legacy security remediation.

## 2. Phases and approval gates

### Phase A — Contract locked

Approved decisions are documented in [Store Backend Contract V2](store-backend-contract-v2-design.md). Any change to status names, stock semantics, token lifetime, shipping policy, or retry policy requires a versioned decision before implementation.

### Phase B — Migration review (current deliverable)

Review the separate draft SQL in [store-backend-v2-schema-review.sql](drafts/store-backend-v2-schema-review.sql). It is deliberately stored under `docs/drafts/`, not `supabase/migrations/`, and must not be run as-is.

Required before any migration is approved:
1. Confirm project migration ownership and source-of-truth: the live project lists migrations that are not all represented by this repository.
2. Reconcile existing schema, indexes, policies, grants, triggers, and all consumers of `asri_payment_orders`.
3. Review the full SQL diff line-by-line; decide whether shipping-rate data is seeded separately.
4. Run the proposed DDL on a disposable/local database or isolated Supabase development branch, never the live project.
5. Test constraints, RLS/grants, concurrency and rollback/forward-repair procedure.
6. Produce a clean, timestamped migration through the project's agreed Supabase CLI workflow only after approval.

### Phase C — Server endpoints (sandbox only)

Implement in a new isolated function path/version after the schema is approved:
1. `POST /orders`: validate request, load current active products, compute totals, validate configured shipping, reserve stock atomically, create order/item snapshots/payment draft/access token hashes, and enforce idempotency in one transaction.
2. `POST /orders/{orderNumber}/payments`: validate payment scope token; allow only one active attempt; create/reuse attempt by idempotency key; call Duitku sandbox.
3. `POST /payments/status`: reconcile the provider status, persist the transition, return the committed canonical status.
4. `POST /tracking`: validate tracking token and return a minimal customer-safe projection.
5. Internal callback path: verify signature, deduplicate event, validate state transition, update payment/order, and never let a late non-paid event downgrade a paid order.
6. Internal expiry/reconciliation job: expire unpaid reservations and payment attempts safely; release stock once; flag paid-after-expiry cases for manual resolution.

Do not alter the current ASRI sandbox function until its compatibility impact is reviewed. Prefer a new versioned function and explicit routing while preserving the old path.

### Phase D — Automated verification

Required test matrix:
- Valid/invalid product IDs, inactive products, invalid variants, quantity limits, empty catalogue.
- Server ignores manipulated client prices, totals, and shipping costs.
- Two concurrent orders competing for the last stock unit cannot oversell.
- Repeated order idempotency key returns the same order.
- Repeated payment idempotency key does not create duplicate attempts.
- Payment-create timeout reconciles the same merchant order before any retry.
- Valid/invalid Duitku signatures, duplicate callbacks, out-of-order callbacks, unknown result codes, late payment after stock release.
- Token valid, expired, revoked, wrong scope, wrong order, and brute-force/rate-limit scenarios.
- No anonymous/authenticated direct read/write access to order/payment/token/shipment data.
- Tracking response omits full address, phone/email, internal notes, raw callback/provider payload and secrets.
- Stock reservation expiry/release/consume is idempotent.
- Build and Playwright tests pass against the exact final commit.

### Phase E — Frontend adapter

Only after Phase C/D pass in sandbox:
- Add an explicit live/demo mode boundary; no silent demo fallback in live mode.
- Connect catalogue read to active products with loading/empty/error states.
- Replace demo checkout and tracking calls with the documented API contract.
- Preserve mobile UI and route behavior.
- Do not expose service-role or Duitku secret values in frontend env vars or bundles.

### Phase F — Release review

Requires a separate explicit release approval. Review final diff, security advisors, grants/RLS, callback behavior, secret handling, browser tests, rollback plan, and environment separation. No production deployment is implied by approval of this plan.

## 3. Current blockers and dependencies

- The audited `asri_products` catalogue was empty (0 active products); a controlled sandbox fixture is needed for end-to-end tests.
- Existing payment tables/functions are service-role-only and the current create endpoint requires a pre-existing draft row.
- Current custom identity logic compares a stored password directly; V2 must not reuse it.
- The live Supabase project migration history includes unrelated app migrations and is not fully represented by this repository. Do not infer that this repo can safely apply migrations to the live project.
- The callback upsert conflict-target issue and stale status response require a tested fix.
- Existing product stock is tracked at product level; per-size/per-color inventory is not represented by the audited `stock_quantity` field. V2 must reject unsupported variant inventory assumptions until a separate variant stock model is approved.

## 4. Proposed acceptance gates

| Gate | Evidence required | Approval required |
|---|---|---|
| Schema review | Reviewed SQL diff, schema compatibility notes, RLS/grants checklist | Yes, before migration creation/application |
| Sandbox server | Endpoint contract tests and sandbox logs without secrets | Yes, before frontend live integration |
| Frontend adapter | CI build, Playwright suite, explicit live-mode empty/error states | Yes, before merge/release |
| Production release | Security review, callback/idempotency evidence, rollback plan | Separate explicit approval |

## 5. Safety statement

This document is a plan. The accompanying SQL is a review draft only, not a Supabase migration. No database operation, Edge Function deployment, live frontend integration, production configuration change, or deployment is authorized by this document.
