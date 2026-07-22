import 'dart:math' as math;

import 'kitchen_generator.dart';
import 'plan_normalizer.dart';

/// Drag-editing rules for a [LayoutPlan]: move the sink, range (oven) and
/// fridge around the kitchen IKEA-planner style. b20 upgrades the editor
/// from "slide along existing runs" to FREE placement: drop an appliance
/// on any wall and the cabinets adapt - runs are created on bare walls,
/// extended to reach the drop point, split around a mid-run fridge, and
/// the normalizer trims neighbouring runs so nothing ever overlaps.
/// Pure logic, no Flutter imports - unit-tested in widget_test.dart.
enum ApplianceKind { sink, range, fridge }

class PlanEditor {
  PlanEditor(this.plan);

  final LayoutPlan plan;

  /// Bumped on every successful edit so painters can shouldRepaint cheaply
  /// even though the plan object is mutated in place.
  int revision = 0;

  /// Min distance of a sink/range centre from a run end (the parser's
  /// `within()` uses 0.42; keep a hair more so re-parses never drop it).
  static const edgeMargin = 0.45;

  /// Min sink<->range centre separation on the same run (worktop between).
  static const minSeparation = 0.95;

  /// Fridge consumes 0.8 m at a run end (generator constant).
  static const fridgeSpan = 0.8;

  /// A run must keep this much total length to host the fridge AND some
  /// worktop; shorter runs refuse it (a fridge-only run is created on
  /// bare wall instead).
  static const minRunAfterFridge = 1.5;

  /// A drop this close to an existing run's end extends that run instead
  /// of creating a new one.
  static const extendReach = 0.60;

  /// Length of a run auto-created under a dropped sink/oven.
  static const newRunLen = 1.5;

  /// Drops within this distance of a run end snap the fridge to the end
  /// instead of splitting the run.
  static const endSnap = 0.55;

  // ------------------------------------------------------------- queries --
  /// Usable interval for sink/range centres on [r] (fridge trims one end).
  (double, double) usableSpan(RunPlan r) {
    var a = r.a, b = r.b;
    if (r.fridge == 'start') a += fridgeSpan;
    if (r.fridge == 'end') b -= fridgeSpan;
    return (a + edgeMargin, b - edgeMargin);
  }

  RunPlan? runWith(ApplianceKind kind) {
    for (final r in plan.runs) {
      switch (kind) {
        case ApplianceKind.sink:
          if (r.sinkAt != null) return r;
        case ApplianceKind.range:
          if (r.rangeAt != null) return r;
        case ApplianceKind.fridge:
          if (r.fridge != null) return r;
      }
    }
    return null;
  }

  /// Current centre position of [kind] along its run, or null.
  double? positionOf(ApplianceKind kind) {
    final r = runWith(kind);
    if (r == null) return null;
    switch (kind) {
      case ApplianceKind.sink:
        return r.sinkAt;
      case ApplianceKind.range:
        return r.rangeAt;
      case ApplianceKind.fridge:
        return r.fridge == 'start' ? r.a + fridgeSpan / 2 : r.b - fridgeSpan / 2;
    }
  }

  double _wallLen(Wall wall) =>
      (wall == Wall.north || wall == Wall.south) ? plan.widthM : plan.depthM;

  RunPlan? _runAt(Wall wall, double u, [double slack = 0.25]) {
    for (final r in plan.runs) {
      if (r.wall == wall && u >= r.a - slack && u <= r.b + slack) return r;
    }
    return null;
  }

  // --------------------------------------------------------------- moves --
  /// b20 entry point: put [kind] at position [u] along [wall], wherever
  /// that is - on, near, or far from existing cabinets. Returns false only
  /// when the drop genuinely cannot be built there (the plan is then left
  /// exactly as it was).
  /// Deep copy of the mutable plan state, for rollback on failed edits.
  (List<RunPlan>, IslandPlan?) _snapshot() {
    final runs = [
      for (final r in plan.runs)
        RunPlan(
            wall: r.wall,
            a: r.a,
            b: r.b,
            sinkAt: r.sinkAt,
            rangeAt: r.rangeAt,
            fridge: r.fridge,
            uppers: r.uppers,
            auto: r.auto)
    ];
    final isl = plan.island;
    final island = isl == null
        ? null
        : IslandPlan(
            x0: isl.x0,
            z0: isl.z0,
            w: isl.w,
            d: isl.d,
            seating: isl.seating,
            cooktop: isl.cooktop);
    return (runs, island);
  }

