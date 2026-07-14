import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:baytak_ar/data/catalog.dart';
import 'package:baytak_ar/main.dart';
import 'package:baytak_ar/services/ai_client.dart';
import 'package:baytak_ar/services/kitchen_design.dart';
import 'package:baytak_ar/services/kitchen_generator.dart';
import 'package:baytak_ar/services/plan_editor.dart';
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

  test('extractJsonObject survives think-blocks, fences and prose', () {
    expect(extractJsonObject('{"a":1}'), '{"a":1}');
    expect(extractJsonObject('```json\n{"a":1}\n```'), '{"a":1}');
    expect(
        extractJsonObject('<think>hmm {not json}</think>Sure!\n'
            '```json\n{"a":{"b":"}"},"c":2}\n```\ntrailing words'),
        '{"a":{"b":"}"},"c":2}');
  });
}
