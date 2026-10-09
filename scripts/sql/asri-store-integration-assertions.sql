\set ON_ERROR_STOP on

-- Seed server-managed shipping rates and isolated products.
insert into public.asri_store_shipping_rates
  (method_code,method_name,destination_province,destination_city,price,is_active)
values
  ('TEST-COURIER','Test Courier','Sulawesi Selatan','Makassar',7000,true),
  ('TEST-COURIER','Test Courier','Sulawesi Selatan',null,9000,true),
  ('TEST-COURIER','Test Courier',null,null,12000,true);

insert into public.asri_products (sku,slug,name,price,stock_quantity,is_active)
values
  ('IT-ATOMIC-A','it-atomic-a','Atomic test item A',2500,5,true),
  ('IT-ATOMIC-B','it-atomic-b','Atomic test item B',4000,0,true),
  ('IT-CONCURRENT-LAST','it-concurrent-last','Last unit concurrency fixture',1000,1,true);

create or replace function pg_temp.test_checkout_payload(
  p_order_number text,
  p_idempotency_key text,
  p_fingerprint text,
  p_product_sku text,
  p_quantity integer,
  p_merchant_order_id text,
  p_payment_hash text,
  p_tracking_hash text
) returns jsonb language sql as $$
  select jsonb_build_object(
    'order_number',p_order_number,
    'idempotency_key',p_idempotency_key,
    'request_fingerprint',p_fingerprint,
    'merchant_order_id',p_merchant_order_id,
    'customer_name','Integration Customer',
    'customer_phone','081234567890',
    'shipping_recipient','Integration Recipient',
    'shipping_phone','081234567890',
    'shipping_address_line','Test Address 123',
    'shipping_city','Makassar',
    'shipping_province','Sulawesi Selatan',
    'shipping_postal_code','90111',
    'shipping_method','TEST-COURIER',
    'payment_token_hash',p_payment_hash,
    'tracking_token_hash',p_tracking_hash,
    'items',jsonb_build_array(jsonb_build_object(
      'product_id',(select id::text from public.asri_products where sku=p_product_sku),
      'quantity',p_quantity,
      'variant_snapshot','{}'::jsonb
    ))
  )
$$;

-- Atomic rollback: one item is unavailable. No order/payment/reservation should persist,
-- and the first product's stock must remain unchanged.
do $$
declare
  before_stock integer;
  before_orders bigint;
begin
  select stock_quantity into before_stock from public.asri_products where sku='IT-ATOMIC-A';
  select count(*) into before_orders from public.asri_store_orders;
  begin
    perform * from public.asri_store_create_checkout(jsonb_build_object(
      'order_number','IT-ROLLBACK','idempotency_key','it-rollback-key',
      'request_fingerprint','it-rollback-fp','merchant_order_id','IT-PAY-ROLLBACK',
      'customer_name','Integration Customer','customer_phone','081234567890',
      'shipping_recipient','Integration Recipient','shipping_phone','081234567890',
      'shipping_address_line','Test Address 123','shipping_city','Makassar',
      'shipping_province','Sulawesi Selatan','shipping_postal_code','90111',
      'shipping_method','TEST-COURIER','payment_token_hash','hash-payment-rollback',
      'tracking_token_hash','hash-tracking-rollback',
      'items',jsonb_build_array(
        jsonb_build_object('product_id',(select id::text from public.asri_products where sku='IT-ATOMIC-A'),'quantity',1),
        jsonb_build_object('product_id',(select id::text from public.asri_products where sku='IT-ATOMIC-B'),'quantity',1)
      )
    ));
    raise exception 'Expected insufficient stock rejection';
  exception when sqlstate 'P0001' then
    if sqlerrm not like 'insufficient_stock%' then raise; end if;
  end;
  if (select stock_quantity from public.asri_products where sku='IT-ATOMIC-A') <> before_stock then
    raise exception 'Rollback failed: first product stock changed';
  end if;
  if (select count(*) from public.asri_store_orders) <> before_orders then
    raise exception 'Rollback failed: order row persisted';
  end if;
  if exists (select 1 from public.asri_payment_orders where merchant_order_id='IT-PAY-ROLLBACK') then
    raise exception 'Rollback failed: payment row persisted';
  end if;
end $$;

-- Successful checkout: server prices and city-specific shipping rate are authoritative.
do $$
declare
  result record;
  retry record;
