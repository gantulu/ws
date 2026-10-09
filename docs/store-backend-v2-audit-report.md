# Store Backend V2 — Deep Audit Report

- Repository: `gantulu/ws`
- Branch: `feat/store-mobile-v1-app`
- Audit date: 2026-10-09
- Scope: repository, official Duitku API V2 documentation, connected Supabase schema/migration ledger, deployed `asri-duitku-sandbox` source, security advisors.
- Method: repository/API reads and Supabase read-only introspection. No secret values read, no production writes, no migration applied, no Edge Function deployed.

## Executive summary

The V1 storefront remains demo-only. Backend V2 cannot safely be connected to the frontend yet. The connected Supabase project contains unrelated application data and more than 40 recorded migrations, but the repository branch has no `supabase/` directory or checked-in migration baseline. The first implementation task is to capture/reconcile that baseline with the official Supabase CLI workflow, then apply the V2 design only to a disposable/local database or isolated development branch.

## Repository findings

- Existing routes and Playwright tests cover the mobile storefront; the UI uses demo data.
- `package.json` uses `latest` dependency tags and there is no committed lockfile; pin versions and commit a lockfile before a release candidate.
- Backend contract, plan, and schema SQL are documentation artifacts; the SQL file is under `docs/drafts/`, ends with `ROLLBACK`, and must never be executed as a migration.
- There is no checked-in Supabase project config, migration history, Edge Function source, or backend integration test harness in this branch.

## Live Supabase schema and migration evidence

- Migration ledger includes payment migrations such as `20261008101511_payment_core`, `20261008101517_duitku_v2`, `20261009060946_create_asri_duitku_payment_schema_v1`, and `20261009062138_create_asri_products_catalog`, plus many unrelated app migrations.
- `public.asri_products` had no products at the previous audit snapshot. Live mode must render an explicit empty state; never fall back silently to demo products.
- `public.asri_payment_orders.amount` is constrained to positive values. V2 rejects a computed total of zero.
- Live catalog introspection confirms only `asri_products` has an observed public SELECT policy (`is_active = true`, roles `anon` and `authenticated`). The payment tables have RLS enabled but no policies; `service_role` has broad table grants and the `postgres` owner has full privileges. No `anon`/`authenticated` table grants were returned for the payment tables. Reconfirm defaults and function-level privileges during baseline capture.
- Supabase security advisor reports `public.ns_invest` has RLS disabled while a policy exists. This is a separate live security issue; audit intended consumers before changing access behavior.
- The advisor also reports numerous functions with mutable `search_path`; prioritize privileged functions in a separate security pass.

## Duitku API V2 contract findings

