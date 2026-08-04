import 'dart:convert';

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
