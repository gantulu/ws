#!/usr/bin/env bash
set -Eeuo pipefail

# Disposable PostgreSQL only. This script never reads or writes Supabase.
# Requires Docker. All containers are removed on exit.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER_NAME="asri-schema-test-${RANDOM}-$$"
DB_NAME="asri_schema_test"
DB_USER="postgres"
DB_PASSWORD="local-only-test-password"
IMAGE="${POSTGRES_TEST_IMAGE:-postgres:16}"

cleanup() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[1/6] Starting disposable PostgreSQL container ($IMAGE)"
docker run --rm -d --name "$CONTAINER_NAME" \
  -e POSTGRES_PASSWORD="$DB_PASSWORD" \
  -e POSTGRES_DB="$DB_NAME" \
  -p 127.0.0.1::5432 \
  "$IMAGE" >/dev/null

ready=0
for attempt in $(seq 1 40); do
  if docker exec "$CONTAINER_NAME" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [[ "$ready" != 1 ]]; then
  echo "FAIL: disposable PostgreSQL did not become ready" >&2
  docker logs "$CONTAINER_NAME" >&2 || true
  exit 1
fi

psql_stdin() {
  docker exec -i "$CONTAINER_NAME" psql -X -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" "$@"
}
psql_scalar() {
  docker exec "$CONTAINER_NAME" psql -X -A -t -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" -c "$1"
}

echo "[2/6] Creating Supabase-like roles in disposable DB"
psql_stdin <<'SQL'
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN BYPASSRLS;
SQL

echo "[3/6] Applying catalog and payment review drafts to disposable DB"
psql_stdin < "$ROOT_DIR/docs/drafts/asri-catalog-baseline-review.sql"
psql_stdin < "$ROOT_DIR/docs/drafts/asri-payment-baseline-review.sql"

echo "[4/6] Applying Store V2 draft without its review-only BEGIN/ROLLBACK wrapper"
# The draft's wrapper is intentionally not executed as written: final ROLLBACK
# would discard all DDL. Run the reviewed DDL as a test transaction instead.
sed '/^[[:space:]]*begin;[[:space:]]*$/Id; /^[[:space:]]*rollback;[[:space:]]*$/Id' \
  "$ROOT_DIR/docs/drafts/store-backend-v2-schema-review.sql" | psql_stdin

echo "[5/6] Creating active/inactive catalog fixtures"
psql_stdin <<'SQL'
INSERT INTO public.asri_products (sku, slug, name, price, stock_quantity, is_active)
VALUES
  ('TEST-ACTIVE', 'test-active', 'Active fixture', 1000, 3, true),
  ('TEST-INACTIVE', 'test-inactive', 'Inactive fixture', 1000, 3, false);
SQL

echo "[6/6] Running schema, constraints, index, trigger, and access assertions"
psql_stdin < "$ROOT_DIR/scripts/sql/asri-schema-assertions.sql"

visible="$(psql_scalar "SET ROLE anon; SELECT count(*) FROM public.asri_products;")"
if [[ "$visible" != "1" ]]; then
  echo "FAIL: anon should see exactly one active product; got: $visible" >&2
  exit 1
fi

echo "PASS: isolated PostgreSQL schema suite completed."
echo "NOTE: this suite does not certify concurrent checkout/reservation behavior; the draft has no atomic stock-reservation RPC yet."
