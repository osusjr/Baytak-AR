# Baytak AR — بيتك

Whole-kitchen and furniture AR visualizer, built as a pitch demo for Amman
kitchen makers and furniture retailers (Abdin Kitchens, JWICO, Universal
Kitchen, Home Centre, THE One, and the rest of the list in
`flutter_app/lib/data/stores.dart` — Midas and Ashley intentionally excluded
since they already ship their own apps).

The one-line pitch: **customers see the whole kitchen as a single 3D scene —
generated from a blueprint — not one cabinet at a time.**

## What's in this folder

```
baytak_ar/
├── flutter_app/          The Flutter application (iOS + Android)
│   ├── lib/              All Dart source (v17: store UI + Design studio)
│   ├── android/…/AndroidManifest.xml + network_security_config.xml
│   └── assets/           5 generated .glb models, catalogue thumbnails,
│                         demo_blueprint.png, tintable textures
├── tools/
│   ├── generate_assets.py       The blueprint→3D pipeline (layout → GLB)
│   ├── design_studio_proto.py   Python mirror of the on-device generator +
│   │                            the v17 element/design system (validated
│   │                            here first, then ported to Dart)
│   └── upload_catalog.py        Push the catalogue to a Supabase project
├── supabase/
│   ├── schema.sql        Cloud catalogue tables + storage buckets + RLS
│   └── README.md         10-minute setup for the cloud catalogue
├── preview/
│   └── kitchen_preview.html Open in any browser: the generated kitchen,
│                            interactive, standing on its own blueprint
└── docs/                 Isometric verification renders
```

## New in Prototype v1 build 26 - THE LAUNCH LAYER

**No more keys in the app.** Build with `AI_PROXY_URL` and every AI call
routes through the new `ai-proxy` Supabase Edge Function
(`supabase/functions/ai-proxy/`): provider keys live in Supabase
secrets, each store has a **license key** the proxy validates (kill
switch included), and every device has a **daily AI quota**. The
benchmark-ranked fallback chains still run client-side - each candidate
simply travels through the proxy.

**The store actually receives orders.** Checkout POSTs the order to the
store's `orders` table (insert-only); offline orders queue on-device and
deliver on the next launch. **Analytics upload too**: product-interest
deltas sync to `analytics_events` on every launch - the store sees what
customers preview, place in AR and buy, in the Supabase dashboard.

**The whole launch procedure is written down**: `supabase/README.md` ->
"LAUNCH PLAYBOOK" - backend setup per store (~30 min), the exact
zero-keys build command, and how the store reads its data.

## Build 25

**The showroom loop closes: quotes + saved designs.** The Design studio
now shows a live itemized **Estimate** (cabinet metres x rate, island,
finish level - a salesperson can defend every line), with **Copy quote**
(formatted text to the clipboard, ready for WhatsApp/SMS) and **Save
design**. Saved kitchens - plan, finishes and price - live in
Profile > **Saved designs**: reopen any customer's kitchen exactly where
they left it, re-style, re-quote, or delete. One shared `estimatePrice()`
drives the product card, the quote and the gallery so they can never
disagree. Rates are demo assumptions and labeled as such in-app.

## Build 24

**The 3D layout editor - drag everything, on the model.** The Design
studio now opens on an isometric 3D view of the generated kitchen, drawn
entirely in Flutter (no WebView - the device landmines stand). Everything
is draggable, IKEA-planner style:

- **Sink / oven / fridge** - grab their round chips and drop them
  anywhere; the cabinet rules from b20 apply on release.
- **Whole cabinet runs** - hold any counter to lift it (a ghost follows
  your finger with a live landing label), slide it along its wall or
  carry it to another wall; appliances ride along, and when the target
  wall reads in the opposite direction the arrangement is mirrored so it
  LOOKS the same as what you built.
- **The island** - hold and drag it across the floor; walkway rules keep
  it honest, and a drag can never silently resize it.
- **Tap a counter** for resize handles (drag the end dots), an
  uppers-on/off toggle, and delete. Every structural edit has **Undo**.
