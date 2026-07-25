# Baytak AR (بيتك) - project briefing

Flutter AR furniture & kitchen visualizer. Demo pitch target: furniture
retailers in Amman, Jordan (Abdin Kitchens, JWICO, Universal Kitchen,
Home Centre, THE One). Investor-grade demo, branded "PROTOTYPE v1"
(internal build counter in lib/theme.dart, currently 25).

## Layout
- `flutter_app/` - the app (Flutter 3.44, Dart 3). Entry: lib/main.dart.
- `tools/` - Python asset pipeline: generate_assets.py bakes the textured
  catalogue GLBs + thumbnails; design_studio_proto.py is the Python mirror
  of the on-device generator + v17 design system (option tables live in
  BOTH files - keep in sync); upload_catalog.py pushes the catalogue to
  Supabase; generate_webar.py emits the static WebAR site into `webar/`;
  bench/ scores vision models against ground-truth blueprints (run it
  before touching the aiVisionModels chain order).
- `supabase/` - cloud catalogue schema (products + demo_config tables,
  public model/thumb buckets, anon read-only RLS) + setup README.
- `webar/` - no-install AR site (host on Netlify/GitHub Pages, QR per
  product).

## Architecture that matters
- Catalogue: lib/data/catalog.dart. Bundled 5-product set is the offline
  fallback; demoCatalog/furnitureCatalog/specialProducts/bestDeals are now
  GETTERS over a swappable list - lib/services/remote_catalog.dart
  replaces it from Supabase when DemoConfig is set (assets cached in
  documents dir by updated_at). byId() NEVER throws: falls back bundled ->
  generated-registry -> placeholder (cart lines can outlive generated
  models across restarts). Screens listing products subscribe via
  AppScope.of(context) so the swap repaints them.
- Config: lib/config/demo_config.dart - all keys are --dart-define
  (OPENAI_API_KEY + OPENAI_MODEL, NVIDIA_API_KEY, GEMINI_API_KEY,
  SUPABASE_URL, SUPABASE_ANON_KEY). No key UI in-app.
- State: lib/state/app_state.dart - cart/favorites/orders/name persisted
  via shared_preferences, exposed by AppScope (InheritedNotifier).
- 3D/AR: model_viewer_plus -> Google Scene Viewer. ONE WebView in the
  whole app, ALWAYS full-screen (ModelViewerScreen). Embedding a WebView
  mid-layout broke page compositing on the test device - do not do it.
- On-device generator: lib/services/kitchen_generator.dart. Plan-driven
  parametric builder + binary glTF writer. LayoutPlan (runs on any wall,
  appliances, windows, island/peninsula, palette; toJson/fromJson) ->
  textured GLB in app documents, opened via file:// src. Also builds whole
  room scenes from furniture placements (90-degree rotations only - keeps
  boxes axis-aligned). b20 COORDINATE CONVENTION (unified, do not revert):
  run u is measured from the WEST end on north/south walls and the NORTH
  end on east/west walls - same as the AI schema; _Frame, the 2D painters
  and the normalizer all agree. planWalls() caps built walls at 3 (lowest
  content side stays open - showroom vignette, never a sealed box);
  windows draw once per BUILT wall. Fridge-only runs (length 0.8,
  fridge='start') are legal - that is a freestanding fridge.
- Plan normalizer: lib/services/plan_normalizer.dart (Python prototype
  tools/plan_normalizer_proto.py - run it after rule changes; constants
  FROZEN from it). Runs after AI parse (blueprint_ai), on studio entry and
  after every drag edit: clamps/merges runs (runs touching at a fridge
  seam stay separate), trims perpendicular runs clear of fridges
  (fridge is immovable - "cabinets adjust"), E/W yields to N/S at plain
  counter corners, island overlaps pulled to touching + attachments
  allowed on adjacent sides only (opposite pair = room-bridging bar ->
  shorter contact pushed to a 0.85 m walkway), island < 0.6 m after
  shrinking is dropped (fixes the "counter covered the whole middle"
  blueprint failure), appliances re-clamped.
