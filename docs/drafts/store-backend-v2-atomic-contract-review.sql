-- REVIEW ONLY — atomic Store V2 checkout and payment transition contract.
-- This file is testable SQL, NOT a migration. It must be loaded only after
-- the three baseline review drafts in a disposable PostgreSQL database.
-- Never apply this file to the legacy/shared Supabase project.
--
-- Trusted server code only: checkout JSON must be validated by the API layer;
-- prices, stock, shipping costs, and totals are recalculated from database rows.
-- Duitku network calls happen AFTER this function commits.

create or replace function public.asri_store_create_checkout(p_payload jsonb)
returns table(order_id uuid, payment_order_id uuid, reservation_expires_at timestamptz, reused boolean)
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_key text := nullif(p_payload->>'idempotency_key','');
  v_fingerprint text := nullif(p_payload->>'request_fingerprint','');
  v_order_number text := nullif(p_payload->>'order_number','');
  v_merchant_order_id text := nullif(p_payload->>'merchant_order_id','');
  v_items jsonb := p_payload->'items';
  v_item jsonb;
  v_product_id uuid;
  v_quantity integer;
  v_product public.asri_products%rowtype;
  v_rate public.asri_store_shipping_rates%rowtype;
  v_order_id uuid;
  v_payment_order_id uuid;
  v_expires timestamptz := clock_timestamp() + interval '15 minutes';
  v_subtotal bigint := 0;
  v_shipping_cost bigint;
  v_total bigint;
  v_line_total bigint;
  v_item_id uuid;
  v_existing_fingerprint text;
  v_scope_rank integer;
  v_city text := nullif(p_payload->>'shipping_city','');
  v_province text := nullif(p_payload->>'shipping_province','');