  void _restore((List<RunPlan>, IslandPlan?) saved) {
    plan.runs
      ..clear()
      ..addAll(saved.$1);
    plan.island = saved.$2;
  }

  bool place(ApplianceKind kind, Wall wall, double u) {
    // snapshot: if the normalizer has to delete the drop target (e.g. a
    // new corner run with no room), roll everything back instead of
    // letting the appliance silently vanish
    final saved = _snapshot();
    var ok = kind == ApplianceKind.fridge
        ? _placeFridge(wall, u)
        : _placeAppliance(kind, wall, u);
    if (ok) {
      normalizePlan(plan);
      ok = runWith(kind) != null;
    }
    if (!ok) {
      _restore(saved);
      return false;
    }
    revision++;
    return true;
  }

  /// Move a whole cabinet run: slide it along its wall, or carry it to
  /// another wall (appliances ride along). [u] is the desired CENTRE of
  /// the run along [wall]. [mirror] flips the appliance arrangement on a
  /// re-wall (the view layer sets it when source and target walls read in
  /// opposite screen directions, so the layout the user built is
  /// preserved VISUALLY). Rolls back losslessly when the destination
  /// cannot host the run.
  bool moveRun(RunPlan run, Wall wall, double u, {bool mirror = false}) {
    if (!plan.runs.contains(run)) return false;
    final saved = _snapshot();
    final m = _wallLen(wall);
    final len = run.length;
    if (m < len + 0.04) return false;
    final a = (u - len / 2).clamp(0.02, m - len - 0.02).toDouble();

    RunPlan moved;
    if (wall == run.wall) {
      final shift = a - run.a;
      run.a += shift;
      run.b += shift;
      if (run.sinkAt != null) run.sinkAt = run.sinkAt! + shift;
      if (run.rangeAt != null) run.rangeAt = run.rangeAt! + shift;
      moved = run;
    } else {
      // wall is final on RunPlan - replace with a re-walled copy,
      // carrying appliances at the same offsets from the run start
      double? carry(double? at) {
        if (at == null) return null;
        final off = at - run.a;
        return a + (mirror ? len - off : off);
      }

      moved = RunPlan(
        wall: wall,
        a: a,
        b: a + len,
        sinkAt: carry(run.sinkAt),
        rangeAt: carry(run.rangeAt),
        fridge: !mirror
            ? run.fridge
            : run.fridge == 'start'
                ? 'end'
                : run.fridge == 'end'
                    ? 'start'
                    : null,
        uppers: run.uppers,
        auto: run.auto,
      );
      final i = plan.runs.indexOf(run);
      plan.runs[i] = moved;
    }
    final carriedSink = moved.sinkAt != null;
    final carriedRange = moved.rangeAt != null;
    final carriedFridge = moved.fridge != null;
    normalizePlan(plan);
    // the move failed if the DRAGGED run itself is gone (a pre-existing
    // run overlapping the interval must not mask its deletion); a merge
    // into a neighbour counts as survival when the combined run covers
    // the drop point. Appliances the run carried must survive too - a
    // drop must never silently delete the sink.
    var survived = plan.runs.contains(moved) ||
        plan.runs.any((r) =>
            r.wall == moved.wall &&
            r.a <= (moved.a + moved.b) / 2 &&
            r.b >= (moved.a + moved.b) / 2 &&
            r.length >= len - 0.05);
    survived = survived &&
        (!carriedSink || runWith(ApplianceKind.sink) != null) &&
        (!carriedRange || runWith(ApplianceKind.range) != null) &&
        (!carriedFridge || runWith(ApplianceKind.fridge) != null);
    if (!survived) {
      _restore(saved);
      return false;
    }
    revision++;
    return true;
  }

