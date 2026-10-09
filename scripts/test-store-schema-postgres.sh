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
  docker exec "$CONTAINER_NAME" psql -X -q -A -t -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" -c "$1"
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

echo "[5/7] Creating active/inactive catalog fixtures"
psql_stdin <<'SQL'
INSERT INTO public.asri_products (sku, slug, name, price, stock_quantity, is_active)
VALUES
  ('TEST-ACTIVE', 'test-active', 'Active fixture', 1000, 3, true),
  ('TEST-INACTIVE', 'test-inactive', 'Inactive fixture', 1000, 3, false);
SQL

echo "[6/7] Running schema, constraints, index, trigger, and access assertions"
psql_stdin < "$ROOT_DIR/scripts/sql/asri-schema-assertions.sql"

visible="$(psql_scalar "SET ROLE anon; SELECT count(*) FROM public.asri_products;")"
if [[ "$visible" != "1" ]]; then
  echo "FAIL: anon should see exactly one active product; got: $visible" >&2
  exit 1
fi

echo "[7/7] Applying atomic contract and running Store V2 integration/concurrency tests"
psql_stdin < "$ROOT_DIR/docs/drafts/store-backend-v2-atomic-contract-review.sql"
psql_stdin < "$ROOT_DIR/scripts/sql/asri-store-integration-assertions.sql"

# Race two independent database sessions for the single remaining stock unit.
# Exactly one checkout must commit; the other must fail for insufficient stock.
TMP_A="$(mktemp)"
TMP_B="$(mktemp)"
cleanup() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  rm -f "${TMP_A:-}" "${TMP_B:-}"
}
trap cleanup EXIT

concurrent_checkout() {
  local suffix="$1"
  local output="$2"
  docker exec "$CONTAINER_NAME" psql -X -q -A -t -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$DB_NAME" -c "
    select pg_sleep(0.25);
    select * from public.asri_store_create_checkout(jsonb_build_object(
      'order_number','IT-CONCURRENT-${suffix}',
      'idempotency_key','it-concurrent-key-${suffix}',
      'request_fingerprint','it-concurrent-fp-${suffix}',
      'merchant_order_id','IT-CONCURRENT-PAY-${suffix}',
      'customer_name','Concurrent Customer',
      'customer_phone','081234567890',
      'shipping_recipient','Concurrent Recipient',
      'shipping_phone','081234567890',
      'shipping_address_line','Test Address 123',
      'shipping_city','Makassar',
      'shipping_province','Sulawesi Selatan',
      'shipping_postal_code','90111',
      'shipping_method','TEST-COURIER',
      'payment_token_hash','hash-payment-concurrent-${suffix}',
      'tracking_token_hash','hash-tracking-concurrent-${suffix}',
      'items',jsonb_build_array(jsonb_build_object(
        'product_id',(select id::text from public.asri_products where sku='IT-CONCURRENT-LAST'),
        'quantity',1
      ))
    ));
  " >"$output" 2>&1
}

set +e
concurrent_checkout A "$TMP_A" &
PID_A=$!
concurrent_checkout B "$TMP_B" &
PID_B=$!
wait "$PID_A"; RC_A=$?
wait "$PID_B"; RC_B=$?
set -e

if [[ "$RC_A" -eq 0 && "$RC_B" -eq 0 ]]; then
  echo "FAIL: both concurrent checkouts succeeded for one stock unit" >&2
  cat "$TMP_A" "$TMP_B" >&2
  exit 1
fi
if [[ "$RC_A" -ne 0 && "$RC_B" -ne 0 ]]; then
  echo "FAIL: both concurrent checkouts failed" >&2
  cat "$TMP_A" "$TMP_B" >&2
  exit 1
fi
if [[ "$RC_A" -ne 0 ]] && ! grep -q 'insufficient_stock' "$TMP_A"; then
  echo "FAIL: checkout A failed for an unexpected reason" >&2
  cat "$TMP_A" >&2
  exit 1
fi
if [[ "$RC_B" -ne 0 ]] && ! grep -q 'insufficient_stock' "$TMP_B"; then
  echo "FAIL: checkout B failed for an unexpected reason" >&2
  cat "$TMP_B" >&2
  exit 1
fi
if [[ "$(psql_scalar "SELECT stock_quantity FROM public.asri_products WHERE sku='IT-CONCURRENT-LAST';")" != "0" ]]; then
  echo "FAIL: concurrent checkout stock result was not exactly zero" >&2
  exit 1
fi
if [[ "$(psql_scalar "SELECT count(*) FROM public.asri_store_orders WHERE order_number IN ('IT-CONCURRENT-A','IT-CONCURRENT-B');")" != "1" ]]; then
  echo "FAIL: expected exactly one committed concurrent order" >&2
  exit 1
fi

echo "PASS: isolated PostgreSQL schema, atomic checkout, payment transitions, rollback, callback idempotency, late-paid handling, and last-unit concurrency tests completed."
