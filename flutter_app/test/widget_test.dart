import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:baytak_ar/data/catalog.dart';
import 'package:baytak_ar/main.dart';
import 'package:baytak_ar/services/ai_client.dart';
import 'package:baytak_ar/services/kitchen_design.dart';
import 'package:baytak_ar/services/kitchen_generator.dart';
import 'package:baytak_ar/services/plan_editor.dart';
import 'package:baytak_ar/services/plan_normalizer.dart';
import 'package:baytak_ar/state/app_state.dart';
import 'package:baytak_ar/theme.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('home renders with the bundled catalogue', (tester) async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(BaytakArApp(state: AppState(prefs)));
    await tester.pump();
    expect(find.text('Baytak'), findsOneWidget);
    expect(find.text(kVersionLabel), findsOneWidget);
  });

  test('LayoutPlan JSON round-trips through toJson/fromJson', () {
    final plan = const KitchenSpec(
      widthM: 4.2,
      depthM: 3.4,
      layout: KitchenLayout.lShape,
      island: true,
    ).toPlan();
    final round = LayoutPlan.fromJson(plan.toJson());
    expect(round.widthM, closeTo(plan.widthM, 1e-9));
    expect(round.depthM, closeTo(plan.depthM, 1e-9));
    expect(round.runs.length, plan.runs.length);
    expect(round.island, isNotNull);
    expect(round.island!.w, closeTo(plan.island!.w, 1e-9));
    expect(round.windows.length, plan.windows.length);
    expect(round.runs.first.sinkAt, isNotNull);
  });

  test('KitchenDesign encodes/decodes and rejects unknown keys', () {
    const d = KitchenDesign(
        lower: 'sage_green', upper: 'white_satin', handle: 'knob');
    final decoded = KitchenDesign.tryDecode(d.encode())!;
    expect(decoded.lower, 'sage_green');
    expect(decoded.upper, 'white_satin');
    expect(decoded.handle, 'knob');

    final bad = KitchenDesign.fromJson(
        {'lower': 'not_a_finish', 'handle': 'lever', 'worktop': null});
    expect(bad.lower, 'warm_walnut');
    expect(bad.handle, 'bar');
    expect(bad.worktop, 'basalt_quartz');
  });

  test('every design option referenced by a preset exists in its table', () {
    for (final d in KitchenDesign.presets.values) {
      expect(cabinetFinishes, contains(d.lower));
      expect(cabinetFinishes, contains(d.upper));
      expect(cabinetFinishes, contains(d.island));
      expect(worktops, contains(d.worktop));
      expect(wallPaints, contains(d.wall));
      expect(floorFinishes, contains(d.floor));
      expect(backsplashes, contains(d.splash));
      expect(hardwareFinishes, contains(d.hardware));
      expect(handleStyles, contains(d.handle));
      expect(doorStyles, contains(d.door));
    }
  });

  test('byId never throws - unknown ids resolve to a placeholder', () {
    expect(byId('sofa_dana').title, 'Dana Sofa');
    final ghost = byId('custom_123456');
    expect(ghost.title, 'Generated design');
    expect(ghost.priceJd, 0);
  });

  group('PlanEditor drag rules', () {
    LayoutPlan lShape() => const KitchenSpec(
          widthM: 4.2,
          depthM: 3.4,
          layout: KitchenLayout.lShape,
          island: true,
        ).toPlan();

    test('sink clamps to the usable span and respects the range', () {
      final plan = lShape();
      final ed = PlanEditor(plan);
      final north = plan.runs.firstWhere((r) => r.wall == Wall.north);
      ed.moveAppliance(ApplianceKind.sink, north, -5);
      expect(north.sinkAt, closeTo(north.a + PlanEditor.edgeMargin, 1e-9));
      // pushing far right: the range sits near the run end, so the sink
      // stops one separation short of it instead of reaching the edge
      ed.moveAppliance(ApplianceKind.sink, north, 99);
      expect(north.sinkAt,
          closeTo(north.rangeAt! - PlanEditor.minSeparation, 1e-9));
      expect(ed.revision, 2);
    });

    test('sink keeps separation from the range on the same run', () {
      final plan = lShape();
      final ed = PlanEditor(plan);
      final north = plan.runs.firstWhere((r) => r.wall == Wall.north);
      final range = north.rangeAt!;
      ed.moveAppliance(ApplianceKind.sink, north, range - 0.1);
      expect((north.sinkAt! - range).abs(),
          greaterThanOrEqualTo(PlanEditor.minSeparation - 1e-9));
    });

    test('sink transfers to another run', () {
      final plan = lShape();
      final ed = PlanEditor(plan);
      final north = plan.runs.firstWhere((r) => r.wall == Wall.north);
      final west = plan.runs.firstWhere((r) => r.wall == Wall.west);
      final ok = ed.moveAppliance(ApplianceKind.sink, west, 2.0);
      expect(ok, isTrue);
      expect(north.sinkAt, isNull);
      expect(west.sinkAt, isNotNull);
      // west run has the fridge at its start - sink must clear it
      expect(west.sinkAt!,
          greaterThanOrEqualTo(west.a + PlanEditor.fridgeSpan +
              PlanEditor.edgeMargin - 1e-9));
    });

    test('fridge snaps to the nearest end and pushes the sink clear', () {
      final plan = lShape();
      final ed = PlanEditor(plan);
      final north = plan.runs.firstWhere((r) => r.wall == Wall.north);
      final west = plan.runs.firstWhere((r) => r.wall == Wall.west);
      // move fridge from west run to the START of the north run,
      // right where the sink currently sits
      final ok = ed.moveFridge(north, north.a + 0.1);
      expect(ok, isTrue);
      expect(west.fridge, isNull);
      expect(north.fridge, 'start');
      // sink survived and cleared the fridge slot
      expect(north.sinkAt, isNotNull);
      expect(north.sinkAt!,
          greaterThanOrEqualTo(north.a + PlanEditor.fridgeSpan +
              PlanEditor.edgeMargin - 1e-9));
    });

    test('fridge refuses a run that is too short', () {
      final plan = LayoutPlan(
        widthM: 3.0,
        depthM: 3.0,
        runs: [RunPlan(wall: Wall.north, a: 0.5, b: 1.8)],
      );
      final ed = PlanEditor(plan);
      expect(ed.moveFridge(plan.runs.first, 0.6), isFalse);
      expect(plan.runs.first.fridge, isNull);
    });
  });

  group('PlanNormalizer (b20)', () {
    // the owner's real U-shape blueprint: two side runs + a bar peninsula
    LayoutPlan ushape({IslandPlan? island}) => LayoutPlan(
          widthM: 3.2,
          depthM: 3.76,
          runs: [
            RunPlan(wall: Wall.west, a: 0.1, b: 2.74, uppers: true),
            RunPlan(
                wall: Wall.east,
                a: 0.1,
                b: 2.24,
                sinkAt: 1.15,
                fridge: 'end',
                uppers: true),
          ],
          island: island ??
              IslandPlan(
                  x0: 0.0, z0: 2.74, w: 1.69, d: 1.02, cooktop: true),
        );

    test('a true peninsula survives normalization untouched', () {
      final plan = ushape();
      normalizePlan(plan);
      final isl = plan.island!;
      expect(isl.w, closeTo(1.69, 0.02));
      expect(isl.d, closeTo(1.02, 0.02));
      expect(plan.runs.length, 2);
    });

    test('a room-filling island is shrunk until the walkway is clear', () {
      final plan = ushape(
          island:
              IslandPlan(x0: 0.4, z0: 0.6, w: 2.4, d: 2.56, cooktop: true));
      normalizePlan(plan);
      final isl = plan.island;
      if (isl != null) {
        // east run front is at x = 3.2 - 0.75 (fridge depth); whatever
        // survives must leave a walkway to it
        expect(isl.x0 + isl.w,
            lessThanOrEqualTo(3.2 - 0.75 - PlanNormalizer.walkway + 1e-6));
      }
    });

    test('a perpendicular run is trimmed clear of the fridge', () {
      final plan = LayoutPlan(
        widthM: 4.2,
        depthM: 3.4,
        runs: [
          RunPlan(
              wall: Wall.north,
              a: 0.1,
              b: 4.1,
              sinkAt: 1.2,
              rangeAt: 3.0,
              fridge: 'start',
              uppers: true),
          RunPlan(wall: Wall.west, a: 0.1, b: 3.3, uppers: true),
        ],
      );
      normalizePlan(plan);
      final west = plan.runs.firstWhere((r) => r.wall == Wall.west);
      expect(west.a, greaterThanOrEqualTo(PlanNormalizer.clearFridge - 1e-9));
    });

    test('four content walls cap at three built walls', () {
      final plan = LayoutPlan(
        widthM: 3.6,
        depthM: 3.0,
        runs: [
          RunPlan(wall: Wall.north, a: 0.1, b: 3.5, uppers: true),
          RunPlan(wall: Wall.south, a: 0.1, b: 3.5),
          RunPlan(wall: Wall.east, a: 0.1, b: 2.9, fridge: 'start'),
          RunPlan(wall: Wall.west, a: 0.1, b: 2.9),
        ],
      );
      normalizePlan(plan);
      expect(planWalls(plan).length, 3);
    });
  });

  group('PlanEditor free placement (b20)', () {
    LayoutPlan lShape() => const KitchenSpec(
          widthM: 4.2,
          depthM: 3.4,
          layout: KitchenLayout.lShape,
          island: false,
        ).toPlan();

    test('sink dropped on a bare wall grows a new cabinet run', () {
      final plan = lShape();
      final ed = PlanEditor(plan);
      expect(plan.runs.any((r) => r.wall == Wall.east), isFalse);
      final ok = ed.place(ApplianceKind.sink, Wall.east, 1.7);
      expect(ok, isTrue);
      final east = plan.runs.firstWhere((r) => r.wall == Wall.east);
      expect(east.sinkAt, isNotNull);
      expect(east.length, greaterThanOrEqualTo(PlanEditor.newRunLen - 0.01));
      // the north run's sink is gone - only one sink in a kitchen
      final north = plan.runs.firstWhere((r) => r.wall == Wall.north);
      expect(north.sinkAt, isNull);
    });

    test('fridge dropped mid-run splits the cabinets around it', () {
      final plan = LayoutPlan(
        widthM: 5.4,
        depthM: 3.2,
        runs: [
          RunPlan(wall: Wall.north, a: 0.1, b: 5.3, uppers: true),
        ],
      );
      final ed = PlanEditor(plan);
      final ok = ed.place(ApplianceKind.fridge, Wall.north, 2.7);
      expect(ok, isTrue);
      final north = plan.runs.where((r) => r.wall == Wall.north).toList();
      expect(north.length, 2);
      expect(north.any((r) => r.fridge != null), isTrue);
      // the two pieces do not overlap
      north.sort((a, b) => a.a.compareTo(b.a));
      expect(north[0].b, lessThanOrEqualTo(north[1].a + 1e-9));
    });

    test('fridge dropped on a bare wall becomes freestanding', () {
      final plan = lShape();
      final ed = PlanEditor(plan);
      final ok = ed.place(ApplianceKind.fridge, Wall.east, 2.0);
      expect(ok, isTrue);
      final east = plan.runs.firstWhere((r) => r.wall == Wall.east);
      expect(east.fridge, isNotNull);
      expect(east.length, closeTo(PlanEditor.fridgeSpan, 0.01));
      // the west run no longer holds the fridge
      final west = plan.runs.where((r) => r.wall == Wall.west);
      expect(west.every((r) => r.fridge == null), isTrue);
    });

    test('auto-created cabinets vanish when the appliance moves back', () {
      final plan = lShape();
      final ed = PlanEditor(plan);
      final north = plan.runs.firstWhere((r) => r.wall == Wall.north);
      final homeU = north.sinkAt!;
      // out to a bare wall: a run is created under the sink...
      ed.place(ApplianceKind.sink, Wall.east, 1.7);
      expect(plan.runs.any((r) => r.wall == Wall.east), isTrue);
      // ...and back home: the auto run must clean itself up
      ed.place(ApplianceKind.sink, Wall.north, homeU);
      expect(plan.runs.any((r) => r.wall == Wall.east), isFalse);
      expect(north.sinkAt, isNotNull);
      // same for a freestanding fridge parked on a bare wall
      ed.place(ApplianceKind.fridge, Wall.east, 1.7);
      expect(plan.runs.any((r) => r.wall == Wall.east), isTrue);
      final west = plan.runs.firstWhere((r) => r.wall == Wall.west);
      ed.place(ApplianceKind.fridge, Wall.west, west.a + 0.1);
      expect(plan.runs.any((r) => r.wall == Wall.east), isFalse);
    });

    test('fridge-only runs survive a JSON round-trip', () {
      final plan = lShape();
      PlanEditor(plan).place(ApplianceKind.fridge, Wall.east, 2.0);
      final round = LayoutPlan.fromJson(plan.toJson());
      expect(
          round.runs.any(
              (r) => r.wall == Wall.east && r.fridge != null),
          isTrue);
    });
  });

  test('extractJsonObject survives think-blocks, fences and prose', () {
    expect(extractJsonObject('{"a":1}'), '{"a":1}');
    expect(extractJsonObject('```json\n{"a":1}\n```'), '{"a":1}');
    expect(
        extractJsonObject('<think>hmm {not json}</think>Sure!\n'
            '```json\n{"a":{"b":"}"},"c":2}\n```\ntrailing words'),
        '{"a":{"b":"}"},"c":2}');
  });
}