  /// Resize a run by dragging one of its ends to [v] (metres along the
  /// wall). Appliances limit how far it can shrink; growth is clamped by
  /// the wall and neighbours via the normalizer. The IKEA staple.
  bool resizeRun(RunPlan run, {required bool startEnd, required double v}) {
    if (!plan.runs.contains(run)) return false;
    final saved = _snapshot();
    final m = _wallLen(run.wall);
    // the shrink limit: keep every appliance (+ margins) inside
    var lo = run.a, hi = run.b;
    final needs = <double>[
      if (run.sinkAt != null) run.sinkAt!,
      if (run.rangeAt != null) run.rangeAt!,
    ];
    if (startEnd) {
      var maxA = hi - PlanNormalizer.minRun;
      for (final p in needs) {
        maxA = math.min(maxA, p - edgeMargin);
      }
      if (run.fridge == 'start') maxA = math.min(maxA, run.a);
      // a fridge-only run has no room to give: clamp bounds can invert
      if (maxA < 0.02) return false;
      lo = v.clamp(0.02, maxA).toDouble();
      if (hi - lo < PlanNormalizer.minRun - 1e-9) return false;
      run.a = lo;
    } else {
      var minB = lo + PlanNormalizer.minRun;
      for (final p in needs) {
        minB = math.max(minB, p + edgeMargin);
      }
      if (run.fridge == 'end') minB = math.max(minB, run.b);
      if (minB > m - 0.02) return false;
      hi = v.clamp(minB, m - 0.02).toDouble();
      if (hi - lo < PlanNormalizer.minRun - 1e-9) return false;
      run.b = hi;
    }
    normalizePlan(plan);
    if (!plan.runs.contains(run)) {
      _restore(saved);
      return false;
    }
    revision++;
    return true;
  }

  /// Remove a whole run (long-press action). The fridge/sink/oven on it
  /// disappear with it - visible, deliberate, and undoable.
  bool removeRun(RunPlan run) {
    if (!plan.runs.remove(run)) return false;
    normalizePlan(plan);
    revision++;
    return true;
  }

  // ---------------------------------------------------------------- undo --
  final List<(List<RunPlan>, IslandPlan?)> _undoStack = [];
  static const _undoDepth = 8;

  /// Push the current state; called by the UI before each structural
  /// gesture (drag release, resize, delete) - NOT on every live move.
  void checkpoint() {
    _undoStack.add(_snapshot());
    if (_undoStack.length > _undoDepth) _undoStack.removeAt(0);
  }

  bool get canUndo => _undoStack.isNotEmpty;

  bool undo() {
    if (_undoStack.isEmpty) return false;
    _restore(_undoStack.removeLast());
    revision++;
    return true;
  }

  /// Drop the most recent checkpoint without restoring it - used when the
  /// gesture it was taken for turned out to be a no-op/failed drop.
  void undoDiscardLast() {
    if (_undoStack.isNotEmpty) _undoStack.removeLast();
  }

  /// Drag the island/peninsula by its centre to floor position ([cx],[cz]).
  /// The normalizer re-applies walkway and attachment rules: the island
  /// may be nudged (pulled to touch a run, pushed to keep a walkway) but
  /// a drag must never silently RESIZE it - dims changing means the spot
  /// cannot host the island, so the move is rolled back instead.
  bool moveIsland(double cx, double cz) {
    final isl = plan.island;
    if (isl == null) return false;
    final saved = _snapshot();
    final w0 = isl.w, d0 = isl.d;
    isl.x0 = (cx - isl.w / 2).clamp(0.0, plan.widthM - isl.w).toDouble();
    isl.z0 = (cz - isl.d / 2).clamp(0.0, plan.depthM - isl.d).toDouble();
    normalizePlan(plan);
    final after = plan.island;
    if (after == null ||
        (after.w - w0).abs() > 0.02 ||
        (after.d - d0).abs() > 0.02) {
      _restore(saved);
      return false;
    }
    revision++;
    return true;
  }

