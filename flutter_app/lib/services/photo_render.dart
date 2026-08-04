import 'dart:typed_data';

import 'ai_client.dart';
import 'kitchen_design.dart';
import 'kitchen_generator.dart';

/// b29 photo render: turns the CURRENT plan + design into a realistic
/// picture of the finished kitchen inside the customer's own room photo
/// (OpenAI image-edit through the store proxy). This is the emotional
/// closer next to the accurate parametric model:
///  * the 3D model + quote stay the MEASURED truth,
///  * the photo render is an AI impression - approximate, not to scale -
///    and the UI says so (honesty rule).
///
/// Prompt building is pure logic (unit-tested): it describes the layout
/// wall by wall and every chosen finish by its human label, so the image
/// model paints the kitchen the customer actually configured.
String renderPrompt(LayoutPlan plan, KitchenDesign design) {
  final b = StringBuffer(
      'Transform this photo of an empty room into a photorealistic view '
      'of the SAME room fitted with the kitchen described below. Keep the '
      'room\'s real geometry, walls, windows, doors, camera angle and '
      'natural lighting exactly as in the photo - only add the kitchen, '
      'with realistic shadows and reflections.\n\n');

  b.writeln('Room size: ${plan.widthM.toStringAsFixed(1)} x '
      '${plan.depthM.toStringAsFixed(1)} metres.');

  String side(Wall w) => switch (w) {
        Wall.north => 'back wall',
        Wall.south => 'front (camera) side',
        Wall.west => 'left wall',
        Wall.east => 'right wall',
      };
  for (final r in plan.runs) {
    final parts = <String>[
      '${r.length.toStringAsFixed(1)} m of base cabinets with worktop',
      if (r.uppers) 'matching upper cabinets',
      if (r.sinkAt != null) 'an undermount sink',
      if (r.rangeAt != null) 'an oven with cooktop',
      if (r.fridge != null)
        'a tall fridge at the ${r.fridge == 'start' ? 'near' : 'far'} end',
    ];
    b.writeln('- On the ${side(r.wall)}: ${parts.join(', ')}.');
  }
  final isl = plan.island;
  if (isl != null) {
    b.writeln('- A freestanding island, '
        '${isl.w.toStringAsFixed(1)} x ${isl.d.toStringAsFixed(1)} m'
        '${isl.cooktop ? ', with a cooktop' : ''}.');
  }

  String cab(String id) =>
      cabinetFinishes[id]?.label ?? id.replaceAll('_', ' ');
  String surf(Map<String, SurfaceFinish> table, String id) =>
      table[id]?.label ?? id.replaceAll('_', ' ');

  b
    ..writeln()
    ..writeln('Finishes (match these closely):')
    ..writeln('- Base cabinets: ${cab(design.lower)}, '
        '${doorStyles[design.door] ?? design.door} doors')
    ..writeln('- Upper cabinets: ${cab(design.upper)}');
  if (plan.island != null) {
    b.writeln('- Island cabinets: ${cab(design.island)}');
  }
  b
    ..writeln('- Worktop: ${surf(worktops, design.worktop)}')
    ..writeln('- Wall paint: ${surf(wallPaints, design.wall)}')
    ..writeln('- Floor: ${surf(floorFinishes, design.floor)}')
    ..writeln('- Backsplash: ${surf(backsplashes, design.splash)}')
    ..writeln('- Handles: ${handleStyles[design.handle] ?? design.handle}, '
        '${hardwareFinishes[design.hardware]?.label ?? design.hardware} '
        'finish')
    ..writeln()
    ..writeln('Photorealistic interior photography, no people, no text.');
  return b.toString();
}

/// One-call orchestrator used by the Design studio.
Future<Uint8List> renderKitchenIntoPhoto({
  required LayoutPlan plan,
  required KitchenDesign design,
  required List<int> roomPhotoBytes,
}) =>
    imageEditCall(
      imageBytes: roomPhotoBytes,
      prompt: renderPrompt(plan, design),
    );
