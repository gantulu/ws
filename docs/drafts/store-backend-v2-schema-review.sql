-- STORE BACKEND V2 SCHEMA REVIEW DRAFT
-- STATUS: REVIEW ONLY. NOT A MIGRATION. DO NOT EXECUTE.
-- Intentionally stored under docs/drafts/, outside supabase/migrations/.
-- Must be reconciled with the live schema, all consumers, grants, policies,
-- and migration ownership before conversion into a real migration.
--
-- Design decisions already approved:
-- guest checkout + scoped opaque tokens; separate order/payment/shipment status;
-- server-configured fixed shipping rates; 15-minute stock reservation;
-- tracking token 90 days; payment token 30 minutes; retry only after confirmed
-- failure/expiry and provider reconciliation.
--
-- Important implementation dependency:
-- Order creation + stock reservation + item snapshots + payment draft + token
-- hashes must be atomic. This DDL alone does NOT provide that transaction.
-- A reviewed server-side RPC/transaction is required before endpoints are usable.

begin;

-- 1) Store order header. Money is integer IDR. Client-supplied totals are never authoritative.
create table public.asri_store_orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique,
  idempotency_key text not null unique,
  order_status text not null default 'pending_payment'
    check (order_status in (
      'pending_payment', 'confirmed', 'processing', 'shipped',
      'delivered', 'cancelled', 'expired'
    )),
  payment_status text not null default 'unpaid'
    check (payment_status in (
      'unpaid', 'pending', 'paid', 'failed', 'expired', 'cancelled', 'refunded'
    )),
  customer_name text not null,
  customer_phone text not null,
  customer_email text,
  shipping_recipient text not null,
  shipping_phone text not null,
  shipping_address_line text not null,
  shipping_district text,
  shipping_city text not null,
  shipping_province text not null,
  shipping_postal_code text not null,
  shipping_notes text,
  shipping_method text not null,
  shipping_rate_snapshot jsonb not null default '{}'::jsonb,
  shipping_cost bigint not null check (shipping_cost >= 0),
  subtotal bigint not null check (subtotal >= 0),
  total_amount bigint not null check (total_amount >= 0),
  currency text not null default 'IDR' check (currency = 'IDR'),
  stock_reservation_expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (total_amount = subtotal + shipping_cost)
);

create index asri_store_orders_created_at_idx
  on public.asri_store_orders (created_at desc);
create index asri_store_orders_payment_status_idx
  on public.asri_store_orders (payment_status, created_at);

-- 2) Immutable purchase snapshots. Product ID is UUID in audited asri_products.
create table public.asri_store_order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.asri_store_orders(id) on delete restrict,
  product_id uuid references public.asri_products(id) on delete set null,
  sku_snapshot text,
  product_name_snapshot text not null,
  variant_snapshot jsonb not null default '{}'::jsonb,
  unit_price bigint not null check (unit_price >= 0),
  quantity integer not null check (quantity > 0),
  line_total bigint not null check (line_total >= 0),
  created_at timestamptz not null default now(),
  check (line_total = unit_price * quantity)
);
create index asri_store_order_items_order_id_idx
  on public.asri_store_order_items (order_id);

-- 3) Server-managed shipping rate configuration. No public writes.
create table public.asri_store_shipping_rates (
  id uuid primary key default gen_random_uuid(),
  method_code text not null,
  method_name text not null,
  destination_province text,
  destination_city text,
  price bigint not null check (price >= 0),
  currency text not null default 'IDR' check (currency = 'IDR'),
  is_active boolean not null default true,
  effective_from timestamptz not null default now(),
  effective_until timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (effective_until is null or effective_until > effective_from)
);
create index asri_store_shipping_rates_lookup_idx
  on public.asri_store_shipping_rates
  (method_code, destination_province, destination_city, is_active);

