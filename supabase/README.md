# Baytak AR - Supabase cloud catalogue

The demo can run its catalogue from a free Supabase project instead of the
APK - the configuration a furniture store would actually buy: they update
products/prices/models server-side, every installed app picks the change
up on next launch, and the app still works offline from its last sync (or
the bundled set) when the network is down.

## Setup (once, ~10 minutes, free tier)

1. Create a project at [supabase.com](https://supabase.com) (free tier).
2. Open the SQL editor, paste and run `schema.sql` (this file's folder).
   It creates the `products` + `demo_config` tables (anon = read-only via
   RLS) and the public `models` / `thumbs` storage buckets.
3. Push the catalogue and assets:

   ```bash
   export SUPABASE_URL=https://<project-ref>.supabase.co
   export SUPABASE_SERVICE_KEY=<service_role key>   # Settings -> API
   python tools/upload_catalog.py
   # optionally also distribute the demo NVIDIA key to demo phones:
   python tools/upload_catalog.py --nvidia-key nvapi-...
   ```

4. Build the app against the project (anon key only - safe to embed):

   ```bash
   flutter run \
     --dart-define=SUPABASE_URL=https://<project-ref>.supabase.co \
     --dart-define=SUPABASE_ANON_KEY=<anon key>
   ```

Profile -> About -> "Catalogue source" shows whether the running app is on
the cloud catalogue or the bundled fallback.

## How the app consumes it

`lib/services/remote_catalog.dart` fetches `products` ordered by
`sort_order`, downloads each row's GLB/thumbnail/hero from storage into the
documents directory (cached by `updated_at` - unchanged files are never
re-downloaded), swaps the live catalogue in memory and repaints the store.
Any error leaves the bundled catalogue untouched.

## Security model (demo vs production)

- The app holds only the **anon** key; RLS makes both tables read-only.
- Buckets are public-read: GLBs and product photos are marketing assets.
- `demo_config.nvidia_api_key` is a **demo convenience** - it reaches every
  install, exactly like baking the key into the build. For production,
  delete that row and proxy AI calls through a Supabase **Edge Function**
  that holds the NVIDIA (or other provider) key server-side; the app then
  calls the function with the anon key + a rate limit. The client seam is
  one function in `lib/services/ai_client.dart` (`visionCall`).
- Writes go through `tools/upload_catalog.py` with the service-role key,
  which never leaves the retailer's machine.

---

# LAUNCH PLAYBOOK (b26) - from pitch demo to licensed store

The app now ships with the full production seam implemented. This is the
exact order of operations to launch for a paying store.

## 1. Backend (you, once per store - ~30 minutes)

```bash
# a. create a Supabase project for the store (supabase.com, Pro plan
#    recommended for production: $25/mo), then in the SQL editor run
#    schema.sql from this folder (idempotent - safe to re-run).

# b. install the Supabase CLI (supabase.com/docs/guides/cli), then:
supabase login
supabase link --project-ref <the-store-project-ref>

# c. deploy the AI proxy and set its secrets - keys NEVER enter the app:
supabase functions deploy ai-proxy
supabase secrets set OPENAI_API_KEY=sk-...        # platform.openai.com
supabase secrets set NVIDIA_API_KEY=nvapi-...     # free fallback chain
supabase secrets set GEMINI_API_KEY=AIza...       # optional 2nd fallback
supabase secrets set REQUIRE_LICENSE=true          # ON by default; set
                                                  # 'false' only for demos
supabase secrets set DEVICE_DAILY_LIMIT=300       # per device/day (fairness)
supabase secrets set LICENSE_DAILY_LIMIT=4000     # per STORE/day - the real
                                                  # spend cap (billed calls)
# b29 photo render (OpenAI gpt-image, ~$0.02-0.19 per picture - these are
# SEPARATE, much lower ceilings; defaults shown):
supabase secrets set DEVICE_DAILY_IMAGE_LIMIT=10  # renders per device/day
supabase secrets set LICENSE_DAILY_IMAGE_LIMIT=80 # renders per STORE/day
# NOTE: b29 requires redeploying the function (functions deploy ai-proxy).

# CRITICAL last-line-of-defense, on YOUR end (2 minutes):
# platform.openai.com -> Settings -> Limits -> set a HARD monthly usage
# limit on the account. The proxy caps calls; this caps dollars. The anon
# key and license key both ship in the app and must be treated as PUBLIC -
# the LICENSE_DAILY_LIMIT + this account cap are what actually protect the
# card, not those keys.

# d. create the store's license key (SQL editor):
#    insert into licenses (key, store) values ('bk-<store>-2026-<random>', '<Store name>');

# e. upload the store's catalogue:
python tools/upload_catalog.py   # uses SUPABASE_URL + SERVICE_ROLE env vars
```

## 2. The launch build (no provider keys!)

```bash
flutter build appbundle \
  --dart-define=SUPABASE_URL=https://<ref>.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=eyJ... \
  --dart-define=AI_PROXY_URL=https://<ref>.supabase.co/functions/v1/ai-proxy \
  --dart-define=LICENSE_KEY=bk-<store>-2026-<random>
```

That build contains ZERO provider keys. The blueprint screen will show
"answered by ... (store proxy)" - your proof the proxy is serving.

## 3. What the store gets automatically

* AI analyses through the proxy (their license, your keys, per-device
  daily quota against abuse).
* Orders land in the `orders` table the moment a customer checks out
  (offline orders queue on-device and deliver on the next launch).
* Product-interest analytics accumulate in `analytics_events` -
  which kitchens get previewed, placed in AR, added to cart.
* Catalogue updates server-side, no app update needed.
* Kill switch: set `active=false` on their license row and AI stops;
  delete the row entirely to revoke a lost device fleet.

## 4. Reading the store's data

Supabase dashboard -> Table editor: `orders` (newest first),
`analytics_events` (aggregate in SQL: `select kind, product_id,
sum(count) from analytics_events group by 1,2 order by 3 desc`),
`proxy_usage` (AI spend control). A branded web portal is the natural
next milestone but the dashboard is enough to operate.