begin
  select * into result from public.asri_store_create_checkout(
    pg_temp.test_checkout_payload('IT-ORDER-1','it-idem-1','it-fp-1','IT-ATOMIC-A',2,
      'IT-PAY-1','hash-payment-1','hash-tracking-1')
  );
  if result.reused then raise exception 'First checkout unexpectedly reused'; end if;
  if (select subtotal from public.asri_store_orders where id=result.order_id) <> 5000 then
    raise exception 'Subtotal was not calculated from database price';
  end if;
  if (select shipping_cost from public.asri_store_orders where id=result.order_id) <> 7000 then
    raise exception 'City-specific shipping rate did not win';
  end if;
  if (select total_amount from public.asri_store_orders where id=result.order_id) <> 12000 then
    raise exception 'Incorrect server-computed total';
  end if;
  if (select stock_quantity from public.asri_products where sku='IT-ATOMIC-A') <> 3 then
    raise exception 'Stock was not reserved exactly once';
  end if;
  select * into retry from public.asri_store_create_checkout(
    pg_temp.test_checkout_payload('IT-ORDER-RETRY','it-idem-1','it-fp-1','IT-ATOMIC-A',2,
      'IT-PAY-RETRY','hash-payment-retry','hash-tracking-retry')
  );
  if not retry.reused or retry.order_id <> result.order_id or retry.payment_order_id <> result.payment_order_id then
    raise exception 'Same-key retry did not return the existing checkout';
  end if;
  begin
    perform * from public.asri_store_create_checkout(
      pg_temp.test_checkout_payload('IT-ORDER-MISMATCH','it-idem-1','different-fingerprint','IT-ATOMIC-A',1,
        'IT-PAY-MISMATCH','hash-payment-mismatch','hash-tracking-mismatch')
    );
    raise exception 'Expected idempotency payload mismatch rejection';
  exception when sqlstate '22023' then
    if sqlerrm <> 'idempotency_key_payload_mismatch' then raise; end if;
  end;
end $$;

-- Payment transition: pending -> paid confirms order and consumes reservation.
do $$
declare
  result record;
  order_uuid uuid;
  payment_uuid uuid;
begin
  select o.id,p.id into order_uuid,payment_uuid
  from public.asri_store_orders o join public.asri_payment_orders p on p.store_order_id=o.id
  where o.order_number='IT-ORDER-1';
  select * into result from public.asri_store_apply_payment_event('IT-PAY-1',12000,'pending','01','it-event-pending');
  if result.payment_status <> 'pending' then raise exception 'Pending transition failed'; end if;
  select * into result from public.asri_store_apply_payment_event('IT-PAY-1',12000,'paid','00','it-event-paid');
  if result.payment_status <> 'paid' or result.order_status <> 'confirmed' then
    raise exception 'Paid transition did not confirm order';
  end if;
  if not exists (select 1 from public.asri_store_stock_reservations where order_id=order_uuid and status='consumed') then
    raise exception 'Paid transition did not consume reservation';
  end if;
  select * into result from public.asri_store_apply_payment_event('IT-PAY-1',12000,'paid','00','it-event-paid');
  if result.outcome <> 'duplicate' then raise exception 'Duplicate callback was not idempotent'; end if;
  if (select count(*) from public.asri_payment_status_history where order_id=payment_uuid and new_status='paid') <> 1 then
    raise exception 'Duplicate callback wrote duplicate status history';
  end if;
end $$;

-- Expiry releases stock once. A later verified paid event is recorded for manual
-- reconciliation, without silently resurrecting the expired order/reservation.
do $$
declare
  result record;
  stock_before integer;
  order_uuid uuid;
begin
  select stock_quantity into stock_before from public.asri_products where sku='IT-ATOMIC-A';
  select * into result from public.asri_store_create_checkout(
    pg_temp.test_checkout_payload('IT-ORDER-LATE','it-idem-late','it-fp-late','IT-ATOMIC-A',1,
      'IT-PAY-LATE','hash-payment-late','hash-tracking-late')
  );
  order_uuid := result.order_id;
  select * into result from public.asri_store_apply_payment_event('IT-PAY-LATE',9500,'expired','02','it-event-expired');
  if result.order_status <> 'expired' then raise exception 'Expiry did not expire order'; end if;
  if (select stock_quantity from public.asri_products where sku='IT-ATOMIC-A') <> stock_before then
    raise exception 'Expiry did not restore reserved stock exactly once';
  end if;
  select * into result from public.asri_store_apply_payment_event('IT-PAY-LATE',9500,'paid','00','it-event-late-paid');
  if result.outcome <> 'late_paid_manual_reconciliation' then
    raise exception 'Late paid outcome was not flagged for manual reconciliation';
  end if;
  if result.order_status <> 'expired' or result.payment_status <> 'paid' then
    raise exception 'Late paid must not silently resurrect an expired order';
  end if;
  if exists (select 1 from public.asri_store_stock_reservations where order_id=order_uuid and status='consumed') then
    raise exception 'Late paid incorrectly consumed expired reservation';
  end if;
end $$;

select 'PASS: checkout rollback, server totals/shipping, idempotency, payment transitions, callback dedupe, expiry release, late-paid reconciliation' as result;
