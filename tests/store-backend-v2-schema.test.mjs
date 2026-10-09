import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const sql = await readFile(new URL("../docs/drafts/store-backend-v2-schema-review.sql", import.meta.url), "utf8");

test("schema artifact remains a non-executable review draft", () => {
  assert.match(sql, /REVIEW ONLY\. NOT A MIGRATION\. DO NOT EXECUTE/);
  assert.match(sql.trim(), /rollback;$/i);
  assert.doesNotMatch(sql, /commit;/i);
});

test("order idempotency binds a key to the original request fingerprint", () => {
  assert.match(sql, /idempotency_key text not null unique/i);
  assert.match(sql, /request_fingerprint text not null/i);
  assert.match(sql, /total_amount bigint not null check \(total_amount > 0\)/i);
});

test("private store tables enable RLS and revoke PUBLIC and client-role privileges", () => {
  const tables = [
    "asri_store_orders", "asri_store_order_items", "asri_store_order_status_history",
    "asri_store_shipping_rates", "asri_store_stock_reservations",
    "asri_store_order_access_tokens", "asri_store_shipments", "asri_store_shipment_events",
  ];
  for (const table of tables) {
    assert.match(sql, new RegExp(`alter table public\\.${table} enable row level security`, "i"), `${table}: RLS enabled`);
    assert.match(sql, new RegExp(`revoke all on public\\.${table} from public, anon, authenticated`, "i"), `${table}: no PUBLIC/client grants`);
  }
});

test("audit history and item snapshots cannot be updated or deleted by the application role", () => {
  assert.match(sql, /create trigger asri_store_order_status_history_immutable/i);
  assert.match(sql, /create trigger asri_store_shipment_events_immutable/i);
  assert.match(sql, /create trigger asri_store_order_items_immutable/i);
  for (const table of ["asri_store_order_status_history", "asri_store_shipment_events", "asri_store_order_items"]) {
    assert.match(sql, new RegExp(`revoke update, delete, truncate, references, trigger on public\\.${table} from public, anon, authenticated, service_role`, "i"));
  }
});

test("stock semantics reserve atomically and never decrement twice on payment", () => {
  assert.match(sql, /decrement available stock_quantity atomically in the same transaction/i);
  assert.match(sql, /do not decrement stock twice/i);
  assert.match(sql, /A reviewed server-side RPC\/transaction is required/i);
});

test("shipping resolution is deterministic and shipment event deduplication handles null provider IDs", () => {
  assert.match(sql, /Resolver contract: filter to active\/effective rows/i);
  assert.match(sql, /priority DESC, effective_from DESC, created_at DESC, id ASC/i);
  assert.match(sql, /where source_event_id is not null/i);
  assert.doesNotMatch(sql, /unique \(shipment_id, source, source_event_id\)/i);
});