- Design system (v17): lib/services/kitchen_design.dart. KitchenDesign =
  one choice per element (lower/upper/island cabinet finishes, worktop,
  wall, floor, backsplash, hardware, handle bar/knob/none, door
  slab/shaker) -> material color/texture overrides + geometry switches for
  the generator. Upper cabinets have their own material slots
  ('upper'/'upper_door'). Presets include all_light/all_dark and the three
  AI palette names. UI: lib/screens/design_studio_screen.dart with live 2D
  plan+elevation CustomPaint preview (NO WebView); every generate path
  (AI one-tap, AI review, manual) lands there before 3D.
- Textures: neutral PNGs in assets/textures/, embedded into generated
  GLBs and TINTED by each material's baseColorFactor; designs can also
  remap which texture a slot uses (e.g. butcher-block worktop -> wood).
  Swap PNGs = new look, no code.
- AI: lib/services/ai_client.dart - hosted models, tried as candidate
  chains: OpenAI GPT-5.6 FIRST when OPENAI_API_KEY is set (api.openai.com,
  paid pay-as-you-go; multimodal so ONE model serves both chains;
  GPT-5.x quirks: max_completion_tokens not max_tokens, no temperature
  override), then NVIDIA (integrate.api.nvidia.com, OpenAI-style
  chat/completions, Bearer nvapi-key), then Gemini via Google's
  OpenAI-compatible endpoint when GEMINI_API_KEY is set. visionCall()
  uses aiVisionModels
  (qwen3.5-397b > nemotron-nano-12b-vl > llama-3.2-90b), textCall() uses
  aiTextModels (mistral-large-3-675b > deepseek-v4-pro >
  nemotron-3-super-120b); BOTH orders are BENCHMARK-RANKED (tools/bench/,
  4 ground-truth blueprints incl. the hard U-shape; RESULTS.md has the
  tables). Rejected: mistral-small-4 (same-kitchen-every-time bug),
  kimi-k2.6 (404), and llama-4-maverick/nemotron-omni/qwen-122b/gemma-4/
  llama-3.3-nemotron-49b/qwen3-next-80b (HANG - the 60 s per-candidate
  timeout + 150 s total budget make every failure fall through to the
  next candidate; do not "optimize" that away). Empty content falls back
  to message.reasoning_content. Images auto-downscaled/JPEG-recompressed
  on-device to <=130 KB raw (NVIDIA ~180 KB inline data-URI limit, base64
  +33%) in an isolate via compute(). Key resolution: dart-define, else
  Supabase demo_config cached to prefs ('cfg_nvidia_key'/'cfg_gemini_key'/
  'cfg_openai_key'). No provider/key UI; aiConfigured() gates the AI
  buttons. extractJsonObject() strips <think> blocks/fences and isolates
  the first balanced JSON object. blueprint_ai.dart is TWO-STAGE: vision
  describes the drawing (surveyor prompt, no schema) -> text model builds
  the plan JSON; single-call path is the automatic fallback; every parse
  passes the echo guard (width/depth < 1 m rejected) AND normalizePlan().
  Prompts share the _senses block (pantry is not a fridge, peninsula is
  the island not a run, dashed edges are not walls, w=x-extent d=z-extent)
  - each line guards a misread observed on the bench U-shape.
  room_ai.dart reads room photos -> measurements + catalogue picks.
- Drag editor: lib/services/plan_editor.dart - pure logic; b20 free
  placement via place(kind, wall, u): drop on/near/far from cabinets and
  runs are created (sink/oven grow a 1.5 m run on bare wall), extended
  (within 0.6 m of an end), or split (mid-run fridge = 0.8 m gap between
  two touching runs); fridge on bare wall = fridge-only run; corner
  conflicts resolved by normalizePlan (constants: edgeMargin 0.45,
  minSeparation 0.95, fridgeSpan 0.8, endSnap 0.55). Editor-created runs
  carry RunPlan.auto (persisted in JSON): when their appliance moves away
  the normalizer deletes them - auto cabinets never outlive their reason
  to exist (b21 fix for "ghost cabinets ruin the design"). UI in
  design_studio_screen.dart: PlanTransform maps plan metres <-> canvas px
  (b20 unified convention), wallCoord() targets ANY wall, chips live-move
  while over existing cabinets and turn into a ghost + landing label over
  bare floor; the STRUCTURAL edit happens once on drag release (never
  during updates - a drag must not litter the plan with run fragments).
  Chip-scoped PanGestureRecognizer keeps page scroll working elsewhere;
  every edit persists the plan + bumps editor.revision for repaint.
  Unit-tested in widget_test.dart - extend those tests when touching the
  drag rules.
