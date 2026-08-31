import 'dart:math' as math;

import 'kitchen_generator.dart';

/// b36 - the wizard's on-device kitchen designer: bare room dimensions ->
/// a complete, buildable LayoutPlan, instantly and without an AI call.
/// Rules FROZEN from tools/auto_plan_proto.py (validated across a
/// 2.2-8.0 x 1.8-8.0 m sweep, ~3.7k rooms x island/tall switches, with
/// zero normalizer notes and zero geometry drift - every emitted plan is
/// already in normal form). Run the proto again after ANY rule change.
///
/// Layout choice (showroom taste: an island outranks a third wall):
///   1. U-shape + island   when U fits (w>=3.2, d>=3.0) and an island fits
///   2. L-shape + island   when L fits (w>=2.6, d>=2.2) and an island fits
///   3. U-shape / 4. L-shape / 5. Galley (w>=2.3, d>=2.4) / 6. Single wall
///
/// Work triangle: fridge at the OPEN end of the west run (next to the
/// entry), sink on the north wall under a window, cooker on the east
/// wall (U) or sharing the north run capped 2 m from the sink (L).
/// Tall pantry (d >= 3.4): the west wall becomes the classic tall bank.

// frozen rule constants (auto_plan_proto.py)
const _uMinW = 3.2, _uMinD = 3.0;
const _lMinW = 2.6, _lMinD = 2.2;
const _galleyMinW = 2.3, _galleyMinD = 2.4;
const _sideEnd = 0.12; // side runs stop this short of the open edge
const _tallMinD = 3.4;
const _tallW = 0.60;
const _islandMargin = 0.90; // > the normalizer's 0.85 walkway minimum
const _islandWMax = 2.40, _islandWMin = 1.20, _islandD = 0.90;
const _windowW = 1.10;
const _clearCounter = 0.67; // = plan_normalizer clearCounter
const _fridgeSpan = 0.8;
const _fridgeD = 0.75;
const _counterD = 0.655;
const _edgeMargin = 0.45;
const _minSep = 0.95;

double _clamp(double v, double lo, double hi) =>
    v < lo ? lo : (v > hi ? hi : v);

/// Legal sink/range band on a run, pre-applying the normalizer's pass-4
/// margins so emitted positions are never re-clamped.
(double, double) _applianceWindow(double a, double b, String? fridge) {
  if (fridge == 'start') a += _fridgeSpan;
  if (fridge == 'end') b -= _fridgeSpan;
  return (a + _edgeMargin, b - _edgeMargin);
}

/// West wall composition shared by L and U: optional pantry column at the
/// north corner, then the counter run with the fridge at the OPEN (south)
/// end - next to where the client walks in.
List<RunPlan> _westBank(double d, bool allowTall) {
  final runs = <RunPlan>[];
  var a = _clearCounter;
  if (allowTall && d >= _tallMinD) {
    runs.add(RunPlan(wall: Wall.west, a: a, b: a + _tallW, tall: true));
    a += _tallW;
  }
  runs.add(RunPlan(
      wall: Wall.west, a: a, b: d - _sideEnd, fridge: 'end', uppers: true));
  return runs;
}

/// Island sized into the free floor rect with [_islandMargin] on all
/// sides; null when it would come out under [_islandWMin].
IslandPlan? _islandFor(double w, double d, double westClear,
    double eastClear, double northClear) {
  final freeX0 = westClear + _islandMargin;
  final freeX1 = w - eastClear - _islandMargin;
  final freeZ0 = northClear + _islandMargin;
  final freeZ1 = d - _islandMargin;
  final iw = _clamp(freeX1 - freeX0, 0, _islandWMax);
  if (iw < _islandWMin || freeZ1 - freeZ0 < _islandD) return null;
  return IslandPlan(
    x0: freeX0 + (freeX1 - freeX0 - iw) / 2,
    z0: freeZ0 + (freeZ1 - freeZ0 - _islandD) / 2,
    w: iw,
    d: _islandD,
  );
}

