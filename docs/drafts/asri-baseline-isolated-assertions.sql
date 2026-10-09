-- REVIEW TEST ONLY — run ONLY against the disposable LOCAL Supabase database.
-- This test is transactional and rolls back all fixture data.
-- Run with psql -v ON_ERROR_STOP=1. Never run against a hosted project.

begin;

do $$
declare
  tbl text;
  expected text[] := array[
    'asri_products',
    'asri_payment_orders',
    'asri_payment_transactions',
    'asri_payment_callbacks',
    'asri_payment_status_history'
  ];
begin
  foreach tbl in array expected loop
    if to_regclass(format('public.%I', tbl)) is null then
      raise exception 'Missing expected table: %', tbl;
    end if;
  end loop;
end;
$$;

-- RLS must be enabled on all five baseline tables.
do $$
declare
  tbl text;
begin
  foreach tbl in array array[
    'asri_products',
    'asri_payment_orders',
    'asri_payment_transactions',
    'asri_payment_callbacks',
    'asri_payment_status_history'
  ] loop
    if not exists (
      select 1
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and c.relname = tbl
        and c.relrowsecurity
    ) then
      raise exception 'RLS is not enabled on public.%', tbl;
    end if;
  end loop;
end;
$$;

-- Catalog public access is read-only and filtered by active state.
do $$
begin
  if not has_table_privilege('anon', 'public.asri_products', 'SELECT') then
    raise exception 'anon must be able to SELECT the public catalog';
  end if;
  if has_table_privilege('anon', 'public.asri_products', 'INSERT')
     or has_table_privilege('anon', 'public.asri_products', 'UPDATE')
     or has_table_privilege('anon', 'public.asri_products', 'DELETE') then
    raise exception 'anon has an unexpected catalog write privilege';
  end if;
  if not exists (
    select 1 from pg_policies
    where schemaname='public'
      and tablename='asri_products'
      and policyname='Public can read active ASRI products'
      and cmd='SELECT'
      and 'anon' = any(roles)
      and qual = '(is_active = true)'
  ) then
    raise exception 'Expected active-products SELECT policy is missing or changed';
  end if;
end;
$$;

-- Payment tables must be private to client roles and available to service_role.
do $$
declare
  tbl text;
begin
  foreach tbl in array array[
    'asri_payment_orders',
    'asri_payment_transactions',
    'asri_payment_callbacks',
    'asri_payment_status_history'
  ] loop
    if has_table_privilege('anon', format('public.%I', tbl), 'SELECT')
       or has_table_privilege('authenticated', format('public.%I', tbl), 'SELECT')
       or has_table_privilege('anon', format('public.%I', tbl), 'INSERT')
       or has_table_privilege('authenticated', format('public.%I', tbl), 'INSERT') then
      raise exception 'Client role unexpectedly has payment table access: %', tbl;
    end if;
    if not has_table_privilege('service_role', format('public.%I', tbl), 'SELECT')
       or not has_table_privilege('service_role', format('public.%I', tbl), 'INSERT')
       or not has_table_privilege('service_role', format('public.%I', tbl), 'UPDATE') then
      raise exception 'service_role missing expected payment table privileges: %', tbl;
    end if;
  end loop;
end;
$$;

-- Verify key indexes, trigger, and history identity column.
do $$
begin
  if to_regclass('public.asri_products_active_category_idx') is null
     or to_regclass('public.asri_products_featured_idx') is null
     or to_regclass('public.asri_payment_transactions_provider_reference_uidx') is null
     or to_regclass('public.asri_payment_callbacks_fingerprint_uidx') is null
     or to_regclass('public.asri_payment_status_history_order_id_idx') is null then
    raise exception 'One or more expected baseline indexes are missing';
  end if;
  if not exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='asri_products'
      and t.tgname='asri_products_updated_at_trigger' and not t.tgisinternal
  ) then
    raise exception 'Product updated_at trigger is missing';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='asri_payment_status_history'
      and column_name='id' and is_identity='YES'
  ) then
    raise exception 'Payment history id is not an identity column';
  end if;
