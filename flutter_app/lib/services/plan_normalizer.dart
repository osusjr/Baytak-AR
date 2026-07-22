import 'dart:math' as math;

import 'kitchen_generator.dart';

/// Plan normalizer (b20): the pure-logic pass that makes ANY LayoutPlan
/// buildable. Runs after AI parsing and after every drag edit, so neither
/// a misreading model nor an aggressive drag can produce a kitchen with
/// overlapping cabinets or an island blocking the walkways (the reported
/// "counter covered the whole middle of the room" failure).
///
/// Ported from tools/plan_normalizer_proto.py - constants FROZEN from the
/// validated prototype. Coordinate convention (b20, unified): run u is
/// measured from the WEST end on north/south walls and from the NORTH end
/// on east/west walls; identical to the AI schema and the generator frame.
///
/// Rules, in order:
///  1. Runs clamped into their wall, degenerates dropped, same-wall
///     overlaps merged. Fridge-only runs (length ~0.8) are legal.
///  2. Corner pass - perpendicular runs must not overlap in plan: a
///     fridge slot is immovable (the other run trims to clear it);
///     otherwise the east/west run yields to the north/south run.
///  3. Island pass - overlaps pulled back to touching, then per side:
///     gaps under [attachEps] are peninsula attachments (allowed on
///     adjacent sides, but an OPPOSITE pair would bridge the room - the
///     shorter contact is pushed out to a walkway); gaps under [walkway]
///     are widened to [walkway]. An island left thinner than [islandMin]
///     is dropped entirely.
///  4. Appliances re-clamped into their possibly-trimmed runs.
class PlanNormalizer {
  PlanNormalizer._();

  static const counterD = 0.655; // counter overhang depth (= generator _cd)
  static const fridgeD = 0.75; // fridge box depth
  static const fridgeSpan = 0.8; // fridge width along the run
  static const clearFridge = 0.82; // perpendicular clearance from a fridge
  static const clearCounter = 0.67; // E/W clearance from an N/S corner
  static const walkway = 0.85; // min island clearance, non-attached side
  static const attachEps = 0.10; // gap below this = attached peninsula
  static const islandMin = 0.60; // island dropped if thinner after shrink
  static const minRun = 0.90; // min counter run length
  static const fridgeOnlyLen = 0.80; // exact fridge-only run length
  static const fridgeOnlyEps = 0.05;
  static const edgeMargin = 0.45; // sink/range distance from run ends
  static const minSep = 0.95; // sink<->range separation
}

double _axisMax(Wall wall, double w, double d) =>
    (wall == Wall.north || wall == Wall.south) ? w : d;

bool _horizontal(Wall wall) => wall == Wall.north || wall == Wall.south;

/// Plan-space rect [x0,z0,x1,z1] of a run incl. its fridge depth.
List<double> _runRect(RunPlan r, double w, double d) {
  final depth =
      r.fridge != null ? PlanNormalizer.fridgeD : PlanNormalizer.counterD;
  switch (r.wall) {
    case Wall.north:
      return [r.a, 0.0, r.b, depth];
    case Wall.south:
      return [r.a, d - depth, r.b, d];
    case Wall.west:
      return [0.0, r.a, depth, r.b];
    case Wall.east:
      return [w - depth, r.a, w, r.b];
  }
}

/// Plan-space rect of just the fridge slot, or null.
List<double>? _fridgeRect(RunPlan r, double w, double d) {
  if (r.fridge == null) return null;
  final fa = r.fridge == 'start' ? r.a : r.b - PlanNormalizer.fridgeSpan;
  final fb = r.fridge == 'start' ? r.a + PlanNormalizer.fridgeSpan : r.b;
  switch (r.wall) {
    case Wall.north:
      return [fa, 0.0, fb, PlanNormalizer.fridgeD];
    case Wall.south:
      return [fa, d - PlanNormalizer.fridgeD, fb, d];
    case Wall.west:
      return [0.0, fa, PlanNormalizer.fridgeD, fb];
    case Wall.east:
      return [w - PlanNormalizer.fridgeD, fa, w, fb];
  }
}

bool _rectsOverlap(List<double> p, List<double> q, [double eps = 0.01]) =>
    p[0] < q[2] - eps &&
    q[0] < p[2] - eps &&
    p[1] < q[3] - eps &&
    q[1] < p[3] - eps;

double _minLen(RunPlan r) => r.fridge != null
    ? PlanNormalizer.fridgeOnlyLen - PlanNormalizer.fridgeOnlyEps
    : PlanNormalizer.minRun;

