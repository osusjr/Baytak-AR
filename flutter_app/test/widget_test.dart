import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:baytak_ar/data/catalog.dart';
import 'package:baytak_ar/main.dart';
import 'package:baytak_ar/services/ai_client.dart';
import 'package:baytak_ar/services/kitchen_design.dart';
import 'package:baytak_ar/services/kitchen_generator.dart';
import 'package:baytak_ar/state/app_state.dart';

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
    expect(find.text('AR · v17'), findsOneWidget);
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

  test('extractJsonObject survives think-blocks, fences and prose', () {
    expect(extractJsonObject('{"a":1}'), '{"a":1}');
    expect(extractJsonObject('```json\n{"a":1}\n```'), '{"a":1}');
    expect(
        extractJsonObject('<think>hmm {not json}</think>Sure!\n'
            '```json\n{"a":{"b":"}"},"c":2}\n```\ntrailing words'),
        '{"a":{"b":"}"},"c":2}');
  });
}