- **Rotate** the view in 90-degree steps; the camera never moves on its
  own (frozen on entry - a drop can't spin the room).

Under the hood: element-level topological depth sorting (scalar painter
sorts provably misorder L-corners), backface-culled walls with low stubs
so near walls stay visible drop targets, grab-anchored floor projection
(no parallax teleports when grabbing the tall fridge), 0.05 m snapping,
and a two-layer paint split so drags only repaint a thin overlay - all
decisions frozen from a three-lens design review before implementation.

## Build 20

**Drop appliances ANYWHERE - the cabinets adapt.** The Design studio chips
are no longer confined to existing counters: drop the fridge mid-run and
the cabinets split around it; drop it in a corner and the perpendicular
run slides back to make room; drop the sink or oven on a bare wall and a
counter grows underneath it. A plan normalizer (ported from a validated
Python prototype, `tools/plan_normalizer_proto.py`) enforces the rules
after every edit: no overlapping cabinets, ever.

**No more counter floods or closed boxes.** The same normalizer runs on
every AI-read blueprint: an island that would blanket the middle of the
room (the reported bug) is shrunk to keep an 0.85 m walkway or dropped,
corner overlaps are trimmed, and the generator now builds at most three
walls - the lowest-content side stays open so the 3D model reads as a
showroom vignette, not a sealed room.

**Two-model AI pipeline.** Blueprint reading is now two-stage: the
benchmark-best vision model (`qwen3.5-397b`) *describes* the drawing like
a surveyor - no schema in sight - and a text reasoning model
(`mistral-large-3-675b`, benchmark-picked from 8 candidates) converts the
description into the plan JSON, applying kitchen sanity rules. Single-call
mode remains as automatic fallback. Also fixed: a coordinate-convention
mismatch that mirrored every AI-read appliance on south/east walls.

## Build 19

**Drag the appliances (IKEA-planner-style).** The Design studio's 2D plan
is interactive: grab the **S**ink, **O**ven or **F**ridge chip and drag
it along any cabinet run - across runs too. A live label reads out the
position in metres while you drag; edge margins, sink↔oven separation and
the fridge slot are enforced so every drop is buildable, and "Build in
3D & AR" re-extrudes the edited plan instantly. No need to redraw a
blueprint to try "what if the fridge was on the other wall".

**Blueprint reading actually measured.** A reproducible benchmark
(`tools/bench/`) scores vision models against ground-truth blueprints.
Result: `qwen/qwen3.5-397b-a17b` leads the chain; the previous leader hung
on every call (the "every blueprint gives the same kitchen" bug). A prompt
echo guard rejects answers that parrot the schema example instead of
measuring the drawing. Optional second provider: a free Gemini key adds
`gemini-3.5-flash` to the fallback chain.

## v17

**Design studio (IKEA-planner-style).** Every generated kitchen is broken
into elements the customer restyles live: wall paint, floor, worktops,
backsplash, upper and lower cabinets *separately*, island finish, hardware
(brass/steel/black), handle style (bar/knob/handleless) and door front
(slab/shaker). A 2D plan + elevation preview repaints instantly on every
tap; "Build in 3D & AR" re-extrudes the GLB on the phone in milliseconds.
Quick looks include **All light** and **All dark** presets. Reachable from
the Blueprint studio (every generate path lands there) and from
Profile → Baytak studio.

**Zero-setup AI on free NVIDIA models.** The provider/API-key pickers are
gone. Blueprint reading and room analysis run against free NVIDIA-hosted
vision models (benchmark-ranked chain, see `tools/bench/`) - the key ships
with the build (`--dart-define`) or via the Supabase `demo_config` table,
and images are auto-compressed on-device to NVIDIA's inline limit. Users
never see a key field.

**Cloud catalogue (Supabase).** Products and hosted GLBs can live in a free
Supabase project instead of the APK - the store updates products server
side, the app syncs on launch, caches models locally, and falls back to the
bundled catalogue offline. See `supabase/README.md`.

## Configuration (build-time, all optional)

```bash
flutter run \
  --dart-define=OPENAI_API_KEY=sk-...               # paid quality mode (GPT-5.6)
  --dart-define=OPENAI_MODEL=gpt-5.6-sol            # or -terra / -luna (cheaper)
  --dart-define=NVIDIA_API_KEY=nvapi-...            # free @ build.nvidia.com
  --dart-define=GEMINI_API_KEY=AIza...              # optional 2nd free provider
  --dart-define=SUPABASE_URL=https://xxx.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=eyJ...            # cloud catalogue
```

With no defines the app runs fully offline: bundled catalogue, manual
measurements in the Blueprint studio, full Design studio and 3D/AR builds.
Only the two AI analysis buttons need a key (any provider works alone).

### Paid quality mode (GPT-5.6, pay-as-you-go - NOT a subscription)

When `OPENAI_API_KEY` is set, GPT-5.6 answers first and the free models
become the fallback chain (a spent credit balance can never kill a demo).
Setup takes ~5 minutes:

1. Create an account at platform.openai.com (this is the developer
   platform - separate from ChatGPT Plus; no subscription involved).
2. Settings -> Billing -> add credits (minimum $5; it is prepaid, so it
   can never bill more than you loaded). Set a monthly budget limit on
   the same page.
3. Create a key at platform.openai.com/api-keys and build with
   `--dart-define=OPENAI_API_KEY=sk-...` (or put it in the Supabase
   demo_config table as `openai_api_key` to key demo phones without
   rebuilding).

Cost per blueprint analysis (two-stage, ~4-5K tokens in / ~2-3K out):

| OPENAI_MODEL | $/analysis (approx) | $5 buys | Notes |
|---|---|---|---|
| `gpt-5.6-sol` (default) | $0.08-0.12 | ~50 analyses | flagship - most powerful |
| `gpt-5.6-terra` | $0.04-0.06 | ~100 | mid tier |
| `gpt-5.6-luna` | $0.015-0.025 | ~250 | budget tier, still GPT-5.6 family |

(The "$0.006/analysis" figure floating around is the older, smaller
`gpt-5.4-mini` - also fine, set it via OPENAI_MODEL if cost matters more
than headroom.)

**Which AI models?** Measured on this repo's benchmark (`tools/bench/`,
four ground-truth blueprints incl. a hard U-shape+bar case, July 2026;
full tables in `tools/bench/RESULTS.md`). Blueprint reading is two-stage:

