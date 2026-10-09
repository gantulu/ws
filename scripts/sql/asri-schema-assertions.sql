\set ON_ERROR_STOP on
DO $$
DECLARE
  expected_tables text[] := ARRAY[
    'asri_products',
    'asri_payment_orders','asri_payment_transactions','asri_payment_callbacks','asri_payment_status_history',
    'asri_store_orders','asri_store_order_items','asri_store_order_status_history',
    'asri_store_shipping_rates','asri_store_stock_reservations','asri_store_order_access_tokens',
    'asri_store_shipments','asri_store_shipment_events'
  ];
  t text;
  table_count integer;
BEGIN
  SELECT count(*) INTO table_count
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relkind='r' AND c.relname = ANY(expected_tables);
  IF table_count <> cardinality(expected_tables) THEN
    RAISE EXCEPTION 'Expected % tables, found %', cardinality(expected_tables), table_count;
  END IF;

  FOREACH t IN ARRAY expected_tables LOOP
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid=to_regclass('public.' || t)) THEN
      RAISE EXCEPTION 'RLS not enabled on %', t;
    END IF;
  END LOOP;

  IF NOT has_table_privilege('anon','public.asri_products','SELECT') THEN
    RAISE EXCEPTION 'anon should have SELECT privilege on catalog';
  END IF;
  IF has_table_privilege('authenticated','public.asri_payment_orders','SELECT')
     OR has_table_privilege('anon','public.asri_payment_orders','SELECT') THEN
    RAISE EXCEPTION 'client role unexpectedly has SELECT on payment orders';
  END IF;
  IF has_table_privilege('anon','public.asri_store_orders','SELECT')
     OR has_table_privilege('authenticated','public.asri_store_orders','SELECT') THEN
    RAISE EXCEPTION 'client role unexpectedly has SELECT on store orders';
  END IF;
  IF NOT has_table_privilege('service_role','public.asri_store_orders','INSERT') THEN
    RAISE EXCEPTION 'service_role should have INSERT on store orders';
  END IF;
  IF has_table_privilege('service_role','public.asri_store_order_items','UPDATE')
     OR has_table_privilege('service_role','public.asri_store_order_items','DELETE')
     OR has_table_privilege('service_role','public.asri_store_order_status_history','UPDATE')
     OR has_table_privilege('service_role','public.asri_store_shipment_events','DELETE') THEN
    RAISE EXCEPTION 'append-only table grants are too broad';
  END IF;
  IF to_regprocedure('public.asri_store_reject_history_mutation()') IS NULL THEN
    RAISE EXCEPTION 'immutable history trigger function missing';
  END IF;
END $$;

-- Constraint rejection tests: invalid price and negative stock must fail.
DO $$
BEGIN
  BEGIN
    INSERT INTO public.asri_products (name, price, stock_quantity) VALUES ('invalid-price', -1, 0);
    RAISE EXCEPTION 'Expected negative price rejection';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO public.asri_products (name, price, stock_quantity) VALUES ('invalid-stock', 1, -1);
    RAISE EXCEPTION 'Expected negative stock rejection';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
END $$;

-- Partial unique transaction index must be inferable when the matching predicate is supplied.
DO $$
DECLARE
  payment_order_id uuid;
BEGIN
  INSERT INTO public.asri_payment_orders (merchant_order_id, amount, status)
  VALUES ('schema-test-payment', 1000, 'pending')
  RETURNING id INTO payment_order_id;

  INSERT INTO public.asri_payment_transactions (order_id, provider, provider_reference, amount, status_message)
  VALUES (payment_order_id, 'duitku', 'schema-test-ref', 1000, 'first')
  ON CONFLICT (provider, provider_reference) WHERE provider_reference IS NOT NULL
  DO UPDATE SET status_message = EXCLUDED.status_message;

  INSERT INTO public.asri_payment_transactions (order_id, provider, provider_reference, amount, status_message)
  VALUES (payment_order_id, 'duitku', 'schema-test-ref', 1000, 'updated')
  ON CONFLICT (provider, provider_reference) WHERE provider_reference IS NOT NULL
  DO UPDATE SET status_message = EXCLUDED.status_message;

  IF (SELECT count(*) FROM public.asri_payment_transactions WHERE provider='duitku' AND provider_reference='schema-test-ref') <> 1 THEN
    RAISE EXCEPTION 'Partial-index upsert created duplicate transaction rows';
  END IF;
  IF (SELECT status_message FROM public.asri_payment_transactions WHERE provider='duitku' AND provider_reference='schema-test-ref') <> 'updated' THEN
    RAISE EXCEPTION 'Partial-index upsert did not update the existing row';
  END IF;

  INSERT INTO public.asri_payment_status_history (order_id, previous_status, new_status, source)
  VALUES (payment_order_id, NULL, 'pending', 'create');
END $$;

-- Callback fingerprint deduplication must reject a duplicate non-null fingerprint.
DO $$
BEGIN
  INSERT INTO public.asri_payment_callbacks (merchant_order_id, payload, event_fingerprint)
  VALUES ('schema-test-payment', '{"case":"one"}', 'fingerprint-unique-test');
  BEGIN
    INSERT INTO public.asri_payment_callbacks (merchant_order_id, payload, event_fingerprint)
    VALUES ('schema-test-payment', '{"case":"duplicate"}', 'fingerprint-unique-test');
    RAISE EXCEPTION 'Expected duplicate callback fingerprint rejection';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
END $$;

-- Build minimum valid V2 order/item fixtures, then verify item snapshot immutability.
DO $$
DECLARE
  product_id uuid;
  order_id uuid;
  item_id uuid;
BEGIN
  SELECT id INTO product_id FROM public.asri_products WHERE sku='TEST-ACTIVE';
  IF product_id IS NULL THEN
    -- Product fixture is inserted after this script by the shell wrapper, so use an isolated fixture here.
    INSERT INTO public.asri_products (sku, slug, name, price, stock_quantity, is_active)
    VALUES ('TEST-V2-PRODUCT', 'test-v2-product', 'V2 fixture', 2500, 2, true)
    RETURNING id INTO product_id;
  END IF;

  INSERT INTO public.asri_store_orders (
    order_number,idempotency_key,request_fingerprint,
    customer_name,customer_phone,shipping_recipient,shipping_phone,
    shipping_address_line,shipping_city,shipping_province,shipping_postal_code,
    shipping_method,shipping_cost,subtotal,total_amount
  ) VALUES (
    'SCHEMA-TEST-ORDER','schema-test-idempotency','schema-test-fingerprint',
    'Test Customer','08123456789','Test Recipient','08123456789',
    'Test Address','Makassar','Sulawesi Selatan','90000',
    'test-courier',0,2500,2500
  ) RETURNING id INTO order_id;

  INSERT INTO public.asri_store_order_items (
    order_id,product_id,sku_snapshot,product_name_snapshot,unit_price,quantity,line_total
  ) VALUES (order_id,product_id,'TEST-V2-PRODUCT','V2 fixture',2500,1,2500)
  RETURNING id INTO item_id;

  BEGIN
    UPDATE public.asri_store_order_items SET quantity=2 WHERE id=item_id;
    RAISE EXCEPTION 'Expected immutable order-item trigger to reject UPDATE';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM = 'Expected immutable order-item trigger to reject UPDATE' THEN
      RAISE;
    END IF;
    IF SQLERRM <> 'store audit/snapshot rows are immutable' THEN
      RAISE;
    END IF;
  END;
END $$;

SELECT 'PASS: schema, RLS/grants, constraints, partial-index upsert, callback deduplication, history identity, and snapshot immutability' AS result;
