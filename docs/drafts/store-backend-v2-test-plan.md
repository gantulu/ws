# Asri baseline and Store V2 isolated database test plan

## Safety boundary
- The test runner creates and destroys a disposable PostgreSQL container.
- It never connects to Supabase, uses no project ref, and reads no secrets.
- Baseline files remain in `docs/drafts/`; this workflow does not promote migrations.
- The Store V2 schema is loaded only after removing its review-only outer `BEGIN`/`ROLLBACK` wrapper.
- `store-backend-v2-atomic-contract-review.sql` is also review-only and is loaded only into the disposable database.

## Run
Requirements: Docker Engine and Bash.

```bash
bash scripts/test-store-schema-postgres.sh
```

Optional PostgreSQL image override:

```bash
POSTGRES_TEST_IMAGE=postgres:16 bash scripts/test-store-schema-postgres.sh
```

GitHub Actions runs the same script for relevant changes to `feat/store-mobile-v1-app` and pull requests.

## Atomic checkout contract
The server-only `public.asri_store_create_checkout(jsonb)` contract:
- serializes the same idempotency key using a transaction-scoped advisory lock;
- rejects reuse of a key with a different request fingerprint;
- resolves shipping from active/effective database rates (city > province > global);
- locks distinct product rows in deterministic UUID order;
- computes item prices, subtotal, shipping, and total from database values;
- writes order, immutable item snapshots, reservations, stock decrements, payment draft, token hashes, and initial history rows in one database transaction;
- returns existing order/payment IDs for a same-fingerprint retry;
- does not call Duitku. Provider API calls occur after the database transaction commits.

The caller must generate high-entropy raw guest tokens, pass only their cryptographic hashes to the RPC, and return raw tokens only once. Callback signature/amount/provider verification must happen before invoking the payment event contract. Do not expose either RPC to `anon` or `authenticated`.

## Payment transition contract
The server-only `public.asri_store_apply_payment_event(...)` contract:
- accepts only normalized states `pending`, `paid`, `failed`, `cancelled`, and `expired`;
- verifies the payment amount against the stored amount;
- serializes updates by merchant order ID and records callback fingerprints for deduplication;
- treats repeated fingerprints as no-ops;
- makes paid state monotonic for ordinary retries;
- releases reserved stock exactly once on a verified failed/cancelled/expired outcome;
- consumes existing reservations on timely verified payment without decrementing stock a second time;
- flags a verified late payment as `late_paid_manual_reconciliation` and does not silently resurrect an expired/cancelled order or consume released stock.

The caller must not use browser redirect/JS result as payment authority. Duitku callback verification and status reconciliation remain required before calling the RPC.

## Test coverage
- DDL application, 13 expected tables, RLS and key grants
- Catalog constraints, payment partial-index upsert, callback fingerprint uniqueness, history identity and snapshot immutability
- Atomic rollback when any requested product is unavailable
- Server-calculated subtotal/total and city-specific shipping-rate precedence
- Idempotent same-key/same-fingerprint checkout and rejection of fingerprint mismatch
- Payment pending -> paid transition, order confirmation, reservation consumption and duplicate callback no-op
- Expiry stock release and late-paid manual reconciliation behavior
- Two concurrent independent PostgreSQL sessions competing for the last unit; exactly one must commit and final stock must be zero

## Still not certified by this suite
- Duitku sandbox end-to-end HTTP calls and live provider signature compatibility
- Scheduled reservation expiry worker and operational retry/reconciliation delivery
- Guest token cryptographic entropy, hash verification, endpoint scope enforcement, revocation and leakage prevention
- All production grants/policies and integration with the eventual dedicated Asri Supabase project
- Migration promotion/release approval

A green suite is an isolated contract-test pass, not a full production release approval. Both baseline files remain drafts.