| Stage | Chain (tried in order) | Why |
|---|---|---|
| 1. describe (vision) | `qwen3.5-397b` > `nemotron-nano-12b-vl` > `llama-3.2-90b-vision` | best layout reader by far |
| 2. plan (reasoning) | `mistral-large-3-675b` > `deepseek-v4-pro` > `nemotron-3-super-120b` | both leaders converted 4/4 descriptions; mistral ~3x faster |

All free NVIDIA-hosted. Notable rejects: `mistral-small-4` drew cabinets
on all four walls of *every* blueprint (the "same kitchen every time"
bug); `llama-4-maverick`, `nemotron-omni-reasoning`, `qwen3.5-122b`,
`gemma-4-31b`, `llama-3.3-nemotron-49b` and `qwen3-next-80b` hung on
every call; `kimi-k2.6` 404s. If NVIDIA's free tier has a bad day, a free
Gemini key (aistudio.google.com, no card) adds `gemini-3.5-flash` as an
independent fallback for both stages. If the demo outgrows free tiers,
the same OpenAI-style client works with paid keys - `gpt-5.4-mini`
(~$0.006/analysis) or `gemini-3.5-flash` paid (~$0.012/analysis) are the
best value; Anthropic's `claude-haiku-4-5` ($1/$5 per MTok) needs a small
client change (different API schema).

**Going to production (b26: IMPLEMENTED):** build with
`--dart-define=AI_PROXY_URL=...` and every AI call routes through the
`ai-proxy` Supabase Edge Function - provider keys live in Supabase
secrets, per-store license keys gate usage, and each device has a daily
AI quota. Orders and analytics upload to the store's tables
(insert-only, offline-safe). The full step-by-step launch procedure is
in `supabase/README.md` -> "LAUNCH PLAYBOOK".