/// Trim run [r] so [a,b] avoids the world-axis band [blkA,blkB].
/// Returns false when r cannot survive the trim.
bool _trimRunToClear(RunPlan r, double blkA, double blkB) {
  if (blkB <= r.a + 1e-9 || blkA >= r.b - 1e-9) return true;
  final keepLo = (r.a, math.min(r.b, blkA));
  final keepHi = (math.max(r.a, blkB), r.b);
  final best = (keepLo.$2 - keepLo.$1) >= (keepHi.$2 - keepHi.$1)
      ? keepLo
      : keepHi;
  if (best.$2 - best.$1 < _minLen(r) - 1e-9) return false;
  r.a = best.$1;
  r.b = best.$2;
  return true;
}

/// Normalizes [plan] in place; returns human-readable fix notes (empty
/// when the plan was already buildable).
List<String> normalizePlan(LayoutPlan plan) {
  final notes = <String>[];
  final w = plan.widthM, d = plan.depthM;

  // ---- 1. clamp, drop degenerates, merge same-wall overlaps -------------
  final kept = <RunPlan>[];
  for (final r in plan.runs) {
    if (r.auto && !r.hasAppliance) {
      // an editor-created run whose appliance moved away: remove it so
      // ghost cabinets never pile up around the kitchen
      notes.add('removed the cabinets added for a moved appliance');
      continue;
    }
    final m = _axisMax(r.wall, w, d);
    r.a = r.a.clamp(0.02, m - 0.02).toDouble();
    r.b = r.b.clamp(0.02, m - 0.02).toDouble();
    if (r.b - r.a >= _minLen(r) - 1e-9) {
      kept.add(r);
    } else {
      notes.add('dropped a sliver of cabinet on the ${r.wall.name} wall');
    }
  }
  kept.sort((x, y) => x.wall == y.wall
      ? x.a.compareTo(y.a)
      : x.wall.index.compareTo(y.wall.index));
  final merged = <RunPlan>[];
  for (final r in kept) {
    final prev = merged.isNotEmpty && merged.last.wall == r.wall
        ? merged.last
        : null;
    // runs that merely TOUCH at a fridge slot stay separate - that gap IS
    // the fridge (the editor's mid-run split); overlapping runs and plain
    // touching counters merge
    final fridgeAtSeam =
        prev != null && (prev.fridge == 'end' || r.fridge == 'start');
    final touching = prev != null && r.a >= prev.b - 0.01;
    if (prev != null &&
        r.a <= prev.b + 0.05 &&
        !(touching && fridgeAtSeam)) {
      prev.b = math.max(prev.b, r.b);
      prev.sinkAt ??= r.sinkAt;
      prev.rangeAt ??= r.rangeAt;
      prev.fridge ??= r.fridge;
      prev.uppers = prev.uppers || r.uppers;
      // a merge containing ANY original cabinets is no longer disposable
      prev.auto = prev.auto && r.auto;
      notes.add('merged overlapping cabinets on the ${r.wall.name} wall');
    } else {
      merged.add(r);
    }
  }
  plan.runs
    ..clear()
    ..addAll(merged);

  // ---- 2. corner pass ----------------------------------------------------
  final survivors = <RunPlan>[];
  for (final r in plan.runs) {
    var ok = true;
    for (final other in plan.runs) {
      if (identical(other, r) || !ok) continue;
      if (_horizontal(r.wall) == _horizontal(other.wall)) continue;
      if (!_rectsOverlap(_runRect(r, w, d), _runRect(other, w, d))) {
        continue;
      }
      final m = _axisMax(r.wall, w, d);
      final frOther = _fridgeRect(other, w, d);
      final frMine = _fridgeRect(r, w, d);
      if (frOther != null && _rectsOverlap(_runRect(r, w, d), frOther)) {
        // the fridge is immovable: this run clears its wall band
        final nearOrigin =
            other.wall == Wall.north || other.wall == Wall.west;
        ok = nearOrigin
            ? _trimRunToClear(r, 0.0, PlanNormalizer.clearFridge)
            : _trimRunToClear(r, m - PlanNormalizer.clearFridge, m);
        notes.add('slid the ${r.wall.name} cabinets clear of the fridge');
      } else if (frMine != null &&
          _rectsOverlap(_runRect(other, w, d), frMine)) {
        // the other run yields when the outer loop visits it
      } else if (!_horizontal(r.wall)) {
        // plain counter corner: east/west yields to north/south
        ok = other.wall == Wall.north
            ? _trimRunToClear(r, 0.0, PlanNormalizer.clearCounter)
            : _trimRunToClear(r, d - PlanNormalizer.clearCounter, d);
        notes.add('trimmed the ${r.wall.name} cabinets at the '
            '${other.wall.name} corner');
      }
    }
    if (ok) {
      survivors.add(r);
    } else {
      notes.add('removed the ${r.wall.name} cabinets - no room left');
    }
  }
  plan.runs
    ..clear()
    ..addAll(survivors);

  // ---- 3. island pass ----------------------------------------------------
  final isl = plan.island;
  if (isl != null) {
    var x0 = math.max(isl.x0, 0.0), z0 = math.max(isl.z0, 0.0);
    var x1 = math.min(isl.x0 + isl.w, w), z1 = math.min(isl.z0 + isl.d, d);
    final obstacles = <List<double>>[
      for (final r in plan.runs) _runRect(r, w, d),
      for (final wall in planWalls(plan))
        switch (wall) {
          Wall.north => [0.0, -0.06, w, 0.0],
          Wall.south => [0.0, d, w, d + 0.06],
          Wall.west => [-0.06, 0.0, 0.0, d],
          Wall.east => [w, 0.0, w + 0.06, d],
        },
    ];

    // pass A: pull overlapping edges back to touching
    for (final ob in obstacles) {
      if (!_rectsOverlap([x0, z0, x1, z1], ob)) continue;
      final pulls = <(double, String, double)>[];
      if (ob[2] > x0 && x0 >= ob[0] - 1e-9) pulls.add((ob[2] - x0, 'x0', ob[2]));
      if (ob[0] < x1 && x1 <= ob[2] + 1e-9) pulls.add((x1 - ob[0], 'x1', ob[0]));
      if (ob[3] > z0 && z0 >= ob[1] - 1e-9) pulls.add((ob[3] - z0, 'z0', ob[3]));
      if (ob[1] < z1 && z1 <= ob[3] + 1e-9) pulls.add((z1 - ob[1], 'z1', ob[1]));
      if (pulls.isEmpty) pulls.add((x1 - ob[0], 'x1', ob[0]));
      pulls.sort((a, b) => a.$1.compareTo(b.$1));
      switch (pulls.first.$2) {
        case 'x0':
          x0 = pulls.first.$3;
        case 'x1':
          x1 = pulls.first.$3;
        case 'z0':
          z0 = pulls.first.$3;
        default:
          z1 = pulls.first.$3;
      }
    }

    // pass B: classify sides; adjacent attachments fine, opposite pairs
    // and tight gaps get pushed out to a walkway
    // state per side: (kind 0=free 1=attached 2=tight, contact, front)
    // front is null when the side faces nothing at all
    final state = <String, (int, double, double?)>{};
    void classify() {
      for (final side in ['x0', 'x1', 'z0', 'z1']) {
        (double, double, double)? nearest; // gap, contact, front
        for (final ob in obstacles) {
          double gap, contact, front;
          if (side == 'x0' || side == 'x1') {
            if (!(z0 < ob[3] && ob[1] < z1)) continue;
            contact = math.min(z1, ob[3]) - math.max(z0, ob[1]);
            if (side == 'x0' && ob[2] <= x0 + 1e-9) {
              gap = x0 - ob[2];
              front = ob[2];
            } else if (side == 'x1' && ob[0] >= x1 - 1e-9) {
              gap = ob[0] - x1;
              front = ob[0];
            } else {
              continue;
            }
          } else {
            if (!(x0 < ob[2] && ob[0] < x1)) continue;
            contact = math.min(x1, ob[2]) - math.max(x0, ob[0]);
            if (side == 'z0' && ob[3] <= z0 + 1e-9) {
              gap = z0 - ob[3];
              front = ob[3];
            } else if (side == 'z1' && ob[1] >= z1 - 1e-9) {
              gap = ob[1] - z1;
              front = ob[1];
            } else {
              continue;
            }
          }
          if (nearest == null || gap < nearest.$1) {
            nearest = (gap, contact, front);
          }
        }
        if (nearest == null) {
          state[side] = (0, 0, null);
        } else if (nearest.$1 < PlanNormalizer.attachEps) {
          state[side] = (1, nearest.$2, nearest.$3);
        } else if (nearest.$1 < PlanNormalizer.walkway) {
          state[side] = (2, nearest.$2, nearest.$3);
        } else {
          state[side] = (0, nearest.$2, nearest.$3);
        }
      }
    }

    classify();

    // a tight side TRANSLATES the island away when the opposite side is
    // free (keeps the island's size - matters for presets and for drag
    // edits); only shrink when there is nowhere to go. Returns whether it
    // shifted - side states are STALE after a shift and must be
    // recomputed (an x-shift changes which obstacles face the z sides).
    bool translate(String loS, String hiS, bool xAxis) {
      final lo = state[loS]!, hi = state[hiS]!;
      final room = xAxis ? w : d;
      final a0 = xAxis ? x0 : z0, a1 = xAxis ? x1 : z1;
      double shift;
      bool blocked;
      if (lo.$1 == 2 && hi.$1 == 0) {
        shift = (lo.$3! + PlanNormalizer.walkway) - a0;
        blocked = a1 + shift > room ||
            (hi.$3 != null && hi.$3! - (a1 + shift) < PlanNormalizer.walkway);
      } else if (hi.$1 == 2 && lo.$1 == 0) {
        shift = (hi.$3! - PlanNormalizer.walkway) - a1;
        blocked = a0 + shift < 0 ||
            (lo.$3 != null && (a0 + shift) - lo.$3! < PlanNormalizer.walkway);
      } else {
        return false;
      }
      if (blocked) return false; // fall through to the shrink pass
      if (xAxis) {
        x0 = a0 + shift;
        x1 = a1 + shift;
      } else {
        z0 = a0 + shift;
        z1 = a1 + shift;
      }
      return true;
    }

    if (translate('x0', 'x1', true)) classify();
    if (translate('z0', 'z1', false)) classify();

    final demoted = <String>{};
    for (final pair in [('x0', 'x1'), ('z0', 'z1')]) {
      if (state[pair.$1]!.$1 == 1 && state[pair.$2]!.$1 == 1) {
        demoted.add(
            state[pair.$1]!.$2 < state[pair.$2]!.$2 ? pair.$1 : pair.$2);
      }
    }

    for (final e in state.entries) {
      final push =
          e.value.$1 == 2 || (e.value.$1 == 1 && demoted.contains(e.key));
      if (!push) continue;
      final front = e.value.$3;
      if (front == null) continue;
      switch (e.key) {
        case 'x0':
          x0 = front + PlanNormalizer.walkway;
        case 'x1':
          x1 = front - PlanNormalizer.walkway;
        case 'z0':
          z0 = front + PlanNormalizer.walkway;
        default:
          z1 = front - PlanNormalizer.walkway;
      }
    }

    if (x1 - x0 < PlanNormalizer.islandMin - 1e-9 ||
        z1 - z0 < PlanNormalizer.islandMin - 1e-9) {
      plan.island = null;
      notes.add('removed the island - it left no room to walk');
    } else if ((x0 - isl.x0).abs() > 1e-6 ||
        (z0 - isl.z0).abs() > 1e-6 ||
        ((x1 - x0) - isl.w).abs() > 1e-6 ||
        ((z1 - z0) - isl.d).abs() > 1e-6) {
      isl
        ..x0 = x0
        ..z0 = z0
        ..w = x1 - x0
        ..d = z1 - z0;
      notes.add('resized the island to keep the walkways clear');
    }
  }

  // ---- 4. appliance re-clamp ---------------------------------------------
  for (final r in plan.runs) {
    var a = r.a, b = r.b;
    if (r.fridge == 'start') a += PlanNormalizer.fridgeSpan;
    if (r.fridge == 'end') b -= PlanNormalizer.fridgeSpan;
    final lo = a + PlanNormalizer.edgeMargin;
    final hi = b - PlanNormalizer.edgeMargin;
    if (hi <= lo) {
      if (r.sinkAt != null || r.rangeAt != null) {
        notes.add('moved appliances off a too-small cabinet');
      }
      r.sinkAt = null;
      r.rangeAt = null;
      continue;
    }
    if (r.sinkAt != null) r.sinkAt = r.sinkAt!.clamp(lo, hi).toDouble();
    if (r.rangeAt != null) r.rangeAt = r.rangeAt!.clamp(lo, hi).toDouble();
    final s = r.sinkAt, g = r.rangeAt;
    if (s != null && g != null && (s - g).abs() < PlanNormalizer.minSep) {
      final below = s - PlanNormalizer.minSep;
      final above = s + PlanNormalizer.minSep;
      if (below >= lo) {
        r.rangeAt = below;
      } else if (above <= hi) {
        r.rangeAt = above;
      } else {
        r.rangeAt = null;
        notes.add('removed the oven - no room next to the sink');
      }
    }
  }
  return notes;
}
