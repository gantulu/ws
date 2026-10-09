# Asri Collection Baseline — Isolated Database Test Plan V1

- Target repo: `gantulu/ws`, branch `feat/store-mobile-v1-app`
- Inputs: `docs/drafts/asri-catalog-baseline-review.sql`, `docs/drafts/asri-payment-baseline-review.sql`
- Assertion file: `docs/drafts/asri-baseline-isolated-assertions.sql`
- Status: **PREPARED — NOT RUN**
- Safety boundary: local disposable Supabase only. Never point these commands at the connected legacy project or any hosted project.

## 1. Preconditions

- Install a current Supabase CLI and Docker.
- Confirm the repository branch and clean working tree.
- Use a disposable temporary directory, not the connected hosted project.
- Do not use `supabase link`, `supabase db push`, `supabase migration up --linked`, or any command that targets a hosted project.
- Do not copy any secret values into test logs.

## 2. Create a disposable local stack

Run these commands in a terminal. They initialize only a temporary local directory:

```bash
TEST_ROOT="$(mktemp -d)"
cd "$TEST_ROOT"
supabase init
supabase start
```

Keep the local database credentials generated/defaulted by the local Supabase stack. Do not link this directory to a remote project.

## 3. Create temporary local migrations

Generate the migration files using the CLI, then copy the reviewed draft contents into the generated files in the temporary directory. The catalog must precede payment because payment history/transaction tables reference payment orders.

```bash
supabase migration new asri_catalog_baseline
supabase migration new asri_payment_baseline
```

Copy from the repository drafts:
- `docs/drafts/asri-catalog-baseline-review.sql` → generated catalog migration file
- `docs/drafts/asri-payment-baseline-review.sql` → generated payment migration file

Remove only the review-only header comments in these temporary copies if desired; do not otherwise edit the SQL without recording the exact diff. Do not copy Store V2 DDL into this baseline test yet.

## 4. Apply only to the local disposable database

```bash
supabase db reset --local
```

This is the first DDL execution gate. If either migration fails, stop, record the error, fix the draft, recreate the temporary copies, and rerun from a clean local reset. Do not promote the draft after a partial/failed run.

## 5. Run database assertions

From the same temporary project, run the assertion SQL against the local database:

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
  -v ON_ERROR_STOP=1 \
  -f /path/to/repository/docs/drafts/asri-baseline-isolated-assertions.sql
```

If the local CLI reports a different local database URL or port, use the URL printed by `supabase status`. The assertions run inside a transaction and end with ROLLBACK; fixture rows must not persist.

## 6. Additional manual checks

- Inspect `supabase db diff --local` and ensure no unexpected objects were introduced.
- Confirm anon can read active products only, cannot write products, and cannot access any payment table.
- Confirm service_role can read/write intended payment tables.
- Confirm `updated_at` changes after product update.
- Confirm invalid amounts/statuses fail with constraint violations.
- Confirm partial unique indexes behave as expected with null and duplicate non-null values.
- Inspect the local migration history; no hosted migration ledger should be queried or changed as part of this test.

## 7. Pass criteria

All must be true:
1. Clean local reset applies both migrations without SQL errors.
2. Assertion SQL exits with status 0 and prints no failed assertions.
3. Catalog RLS, trigger, grants and constraint checks pass.
4. Payment table RLS, client denial, service-role grants, foreign keys, status/amount constraints and partial indexes pass.
5. Test fixture data is rolled back.
6. The tested SQL matches the current reviewed draft contents byte-for-byte after only the documented temporary header handling.

## 8. After passing

Only after evidence is attached to the branch:
1. Fix any separately identified issues in the Store V2 draft (including the PL/pgSQL delimiter defect).
2. Reconcile the full Store V2 schema against the passing baseline.
3. Create official timestamped migrations in `supabase/migrations/` using Supabase CLI, in a separate reviewed commit.
4. Re-run the complete local test suite against those exact migration files.
5. Do not create a hosted Asri project or apply migrations until separately instructed.