## See it in 60 seconds (no Flutter needed)

Open `preview/kitchen_preview.html` in a browser (needs internet once, to
fetch three.js from a CDN). You'll watch Kitchen K-01 assemble on top of its
blueprint; drag to orbit, scroll to zoom, try Top view. You can also drag
`flutter_app/assets/models/demo_kitchen.glb` into any glTF viewer
(e.g. gltf-viewer.donmccurdy.com) or open it with Windows 3D Viewer.

## Honest map: what is real vs. stubbed

Real and working in this demo: the blueprint→3D extrusion pipeline
(`tools/generate_assets.py` builds the exact model the app ships — 130 parts,
correct kitchen ergonomics: 0.90 m counters, 1.50 m uppers, toe kicks,
appliance placement); the whole-kitchen and single-item 3D viewers; the AR
hand-off button (Scene Viewer on ARCore Androids); the guided 24-photo orbit
capture that saves a reconstruction-ready photo set + manifest; the Amman
store directory.

Stubbed with a documented seam: the raster-blueprint *recognition* step (the
demo uses a precomputed trace of the bundled drawing — the extruder that
follows it is fully real), and the photogrammetry *reconstruction* step (the
app produces the exact input; the compute must run in native iOS code or a
cloud API — see roadmap). On-device photogrammetry cannot run inside
Dart/Flutter itself on today's stacks; anyone claiming otherwise is demoing
smoke.

## Run the app

Prereqs: Flutter SDK 3.22+ installed (`flutter doctor` clean).

```bash
cd flutter_app
flutter create .            # generates android/ + ios/ platform folders
flutter pub get
```

Then apply the platform config below (one-time), plug in a device, and:

```bash
flutter run
```

The v3 UI is a full store app (structure translated from the ARoom Kotlin
reference into Flutter): bottom navigation with Home / Search / Cart /
Profile; Home carries category tabs with a special-products rail, "Best
deals" rail and product grid; product pages embed the live 3D viewer with
finish/size selectors, description and a sticky add-to-cart bar; the cart
has quantity steppers, totals and a demo checkout that records local
orders; Profile holds favorites, orders, and the Baytak studio tools.
Blueprint studio now accepts **user-uploaded drawings** (gallery or
camera) alongside the bundled demo; uploads persist on-device. Cart,
favorites, orders and the profile name persist locally
(shared_preferences) - no login/backend by design, so the showroom demo
works offline. Display/body/mono fonts (Fraunces, Manrope, IBM Plex Mono)
load via google_fonts on first run with internet, then cache.

### Android config

The manifest is already included in this repo
(`android/app/src/main/AndroidManifest.xml`) with camera + internet
permissions and a network security config that permits cleartext for
**localhost only** - model_viewer_plus serves the bundled models from an
in-app http server on 127.0.0.1, and without this Android 9+ blocks it with
`ERR_CLEARTEXT_NOT_PERMITTED`. `flutter create .` keeps existing files, so
these survive project regeneration.

One manual edit remains: in `android/app/build.gradle.kts` inside
`defaultConfig` set `minSdk = 24`.

Build an installable APK:

```bash
flutter build apk --release
# output: build/app/outputs/flutter-apk/app-release.apk — send to any Android phone
```

### iOS config (required)

In `ios/Runner/Info.plist` add:

```xml
<key>NSCameraUsageDescription</key>
<string>Baytak AR captures photo orbits of furniture to build 3D models.</string>
```

Set the platform floor in `ios/Podfile` to `platform :ios, '13.0'`.

## About the IPA — read this before anything else

An `.ipa` cannot be produced in this workspace: iOS builds require macOS +
Xcode, and installable IPAs must be **signed with an Apple identity** — there
is no way around Apple's signing chain. Here are your three real routes, in
order of practicality for a fresh-grad demo:

