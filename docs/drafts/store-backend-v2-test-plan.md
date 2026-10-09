# Asri baseline and Store V2 isolated database test plan

## Safety boundary
- The test runner creates and destroys a disposable local PostgreSQL container.
- It never connects to Supabase, uses no project ref, and reads no secrets.
- Baseline files remain in `docs/drafts/`; this workflow does not promote migrations.
- The Store V2 draft is applied only after removing its review-only outer `BEGIN`/`ROLLBACK` wrapper, otherwise the rollback intentionally discards the DDL.

## Run
Requirements: Docker Engine and Bash.

```bash
bash scripts/test-store-schema-postgres.sh
```

Optional PostgreSQL image override:

```bash
POSTGRES_TEST_IMAGE=postgres:16 bash scripts/test-store-schema-postgres.sh
```

The GitHub Actions workflow runs the same script on relevant changes to `feat/store-mobile-v1-app`.

## Coverage
- DDL application to a clean PostgreSQL database
- Presence of all expected baseline and Store V2 tables
- RLS enabled and key client/server grants
- Catalog check constraints
- Payment transaction upsert against the unique partial index
- Callback event-fingerprint deduplication
- Payment status-history identity default
- Order-item immutability trigger
- Public catalog RLS visibility for active vs inactive products

## Explicitly not certified by this schema suite
- Atomic order creation + stock reservation + payment draft + token issuance
- Concurrent checkout against limited stock
- Payment callback/status race conditions and idempotent state transitions
- Token generation, hash validation, expiry, scope enforcement, revocation, and leakage prevention
- Duitku sandbox end-to-end requests
- Production grants/policies beyond the assertions listed above

These require implementation-level integration tests after the atomic server-side transaction/RPC and state-transition contracts are designed. A successful schema run must not be described as a full Store V2 release PASS.
