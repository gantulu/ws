# ASRI Duitku V1.2 — Remediation Design & Sandbox Plan

**Status:** Design prepared; implementation and sandbox E2E are not yet run  
**Version:** V1.2  
**Workspace repository:** `gantulu/ws`  
**Application repository under review:** `gantulu/asri`  
**Integration:** Duitku API V2 + Supabase Edge Function  
**Scope:** R3 full remediation + sandbox validation

## 1. Safety and execution boundaries

1. Treat Supabase project `oszqantvugvbvydlizix` (currently named `No signal`) as a candidate only. Confirm it is the ASRI project before any database or Edge Function mutation.
2. Do not change production configuration or secrets. Sandbox credentials must be configured in the sandbox environment through the secret manager, never committed to Git.
3. Do not drop, rename, or merge legacy tables until repository consumers, views, triggers, policies, and jobs have been mapped.
4. Keep the requested custom phone/password authentication model; do not introduce Supabase Auth without a separate decision.
5. All changes should be made on a branch and reviewed via pull request before merging/deployment.
6. This repository holds the remediation plan and test artifacts; it is not a substitute for the actual ASRI app repository or Supabase project.

## 2. Audit findings carried forward

### P0 — Security and payment integrity

- `public.payments` has a public SELECT policy with predicate `true`, allowing broad reads of payment records.
- `public.ns_invest` has RLS disabled while containing sensitive profile, password, balance, banking, and verification fields. Confirm ownership and all consumers before enabling restrictive policies.
- `public.rls_auto_enable()` and `public.update_investment()` are SECURITY DEFINER functions reported executable by `anon` and `authenticated`. Inspect function bodies and dependencies; revoke broad EXECUTE grants unless explicitly required.
- The Duitku `/create` flow accepts the payment amount from the frontend. The server must calculate/validate the total from trusted product, quantity, discount, and shipping data or a previously trusted order record.
- Callback processing must be made idempotent and atomic across order, transaction, and callback records. A repeated callback must not double-apply state changes or downgrade a paid order.

### P1 — Consistency and authentication

- The `/status` route must check database write errors and keep order and transaction records consistent.
- A provider inquiry may succeed while persisting the result fails; add explicit recovery/reconciliation behavior.
- Validate state transitions and reject unknown provider statuses. Paid orders must never be downgraded by stale callbacks/status responses.
- Audit custom authentication end-to-end. If stored passwords are plaintext or reversibly encoded, migrate to a modern password hash; add rate limiting and generic login errors.
- `verify_jwt=false` is configured for the function. The public callback is expected, but every non-callback route must enforce application-level authentication and ownership checks.
- RLS being enabled on `payment_orders`, `payment_transactions`, and `payment_callbacks` does not itself prove that access is correctly constrained; inspect and test all policies.

## 3. Target architecture

### 3.1 Create payment

1. Authenticate the customer using the existing custom-auth contract.
2. Validate that the customer owns the cart/order and that each product is active and purchasable.
3. Recalculate line totals, discounts, shipping, and grand total on the server using trusted database values. Never trust client-supplied prices or grand totals.
4. Create a unique merchant order ID and persist a pending order before calling Duitku.
5. Call Duitku inquiry using server-side sandbox credentials and the official API contract.
6. Persist provider reference, payment URL/payment instructions, expiry, and provider status. If persistence fails after provider inquiry succeeds, log a redacted diagnostic and support reconciliation without creating duplicate charges.
7. Return only the minimum payment data required by the client.

### 3.2 Callback processing

1. Accept the callback without JWT only because the payment provider must be able to reach it.
2. Parse the documented callback content type; validate required fields and signature using the exact Duitku contract.
3. Verify merchant code, merchant order ID, expected amount, provider reference, and compatible transaction state.
4. Record the callback as an audit event, including signature validity and processing outcome; redact unnecessary personal data and secrets.
5. Process order and transaction updates in one database transaction, ideally through a narrowly scoped database function/RPC with fixed `search_path` and minimal EXECUTE grants.
6. Enforce idempotency using stable provider/order identifiers and uniqueness constraints. Replays should return the provider-expected acknowledgement without duplicating side effects.
7. Never change `paid` to `failed`, `cancelled`, or `pending` due to a stale or duplicate event.
8. Return the exact acknowledgement required by Duitku documentation. Do not treat a browser return URL as payment confirmation.

### 3.3 Status reconciliation

1. Authenticate the requester and verify order ownership before revealing order status.
2. Query the official Duitku transaction-status endpoint from the server.
3. Validate merchant order ID, amount and provider response fields against stored order data.
4. Apply only valid state transitions and update order/transaction rows atomically.
5. Check and handle every database error. Record a redacted reconciliation event when provider status and local state disagree.

### 3.4 Database access policies