**Route A — you have (or can borrow) any Mac.** Free Apple ID is enough, no
$99 account. Open `ios/Runner.xcworkspace` in Xcode, select your iPhone,
set your Apple ID under Signing & Capabilities (Personal Team), press Run.
The app installs and works for 7 days per signing (just re-run to refresh).
On the phone: Settings → General → VPN & Device Management → trust your
developer profile. This is how most student demos ship.

**Route B — no Mac at all.** Use a cloud macOS CI. Codemagic's free tier
builds Flutter iOS; configure an unsigned build
(`flutter build ios --release --no-codesign`), have the workflow zip
`Runner.app` into `Payload/` and rename to `.ipa`, then sideload that
unsigned IPA onto your iPhone from Windows/Linux with **Sideloadly** or
**AltStore**, which sign it on the fly with your free Apple ID (same 7-day
refresh). GitHub Actions with a `macos-latest` runner works identically.

**Route C — the real thing.** Apple Developer Program ($99/yr) →
`flutter build ipa` → distribute via TestFlight. This is the route once a
store says yes, because you can put the demo on *their* phones cleanly.

Meanwhile, the **APK from the Android section installs in two minutes** and
demos every feature — lead store pitches with Android, keep the iPhone for
Route A.

## AR notes per platform

**Android (Scene Viewer).** Needs the free "Google Play Services for AR"
(ARCore) app — most phones from ~2019 on. Scene Viewer can be strict about
wanting an **https-hosted** model in AR mode; if the AR button opens 3D view
but refuses AR, upload `demo_kitchen.glb` anywhere public (GitHub raw /
Firebase Hosting) and point `src:` in `model_viewer_screen.dart` at that URL —
the plain 3D viewer keeps using the bundled asset either way.

**iOS (Quick Look).** Android AR uses the bundled `.glb` directly. iOS Quick Look requires `.usdz`:
on any Mac, open the `.glb` in **Reality Converter** (free, Apple) → export
`.usdz` → host it anywhere https → set `iosSrc:` in
`lib/screens/model_viewer_screen.dart`. One line, already marked with a
comment.

## Roadmap seams (already architected in the code)

**Furniture scanning → 3D model.** `PhotogrammetryService` saves the photo
orbit + manifest. Plug in one of: (a) **Apple Object Capture** (iOS 17+,
on-device, best quality) behind a `MethodChannel('baytak/object_capture')` —
Swift side runs `ObjectCaptureSession` and returns a USDZ/GLB path; (b) a
**cloud photogrammetry API** (Luma AI, Polycam, KIRI Engine) — upload the
scan directory, poll, download `.glb`, open it in the existing viewer. (b)
is the cross-platform answer and the one to demo on Android.

**Kitchen/room scanning.** On LiDAR iPhones, **Apple RoomPlan** returns a
*parametric* room (walls, openings, counters as JSON) — which is exactly the
input format of the extruder in `tools/generate_assets.py`. That pairing
(RoomPlan → same extruder) is your cleanest path to "scan the kitchen,
get the model."

**Blueprint recognition.** v1 pragmatic: a trace-assist UI where the shop
tech taps wall corners and drags cabinet runs over the uploaded drawing —
30 seconds of human input, zero ML risk, feeds the extruder directly.
v2: automatic raster floor-plan vectorization (research keyword:
CubiCasa5K dataset; "raster-to-vector floor plan" literature).

**True in-app AR placement** (anchoring the kitchen to a detected floor
plane inside the Flutter UI rather than handing off to Scene Viewer): add
`ar_flutter_plugin_2`, render the same GLBs as anchored nodes on plane tap.
Kept out of the demo build on purpose — the plugin needs per-platform setup
and its API moves; the hand-off AR already demos the experience.

## Regenerating / editing the kitchen

Everything about K-01 lives in the `LAYOUT` dict at the top of
`tools/generate_assets.py` — segment widths, island size, window, materials.
Edit and run:

```bash
python3 tools/generate_assets.py
```

New blueprint PNG, new GLB, new preview data — all regenerate in ~2 seconds.
That speed *is* the pitch to the stores: "change the drawing, the kitchen
follows."
