import 'dart:async';

import '../data/catalog.dart';

/// Blueprint -> 3D pipeline seam.
///
/// DEMO BEHAVIOUR
///   Streams the real pipeline stages (they mirror what
///   tools/generate_assets.py actually does) and resolves to the
///   pre-generated bundled model. The point of the demo is that the drawing
///   shown on the Blueprint screen and the model you walk through are the
///   same layout, produced by the same extrusion rules.
///
/// PRODUCTION PATH (see README "Blueprint pipeline roadmap")
///   1. Upload the raster blueprint to a backend.
///   2. Floor-plan recognition: wall/opening/fixture vectorization
///      (models trained on datasets such as CubiCasa5K, or a manual
///      trace-assist UI as a pragmatic v1).
///   3. Run the SAME parametric extruder as generate_assets.py
///      (layout JSON -> boxes -> GLB). The extruder is already written.
///   4. Return a hosted .glb (+ .usdz for iOS Quick Look) to this client.
class BlueprintService {
  BlueprintService._();
  static final instance = BlueprintService._();

  static const stages = <String>[
    'Reading blueprint raster...',
    'Tracing walls and openings...',
    'Detecting cabinet runs, island and appliances...',
    'Extruding layout to 3D (walls, counters, uppers)...',
    'Assigning materials: walnut / olive / basalt / brass...',
    'Exporting glTF binary...',
  ];

  /// Emits each stage, then completes with the generated kitchen model.
  Stream<String> generate() async* {
    for (final stage in stages) {
      yield stage;
      await Future<void>.delayed(const Duration(milliseconds: 520));
    }
  }

  DemoModel get result => kitchenK01;
}