Official source: [Duitku API V2 — Bahasa Indonesia](https://docs.duitku.com/api/id/).

- Inquiry: `POST https://sandbox.duitku.com/webapi/api/merchant/v2/inquiry`; production host is separate.
- Get payment methods: `POST /webapi/api/merchant/paymentmethod/getpaymentmethod`; signature string is `merchantCode + amount + datetime`, HMAC-SHA256.
- Inquiry signature string: `merchantCode + merchantOrderId + paymentAmount`, HMAC-SHA256.
- Callback signature string: `merchantCode + amount + merchantOrderId`, HMAC-SHA256. Callback uses form-urlencoded POST and should return HTTP 200 after successfully handling a valid event.
- Transaction status signature string: `merchantCode + merchantOrderId`, HMAC-SHA256. Current Indonesian docs describe `statusCode` as `00=Success`, `01=Pending`, `02=Canceled`. Callback `resultCode` is a different field: `00=Success`, `01=Failed`.
- Do not map callback `resultCode` and transaction status `statusCode` using the same enum. Avoid aggressive status polling; Duitku warns that excessive hits can be blocked for about an hour.
- Current API changelog includes HMAC signature updates (April 2026) and callback `customerName` (June 2026); code should follow the current Indonesian API V2 contract, not legacy MD5 examples.

## Deployed Edge Function — confirmed issues

Function `asri-duitku-sandbox` is active at version 4 with `verify_jwt=false`. It uses the sandbox host and server-side HMAC helper. Secret values were not inspected.

1. **Unsafe identity contract:** it reads `public.users` and compares the submitted password directly to the stored `password` value. V2 guest checkout must not reuse this pattern.
2. **Callback duplicate handling:** the callback event row is inserted before the payment/order state update. A duplicate fingerprint immediately returns HTTP 200 even if the first processing attempt failed after inserting the event. This can strand an unprocessed callback. Use a durable processing state/lease and retry-safe transactional processing.
3. **Non-atomic payment update:** transaction upsert, payment order update, status history insert, and callback processing marker are separate operations. A partial failure can leave inconsistent state. Move state transition + history + callback processing into a database transaction/RPC.
4. **Partial-index upsert:** transaction upsert targets `provider,provider_reference`; the observed unique index is partial for non-null references. Verify conflict inference on the actual database and prefer explicit tested deduplication logic.
5. **Stale status response:** status check updates the database but returns `order.status` from the pre-update row.
6. **Incorrect timeout semantics:** inquiry network exceptions can escape into the generic 500 handler without marking the outcome as unknown/reconcilable. Do not blindly retry a payment create when provider outcome is unknown.
7. **Callback state transitions:** a paid order is protected against downgrade, but other terminal/out-of-order states are not fully modeled. Unknown callback result codes currently map to pending; preserve the raw code and route unknown states to reconciliation.
8. **Error/observability:** raw provider error text may be returned/stored in places without a clear allowlist. Do not log secrets, tokens, or full sensitive payloads.

## Reusable Duitku contract helper implementation

Added `backend/store-v2/duitku-contract.mjs`, a runtime-portable helper module for HMAC-SHA256 signature inputs/creation, signature comparison, distinct callback/status-code mapping, and conservative payment transition decisions. Added Node 22 tests with independent `node:crypto` HMAC reference calculations. These helpers are not yet wired into the deployed Edge Function; wiring them requires the new versioned Store V2 function and the database transaction/RPC layer.

## SQL review draft revisions

The schema review draft now adds:
- request fingerprint beside the globally unique order idempotency key;
- rejection of zero-total orders to match the existing payment amount constraint;
- explicit RLS and privilege revocation from `PUBLIC`, `anon`, and `authenticated`;
- append-only triggers and no UPDATE/DELETE privileges for order/payment audit histories and item snapshots;
- deterministic shipping-rate selection contract;
- partial unique index for shipment event deduplication only when a source event ID exists;
- explicit note that atomic order/stock/payment/token creation requires a reviewed transaction/RPC and is not provided by DDL alone.

These are static design improvements, not a database migration. SQL syntax, trigger behavior, RLS/grants, row locks, race conditions, and rollback still require a real disposable PostgreSQL/Supabase environment.

## Next implementation sequence

1. Add static schema guards and reusable Duitku API V2 signature/status-transition helpers to CI. (Started on the feature branch.)
2. Capture remote schema/migration baseline using the official Supabase CLI in an isolated audit branch; inspect all existing consumers and grants.
3. Convert the reviewed DDL to a timestamped migration only after the baseline is reproducible and a local/isolated database run passes.
4. Implement atomic database RPCs for order creation/reservation, payment transition, callback deduplication, stock release/consume, and expiry.
5. Implement a new versioned store Edge Function; leave legacy functions untouched.
6. Test Duitku sandbox signatures, callback replay/failure/reordering, status reconciliation, payment timeout, and stock concurrency.
7. Connect the frontend only after backend integration tests pass. Current product catalogue is empty, so live mode must show an honest empty state.

## Official source of truth

- [Duitku API V2 (Bahasa Indonesia)](https://docs.duitku.com/api/id/)
- [Supabase database migrations](https://supabase.com/docs/guides/local-development/database-migrations)
- [Supabase Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security)
- [Supabase database functions and privileges](https://supabase.com/docs/guides/database/functions)
