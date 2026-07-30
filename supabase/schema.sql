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

-- ===========================================================================
-- LAUNCH TABLES (b26): production backend for licensed stores.
-- The app holds ONLY the anon key; provider AI keys live in Edge Function
-- secrets. anon can INSERT events/orders but never read them back - the
-- store reads its data in the Supabase dashboard (or a future portal).
-- ===========================================================================

-- ---------------------------------------------------------------- licenses
-- One row per licensed store. The ai-proxy Edge Function checks the
-- x-license-key header against this table when REQUIRE_LICENSE=true.
-- No anon policies: only the service role (inside the function) reads it.
create table if not exists public.licenses (
  key        text primary key,            -- e.g. 'bk-abdin-2026-xxxx'
  store      text not null,               -- display name
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.licenses enable row level security;

-- ------------------------------------------------------------- proxy_usage
-- Per-device daily AI-call counter (abuse guard). Service-role only.
create table if not exists public.proxy_usage (
  device_id text not null,
  day       date not null,
  count     integer not null default 0,
  primary key (device_id, day)
);
alter table public.proxy_usage enable row level security;

-- Atomic increment used by the Edge Function; returns the new count.
create or replace function public.bump_proxy_usage(p_device text, p_day date)
returns integer
language sql
security definer
set search_path = public
as $$
  insert into proxy_usage (device_id, day, count)
  values (p_device, p_day, 1)
  on conflict (device_id, day)
  do update set count = proxy_usage.count + 1
  returning count;
$$;
revoke all on function public.bump_proxy_usage(text, date)
  from public, anon, authenticated;  -- service_role keeps its own grant

-- --------------------------------------------------------- analytics_events
-- Daily-aggregated interest events uploaded by the app (insert-only).
create table if not exists public.analytics_events (
  id          bigint generated always as identity primary key,
  device_id   text not null,
  kind        text not null,              -- details/viewer/cart/generate/...
  product_id  text,
  count       integer not null default 1,
  inserted_at timestamptz not null default now()
);
alter table public.analytics_events enable row level security;

drop policy if exists "anon insert analytics" on public.analytics_events;
create policy "anon insert analytics"
  on public.analytics_events for insert
  to anon, authenticated
  with check (count > 0 and count <= 10000
              and char_length(device_id) between 8 and 64);

-- ------------------------------------------------------------------- orders
-- Orders submitted from the app (insert-only from anon; the store reads
-- them in the dashboard). Lines carry product ids + prices as JSON.
create table if not exists public.orders (
  id          text primary key,           -- app-generated (device+millis)
  device_id   text not null,
  customer    text not null default '',
  lines       jsonb not null default '[]',
  total_jd    integer not null default 0,
  created_at  timestamptz not null default now()
);
alter table public.orders enable row level security;

drop policy if exists "anon insert orders" on public.orders;
create policy "anon insert orders"
  on public.orders for insert
  to anon, authenticated
  with check (char_length(id) between 8 and 64 and total_jd >= 0
              and char_length(device_id) between 8 and 64);
-- HARDENING NOTE: the anon key is public, so these tables accept junk
-- inserts (spam, never data theft - there is NO anon SELECT). Real orders
-- carry real customer names + valid product ids; a store filters those in
-- the dashboard. For a fully sealed launch, route inserts through an
-- 'ingest' Edge Function behind the license gate (same pattern as
-- ai-proxy) and drop these anon policies.