- Remove the public `payments` SELECT policy only after mapping all app consumers; replace it with least-privilege access.
- For customer-facing reads, expose only fields needed by the owner, using the authenticated custom identity verified server-side. Do not assume a client-supplied user ID is trustworthy.
- Keep callback and provider transaction audit tables server-only unless a concrete read requirement is documented.
- For `ns_invest`, confirm whether it belongs to ASRI. If unrelated, do not change it as part of this payment remediation; track it separately with its own owner.
- Audit all SECURITY DEFINER functions for fixed `search_path`, input validation, least privilege, and unnecessary grants.
- Never put service-role credentials or Duitku API keys in client code, repository files, logs, or API responses.

## 4. Status transition policy

Expected minimum rules:

| Current status | Incoming status | Rule |
|---|---|---|
| pending | paid | Accept only after verified provider evidence |
| pending | failed | Accept only from verified provider evidence |
| pending | cancelled / expired | Accept only under documented provider/order rules |
| paid | pending / failed / cancelled | Reject downgrade; alert for reconciliation |
| failed / cancelled / expired | paid | Do not blindly accept; verify provider status and handle explicitly |
| any | unknown | Reject or quarantine; do not mutate order state |

Exact Duitku result/status codes and allowed transitions must be cross-checked against the current official API documentation before implementation.

## 5. Sandbox test matrix

All tests must use sandbox merchant credentials and non-production data. Record request/response status, database state, and redacted logs. Never store secrets in test fixtures.

| ID | Scenario | Expected result |
|---|---|---|
| SBX-01 | Valid create request with server-calculated amount | One pending order and one provider inquiry |
| SBX-02 | Client tampers with price or grand total | Server ignores/rejects tampered total |
| SBX-03 | Missing/invalid application authentication on create/status | 401/403; no payment mutation |
| SBX-04 | Customer requests another user's order | 403/404; no sensitive data leaked |
| SBX-05 | Valid successful callback | Order becomes paid once; transaction is consistent |
| SBX-06 | Same successful callback replayed | Idempotent acknowledgement; no duplicate side effect |
| SBX-07 | Invalid callback signature | Rejected; order remains unchanged; audit outcome recorded |
| SBX-08 | Wrong merchant code | Rejected; order remains unchanged |
| SBX-09 | Callback amount differs from stored order | Rejected/quarantined; order remains unchanged |
| SBX-10 | Failed/cancelled callback after order is paid | Paid state is not downgraded |
| SBX-11 | Provider inquiry succeeds but local persistence fails | Recoverable error/reconciliation path; no silent success |
| SBX-12 | Status query returns provider failure/unknown status | No unsafe state transition; diagnostic recorded |
| SBX-13 | Database write fails during callback processing | Entire state mutation rolls back; retry is safe |
| SBX-14 | Public/anonymous client reads payment tables | No unrestricted customer/payment data is exposed |
| SBX-15 | Execute privileged functions as anon/authenticated | Denied unless explicitly required and reviewed |
| SBX-16 | Password storage/login audit | No plaintext/reversible password storage; rate limit verified |

## 6. Acceptance criteria

- [ ] Confirmed correct Supabase project and isolated sandbox environment.
- [ ] No production secrets or payment credentials committed.
- [ ] Public payment data exposure removed and verified with anonymous access tests.
- [ ] `ns_invest` ownership confirmed; RLS remediation either scoped safely or separated.
- [ ] SECURITY DEFINER functions reviewed and EXECUTE grants minimized.
- [ ] Payment amount is server-derived and resistant to client tampering.
- [ ] Callback signature, merchant, order, amount, and provider references are validated.
- [ ] Callback handling is atomic, idempotent, and replay-safe.
- [ ] Status reconciliation checks all database errors and enforces valid transitions.
- [ ] Custom authentication remains in place and has secure password storage and rate limiting.
- [ ] Sandbox tests SBX-01 through SBX-16 have recorded outcomes.
- [ ] Static analysis, type/lint checks, and relevant tests pass.
- [ ] Changes are reviewed in a pull request before merge/deployment.

## 7. Official references

- Duitku API documentation (Indonesia): https://docs.duitku.com/api/id/
- Duitku Pop documentation: https://docs.duitku.com/pop/id/
- Supabase database overview: https://supabase.com/docs/guides/database/overview
- Supabase Row Level Security: https://supabase.com/docs/guides/database/postgres/row-level-security
- Supabase Edge Functions: https://supabase.com/docs/guides/functions
- Supabase Edge Function secrets: https://supabase.com/docs/guides/functions/secrets
- Supabase Edge Function auth: https://supabase.com/docs/guides/functions/auth
- Supabase Edge Function auth headers: https://supabase.com/docs/guides/functions/auth-headers

## 8. Current verification state

- Repository `gantulu/ws` initialized for this work.
- This document is a remediation design and test plan, not a claim that the code or database has been fixed.
- No sandbox transaction has been executed as part of this document creation.
- No Supabase schema, Edge Function, or secret has been modified.