-- 4) Stock reservation ledger. Reservation creation must lock product rows and
-- decrement available stock_quantity atomically in the same transaction.
-- 'consumed' means the reserved units were sold; do not decrement stock twice.
create table public.asri_store_stock_reservations (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.asri_store_orders(id) on delete restrict,
  order_item_id uuid not null references public.asri_store_order_items(id) on delete restrict,
  product_id uuid not null references public.asri_products(id) on delete restrict,
  quantity integer not null check (quantity > 0),
  status text not null default 'reserved'
    check (status in ('reserved', 'consumed', 'released', 'expired')),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  released_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (order_item_id)
);
create index asri_store_stock_reservations_expiry_idx
  on public.asri_store_stock_reservations (status, expires_at);

-- 5) Guest bearer tokens. Store only hashes; raw token is returned once by server.
create table public.asri_store_order_access_tokens (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.asri_store_orders(id) on delete restrict,
  token_hash text not null unique,
  scope text not null check (scope in ('tracking:read', 'payment:create')),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  last_used_at timestamptz,
  created_at timestamptz not null default now()
);
create index asri_store_order_access_tokens_order_scope_idx
  on public.asri_store_order_access_tokens (order_id, scope, expires_at)
  where revoked_at is null;

-- 6) Shipment state and carrier/tracking snapshot.
create table public.asri_store_shipments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.asri_store_orders(id) on delete restrict,
  carrier_code text,
  carrier_name text,
  tracking_number text,
  status text not null default 'not_shipped'
    check (status in (
      'not_shipped', 'ready_to_ship', 'shipped', 'in_transit',
      'delivered', 'exception', 'returned'
    )),
  shipped_at timestamptz,
  delivered_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (order_id)
);
create index asri_store_shipments_tracking_idx
  on public.asri_store_shipments (tracking_number)
  where tracking_number is not null;

-- 7) Shipment event history. source distinguishes internal/manual from verified carrier events.
create table public.asri_store_shipment_events (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references public.asri_store_shipments(id) on delete restrict,
  status text not null,
  description text not null,
  location text,
  event_at timestamptz not null,
  source text not null check (source in ('internal', 'manual_verified', 'carrier_api')),
  source_event_id text,
  created_at timestamptz not null default now(),
  unique (shipment_id, source, source_event_id)
);
create index asri_store_shipment_events_timeline_idx
  on public.asri_store_shipment_events (shipment_id, event_at desc);

-- 8) Link each existing payment attempt to a store order. This is additive only,
-- but must not be applied until all function consumers and constraints are reviewed.
alter table public.asri_payment_orders
  add column store_order_id uuid
  references public.asri_store_orders(id) on delete restrict;

alter table public.asri_payment_orders
  add column idempotency_key text;

create unique index asri_payment_orders_store_order_idempotency_key_uidx
  on public.asri_payment_orders (store_order_id, idempotency_key)
  where store_order_id is not null and idempotency_key is not null;

create index asri_payment_orders_store_order_id_idx
  on public.asri_payment_orders (store_order_id)
  where store_order_id is not null;

-- 9) Lock down client roles. No anon/authenticated direct order/payment/token/shipment access.
-- service_role access is expected for trusted server code; verify exact grants in isolated DB.
alter table public.asri_store_orders enable row level security;
alter table public.asri_store_order_items enable row level security;
alter table public.asri_store_shipping_rates enable row level security;
alter table public.asri_store_stock_reservations enable row level security;
alter table public.asri_store_order_access_tokens enable row level security;
alter table public.asri_store_shipments enable row level security;
alter table public.asri_store_shipment_events enable row level security;

revoke all on public.asri_store_orders from anon, authenticated;
revoke all on public.asri_store_order_items from anon, authenticated;
revoke all on public.asri_store_shipping_rates from anon, authenticated;
revoke all on public.asri_store_stock_reservations from anon, authenticated;
revoke all on public.asri_store_order_access_tokens from anon, authenticated;
revoke all on public.asri_store_shipments from anon, authenticated;
revoke all on public.asri_store_shipment_events from anon, authenticated;

revoke all on public.asri_payment_orders from anon, authenticated;

-- This is a review draft, so transaction is intentionally not committed/applied.
-- When converted to a real migration, transaction handling must follow the
-- project's migration runner conventions. Do not execute this file as-is.
rollback;
