# Store Backend V2 — Implementation Plan for Review

- Repository: `gantulu/ws`
- Branch: `feat/store-mobile-v1-app`
- Design: Store Backend Contract V2 Draft 2
- Status: **ACTIVE IMPLEMENTATION PLAN — REPOSITORY/SANDBOX WORK PROCEEDS; LIVE MIGRATION BLOCKED UNTIL BASELINE RECONCILIATION**
- Approved contract decisions: guest checkout with scoped opaque tokens; separated order/payment/shipment states; server-configured fixed shipping rates; atomic stock reservation for 15 minutes; tracking token 90 days; payment token 30 minutes; retry only after confirmed failure/expiry and provider reconciliation.
- No database changes, Edge Function changes, frontend live integration, or deployment have been made as part of this plan.

## 1. Scope boundary

Included in the planned V2 implementation:
- New store-order domain tables and constraints, including append-only order status history.
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

## 2. Execution phases and safety gates

### Phase A — Contract baseline

The approved decisions are documented in [Store Backend Contract V2](store-backend-contract-v2-design.md). Preserve those decisions. If code-level evidence proves a contract change is necessary, document the evidence and version the contract rather than silently changing behavior.

### Phase B — Migration review (current deliverable)

Review the separate draft SQL in [store-backend-v2-schema-review.sql](drafts/store-backend-v2-schema-review.sql). It is deliberately stored under `docs/drafts/`, not `supabase/migrations/`, and must not be run as-is.

Required before creating/applying a migration:
1. Reconcile the live migration ledger against repository migration files. The current repository branch has no `supabase/` directory, while the linked project has 40+ migration records; the project/repository source of truth is therefore not yet reproducible from this branch.
2. Capture the remote schema baseline with the official Supabase CLI workflow (`supabase db pull`) into a separate audit branch; review the generated diff and ownership before treating it as canonical.
3. Reconcile existing schema, indexes, policies, grants, triggers, and every consumer of `asri_payment_orders`.
4. Run the corrected DDL on a disposable/local database or isolated Supabase development branch, never directly against the live project.
5. Test constraints, grants/RLS, trigger behavior, concurrency, idempotency, and forward-repair/rollback procedure.
6. Generate a timestamped migration using the official Supabase CLI workflow; commit the migration and test evidence together. No repeated approval prompts are required for these repository and isolated-environment steps.

### Phase C — Server endpoints (sandbox only)

Implement in a new isolated function path/version after the schema baseline is reproducible and the local/branch schema tests pass:
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

After Phase C/D pass in sandbox:
- Add an explicit live/demo mode boundary; no silent demo fallback in live mode.
- Connect catalogue read to active products with loading/empty/error states.
- Replace demo checkout and tracking calls with the documented API contract.
- Preserve mobile UI and route behavior.
- Do not expose service-role or Duitku secret values in frontend env vars or bundles.

### Phase F — Release review

Review final diff, security advisors, grants/RLS, callback behavior, secret handling, browser tests, rollback plan, and environment separation. Proceed through repository and isolated/sandbox stages without repeated approval prompts. Do not infer production deployment from sandbox success.

## 3. Current blockers and dependencies

- The audited `asri_products` catalogue was empty (0 active products); a controlled sandbox fixture is needed for end-to-end tests. The live storefront must remain empty-state-only until products are deliberately published.
- Existing payment tables/functions are service-role-only and the current create endpoint requires a pre-existing draft row.
- Current custom identity logic compares a stored password directly; V2 must not reuse it.
- The live Supabase project migration history contains 40+ migrations, while this repository branch has no `supabase/` directory. The repository is not yet a complete migration source of truth; first capture/reconcile the remote baseline using the official Supabase CLI migration workflow.
- The callback path has multiple correctness issues requiring fixes: partial-index conflict inference, status response from a stale pre-update row, callback result-code mapping, incorrect use of `paymentCode` as payment method, duplicate callback handling before verifying that the event belongs to a valid order, and non-atomic order/history/transaction updates.
- The existing payment table enforces `amount > 0`; the first release rejects zero-total orders. A zero-payment flow is outside V2.
- Existing product stock is tracked at product level; per-size/per-color inventory is not represented by the audited `stock_quantity` field. V2 must reject unsupported variant inventory assumptions until a separate variant stock model exists.
- Duitku API V2's current docs use HMAC-SHA256 for inquiry/callback/status signatures. `transactionStatus` status codes differ from callback `resultCode`; preserve separate mappings. Do not poll status aggressively because Duitku documents rate limits.
- The Supabase security advisor reports `public.ns_invest` has RLS disabled despite a policy existing. This is unrelated to the store schema but is a live security finding; do not silently change access behavior without auditing intended consumers/policies.

## 4. Verification gates (execution proceeds automatically where safe)

| Gate | Evidence required | Next action |
|---|---|---|
| Schema baseline | Remote migration ledger reconciled with versioned repository baseline | Continue migration design only when reproducible |
| Schema sandbox | DDL applies cleanly; grants/RLS and constraints pass; concurrency test proves no oversell | Generate the versioned migration and continue server work |
| Sandbox server | Endpoint contract tests and Duitku sandbox evidence without secrets | Continue frontend adapter after backend contract passes |
| Frontend adapter | CI build, Playwright suite, explicit live-mode empty/error states | Prepare release candidate |
| Production release | Security review, callback/idempotency evidence, rollback plan and environment verification | Deploy only to the explicitly configured target; never substitute production for sandbox tests |

## 5. Current execution status and safety statement

The accompanying SQL remains a review draft, not a migration. Repository implementation, documentation, static tests, and isolated/local tests may proceed without asking for approval at every step. The current connected Supabase project is a live project with unrelated application data and a migration ledger not represented in this repository. Do not apply the proposed DDL to that project until a reproducible baseline and an isolated test result exist. This is a technical safety gate, not a request for repeated user approval. Do not read or print secret values. Do not deploy an untested function or connect the storefront to live writes before the server contract passes sandbox verification.