begin
  if v_key is null or v_fingerprint is null or v_order_number is null
     or v_merchant_order_id is null or jsonb_typeof(v_items) <> 'array'
     or jsonb_array_length(v_items) = 0 then
    raise exception using errcode='22023', message='invalid_checkout_payload';
  end if;
  if length(v_key) > 200 or length(v_fingerprint) > 200 then
    raise exception using errcode='22023', message='invalid_idempotency_fields';
  end if;

  -- Serialize retries using the same key before checking existing rows.
  perform pg_advisory_xact_lock(pg_catalog.hashtextextended(v_key, 0));
  select o.id, o.request_fingerprint, p.id
    into v_order_id, v_existing_fingerprint, v_payment_order_id
  from public.asri_store_orders o
  left join public.asri_payment_orders p on p.store_order_id=o.id
  where o.idempotency_key=v_key
  limit 1;
  if v_order_id is not null then
    if v_existing_fingerprint <> v_fingerprint then
      raise exception using errcode='22023', message='idempotency_key_payload_mismatch';
    end if;
    return query select v_order_id, v_payment_order_id,
      (select o.stock_reservation_expires_at from public.asri_store_orders o where o.id=v_order_id), true;
    return;
  end if;

  if nullif(p_payload->>'customer_name','') is null
     or nullif(p_payload->>'customer_phone','') is null
     or nullif(p_payload->>'shipping_recipient','') is null
     or nullif(p_payload->>'shipping_phone','') is null
     or nullif(p_payload->>'shipping_address_line','') is null
     or v_city is null or v_province is null
     or nullif(p_payload->>'shipping_postal_code','') is null
     or nullif(p_payload->>'shipping_method','') is null
     or nullif(p_payload->>'payment_token_hash','') is null
     or nullif(p_payload->>'tracking_token_hash','') is null then
    raise exception using errcode='22023', message='missing_required_checkout_field';
  end if;

  -- Resolve one active/effective shipping rate; city > province > global fallback.
  select r.* into v_rate
  from public.asri_store_shipping_rates r
  where r.method_code=p_payload->>'shipping_method'
    and r.is_active
    and r.effective_from <= clock_timestamp()
    and (r.effective_until is null or r.effective_until > clock_timestamp())
    and (
      (r.destination_city is not null and lower(r.destination_city)=lower(v_city)
        and (r.destination_province is null or lower(r.destination_province)=lower(v_province)))
      or (r.destination_city is null and r.destination_province is not null
        and lower(r.destination_province)=lower(v_province))
      or (r.destination_city is null and r.destination_province is null)
    )
  order by case
      when r.destination_city is not null then 3
      when r.destination_province is not null then 2
      else 1 end desc,
    r.priority desc, r.effective_from desc, r.created_at desc, r.id asc
  limit 1;
  if not found then
    raise exception using errcode='22023', message='shipping_rate_unavailable';
  end if;
  v_shipping_cost := v_rate.price;

  -- Lock all referenced product rows in deterministic UUID order, preventing
  -- oversell and reducing deadlock risk for carts with multiple products.
  for v_product_id in
    select distinct (x->>'product_id')::uuid
    from jsonb_array_elements(v_items) x
    order by 1
  loop
    select * into v_product from public.asri_products
    where id=v_product_id for update;
    if not found or not v_product.is_active then
      raise exception using errcode='22023', message='product_unavailable';
    end if;
    select coalesce(sum((x->>'quantity')::integer),0)::integer into v_quantity
    from jsonb_array_elements(v_items) x
    where (x->>'product_id')::uuid=v_product_id;
    if v_quantity <= 0 or exists (
      select 1 from jsonb_array_elements(v_items) x
      where (x->>'product_id')::uuid=v_product_id
        and (coalesce(x->>'quantity','') !~ '^[1-9][0-9]*'
          or (x->>'quantity')::numeric > 2147483647)
    ) then
      raise exception using errcode='22023', message='invalid_item_quantity';
    end if;
    if v_product.stock_quantity < v_quantity then
      raise exception using errcode='P0001', message='insufficient_stock';
    end if;
  end loop;

  -- Calculate totals from trusted current product prices, before any writes.
  for v_item in select value from jsonb_array_elements(v_items)
  loop
    if coalesce(v_item->>'product_id','') !~* '^[0-9a-f-]{36}$'
       or coalesce(v_item->>'quantity','') !~ '^[1-9][0-9]*' then
      raise exception using errcode='22023', message='invalid_item';
    end if;
    select * into v_product from public.asri_products
      where id=(v_item->>'product_id')::uuid;
    v_quantity := (v_item->>'quantity')::integer;
    v_line_total := v_product.price::bigint * v_quantity::bigint;
    if v_line_total > 9000000000000000 or v_subtotal > 9000000000000000-v_line_total then
      raise exception using errcode='22003', message='order_total_overflow';
    end if;
    v_subtotal := v_subtotal + v_line_total;
  end loop;
  v_total := v_subtotal + v_shipping_cost;
  if v_total <= 0 or v_total > 9000000000000000 then
    raise exception using errcode='22003', message='invalid_order_total';
  end if;

  insert into public.asri_store_orders (
    order_number,idempotency_key,request_fingerprint,customer_name,customer_phone,customer_email,
    shipping_recipient,shipping_phone,shipping_address_line,shipping_district,shipping_city,
    shipping_province,shipping_postal_code,shipping_notes,shipping_method,shipping_rate_snapshot,
    shipping_cost,subtotal,total_amount,stock_reservation_expires_at
  ) values (
    v_order_number,v_key,v_fingerprint,p_payload->>'customer_name',p_payload->>'customer_phone',
    nullif(p_payload->>'customer_email',''),p_payload->>'shipping_recipient',p_payload->>'shipping_phone',
    p_payload->>'shipping_address_line',nullif(p_payload->>'shipping_district',''),v_city,v_province,
    p_payload->>'shipping_postal_code',nullif(p_payload->>'shipping_notes',''),v_rate.method_code,
    jsonb_build_object('rate_id',v_rate.id,'method_name',v_rate.method_name,'price',v_rate.price,
      'destination_city',v_rate.destination_city,'destination_province',v_rate.destination_province),
    v_shipping_cost,v_subtotal,v_total,v_expires
  ) returning id into v_order_id;

  for v_item in select value from jsonb_array_elements(v_items)
  loop
    select * into v_product from public.asri_products where id=(v_item->>'product_id')::uuid;
    v_quantity := (v_item->>'quantity')::integer;
    v_line_total := v_product.price::bigint * v_quantity::bigint;
    insert into public.asri_store_order_items (
      order_id,product_id,sku_snapshot,product_name_snapshot,variant_snapshot,unit_price,quantity,line_total
    ) values (
      v_order_id,v_product.id,v_product.sku,v_product.name,
      coalesce(v_item->'variant_snapshot','{}'::jsonb),v_product.price,v_quantity,v_line_total
    ) returning id into v_item_id;

    insert into public.asri_store_stock_reservations
      (order_id,order_item_id,product_id,quantity,status,expires_at)
    values (v_order_id,v_item_id,v_product.id,v_quantity,'reserved',v_expires);
  end loop;

  -- Decrement stock once per distinct product, in the same transaction as all
  -- order/reservation/payment/token writes. Release restores stock exactly once.
  for v_product_id in
    select distinct (x->>'product_id')::uuid
    from jsonb_array_elements(v_items) x
    order by 1
  loop
    select coalesce(sum((x->>'quantity')::integer),0)::integer into v_quantity
    from jsonb_array_elements(v_items) x
    where (x->>'product_id')::uuid=v_product_id;
    update public.asri_products set stock_quantity=stock_quantity-v_quantity
      where id=v_product_id and stock_quantity >= v_quantity;
    if not found then
      raise exception using errcode='P0001', message='insufficient_stock_race';
    end if;
  end loop;

  insert into public.asri_payment_orders (
    merchant_order_id,amount,currency,status,provider,expires_at,store_order_id,idempotency_key
  ) values (
    v_merchant_order_id,v_total,'IDR','draft','duitku',v_expires,v_order_id,v_key
  ) returning id into v_payment_order_id;

  insert into public.asri_store_order_access_tokens(order_id,token_hash,scope,expires_at)
  values
    (v_order_id,p_payload->>'tracking_token_hash','tracking:read',clock_timestamp()+interval '90 days'),
    (v_order_id,p_payload->>'payment_token_hash','payment:create',clock_timestamp()+interval '30 minutes');

  insert into public.asri_store_order_status_history(order_id,previous_status,new_status,source,note)
  values (v_order_id,null,'pending_payment','order_create','Atomic checkout committed');

  insert into public.asri_payment_status_history(order_id,previous_status,new_status,source,note)
  values (v_payment_order_id,null,'draft','create','Payment draft created with checkout');

  return query select v_order_id,v_payment_order_id,v_expires,false;