end;
$$;

-- Seed fixtures under the test transaction only.
insert into public.asri_products
  (sku, slug, name, price, stock_quantity, is_active)
values
  ('TEST-ACTIVE', 'test-active', 'Test active product', 1000, 2, true),
  ('TEST-INACTIVE', 'test-inactive', 'Test inactive product', 1000, 2, false);

-- Anonymous SELECT should return only the active fixture, despite inactive fixture existing.
set local role anon;
do $$
declare
  total_rows integer;
  inactive_rows integer;
begin
  select count(*) into total_rows from public.asri_products
  where sku in ('TEST-ACTIVE', 'TEST-INACTIVE');
  select count(*) into inactive_rows from public.asri_products
  where sku = 'TEST-INACTIVE';
  if total_rows <> 1 or inactive_rows <> 0 then
    raise exception 'Catalog RLS failure: total visible %, inactive visible %', total_rows, inactive_rows;
  end if;
end;
$$;
reset role;

-- Constraint probes: each invalid insert must fail with check_violation.
do $$
begin
  begin
    insert into public.asri_products (name, price, stock_quantity)
    values ('Invalid negative price', -1, 0);
    raise exception 'Negative product price unexpectedly accepted';
  exception when check_violation then
    null;
  end;

  begin
    insert into public.asri_products (name, price, stock_quantity)
    values ('Invalid negative stock', 1, -1);
    raise exception 'Negative product stock unexpectedly accepted';
  exception when check_violation then
    null;
  end;

  begin
    insert into public.asri_payment_orders (merchant_order_id, amount)
    values ('TEST-ZERO-AMOUNT', 0);
    raise exception 'Zero payment amount unexpectedly accepted';
  exception when check_violation then
    null;
  end;

  begin
    insert into public.asri_payment_orders (merchant_order_id, amount, status)
    values ('TEST-INVALID-STATUS', 1000, 'mystery');
    raise exception 'Unknown payment status unexpectedly accepted';
  exception when check_violation then
    null;
  end;
end;
$$;

-- Verify updated_at trigger changes timestamp. Transaction rollback removes this fixture.
do $$
declare
  before_update timestamptz;
  after_update timestamptz;
begin
  select updated_at into before_update
  from public.asri_products where sku='TEST-ACTIVE';
  perform pg_sleep(0.01);
  update public.asri_products set name='Test product updated'
  where sku='TEST-ACTIVE';
  select updated_at into after_update
  from public.asri_products where sku='TEST-ACTIVE';
  if after_update <= before_update then
    raise exception 'updated_at trigger did not advance timestamp';
  end if;
end;
$$;

-- Verify partial uniqueness: NULL references/fingerprints remain allowed.
insert into public.asri_payment_orders (merchant_order_id, amount, status)
values ('TEST-ORDER-001', 1000, 'draft');
insert into public.asri_payment_orders (merchant_order_id, amount, status)
values ('TEST-ORDER-002', 1000, 'draft');

insert into public.asri_payment_transactions (order_id, provider, provider_reference, amount)
select id, 'duitku', null, 1000
from public.asri_payment_orders
where merchant_order_id in ('TEST-ORDER-001','TEST-ORDER-002');

insert into public.asri_payment_callbacks (merchant_order_id, payload, event_fingerprint)
values
  ('TEST-ORDER-001', '{}'::jsonb, null),
  ('TEST-ORDER-002', '{}'::jsonb, null);

-- History ID should be generated automatically.
insert into public.asri_payment_status_history (order_id, new_status, source)
select id, 'draft', 'create'
from public.asri_payment_orders
where merchant_order_id='TEST-ORDER-001';

do $$
begin
  if (select count(*) from public.asri_payment_status_history
      where order_id = (select id from public.asri_payment_orders where merchant_order_id='TEST-ORDER-001')) <> 1 then
    raise exception 'Payment status history insert failed';
  end if;
end;
$$;

rollback;