/// Room dimensions -> a complete plan in normal form.
LayoutPlan autoPlan(
  double widthM,
  double depthM, {
  bool allowIsland = true,
  bool allowTall = true,
  String palette = 'warm_walnut',
}) {
  final w = widthM, d = depthM;
  final uOk = w >= _uMinW && d >= _uMinD;
  final lOk = w >= _lMinW && d >= _lMinD;
  final islU =
      allowIsland ? _islandFor(w, d, _fridgeD, _counterD, _counterD) : null;
  final islL = allowIsland ? _islandFor(w, d, _fridgeD, 0.0, _counterD) : null;

  final String layout;
  IslandPlan? island;
  if (uOk && islU != null) {
    layout = 'U-shape';
    island = islU;
  } else if (lOk && islL != null) {
    layout = 'L-shape';
    island = islL;
  } else if (uOk) {
    layout = 'U-shape';
  } else if (lOk) {
    layout = 'L-shape';
  } else if (w >= _galleyMinW && d >= _galleyMinD) {
    layout = 'Galley';
  } else {
    layout = 'Single wall';
  }

  final runs = <RunPlan>[];
  final windows = <WindowPlan>[];
  var tall = false;
  if (layout == 'U-shape' || layout == 'L-shape') {
    const na = 0.02;
    final nb = w - 0.02;
    final (lo, hi) = _applianceWindow(na, nb, null);
    final sink = _clamp(layout == 'U-shape' ? 0.45 * w : 0.30 * w, lo, hi);
    double? rng;
    if (layout == 'L-shape') {
      rng = _clamp(math.min(sink + 2.0, na + 0.72 * (nb - na)),
          sink + _minSep, hi);
    }
    runs.add(RunPlan(
        wall: Wall.north, a: na, b: nb, sinkAt: sink, rangeAt: rng,
        uppers: true));
    windows.add(WindowPlan(wall: Wall.north, center: sink, width: _windowW));
    final west = _westBank(d, allowTall);
    tall = west.any((r) => r.tall);
    runs.addAll(west);
    if (layout == 'U-shape') {
      const ea = _clearCounter;
      final eb = d - _sideEnd;
      final (elo, ehi) = _applianceWindow(ea, eb, null);
      runs.add(RunPlan(
          wall: Wall.east,
          a: ea,
          b: eb,
          rangeAt: _clamp(0.45 * d, elo, ehi),
          uppers: true));
    }
  } else if (layout == 'Galley') {
    const wa = 0.02;
    final wb = d - 0.02;
    final (slo, shi) = _applianceWindow(wa, wb, 'start');
    runs.add(RunPlan(
        wall: Wall.west,
        a: wa,
        b: wb,
        sinkAt: _clamp(0.55 * d, slo, shi),
        fridge: 'start',
        uppers: true));
    final (rlo, rhi) = _applianceWindow(wa, wb, null);
    runs.add(RunPlan(
        wall: Wall.east,
        a: wa,
        b: wb,
        rangeAt: _clamp(0.45 * d, rlo, rhi),
        uppers: true));
    windows.add(WindowPlan(
        wall: Wall.north,
        center: w / 2,
        width: math.min(_windowW, w - 0.8)));
  } else {
    const na = 0.05;
    final nb = w - 0.05;
    final (lo, hi) = _applianceWindow(na, nb, 'end');
    final double sink;
    double? rng;
    if (hi - lo >= _minSep) {
      sink = lo + 0.18 * (hi - lo - _minSep);
      rng = math.min(hi, sink + math.max(_minSep, 0.5 * (hi - lo)));
    } else {
      sink = (lo + hi) / 2;
    }
    runs.add(RunPlan(
        wall: Wall.north,
        a: na,
        b: nb,
        sinkAt: sink,
        rangeAt: rng,
        fridge: 'end',
        uppers: true));
    windows.add(WindowPlan(
        wall: Wall.north,
        center: _clamp(sink, 0.65, w - 0.65),
        width: math.min(_windowW, w - 1.2)));
  }

  final bits = [layout, if (island != null) 'island', if (tall) 'pantry'];
  return LayoutPlan(
    widthM: w,
    depthM: d,
    runs: runs,
    island: island,
    windows: windows,
    summary: '${bits.join(' + ')} - designed on this phone',
    palette: palette,
  );
}