end;
$$;

-- Only the trusted server role may execute checkout; never grant this to clients.
revoke all on function public.asri_store_create_checkout(jsonb) from public, anon, authenticated;
grant execute on function public.asri_store_create_checkout(jsonb) to service_role;

-- Apply one verified payment outcome. Callback signature verification and provider
-- status lookup happen in the Edge Function before this RPC. A late success after
-- order expiry is recorded as paid but does not silently resurrect expired stock/order.
create or replace function public.asri_store_apply_payment_event(
  p_merchant_order_id text,
  p_amount bigint,
  p_new_status text,
  p_provider_status_code text,
  p_event_fingerprint text
)
returns table(payment_order_id uuid, order_id uuid, payment_status text, order_status text, outcome text)
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  v_payment public.asri_payment_orders%rowtype;
  v_order public.asri_store_orders%rowtype;
  v_next_order_status text;
  v_outcome text := 'applied';
begin
  if p_new_status not in ('pending','paid','failed','cancelled','expired') then
    raise exception using errcode='22023', message='invalid_payment_transition_target';
  end if;
  if p_event_fingerprint is null or length(p_event_fingerprint)=0 then
    raise exception using errcode='22023', message='event_fingerprint_required';
  end if;

  -- Serialize callbacks for the same merchant order ID.
  perform pg_advisory_xact_lock(pg_catalog.hashtextextended(p_merchant_order_id, 0));
  select * into v_payment from public.asri_payment_orders
    where merchant_order_id=p_merchant_order_id for update;
  if not found then
    raise exception using errcode='P0002', message='payment_order_not_found';
  end if;
  if v_payment.amount <> p_amount then
    raise exception using errcode='22023', message='payment_amount_mismatch';
  end if;
  select * into v_order from public.asri_store_orders
    where id=v_payment.store_order_id for update;
  if not found then
    raise exception using errcode='P0002', message='store_order_not_found';
  end if;

  -- Persist fingerprint once. Duplicate callbacks are acknowledged as no-ops.
  insert into public.asri_payment_callbacks(
    provider,merchant_order_id,signature_valid,result_code,payload,processing_status,event_fingerprint,processed_at
  ) values (
    v_payment.provider,p_merchant_order_id,true,p_provider_status_code,
    jsonb_build_object('merchantOrderId',p_merchant_order_id,'amount',p_amount,'status',p_new_status),
    'processed',p_event_fingerprint,clock_timestamp()
  ) on conflict (event_fingerprint) where event_fingerprint is not null do nothing;
  if not found then
    return query select v_payment.id,v_order.id,v_payment.status,v_order.order_status,'duplicate';
    return;
  end if;

  -- Paid is monotonic for normal retries. A terminal non-paid state can only be
  -- overridden by verified paid evidence, which is flagged for reconciliation.
  if v_payment.status='paid' then
    v_outcome := 'already_paid';
    return query select v_payment.id,v_order.id,v_payment.status,v_order.order_status,v_outcome;
    return;
  end if;
  if v_payment.status in ('failed','cancelled','expired','creation_failed') and p_new_status <> 'paid' then
    v_outcome := 'terminal_noop';
    return query select v_payment.id,v_order.id,v_payment.status,v_order.order_status,v_outcome;
    return;
  end if;

  if p_new_status='pending' and v_payment.status <> 'draft' then
    v_outcome := 'stale_noop';
    return query select v_payment.id,v_order.id,v_payment.status,v_order.order_status,v_outcome;
    return;
  end if;

  update public.asri_payment_orders
  set status=p_new_status, provider_status_code=p_provider_status_code,
      paid_at=case when p_new_status='paid' then clock_timestamp() else paid_at end,
      failed_at=case when p_new_status in ('failed','cancelled','expired') then clock_timestamp() else failed_at end,
      updated_at=clock_timestamp()
  where id=v_payment.id;

  if p_new_status='paid' then
    if v_order.order_status='expired' or v_order.order_status='cancelled'
       or v_order.stock_reservation_expires_at <= clock_timestamp() then
      update public.asri_store_orders set payment_status='paid',updated_at=clock_timestamp()
        where id=v_order.id;
      v_outcome := 'late_paid_manual_reconciliation';
      -- Do not consume expired/released reservations or restore a cancelled order.
    else
      update public.asri_store_orders set payment_status='paid',order_status='confirmed',updated_at=clock_timestamp()
        where id=v_order.id;
      update public.asri_store_stock_reservations set status='consumed',
        consumed_at=clock_timestamp(),updated_at=clock_timestamp()
        where order_id=v_order.id and status='reserved' and expires_at > clock_timestamp();
      insert into public.asri_store_order_status_history(order_id,previous_status,new_status,source,note)
      values (v_order.id,v_order.order_status,'confirmed','payment_callback','Verified payment success');
    end if;
  elsif p_new_status in ('failed','cancelled','expired') then
    update public.asri_store_orders set payment_status=p_new_status,updated_at=clock_timestamp()
      where id=v_order.id;
    if v_order.order_status='pending_payment' then
      v_next_order_status := case when p_new_status='expired' then 'expired' else 'cancelled' end;
      update public.asri_store_orders set order_status=v_next_order_status,updated_at=clock_timestamp()
        where id=v_order.id;
      insert into public.asri_store_order_status_history(order_id,previous_status,new_status,source,note)
      values (v_order.id,v_order.order_status,v_next_order_status,'payment_callback','Verified non-success payment outcome');
    end if;
    -- Restore stock only when a reservation is transitioned from reserved once.
    with released as (
      update public.asri_store_stock_reservations
      set status=case when p_new_status='expired' then 'expired' else 'released' end,
          released_at=clock_timestamp(),updated_at=clock_timestamp()
      where order_id=v_order.id and status='reserved'
      returning product_id,quantity
    ), totals as (
      select product_id,sum(quantity)::integer quantity from released group by product_id
    )
    update public.asri_products p set stock_quantity=p.stock_quantity+t.quantity
      from totals t where p.id=t.product_id;
  else
    update public.asri_store_orders set payment_status='pending',updated_at=clock_timestamp()
      where id=v_order.id;
  end if;

  insert into public.asri_payment_status_history(order_id,previous_status,new_status,source,provider_status_code,note)
  values (v_payment.id,v_payment.status,p_new_status,'callback',p_provider_status_code,v_outcome);

  return query
    select p.id,o.id,p.status,o.order_status,v_outcome
    from public.asri_payment_orders p
    join public.asri_store_orders o on o.id=p.store_order_id
    where p.id=v_payment.id;
end;
$$;

revoke all on function public.asri_store_apply_payment_event(text,bigint,text,text,text) from public, anon, authenticated;
grant execute on function public.asri_store_apply_payment_event(text,bigint,text,text,text) to service_role;