- 3D layout editor (b24): lib/widgets/iso_kitchen_editor.dart - the
  Design studio's headline view; isometric CustomPaint scene (NO WebView)
  where chips (S/O/F, eager grab), whole runs + island (long-press 260 ms
  to lift - preserves page scroll), and resize handles are draggable;
  release applies place()/moveRun()/moveIsland()/resizeRun() + normalize.
  Panel-frozen decisions (do not regress): element-level TOPOLOGICAL
  depth sort (scalar keys misorder L-corners), walls backface-culled
  (near built walls = 0.14 m stubs), view rotation k is VIEW-SPACE ONLY
  (plan data never rotated; k frozen on entry, changed only by the rotate
  button), grab-anchored floor unprojection (parallax-free fridge drags),
  re-wall drops mirror the run when target wall reads opposite on screen,
  0.05 m quantization, two-layer painters (static scene keyed on
  revision/selection; overlay repaints per drag tick via ValueNotifier).
  PlanEditor extras: moveRun(mirror:)/resizeRun/removeRun/checkpoint/
  undo (stack depth 8) + undoDiscardLast for failed gestures.
- Analytics: lib/services/analytics.dart - on-device event counts
  (details/viewer/cart/generate/design/room_scene), screen in Profile.

## Device-specific landmines (test phone: Galaxy S9+, Android 10, Mali-G72)
- Impeller is DISABLED in AndroidManifest (EnableImpeller=false): Mali
  Impeller silently blanked entire routes. Keep Skia.
- PageTransitionsTheme uses FadeUpwardsPageTransitionsBuilder on both
  platforms: the default Zoom transition GPU-snapshots pages (broken on
  this GPU). CupertinoPageTransitionsBuilder no longer exists in the
  material library - do not reintroduce it.
- Version stamps: the user-facing label is kVersionLabel ('PROTOTYPE v1',
  lib/theme.dart) shown in the home header; Blueprint/Details/Room/
  Design-studio screens carry "... $kBuildStamp - RENDER OK" strips.
  Bump kBuildNumber (theme.dart) EVERY change round - the build counter
  is how stale builds are detected now that the label stays fixed.
- main.dart installs an ErrorWidget.builder that paints exceptions on
  screen. Keep it until release.

## Dart 3 gotchas already hit (do not regress)
- utf8.encode returns Uint8List: build List<int> then Uint8List.fromList.
- .clamp() returns num: append .toDouble() where a double is required.
- CardTheme->CardThemeData, TabBarTheme->TabBarThemeData.
- model_viewer_plus: use ArScale.fixed / ArPlacement.floor enums.
- Statics on a StatefulWidget need the class prefix from its State.

## Dev environment quirks (owner's machine, Windows 11)
- 360 Total Security blocks builds ("Access is denied / Unable to
  determine engine version"), especially after flutter clean or new
  packages. Ritual: taskkill dart.exe & java.exe, disable 360, build,
  re-enable. Avoid `flutter clean` unless truly needed.
- Do NOT run `flutter upgrade` mid-project.
- minSdk 24 was set manually in android/app/build.gradle.kts - never
  regenerate/overwrite the android folder.

## Working conventions
- All generated-geometry changes are prototyped and validated in Python
  (tools/ mirrors) BEFORE porting to Dart - coordinates are frozen from
  the validated prototype. v17 design-system geometry (handles, shaker
  fronts, upper-material split) lives in tools/design_studio_proto.py.
- Honesty rule: demo limitations are stated in-app (photo-based room
  measurement vs live AR, on-device analytics vs backend, key handling).
  Production seams are documented where they occur in code (demo keys via
  dart-define/demo_config vs a backend proxy; supabase/README.md).