  bool _placeAppliance(ApplianceKind kind, Wall wall, double u) {
    final m = _wallLen(wall);
    if (u < -0.3 || u > m + 0.3) return false;

    var target = _runAt(wall, u);
    if (target == null) {
      // extend a nearby run on the same wall toward the drop point
      for (final r in plan.runs) {
        if (r.wall != wall) continue;
        if (u < r.a && r.a - u <= extendReach) {
          r.a = (u - edgeMargin - 0.05).clamp(0.02, r.a).toDouble();
          target = r;
          break;
        }
        if (u > r.b && u - r.b <= extendReach) {
          r.b = (u + edgeMargin + 0.05).clamp(r.b, m - 0.02).toDouble();
          target = r;
          break;
        }
      }
    }
    if (target == null) {
      // bare wall: create a run under the appliance (marked auto so it
      // removes itself when the appliance moves away again)
      if (m < newRunLen + 0.04) return false;
      var a = u - newRunLen / 2, b = u + newRunLen / 2;
      if (a < 0.02) {
        b += 0.02 - a;
        a = 0.02;
      }
      if (b > m - 0.02) {
        a -= b - (m - 0.02);
        b = m - 0.02;
      }
      target = RunPlan(wall: wall, a: a, b: b, uppers: true, auto: true);
      plan.runs.add(target);
    }
    return moveAppliance(kind, target, u);
  }

  bool _placeFridge(Wall wall, double u) {
    final m = _wallLen(wall);
    if (u < -0.3 || u > m + 0.3) return false;

    // remember the old spot so a failed placement can be rolled back
    final oldRun = runWith(ApplianceKind.fridge);
    final oldMark = oldRun?.fridge;
    final oldWasOnly = oldRun != null && oldRun.length < 0.86;
    void clearOld() {
      if (oldRun == null) return;
      oldRun.fridge = null;
      if (oldWasOnly) plan.runs.remove(oldRun);
    }

    void restoreOld() {
      if (oldRun == null) return;
      oldRun.fridge = oldMark;
      if (oldWasOnly && !plan.runs.contains(oldRun)) plan.runs.add(oldRun);
    }

    clearOld();
    final target = _runAt(wall, u, 0.2);
    if (target != null) {
      if (target.length < minRunAfterFridge) {
        restoreOld();
        return false;
      }
      if (u - target.a < endSnap) {
        target.fridge = 'start';
      } else if (target.b - u < endSnap) {
        target.fridge = 'end';
      } else {
        // split the run around a 0.8 m fridge gap at the drop point
        final leftCounter = (u - fridgeSpan / 2) - target.a;
        final rightCounter = target.b - (u + fridgeSpan / 2);
        if (leftCounter < 0.7) {
          target.fridge = 'start';
        } else if (rightCounter < 0.7) {
          target.fridge = 'end';
        } else {
          final oldB = target.b;
          final right = RunPlan(
            wall: wall,
            a: u + fridgeSpan / 2,
            b: oldB,
            uppers: target.uppers,
            auto: target.auto,
          );
          target.b = u + fridgeSpan / 2;
          target.fridge = 'end';
          // appliances stay at their absolute positions
          if (target.sinkAt != null && target.sinkAt! > right.a) {
            right.sinkAt = target.sinkAt;
            target.sinkAt = null;
          }
          if (target.rangeAt != null && target.rangeAt! > right.a) {
            right.rangeAt = target.rangeAt;
            target.rangeAt = null;
          }
          plan.runs.add(right);
        }
      }
      _reclampAfterFridge(target);
      return true;
    }

    // bare wall: a freestanding fridge (a fridge-only run)
    if (m < fridgeSpan + 0.04) {
      restoreOld();
      return false;
    }
    var a = u - fridgeSpan / 2, b = u + fridgeSpan / 2;
    if (a < 0.02) {
      b += 0.02 - a;
      a = 0.02;
    }
    if (b > m - 0.02) {
      a -= b - (m - 0.02);
      b = m - 0.02;
    }
    // keep clear of other runs on this wall, or the normalizer's merge
    // would swallow the fridge and teleport it to the run's far end
    for (final r in plan.runs) {
      if (r.wall != wall) continue;
      if (a < r.b + 0.06 && r.a < b + 0.06) {
        if (r.length >= minRunAfterFridge) {
          // close enough to cabinets - snap onto their nearest end
          r.fridge = (u - r.a).abs() < (r.b - u).abs() ? 'start' : 'end';
          _reclampAfterFridge(r);
          return true;
        }
        // shift the freestanding fridge to clear the short run
        if (u < (r.a + r.b) / 2 && r.a - 0.06 - fridgeSpan >= 0.02) {
          b = r.a - 0.06;
          a = b - fridgeSpan;
        } else if (r.b + 0.06 + fridgeSpan <= m - 0.02) {
          a = r.b + 0.06;
          b = a + fridgeSpan;
        } else {
          restoreOld();
          return false;
        }
      }
    }
    plan.runs.add(RunPlan(
        wall: wall, a: a, b: b, fridge: 'start', uppers: false, auto: true));
    return true;
  }

