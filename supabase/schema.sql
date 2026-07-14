-- Baytak AR - cloud catalogue schema (v17)
-- Run this in the Supabase SQL editor of a fresh (free-tier) project,
-- then push the demo catalogue with:  python tools/upload_catalog.py
--
-- Design: the app is read-only (anon key). Writes happen only through
-- tools/upload_catalog.py using the service-role key, which never ships
-- in the app. Storage buckets are public-read: the GLBs/thumbnails are
-- marketing assets, not secrets.

-- ---------------------------------------------------------------- products
create table if not exists public.products (
  id            text primary key,
  title         text not null,
  category      text not null
                check (category in ('kitchens', 'living', 'dining', 'storage')),
  blurb         text not null default '',
  description   text not null default '',
  w_cm          integer not null default 0,
  d_cm          integer not null default 0,
  h_cm          integer not null default 0,
  materials     jsonb not null default '[]',  -- ["Walnut cabinetry", ...]
  finishes      jsonb not null default '[]',  -- ARGB ints for swatches
  variants      jsonb not null default '[]',
  price_jd      integer not null default 0,
  deal_price_jd integer,
  camera_orbit  text,
  asset_path    text not null,                -- object path in bucket 'models'
  thumb_path    text not null,                -- object path in bucket 'thumbs'
  hero_path     text,                         -- optional, bucket 'thumbs'
  sort_order    integer not null default 100,
  updated_at    timestamptz not null default now()
);

alter table public.products enable row level security;

drop policy if exists "anon read products" on public.products;
create policy "anon read products"
  on public.products for select
  to anon, authenticated
  using (true);

-- --------------------------------------------------------------- demo_config
-- Key/value knobs pushed to demo phones without rebuilding the app.
-- Currently read by the app: 'nvidia_api_key' (free build.nvidia.com key).
-- HONESTY NOTE: anything in this table reaches every app install - it is a
-- demo convenience, not a production key store. Production proxies AI calls
-- through an Edge Function that keeps keys server-side (see supabase/README).
create table if not exists public.demo_config (
  key   text primary key,
  value text not null
);

alter table public.demo_config enable row level security;

drop policy if exists "anon read demo_config" on public.demo_config;
create policy "anon read demo_config"
  on public.demo_config for select
  to anon, authenticated
  using (true);

-- ----------------------------------------------------------------- storage
-- Public-read buckets for the 3D models and the card images.
insert into storage.buckets (id, name, public)
values ('models', 'models', true), ('thumbs', 'thumbs', true)
on conflict (id) do update set public = true;
