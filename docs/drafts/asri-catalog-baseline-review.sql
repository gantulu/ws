-- REVIEW ONLY — Asri Collection catalog baseline draft
-- Reference: read-only audit of public.asri_products in the legacy shared project.
-- Target: a NEW dedicated Asri Collection Supabase project only.
-- This file intentionally lives in docs/drafts; it is NOT an executable migration yet.
-- Before promotion into supabase/migrations, generate the migration file with Supabase CLI,
-- copy the reviewed SQL, then run local/disposable-database verification.
-- Safe boundary: this file is a repository migration draft; do not apply to the legacy project.
-- Compatibility: preserves legacy column names, defaults, nullable SKU/slug, constraints,
-- partial indexes, active-product public read policy, and updated_at trigger contract.

create table public.asri_products (
  id uuid primary key default gen_random_uuid(),
  sku text unique,
  slug text unique,
  name text not null,
  description text,
  category text,
  brand text,
  price bigint not null,
  compare_at_price bigint,
  currency text not null default 'IDR',
  stock_quantity integer not null default 0,
  images text[] not null default '{}'::text[],
  colors jsonb not null default '[]'::jsonb,
  sizes jsonb not null default '[]'::jsonb,
  is_active boolean not null default true,
  is_featured boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint asri_products_price_check check (price >= 0),
  constraint asri_products_compare_at_price_check check (compare_at_price is null or compare_at_price >= 0),
  constraint asri_products_compare_price_check check (compare_at_price is null or compare_at_price >= price),
  constraint asri_products_currency_check check (currency = 'IDR'),
  constraint asri_products_stock_quantity_check check (stock_quantity >= 0)
);

create index asri_products_active_category_idx
  on public.asri_products (category, created_at desc)
  where is_active = true;

create index asri_products_featured_idx
  on public.asri_products (is_featured, created_at desc)
  where is_active = true;

create or replace function public.asri_products_set_updated_at()
returns trigger
language plpgsql
set search_path = pg_catalog
as $$
begin
  new.updated_at := pg_catalog.now();
  return new;
end;
$$;

revoke all on function public.asri_products_set_updated_at() from public, anon, authenticated;

create trigger asri_products_updated_at_trigger
before update on public.asri_products
for each row execute function public.asri_products_set_updated_at();

alter table public.asri_products enable row level security;

revoke all on public.asri_products from public, anon, authenticated;
grant select on public.asri_products to anon, authenticated;
grant all on public.asri_products to service_role;

create policy "Public can read active ASRI products"
  on public.asri_products
  for select
  to anon, authenticated
  using (is_active = true);
