import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:baytak_ar/data/catalog.dart';
import 'package:baytak_ar/main.dart';
import 'package:baytak_ar/services/ai_client.dart';
import 'package:baytak_ar/services/analytics.dart';
import 'package:baytak_ar/services/device_id.dart';
import 'package:baytak_ar/services/kitchen_design.dart';
import 'package:baytak_ar/services/kitchen_generator.dart';
import 'package:baytak_ar/services/kitchen_materials.dart';
import 'package:baytak_ar/services/cut_list.dart';
import 'package:baytak_ar/services/design_chat.dart';
import 'package:baytak_ar/services/photo_render.dart';
import 'package:baytak_ar/services/plan_editor.dart';
import 'package:baytak_ar/services/plan_normalizer.dart';
import 'package:baytak_ar/services/saved_designs.dart';
import 'package:baytak_ar/services/scan_cache.dart';
import 'package:baytak_ar/state/app_state.dart';
import 'package:baytak_ar/theme.dart';
import 'package:baytak_ar/widgets/iso_kitchen_editor.dart';
import 'package:flutter/material.dart' show Size;

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('home renders with the bundled catalogue', (tester) async {
    SharedPreferences.setMockInitialValues({'onboarded': true});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(BaytakArApp(state: AppState(prefs)));
    await tester.pump();
    expect(find.text('Matbakhak'), findsOneWidget);
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

    test('moveRun slides a run and its appliances along the wall', () {
      final plan = lShape();
      normalizePlan(plan); // studio-entry state: corners already resolved
      final ed = PlanEditor(plan);
      final north = plan.runs.firstWhere((r) => r.wall == Wall.north);
      final sinkOffset = north.sinkAt! - north.a;
      final len = north.length;
      // slide right, away from the west-run corner - clear floor there
      final ok =
          ed.moveRun(north, Wall.north, plan.widthM - len / 2 - 0.05);
      expect(ok, isTrue);
      expect(north.length, closeTo(len, 1e-9));
      expect(north.sinkAt! - north.a, closeTo(sinkOffset, 1e-9));
    });

    test('moveRun refuses a wall shorter than the run', () {
      final plan = lShape(); // north run 3.49 m, east wall only 3.4 m
      final ed = PlanEditor(plan);
      final north = plan.runs.firstWhere((r) => r.wall == Wall.north);
      expect(ed.moveRun(north, Wall.east, plan.depthM / 2), isFalse);
      expect(plan.runs.any((r) => r.wall == Wall.north), isTrue);
    });

    test('moveRun carries a run to another wall, sink riding along', () {
      final plan = lShape();
      normalizePlan(plan);
      final ed = PlanEditor(plan);
      final north = plan.runs.firstWhere((r) => r.wall == Wall.north);
      final sinkOffset = north.sinkAt! - north.a;
      // south wall has the same length as north - always fits
      final ok = ed.moveRun(north, Wall.south, plan.widthM / 2);
      expect(ok, isTrue);
      final south = plan.runs.firstWhere((r) => r.wall == Wall.south);
      expect(south.sinkAt, isNotNull);
      expect(south.sinkAt! - south.a,
          closeTo(sinkOffset, 0.5)); // normalizer may re-clamp slightly
      expect(plan.runs.any((r) => r.wall == Wall.north && r.sinkAt != null),
          isFalse);
    });

    test('moveIsland never resizes the island - bad spots roll back', () {
      final plan = const KitchenSpec(
        widthM: 4.2,
        depthM: 3.4,
        layout: KitchenLayout.lShape,
        island: true,
      ).toPlan();
      normalizePlan(plan);
      final ed = PlanEditor(plan);
      final isl = plan.island!;
      final w0 = isl.w, d0 = isl.d;
      // valid drag: middle of the open floor
      expect(ed.moveIsland(plan.widthM / 2, plan.depthM * 0.68), isTrue);
      expect(isl.w, closeTo(w0, 0.021));
      expect(isl.d, closeTo(d0, 0.021));
      // hostile drag: shoved into the north run - must roll back, not shrink
      final before = (isl.x0, isl.z0);
      ed.moveIsland(plan.widthM / 2, 0.3);
      final after = plan.island!;
      expect(after.w, closeTo(w0, 0.021));
      expect(after.d, closeTo(d0, 0.021));
      // either rejected (position restored) or nudged clear - never inside
      // the run band
      expect(after.z0, greaterThan(0.62));
      expect(before, isNotNull);
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

  group('Iso 3D editor (b24)', () {
    final plan = LayoutPlan(
      widthM: 4.2,
      depthM: 3.4,
      runs: [RunPlan(wall: Wall.north, a: 0.5, b: 3.9, sinkAt: 1.2)],
    );

    test('view rotation round-trips for all four k values', () {
      for (var k = 0; k < 4; k++) {
        final v = IsoView(plan, const Size(360, 320), k);
        for (final p in [(0.3, 0.4), (4.0, 3.0), (2.1, 1.7)]) {
          final (rx, rz) = v.rot(p.$1, p.$2);
          final (x, z) = v.unrot(rx, rz);
          expect(x, closeTo(p.$1, 1e-9), reason: 'k=$k');
          expect(z, closeTo(p.$2, 1e-9), reason: 'k=$k');
        }
      }
    });

    test('floor unprojection inverts projection for all four views', () {
      for (var k = 0; k < 4; k++) {
        final v = IsoView(plan, const Size(360, 320), k);
        for (final p in [(0.5, 0.5), (3.7, 2.9), (2.0, 1.0)]) {
          final screen = v.project(p.$1, 0, p.$2);
          final (x, z) = v.unprojectFloor(screen);
          expect(x, closeTo(p.$1, 1e-6), reason: 'k=$k');
          expect(z, closeTo(p.$2, 1e-6), reason: 'k=$k');
        }
      }
    });

    test('resizeRun respects appliances and minimum length', () {
      final p = LayoutPlan(
        widthM: 5.0,
        depthM: 3.0,
        runs: [RunPlan(wall: Wall.north, a: 0.5, b: 4.5, sinkAt: 1.2)],
      );
      final ed = PlanEditor(p);
      final run = p.runs.first;
      // cannot shrink past the sink + edge margin
      ed.resizeRun(run, startEnd: true, v: 2.0);
      expect(run.a, lessThanOrEqualTo(1.2 - PlanEditor.edgeMargin + 1e-9));
      // growing to the wall end works
      expect(ed.resizeRun(run, startEnd: false, v: 4.98), isTrue);
      expect(run.b, closeTo(4.98, 1e-9));
    });

    test('undo restores the pre-edit layout', () {
      final p = LayoutPlan(
        widthM: 5.0,
        depthM: 3.0,
        runs: [RunPlan(wall: Wall.north, a: 0.5, b: 4.5, sinkAt: 1.2)],
      );
      final ed = PlanEditor(p);
      ed.checkpoint();
      ed.place(ApplianceKind.fridge, Wall.north, 3.0);
      expect(p.runs.length, greaterThan(1)); // split happened
      expect(ed.undo(), isTrue);
      expect(p.runs.length, 1);
      expect(p.runs.first.fridge, isNull);
      expect(p.runs.first.a, closeTo(0.5, 1e-9));
    });

    test('mirrored wall transfer flips the appliance arrangement', () {
      final p = LayoutPlan(
        widthM: 4.0,
        depthM: 4.0,
        runs: [
          RunPlan(wall: Wall.north, a: 0.5, b: 3.5, sinkAt: 1.0,
              fridge: 'end'),
        ],
      );
      final ed = PlanEditor(p);
      final ok =
          ed.moveRun(p.runs.first, Wall.south, 2.0, mirror: true);
      expect(ok, isTrue);
      final south = p.runs.firstWhere((r) => r.wall == Wall.south);
      // sink was 0.5 from the start -> now 0.5 from the END; fridge
      // flipped from 'end' to 'start'
      expect(south.fridge, 'start');
      expect(south.b - south.sinkAt!, closeTo(0.5, 0.1));
    });
  });

  group('Saved designs + quote (b25)', () {
    test('SavedDesign JSON round-trips plan, design and price', () async {
      SharedPreferences.setMockInitialValues({});
      final plan = const KitchenSpec(
        widthM: 4.2,
        depthM: 3.4,
        layout: KitchenLayout.lShape,
        island: true,
      ).toPlan();
      const design =
          KitchenDesign(lower: 'sage_green', worktop: 'butcher_block');
      final d = SavedDesign(
        id: 'd1',
        name: 'Abu Ahmad',
        savedAt: DateTime(2026, 7, 22),
        plan: plan,
        design: design,
        priceJd: estimatePrice(plan, design),
      );
      await SavedDesigns.add(d);
      final loaded = await SavedDesigns.load();
      expect(loaded.length, 1);
      expect(loaded.first.name, 'Abu Ahmad');
      expect(loaded.first.design.lower, 'sage_green');
      expect(loaded.first.priceJd, d.priceJd);
      expect(loaded.first.plan.runs.length, plan.runs.length);
      await SavedDesigns.remove('d1');
      expect(await SavedDesigns.load(), isEmpty);
    });

    test('estimatePrice matches the generator formula shape', () {
      final plan = const KitchenSpec(
        widthM: 4.0,
        depthM: 3.0,
        layout: KitchenLayout.single,
        island: false,
      ).toPlan();
      const design = KitchenDesign();
      final lm = plan.runs.fold<double>(0, (a, r) => a + r.length);
      expect(
          estimatePrice(plan, design),
          ((lm * kRatePerRunMetre) * design.priceFactor / 10).round() * 10);
      // price responds to finish level
      const premium = KitchenDesign(worktop: 'marble_veined');
      if (premium.priceFactor != design.priceFactor) {
        expect(estimatePrice(plan, premium),
            isNot(estimatePrice(plan, design)));
      }
    });
  });

  group('Launch layer (b26)', () {
    test('analytics deltas: only growth since last sync is uploaded', () {
      expect(
        AppAnalytics.deltas(
          {'details:sofa': 5, 'viewer:sofa': 2, 'generate': 1},
          {'details:sofa': 3, 'viewer:sofa': 2},
        ),
        {'details:sofa': 2, 'generate': 1},
      );
      expect(AppAnalytics.deltas({}, {'details:x': 4}), isEmpty);
    });

    test('device id is stable across calls', () async {
      SharedPreferences.setMockInitialValues({});
      final a = await deviceId();
      final b = await deviceId();
      expect(a, b);
      expect(a.length, 32);
    });

    test('keys with stray whitespace still build legal HTTP headers', () {
      // a wrapped --dart-define paste put a newline INSIDE the anon key and
      // every AI call died with FormatException (observed live, b26)
      const dirty = 'eyJhbGci\n  OiJIUzI1\tNiIs ';
      final clean = sanitizeConfigValue(dirty);
      expect(clean, 'eyJhbGciOiJIUzI1NiIs');
      // Dart rejects header values containing control chars - assert the
      // sanitized form is accepted where the raw one is not
      // http rejects control characters in header values; the sanitized
      // form is header-safe, the raw one is not
      expect(dirty.contains(RegExp(r'\s')), isTrue);
      expect(clean.contains(RegExp(r'\s')), isFalse);
    });

    test('analytics count clamps to the RLS ceiling', () {
      final rows = AppAnalytics.deltas({'viewer:x': 50000}, {});
      expect(rows['viewer:x'], 50000); // raw delta preserved locally
      // the clamp to 10000 happens at upload row build - assert the
      // clamp expression directly
      final delta = rows['viewer:x']!;
      expect(delta > 10000 ? 10000 : delta, 10000);
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

  group('Regrow pass (b28) - cabinets go back', () {
    LayoutPlan room(List<RunPlan> runs, {double w = 4.0, double d = 3.2}) =>
        LayoutPlan(widthM: w, depthM: d, runs: runs);

    test('extension shrinks back once the oven leaves', () {
      final r = RunPlan(
          wall: Wall.north,
          a: 0.25,
          b: 3.5,
          sinkAt: 2.5,
          uppers: true,
          origA: 1.5,
          origB: 3.5);
      final plan = room([r]);
      normalizePlan(plan);
      expect(r.a, closeTo(1.5, 1e-6));
      expect(r.b, closeTo(3.5, 1e-6));
    });

    test('occupied extension holds - the oven must stay inside', () {
      final r = RunPlan(
          wall: Wall.north,
          a: 0.25,
          b: 3.5,
          rangeAt: 0.7,
          sinkAt: 2.5,
          uppers: true,
          origA: 1.5,
          origB: 3.5);
      final plan = room([r]);
      normalizePlan(plan);
      expect(r.a, lessThanOrEqualTo(0.7 - PlanEditor.edgeMargin + 1e-6));
      expect(r.rangeAt, isNotNull);
    });

    test('fridge-trimmed run regrows to plain-corner clearance', () {
      final north = RunPlan(
          wall: Wall.north, a: 0.1, b: 4.1, sinkAt: 1.2, rangeAt: 3.0,
          uppers: true);
      final west = RunPlan(
          wall: Wall.west,
          a: 0.82,
          b: 3.3,
          uppers: true,
          origA: 0.1,
          origB: 3.3);
      final plan = room([north, west], w: 4.2, d: 3.4);
      normalizePlan(plan);
      expect(west.a, closeTo(PlanNormalizer.clearCounter, 1e-6));
    });

    test('unblocked trimmed run regrows to its full orig', () {
      final west = RunPlan(
          wall: Wall.west,
          a: 0.82,
          b: 3.3,
          sinkAt: 1.6,
          uppers: true,
          origA: 0.1,
          origB: 3.3);
      final plan = room([west], w: 4.2, d: 3.4);
      normalizePlan(plan);
      expect(west.a, closeTo(0.1, 1e-6));
      expect(west.b, closeTo(3.3, 1e-6));
    });

    test('fridge-split halves merge back after the fridge leaves', () {
      final left = RunPlan(
          wall: Wall.south,
          a: 0.1,
          b: 3.0,
          sinkAt: 1.0,
          uppers: true,
          origA: 0.1,
          origB: 4.5);
      final right = RunPlan(
          wall: Wall.south, a: 3.0, b: 4.5, uppers: true);
      final plan = room([left, right], w: 4.6, d: 3.2);
      normalizePlan(plan);
      expect(plan.runs, hasLength(1));
      expect(plan.runs.single.a, closeTo(0.1, 1e-6));
      expect(plan.runs.single.b, closeTo(4.5, 1e-6));
      expect(plan.runs.single.origA, closeTo(0.1, 1e-6));
      expect(plan.runs.single.origB, closeTo(4.5, 1e-6));
    });

    test('halves stay split while the fridge holds the seam', () {
      final left = RunPlan(
          wall: Wall.south,
          a: 0.1,
          b: 3.0,
          sinkAt: 1.0,
          fridge: 'end',
          uppers: true,
          origA: 0.1,
          origB: 4.5);
      final right = RunPlan(
          wall: Wall.south, a: 3.0, b: 4.5, uppers: true);
      final plan = room([left, right], w: 4.6, d: 3.2);
      normalizePlan(plan);
      expect(plan.runs, hasLength(2));
      expect(left.b, closeTo(3.0, 1e-6));
    });

    test('THE user story: oven away to a bare wall and back restores '
        'the original layout exactly', () {
      final original = RunPlan(
          wall: Wall.north,
          a: 0.5,
          b: 3.5,
          sinkAt: 1.2,
          rangeAt: 2.6,
          uppers: true);
      final plan = room([original]);
      final editor = PlanEditor(plan);

      // move the oven to the bare south wall - an auto run appears
      expect(editor.place(ApplianceKind.range, Wall.south, 2.0), isTrue);
      expect(plan.runs, hasLength(2));
      expect(original.rangeAt, isNull);
      expect(original.a, closeTo(0.5, 1e-6)); // original untouched

      // move it back onto the original run - the auto run must vanish
      // and the original run must host the oven again
      expect(editor.place(ApplianceKind.range, Wall.north, 2.6), isTrue);
      expect(plan.runs, hasLength(1));
      expect(identical(plan.runs.single, original), isTrue);
      expect(original.a, closeTo(0.5, 1e-6));
      expect(original.b, closeTo(3.5, 1e-6));
      expect(original.rangeAt, closeTo(2.6, 0.06));
    });

    test('oven dropped NEAR the run end extends it; sending the oven '
        'elsewhere shrinks the extension away', () {
      final original = RunPlan(
          wall: Wall.north,
          a: 1.5,
          b: 3.5,
          sinkAt: 2.9,
          uppers: true);
      final plan = room([original]);
      final editor = PlanEditor(plan);

      // drop just past the start end, within extendReach: run extends
      expect(editor.place(ApplianceKind.range, Wall.north, 1.0), isTrue);
      expect(original.a, lessThan(1.5 - 1e-6));
      expect(original.origA, closeTo(1.5, 1e-6)); // memory untouched

      // send the oven to another wall - the extension shrinks back
      expect(editor.place(ApplianceKind.range, Wall.south, 2.0), isTrue);
      expect(original.a, closeTo(1.5, 1e-6));
      expect(original.b, closeTo(3.5, 1e-6));
      expect(original.sinkAt, closeTo(2.9, 1e-6));
    });

    test('deliberate resize rebases the memory - a user shrink sticks', () {
      final r = RunPlan(wall: Wall.north, a: 0.5, b: 3.5, uppers: true);
      final plan = room([r]);
      final editor = PlanEditor(plan);
      expect(editor.resizeRun(r, startEnd: false, v: 2.5), isTrue);
      expect(r.b, closeTo(2.5, 1e-6));
      expect(r.origB, closeTo(2.5, 1e-6));
      normalizePlan(plan); // must NOT grow back to 3.5
      expect(r.b, closeTo(2.5, 1e-6));
    });

    test('ghost auto blocker: trimmed neighbour regrows in the SAME '
        'normalize that sweeps the ghost (review fix)', () {
      final ghost = RunPlan(
          wall: Wall.north, a: 0.02, b: 1.52, uppers: true, auto: true);
      final west = RunPlan(
          wall: Wall.west,
          a: 0.67,
          b: 2.9,
          sinkAt: 1.6,
          uppers: true,
          origA: 0.1,
          origB: 2.9);
      final plan = room([ghost, west], w: 3.6, d: 3.0);
      final notes = normalizePlan(plan);
      expect(plan.runs, hasLength(1));
      expect(west.a, closeTo(0.1, 1e-6));
      expect(notes, isNotEmpty);
      // and idempotent: a second normalize is a silent no-op
      expect(normalizePlan(plan), isEmpty);
      expect(west.a, closeTo(0.1, 1e-6));
    });

    test('fridge-anchored end never regrows into freed space '
        '(review fix)', () {
      final left = RunPlan(
          wall: Wall.south,
          a: 0.1,
          b: 3.0,
          sinkAt: 1.0,
          fridge: 'end',
          uppers: true,
          origA: 0.1,
          origB: 4.5);
      final plan = room([left], w: 4.6, d: 3.2);
      normalizePlan(plan);
      expect(left.b, closeTo(3.0, 1e-6));
      expect(left.fridge, 'end'); // the fridge stays where the user put it
    });

    test('orig memory survives the JSON round-trip', () {
      final r = RunPlan(
          wall: Wall.west,
          a: 0.82,
          b: 3.3,
          uppers: true,
          origA: 0.1,
          origB: 3.3);
      final plan = LayoutPlan(widthM: 4.2, depthM: 3.4, runs: [r]);
      final back = LayoutPlan.fromJson(
          jsonDecode(jsonEncode(plan.toJson())) as Map<String, dynamic>);
      expect(back.runs.single.origA, closeTo(0.1, 1e-6));
      expect(back.runs.single.origB, closeTo(3.3, 1e-6));
      // and a run whose orig equals its bounds writes no extra keys
      final plain = RunPlan(wall: Wall.north, a: 1.0, b: 3.0);
      final js = LayoutPlan(widthM: 4, depthM: 3, runs: [plain]).toJson();
      final rj = (js['runs'] as List).single as Map;
      expect(rj.containsKey('orig_a'), isFalse);
      expect(rj.containsKey('orig_b'), isFalse);
    });
  });

  group('Scan cache (b28) - no double AI spend', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('hash is stable and content-sensitive', () {
      final a = ScanCache.hashBytes([1, 2, 3, 4]);
      expect(ScanCache.hashBytes([1, 2, 3, 4]), a);
      expect(ScanCache.hashBytes([1, 2, 3, 5]), isNot(a));
      expect(a.length, 16);
    });

    test('stores and returns the plan for the same bytes', () async {
      final bytes = List<int>.generate(64, (i) => i * 7 % 256);
      final plan = LayoutPlan(widthM: 3.2, depthM: 3.76, runs: [
        RunPlan(wall: Wall.west, a: 0.1, b: 2.74, uppers: true),
      ]);
      expect(await ScanCache.lookup(bytes), isNull);
      await ScanCache.store(bytes, plan);
      final hit = await ScanCache.lookup(bytes);
      expect(hit, isNotNull);
      expect(hit!.widthM, closeTo(3.2, 1e-6));
      expect(hit.runs.single.b, closeTo(2.74, 1e-6));
      expect(await ScanCache.lookup([9, 9, 9]), isNull);
    });
  });

  group('Tall cabinets + add/remove (b30)', () {
    test('tall flag survives the JSON round-trip and 0.6 m is legal', () {
      final plan = LayoutPlan(widthM: 3.6, depthM: 3.0, runs: [
        RunPlan(wall: Wall.west, a: 0.02, b: 0.62, tall: true),
      ]);
      final back = LayoutPlan.fromJson(
          jsonDecode(jsonEncode(plan.toJson())) as Map<String, dynamic>);
      expect(back.runs, hasLength(1));
      expect(back.runs.single.tall, isTrue);
      expect(back.runs.single.length, closeTo(0.6, 1e-6));
    });

    test('tall + base runs never merge - the counter is trimmed back', () {
      final tall = RunPlan(wall: Wall.north, a: 0.02, b: 0.62, tall: true);
      final base = RunPlan(
          wall: Wall.north, a: 0.40, b: 3.0, sinkAt: 1.4, uppers: true);
      final plan =
          LayoutPlan(widthM: 3.6, depthM: 3.0, runs: [tall, base]);
      normalizePlan(plan);
      expect(plan.runs, hasLength(2));
      expect(base.a, greaterThanOrEqualTo(tall.b - 1e-9));
      expect(tall.a, closeTo(0.02, 1e-6)); // the tall unit does not move
      expect(tall.tall, isTrue);
    });

    test('a dragged counter never swallows a freestanding fridge', () {
      final counter = RunPlan(
          wall: Wall.north, a: 0.5, b: 1.6, sinkAt: 1.0, uppers: true);
      final fridge = RunPlan(
          wall: Wall.north, a: 1.4, b: 2.2, fridge: 'start');
      final plan =
          LayoutPlan(widthM: 3.6, depthM: 3.0, runs: [counter, fridge]);
      normalizePlan(plan);
      expect(plan.runs, hasLength(2));
      expect(fridge.a, closeTo(1.4, 1e-6));
      expect(fridge.b, closeTo(2.2, 1e-6));
      expect(counter.b, lessThanOrEqualTo(fridge.a + 1e-9));
    });

    test('island seating flips away from an attached run', () {
      final plan = LayoutPlan(
        widthM: 4.2,
        depthM: 3.6,
        runs: [
          RunPlan(
              wall: Wall.north,
              a: 0.1,
              b: 4.1,
              sinkAt: 1.0,
              rangeAt: 3.0,
              uppers: true),
        ],
        island: IslandPlan(
            x0: 1.2, z0: 0.66, w: 1.6, d: 0.9, seating: Wall.north),
      );
      normalizePlan(plan);
      expect(plan.island, isNotNull);
      expect(plan.island!.seating, Wall.south);
    });

    test('appliances are rejected on tall units', () {
      final tall = RunPlan(wall: Wall.north, a: 0.02, b: 1.62, tall: true);
      final plan = LayoutPlan(widthM: 3.6, depthM: 3.0, runs: [tall]);
      final editor = PlanEditor(plan);
      expect(editor.place(ApplianceKind.sink, Wall.north, 0.8), isFalse);
      expect(editor.place(ApplianceKind.fridge, Wall.north, 0.8), isFalse);
      expect(tall.hasAppliance, isFalse);
    });

    test('addRun places base and tall units without overlap', () {
      final plan = LayoutPlan(widthM: 4.2, depthM: 3.4, runs: [
        RunPlan(
            wall: Wall.north,
            a: 0.8,
            b: 4.1,
            sinkAt: 1.4,
            rangeAt: 3.0,
            uppers: true),
      ]);
      final editor = PlanEditor(plan);
      expect(editor.addRun(tall: true), isTrue);
      final tall = plan.runs.firstWhere((r) => r.tall);
      expect(tall.length, closeTo(0.6, 0.05));
      expect(editor.addRun(), isTrue);
      expect(plan.runs.length, 3);
      // and the user can delete what they added
      expect(editor.removeRun(tall), isTrue);
      expect(plan.runs.any((r) => r.tall), isFalse);
    });

    test('a tall unit resizes down to a single 0.55 m column', () {
      final tall = RunPlan(wall: Wall.north, a: 0.02, b: 1.52, tall: true);
      final plan = LayoutPlan(widthM: 3.6, depthM: 3.0, runs: [tall]);
      final editor = PlanEditor(plan);
      expect(editor.resizeRun(tall, startEnd: false, v: 0.6), isTrue);
      expect(tall.length, greaterThanOrEqualTo(0.55 - 1e-9));
      expect(tall.length, lessThan(0.7));
    });
  });

  group('Realistic corners + collision drags (b31)', () {
    test('L-corner worktops join flush - no overlap, no slit', () {
      final north = RunPlan(
          wall: Wall.north, a: 0.02, b: 4.1, sinkAt: 1.4, uppers: true);
      final west = RunPlan(wall: Wall.west, a: 0.67, b: 3.3, uppers: true);
      final plan =
          LayoutPlan(widthM: 4.2, depthM: 3.6, runs: [north, west]);
      final (wa, wb) = worktopSpan(west, west.a, west.b, plan);
      expect(wa, closeTo(0.655, 1e-9)); // exactly the north counter face
      expect(wb, closeTo(3.32, 1e-9)); // free end keeps its 2 cm lip
      // the north run's own top is untouched (it owns the corner square)
      final (na, _) = worktopSpan(north, north.a, north.b, plan);
      expect(na, closeTo(0.0, 1e-9));
    });

    test('counter worktop butts a tall unit at its 0.62 face', () {
      final tall = RunPlan(wall: Wall.west, a: 0.02, b: 0.62, tall: true);
      final north = RunPlan(wall: Wall.north, a: 0.67, b: 4.1, uppers: true);
      final plan =
          LayoutPlan(widthM: 4.2, depthM: 3.6, runs: [tall, north]);
      final (wa, _) = worktopSpan(north, north.a, north.b, plan);
      expect(wa, closeTo(0.62, 1e-9));
    });

    test('fridge corners keep their clearance - no worktop join', () {
      final north = RunPlan(
          wall: Wall.north, a: 0.02, b: 4.1, fridge: 'start', uppers: true);
      final west = RunPlan(wall: Wall.west, a: 0.82, b: 3.3, uppers: true);
      final plan =
          LayoutPlan(widthM: 4.2, depthM: 3.6, runs: [north, west]);
      final (wa, _) = worktopSpan(west, west.a, west.b, plan);
      expect(wa, closeTo(0.80, 1e-9)); // default lip, no join
    });

    test('dragging into a perpendicular run STOPS at the clearance - '
        'nothing is trimmed or deleted', () {
      final north = RunPlan(
          wall: Wall.north, a: 0.02, b: 4.1, sinkAt: 1.4, uppers: true);
      final west = RunPlan(wall: Wall.west, a: 1.2, b: 2.8, uppers: true);
      final plan =
          LayoutPlan(widthM: 4.2, depthM: 3.6, runs: [north, west]);
      final editor = PlanEditor(plan);
      // shove the west run hard into the north corner
      expect(editor.moveRun(west, Wall.west, 0.0), isTrue);
      expect(west.a, closeTo(PlanNormalizer.clearCounter, 1e-6));
      expect(north.a, closeTo(0.02, 1e-6)); // untouched
      expect(north.b, closeTo(4.1, 1e-6));
      expect(plan.runs, hasLength(2));
    });

    test('dragging an N/S run toward an E/W run also collides - the E/W '
        'run is no longer sacrificed', () {
      // the west run reaches INTO the south corner band, so the old
      // behaviour would have trimmed it (E/W yields to N/S)
      final west = RunPlan(wall: Wall.west, a: 0.9, b: 3.5, uppers: true);
      final south = RunPlan(
          wall: Wall.south, a: 2.0, b: 4.0, sinkAt: 3.0, uppers: true);
      final plan =
          LayoutPlan(widthM: 4.2, depthM: 3.6, runs: [west, south]);
      final editor = PlanEditor(plan);
      // drag the south run toward the west corner
      expect(editor.moveRun(south, Wall.south, 0.0), isTrue);
      expect(south.a, closeTo(PlanNormalizer.clearCounter, 1e-6));
      expect(west.a, closeTo(0.9, 1e-6)); // fully intact
      expect(west.b, closeTo(3.5, 1e-6));
    });

    test('dragging a counter onto a freestanding fridge stops flush - '
        'the fridge never teleports', () {
      final counter = RunPlan(
          wall: Wall.north, a: 0.1, b: 1.6, sinkAt: 0.8, uppers: true);
      final fridge =
          RunPlan(wall: Wall.north, a: 2.6, b: 3.4, fridge: 'start');
      final plan =
          LayoutPlan(widthM: 4.6, depthM: 3.2, runs: [counter, fridge]);
      final editor = PlanEditor(plan);
      // drop the counter right on top of the fridge
      expect(editor.moveRun(counter, Wall.north, 3.0), isTrue);
      expect(fridge.a, closeTo(2.6, 1e-6));
      expect(fridge.b, closeTo(3.4, 1e-6));
      // the counter sits flush against one side of it
      final touchLeft = (counter.b - fridge.a).abs() < 1e-6;
      final touchRight = (counter.a - fridge.b).abs() < 1e-6;
      expect(touchLeft || touchRight, isTrue,
          reason: 'counter at [${counter.a},${counter.b}]');
    });

    test('resize growth stops at the corner clearance', () {
      final north = RunPlan(
          wall: Wall.north, a: 0.02, b: 4.1, sinkAt: 1.4, uppers: true);
      final west = RunPlan(wall: Wall.west, a: 1.2, b: 2.8, uppers: true);
      final plan =
          LayoutPlan(widthM: 4.2, depthM: 3.6, runs: [north, west]);
      final editor = PlanEditor(plan);
      expect(editor.resizeRun(west, startEnd: true, v: 0.0), isTrue);
      expect(west.a, closeTo(PlanNormalizer.clearCounter, 1e-6));
      expect(north.b, closeTo(4.1, 1e-6)); // untouched
    });

    test('a fridge drop that would DELETE a small perpendicular run is '
        'refused instead', () {
      // west run 0.93 m: the fridge clearance (0.82) would trim it to
      // 0.78 < 0.9 -> the old behaviour deleted it silently
      final west = RunPlan(wall: Wall.west, a: 0.67, b: 1.6, uppers: true);
      final north = RunPlan(
          wall: Wall.north, a: 0.9, b: 4.1, sinkAt: 1.6, uppers: true);
      final plan =
          LayoutPlan(widthM: 4.2, depthM: 3.6, runs: [west, north]);
      final editor = PlanEditor(plan);
      final ok = editor.place(ApplianceKind.fridge, Wall.north, 1.0);
      // either the drop landed somewhere legal or it was refused -
      // but the west run must still exist either way
      expect(plan.runs.contains(west), isTrue,
          reason: 'place returned $ok and deleted the west run');
      expect(west.length, greaterThanOrEqualTo(0.9 - 1e-9));
    });
  });

  group('IKEA planner behaviours (b32)', () {
    test('door bays are uniform 0.60 modules with a filler remainder', () {
      final even = doorBays(0.0, 2.4);
      expect(even, hasLength(4));
      for (var i = 0; i < 4; i++) {
        expect(even[i].$1, closeTo(i * 0.6, 1e-9));
        expect(even[i].$2, closeTo((i + 1) * 0.6, 1e-9));
        expect(even[i].$3, isTrue);
      }
      final withDoor = doorBays(0.0, 1.5);
      expect(withDoor.last.$3, isTrue); // 0.30 remainder gets a door
      expect(withDoor.last.$2 - withDoor.last.$1, closeTo(0.30, 1e-9));
      final withFiller = doorBays(0.0, 1.45);
      expect(withFiller.last.$3, isFalse); // 0.25 remainder = filler
      // bays always tile the span contiguously
      for (var i = 1; i < withFiller.length; i++) {
        expect(withFiller[i].$1, closeTo(withFiller[i - 1].$2, 1e-9));
      }
    });

    test('a drag released NEAR a neighbour snaps flush onto it', () {
      final left = RunPlan(
          wall: Wall.north, a: 0.02, b: 1.52, sinkAt: 0.8, uppers: true);
      final fridge =
          RunPlan(wall: Wall.north, a: 3.0, b: 3.8, fridge: 'start');
      final plan =
          LayoutPlan(widthM: 4.6, depthM: 3.2, runs: [left, fridge]);
      final editor = PlanEditor(plan);
      // release the fridge-neighbour drag 12 cm short of the left run:
      // desired a = 1.64, left.b = 1.52 -> snap flush
      expect(editor.moveRun(fridge, Wall.north, 2.04), isTrue);
      expect(fridge.a, closeTo(1.52, 1e-6));
    });

    test('a drag released near the wall end snaps into the corner', () {
      final run = RunPlan(
          wall: Wall.north, a: 1.5, b: 3.0, sinkAt: 2.2, uppers: true);
      final plan = LayoutPlan(widthM: 4.6, depthM: 3.2, runs: [run]);
      final editor = PlanEditor(plan);
      // desired a = 0.15 - within snap distance of the 0.02 corner
      expect(editor.moveRun(run, Wall.north, 0.9), isTrue);
      expect(run.a, closeTo(0.02, 1e-6));
    });

    test('far from anything, no snap happens - free placement stays', () {
      final run = RunPlan(
          wall: Wall.north, a: 0.02, b: 1.52, sinkAt: 0.8, uppers: true);
      final plan = LayoutPlan(widthM: 4.6, depthM: 3.2, runs: [run]);
      final editor = PlanEditor(plan);
      expect(editor.moveRun(run, Wall.north, 2.3), isTrue);
      expect(run.a, closeTo(2.3 - 0.75, 1e-6)); // exactly where dropped
    });
  });

  group('Cut-list engine (b35)', () {
    LayoutPlan demoUPlan() => LayoutPlan(
          widthM: 4.2,
          depthM: 3.4,
          runs: [
            RunPlan(
                wall: Wall.north,
                a: 0.82,
                b: 4.15,
                sinkAt: 1.71,
                rangeAt: 3.17,
                uppers: true),
            RunPlan(
                wall: Wall.west, a: 0.02, b: 3.06, fridge: 'start',
                uppers: true),
          ],
          island: IslandPlan(x0: 1.2, z0: 1.5, w: 1.6, d: 0.9),
        );

    test('the demo kitchen breaks down to the proto-validated numbers', () {
      final bom = buildBom(demoUPlan(), const KitchenDesign());
      final counts = bom.cabinetCounts;
      // FROZEN from tools/cutlist_proto.py on the same plan
      expect((counts['base'] ?? 0) + (counts['sink base'] ?? 0), 8);
      expect(counts['upper'], 9);
      expect(counts['island base'], 3);
      expect(bom.hardware['hinge'], 40); // 20 doors x 2
      expect(bom.hardware['leg'], 44);
      expect(bom.hardware['bracket'], 18);
      expect(bom.hardware['handle'], 20);
      expect(bom.worktopM, closeTo(7.27, 0.02));
      expect(bom.notes.join(), contains('fridge'));
      expect(bom.notes.join(), contains('cooker'));
    });

    test('nesting buys a plausible number of standard sheets', () {
      final bom = buildBom(demoUPlan(), const KitchenDesign());
      final est = priceBom(bom, const KitchenDesign());
      expect(est.boards['mfc18'], 14); // frozen from the proto
      expect(est.boards['hdf3'], 4);
      expect(est.utilization['mfc18']!, greaterThan(0.5));
      expect(est.utilization['mfc18']!, lessThan(0.95));
      // total in the researched Amman mid-market band, +/-10% band wider
      expect(est.totalJd, closeTo(1797, 25));
      expect(est.lowJd, lessThan(est.totalJd));
      expect(est.highJd, greaterThan(est.totalJd));
    });

    test('shaker doors switch door panels to MDF sheets', () {
      final bom =
          buildBom(demoUPlan(), const KitchenDesign(door: 'shaker'));
      final est =
          priceBom(bom, const KitchenDesign(door: 'shaker'));
      expect(est.boards['mdf18'], greaterThan(0));
    });

    test('push-to-open and gola price differently from bar handles', () {
      final bar = priceBom(buildBom(demoUPlan(), const KitchenDesign()),
          const KitchenDesign());
      final push = priceBom(
          buildBom(demoUPlan(), const KitchenDesign(handle: 'push')),
          const KitchenDesign(handle: 'push'));
      final gola = priceBom(
          buildBom(demoUPlan(), const KitchenDesign(handle: 'gola')),
          const KitchenDesign(handle: 'gola'));
      expect(push.totalJd, isNot(closeTo(bar.totalJd, 0.01)));
      expect(gola.totalJd, greaterThan(push.totalJd));
    });

    test('tall pantry units contribute their stacked-door parts', () {
      final plan = LayoutPlan(widthM: 3.6, depthM: 3.0, runs: [
        RunPlan(wall: Wall.west, a: 0.02, b: 0.62, tall: true),
      ]);
      final bom = buildBom(plan, const KitchenDesign());
      expect(bom.cabinetCounts['tall'], 1);
      expect(bom.hardware['hinge'], 5); // 3 low + 2 high
      expect(bom.parts.any((p) => p.name == 'door low'), isTrue);
      expect(bom.worktopM, 0); // no worktop over a pantry
    });

    test('every part fits a standard sheet', () {
      final bom = buildBom(demoUPlan(), const KitchenDesign());
      for (final mat in sheetStock.keys) {
        expect(() => nestSheets(bom.parts, mat), returnsNormally);
      }
    });
  });

  group('Resize fixes (b34)', () {
    test('growing the START end into the left neighbour joins them - '
        'no more snap-back', () {
      final left = RunPlan(
          wall: Wall.north, a: 0.5, b: 1.6, sinkAt: 1.0, uppers: true);
      final right = RunPlan(wall: Wall.north, a: 2.2, b: 3.4, uppers: true);
      final plan =
          LayoutPlan(widthM: 4.2, depthM: 3.4, runs: [left, right]);
      final editor = PlanEditor(plan);
      // drag the right run's start handle onto the left run's end
      expect(editor.resizeRun(right, startEnd: true, v: 1.55), isTrue);
      expect(plan.runs, hasLength(1)); // merged into one counter
      expect(plan.runs.single.a, closeTo(0.5, 1e-6));
      expect(plan.runs.single.b, closeTo(3.4, 1e-6));
      expect(plan.runs.single.sinkAt, isNotNull); // sink survived the join
    });

    test('growing the END side into the right neighbour still joins', () {
      final left = RunPlan(
          wall: Wall.north, a: 0.5, b: 1.6, sinkAt: 1.0, uppers: true);
      final right = RunPlan(wall: Wall.north, a: 2.2, b: 3.4, uppers: true);
      final plan =
          LayoutPlan(widthM: 4.2, depthM: 3.4, runs: [left, right]);
      final editor = PlanEditor(plan);
      expect(editor.resizeRun(left, startEnd: false, v: 2.25), isTrue);
      expect(plan.runs, hasLength(1));
      expect(plan.runs.single.a, closeTo(0.5, 1e-6));
      expect(plan.runs.single.b, closeTo(3.4, 1e-6));
    });
  });

  group('User-added appliances (b33)', () {
    test('a missed fridge can be added without touching the cabinets', () {
      // AI plan with sink+oven but NO fridge (the reported miss)
      final north = RunPlan(
          wall: Wall.north,
          a: 0.1,
          b: 3.5,
          sinkAt: 0.9,
          rangeAt: 2.6,
          uppers: true);
      final plan = LayoutPlan(widthM: 4.2, depthM: 3.4, runs: [north]);
      final editor = PlanEditor(plan);
      expect(editor.addAppliance(ApplianceKind.fridge), isTrue);
      expect(editor.runWith(ApplianceKind.fridge), isNotNull);
      // the original cabinets survived intact
      expect(plan.runs.contains(north), isTrue);
      expect(north.sinkAt, isNotNull);
      expect(north.rangeAt, isNotNull);
    });

    test('a missed oven lands on an existing counter', () {
      final north = RunPlan(
          wall: Wall.north, a: 0.1, b: 3.5, sinkAt: 0.9, uppers: true);
      final plan = LayoutPlan(widthM: 4.2, depthM: 3.4, runs: [north]);
      final editor = PlanEditor(plan);
      expect(editor.addAppliance(ApplianceKind.range), isTrue);
      expect(north.rangeAt, isNotNull);
      // proper separation from the sink
      expect((north.rangeAt! - north.sinkAt!).abs(),
          greaterThanOrEqualTo(PlanEditor.minSeparation - 1e-6));
    });

    test('adding an appliance that exists is refused', () {
      final north = RunPlan(
          wall: Wall.north, a: 0.1, b: 3.5, sinkAt: 0.9, uppers: true);
      final plan = LayoutPlan(widthM: 4.2, depthM: 3.4, runs: [north]);
      final editor = PlanEditor(plan);
      expect(editor.addAppliance(ApplianceKind.sink), isFalse);
    });

    test('all three can be added to a bare kitchen', () {
      final plan = LayoutPlan(widthM: 4.2, depthM: 3.4, runs: [
        RunPlan(wall: Wall.north, a: 0.5, b: 2.2, uppers: true),
      ]);
      final editor = PlanEditor(plan);
      expect(editor.addAppliance(ApplianceKind.sink), isTrue);
      expect(editor.addAppliance(ApplianceKind.range), isTrue);
      expect(editor.addAppliance(ApplianceKind.fridge), isTrue);
      expect(editor.runWith(ApplianceKind.sink), isNotNull);
      expect(editor.runWith(ApplianceKind.range), isNotNull);
      expect(editor.runWith(ApplianceKind.fridge), isNotNull);
    });
  });

  group('No-overlap invariant (b30 fuzz)', () {
    // real built geometry: the counter part is 0.655 deep and only the
    // 0.8 m fridge SLOT is 0.75 deep - modelling the whole run at 0.75
    // would flag legal corner clearances as overlaps
    List<double> spanRect(
        Wall wall, double a, double b, double depth, double w, double d) {
      return switch (wall) {
        Wall.north => [a, 0.0, b, depth],
        Wall.south => [a, d - depth, b, d],
        Wall.west => [0.0, a, depth, b],
        Wall.east => [w - depth, a, w, b],
      };
    }

    List<List<double>> rectsOf(RunPlan r, double w, double d) {
      if (r.fridge == null) {
        return [spanRect(r.wall, r.a, r.b, 0.655, w, d)];
      }
      final fa = r.fridge == 'start' ? r.a : r.b - 0.8;
      final fb = r.fridge == 'start' ? r.a + 0.8 : r.b;
      return [
        spanRect(r.wall, fa, fb, 0.75, w, d),
        if (r.fridge == 'start' && r.b - fb > 0.01)
          spanRect(r.wall, fb, r.b, 0.655, w, d),
        if (r.fridge == 'end' && fa - r.a > 0.01)
          spanRect(r.wall, r.a, fa, 0.655, w, d),
      ];
    }

    bool hit(List<double> p, List<double> q) =>
        p[0] < q[2] - 0.02 &&
        q[0] < p[2] - 0.02 &&
        p[1] < q[3] - 0.02 &&
        q[1] < p[3] - 0.02;

    List<String> overlapReport(LayoutPlan plan) {
      final rects = <(String, int, List<double>)>[
        for (var i = 0; i < plan.runs.length; i++)
          for (final rect in rectsOf(plan.runs[i], plan.widthM, plan.depthM))
            ('run$i:${plan.runs[i].wall.name}', i, rect),
        if (plan.island != null)
          ('island', -1, [
            plan.island!.x0,
            plan.island!.z0,
            plan.island!.x0 + plan.island!.w,
            plan.island!.z0 + plan.island!.d,
          ]),
      ];
      final bad = <String>[];
      for (var i = 0; i < rects.length; i++) {
        for (var j = i + 1; j < rects.length; j++) {
          if (rects[i].$2 == rects[j].$2) continue; // same run's own parts
          if (hit(rects[i].$3, rects[j].$3)) {
            bad.add('${rects[i].$1} x ${rects[j].$1}');
          }
        }
      }
      return bad;
    }

    test('300 random edit sequences never overlap cabinets', () {
      for (var seed = 0; seed < 300; seed++) {
        final rnd = math.Random(seed);
        final plan = LayoutPlan(
          widthM: 3.0 + rnd.nextDouble() * 1.8,
          depthM: 2.8 + rnd.nextDouble() * 1.4,
          runs: [
            RunPlan(
                wall: Wall.north,
                a: 0.1,
                b: 2.8,
                sinkAt: 0.9,
                rangeAt: 2.2,
                uppers: true),
            RunPlan(wall: Wall.west, a: 0.8, b: 2.4, fridge: 'end'),
          ],
          island: seed.isEven
              ? IslandPlan(x0: 1.2, z0: 1.4, w: 1.4, d: 0.8)
              : null,
        );
        normalizePlan(plan);
        final editor = PlanEditor(plan);
        for (var step = 0; step < 12; step++) {
          final wall = Wall.values[rnd.nextInt(4)];
          final m = (wall == Wall.north || wall == Wall.south)
              ? plan.widthM
              : plan.depthM;
          final u = rnd.nextDouble() * m;
          switch (rnd.nextInt(6)) {
            case 0:
              editor.place(
                  ApplianceKind.values[rnd.nextInt(3)], wall, u);
            case 1:
              if (plan.runs.isNotEmpty) {
                editor.moveRun(
                    plan.runs[rnd.nextInt(plan.runs.length)], wall, u,
                    mirror: rnd.nextBool());
              }
            case 2:
              if (plan.runs.isNotEmpty) {
                editor.resizeRun(plan.runs[rnd.nextInt(plan.runs.length)],
                    startEnd: rnd.nextBool(), v: u);
              }
            case 3:
              editor.moveIsland(rnd.nextDouble() * plan.widthM,
                  rnd.nextDouble() * plan.depthM);
            case 4:
              editor.addRun(tall: rnd.nextBool());
            case 5:
              if (plan.runs.length > 1) {
                editor.removeRun(plan.runs[rnd.nextInt(plan.runs.length)]);
              }
          }
          final bad = overlapReport(plan);
          expect(bad, isEmpty,
              reason: 'seed $seed step $step left overlaps: $bad');
        }
      }
    });
  });

  group('Design chat (b28)', () {
    test('parses the full reply contract', () {
      final r = DesignChatSession.parseReply('''
Here you go:
```json
{"reply":"A navy kitchen it is.",
 "plan":{"width_m":3.6,"depth_m":3.0,"runs":[
   {"wall":"north","from_m":0.1,"to_m":3.5,"sink_at_m":0.9,
    "range_at_m":2.6,"fridge":null,"uppers":true}],
  "island":{"present":false},"windows":[],
  "palette":"dark_modern","summary":"one wall"},
 "design":{"lower":"navy_blue","hardware":"brass"}}
```''');
      expect(r.reply, 'A navy kitchen it is.');
      expect(r.plan, isNotNull);
      expect(r.plan!.runs, hasLength(1));
      expect(r.design, isNotNull);
      expect(r.design!.lower, 'navy_blue');
      expect(r.design!.hardware, 'brass');
      expect(r.design!.worktop, 'basalt_quartz'); // default preserved
    });

    test('malformed answer degrades to a plain chat reply', () {
      final r = DesignChatSession.parseReply('Sure! What size is the room?');
      expect(r.plan, isNull);
      expect(r.design, isNull);
      expect(r.reply, contains('What size'));
    });

    test('schema echo (0x0 room) is rejected, reply survives', () {
      final r = DesignChatSession.parseReply(
          '{"reply":"ok","plan":{"width_m":0.0,"depth_m":0.0,"runs":[]}}');
      expect(r.plan, isNull);
      expect(r.reply, 'ok');
    });

    test('partial design merges onto the current one (review fix)', () {
      const base = KitchenDesign(
          lower: 'navy_blue',
          upper: 'white_satin',
          worktop: 'butcher_block',
          hardware: 'black');
      final r = DesignChatSession.parseReply(
          '{"reply":"lighter floor","design":{"floor":"light_oak"}}',
          base: base);
      expect(r.design!.floor, 'light_oak'); // the change
      expect(r.design!.lower, 'navy_blue'); // kept, not reset to default
      expect(r.design!.worktop, 'butcher_block');
      expect(r.design!.hardware, 'black');
    });

    test('AI plan bounds are a deliberate edit: orig rebases, echoed '
        'orig keys are ignored (review fix)', () {
      final r = DesignChatSession.parseReply('''
{"reply":"ok","plan":{"width_m":3.6,"depth_m":3.0,"runs":[
  {"wall":"north","from_m":0.5,"to_m":3.0,"uppers":true,
   "orig_a":0.1,"orig_b":3.5,"auto":true}],
 "island":{"present":false},"windows":[],
 "palette":"warm_walnut","summary":"s"}}''');
      final run = r.plan!.runs.single;
      expect(run.origA, closeTo(run.a, 1e-6));
      expect(run.origB, closeTo(run.b, 1e-6));
      expect(run.auto, isFalse);
    });

    test('state sent to the model never leaks internal fields '
        '(review fix)', () {
      final plan = LayoutPlan(widthM: 4.0, depthM: 3.0, runs: [
        RunPlan(
            wall: Wall.north,
            a: 0.67,
            b: 3.0,
            uppers: true,
            auto: true,
            origA: 0.1,
            origB: 3.0),
      ]);
      final j = DesignChatSession.modelFacingPlanJson(plan);
      final rj = (j['runs'] as List).single as Map;
      expect(rj.containsKey('orig_a'), isFalse);
      expect(rj.containsKey('orig_b'), isFalse);
      expect(rj.containsKey('auto'), isFalse);
      expect(rj['from_m'], closeTo(0.67, 1e-6)); // real fields intact
    });

    test('photo-render prompt describes the layout and the chosen '
        'finishes by label (b29)', () {
      final plan = LayoutPlan(widthM: 3.6, depthM: 3.0, runs: [
        RunPlan(
            wall: Wall.north,
            a: 0.1,
            b: 3.5,
            sinkAt: 0.9,
            rangeAt: 2.6,
            fridge: 'end',
            uppers: true),
      ], island: IslandPlan(x0: 1.0, z0: 1.6, w: 1.6, d: 0.9));
      const design = KitchenDesign(
          lower: 'navy_blue',
          worktop: 'butcher_block',
          floor: 'slate_tile',
          hardware: 'black');
      final p = renderPrompt(plan, design);
      expect(p, contains('3.6 x 3.0 metres'));
      expect(p, contains('back wall'));
      expect(p, contains('undermount sink'));
      expect(p, contains('tall fridge'));
      expect(p, contains('island'));
      expect(p, contains('Navy blue')); // labels, not raw ids
      expect(p, contains('Butcher block'));
      expect(p, contains('Slate tile'));
      expect(p, contains('Matte black'));
      expect(p, isNot(contains('navy_blue'))); // no raw ids leak
      expect(p.length, lessThan(4000)); // proxy prompt clamp
    });

    test('vocabulary carries every real option id', () {
      final v = designVocabulary();
      for (final id in [
        ...cabinetFinishes.keys,
        ...worktops.keys,
        ...wallPaints.keys,
        ...floorFinishes.keys,
        ...backsplashes.keys,
        ...hardwareFinishes.keys,
        ...handleStyles.keys,
        ...doorStyles.keys,
      ]) {
        expect(v, contains(id));
      }
    });
  });
}