  /// Move the sink or range to position [u] along [target]. Clamps to the
  /// usable span and keeps [minSeparation] from the other appliance on the
  /// same run. Returns false when [target] cannot host the appliance.
  bool moveAppliance(ApplianceKind kind, RunPlan target, double u) {
    assert(kind != ApplianceKind.fridge, 'use place/moveFridge');
    final (lo, hi) = usableSpan(target);
    if (hi - lo < 0.05) return false; // run too short (or fully fridge)

    var pos = u.clamp(lo, hi).toDouble();

    // keep clear of the other appliance on this run
    final other =
        kind == ApplianceKind.sink ? target.rangeAt : target.sinkAt;
    if (other != null) {
      if ((pos - other).abs() < minSeparation) {
        final below = other - minSeparation;
        final above = other + minSeparation;
        final canBelow = below >= lo;
        final canAbove = above <= hi;
        if (canBelow && (!canAbove || pos < other)) {
          pos = below;
        } else if (canAbove) {
          pos = above;
        } else {
          return false; // no room next to the other appliance
        }
      }
    }

    final from = runWith(kind);
    if (from != null && from != target) {
      if (kind == ApplianceKind.sink) {
        from.sinkAt = null;
      } else {
        from.rangeAt = null;
      }
    }
    if (kind == ApplianceKind.sink) {
      target.sinkAt = pos;
    } else {
      target.rangeAt = pos;
    }
    revision++;
    return true;
  }

  /// Snap the fridge to the 'start' or 'end' of [target] (nearest end to
  /// the drop position [u]). Re-clamps any sink/range that the fridge now
  /// overlaps. Returns false when the run is too short to host it.
  /// (Pre-b20 API kept for same-run snaps and tests; [place] is the
  /// general entry point.)
  bool moveFridge(RunPlan target, double u) {
    if (target.length < minRunAfterFridge) return false;
    final end = (u - target.a) < (target.b - u) ? 'start' : 'end';

    final from = runWith(ApplianceKind.fridge);
    if (from != null) from.fridge = null;
    target.fridge = end;
    _reclampAfterFridge(target);
    revision++;
    return true;
  }

  /// Push sink/range out of the fridge's slot, keeping their separation.
  void _reclampAfterFridge(RunPlan target) {
    final (lo, hi) = usableSpan(target);
    double? reclamp(double? v) {
      if (v == null) return null;
      return v.clamp(lo, hi).toDouble();
    }

    target.sinkAt = reclamp(target.sinkAt);
    target.rangeAt = reclamp(target.rangeAt);
    // separation may now be violated after clamping; nudge the range
    final s = target.sinkAt, g = target.rangeAt;
    if (s != null && g != null && (s - g).abs() < minSeparation) {
      final below = s - minSeparation, above = s + minSeparation;
      if (below >= lo) {
        target.rangeAt = below;
      } else if (above <= hi) {
        target.rangeAt = above;
      } else {
        target.rangeAt = null; // no room left - drop rather than overlap
      }
    }
  }
}
