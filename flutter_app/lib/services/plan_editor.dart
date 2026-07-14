import 'kitchen_generator.dart';

/// Drag-editing rules for a [LayoutPlan] (v19): move the sink, range
/// (oven) and fridge around the kitchen IKEA-planner style, with the same
/// clearances the generator and the AI parser already enforce. Pure logic,
/// no Flutter imports - unit-tested in widget_test.dart.
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

  /// A run must keep this much cabinet after the fridge to be a valid
  /// fridge target (the generator draws no counter under 0.7 m).
  static const minRunAfterFridge = 1.5;

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

  // --------------------------------------------------------------- moves --
  /// Move the sink or range to position [u] along [target]. Clamps to the
  /// usable span and keeps [minSeparation] from the other appliance on the
  /// same run. Returns false when [target] cannot host the appliance.
  bool moveAppliance(ApplianceKind kind, RunPlan target, double u) {
    assert(kind != ApplianceKind.fridge, 'use moveFridge');
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
  bool moveFridge(RunPlan target, double u) {
    if (target.length < minRunAfterFridge) return false;
    final end =
        (u - target.a) < (target.b - u) ? 'start' : 'end';

    final from = runWith(ApplianceKind.fridge);
    if (from != null) from.fridge = null;
    target.fridge = end;

    // push sink/range out of the fridge's slot
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
    revision++;
    return true;
  }
}
