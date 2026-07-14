# Baytak AR (بيتك) - project briefing

Flutter AR furniture & kitchen visualizer. Demo pitch target: furniture
retailers in Amman, Jordan (Abdin Kitchens, JWICO, Universal Kitchen,
Home Centre, THE One). Investor-grade demo, currently at v16.

## Layout
- `flutter_app/` - the app (Flutter 3.44, Dart 3). Entry: lib/main.dart.
- `tools/` - Python asset pipeline: generate_assets.py bakes the textured
  catalogue GLBs + thumbnails; generate_webar.py emits the static WebAR
  site into `webar/`.
- `webar/` - no-install AR site (host on Netlify/GitHub Pages, QR per
  product).

## Architecture that matters
- Catalogue: lib/data/catalog.dart (5 demo products, bundled GLB assets).
- State: lib/state/app_state.dart - cart/favorites/orders/name persisted
  via shared_preferences, exposed by AppScope (InheritedNotifier).
- 3D/AR: model_viewer_plus -> Google Scene Viewer. ONE WebView in the
  whole app, ALWAYS full-screen (ModelViewerScreen). Embedding a WebView
  mid-layout broke page compositing on the test device - do not do it.
- On-device generator: lib/services/kitchen_generator.dart. Plan-driven
  parametric builder + binary glTF writer. LayoutPlan (runs on any wall,
  appliances, windows, island/peninsula, palette) -> textured GLB in app
  documents, opened via file:// src. Also builds whole room scenes from
  furniture placements (90-degree rotations only - keeps boxes
  axis-aligned).
- Textures: neutral PNGs in assets/textures/, embedded into generated
  GLBs and TINTED by each material's baseColorFactor (palettes:
  warm_walnut / light_oak / dark_modern). Swap PNGs = new look, no code.
- AI: lib/services/ai_client.dart - provider-agnostic vision call.
  Gemini (free tier, default; model fallback chain, 8192 output tokens
  because thinking counts against the budget, responseMimeType JSON) or
  Anthropic (paid). Keys entered in-app, stored in shared_preferences
  only. blueprint_ai.dart reads kitchen blueprints -> LayoutPlan;
  room_ai.dart reads room photos -> measurements + catalogue picks with
  x/z/rot placements.
- Analytics: lib/services/analytics.dart - on-device event counts
  (details/viewer/cart/generate/room_scene), screen in Profile.

## Device-specific landmines (test phone: Galaxy S9+, Android 10, Mali-G72)
- Impeller is DISABLED in AndroidManifest (EnableImpeller=false): Mali
  Impeller silently blanked entire routes. Keep Skia.
- PageTransitionsTheme uses FadeUpwardsPageTransitionsBuilder on both
  platforms: the default Zoom transition GPU-snapshots pages (broken on
  this GPU). CupertinoPageTransitionsBuilder no longer exists in the
  material library - do not reintroduce it.
- Version stamps: home header shows "AR · vN"; Blueprint/Details/Room
  screens carry "... vN - RENDER OK" strips. Bump ALL stamps every
  change round - they are how stale builds are detected.
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
  the validated prototype.
- Honesty rule: demo limitations are stated in-app (photo-based room
  measurement vs live AR, on-device analytics vs backend, key handling).
  Production seams are documented where they occur in code.
