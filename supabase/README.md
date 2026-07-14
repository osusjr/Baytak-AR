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
