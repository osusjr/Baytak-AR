import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../data/catalog.dart';
import 'kitchen_design.dart';

/// ON-DEVICE blueprint->3D pipeline, v2 (plan-driven).
/// A [LayoutPlan] - produced by AI image analysis or by the manual form -
/// describes runs on any wall with positioned appliances, optional windows,
/// and a freely placed island/bar (touching a run reads as a peninsula,
/// optionally carrying the cooktop). The builder extrudes it into a
/// spec-valid binary glTF on the phone in milliseconds.

// ---------------------------------------------------------------------------
// plan schema
// ---------------------------------------------------------------------------
enum Wall { north, south, east, west }

Wall? _wallFrom(String? s) {
  switch ((s ?? '').toLowerCase()) {
    case 'north':
      return Wall.north;
    case 'south':
      return Wall.south;
    case 'east':
      return Wall.east;
    case 'west':
      return Wall.west;
  }
  return null;
}

class RunPlan {
  RunPlan({
    required this.wall,
    required this.a,
    required this.b,
    this.sinkAt,
    this.rangeAt,
    this.fridge, // 'start' | 'end' | null
    this.uppers = false,
  });

  final Wall wall;
  double a, b; // metres along the wall axis (x for N/S, z for E/W)
  double? sinkAt;
  double? rangeAt;
  String? fridge;
  bool uppers;

  double get length => b - a;
}

class WindowPlan {
  WindowPlan({required this.wall, required this.center, required this.width});
  final Wall wall;
  final double center;
  final double width;
}

class IslandPlan {
  IslandPlan({
    required this.x0,
    required this.z0,
    required this.w,
    required this.d,
    this.seating = Wall.south,
    this.cooktop = false,
  });

  double x0, z0, w, d;
  Wall seating;
  bool cooktop;
}

class LayoutPlan {
  LayoutPlan({
    required this.widthM,
    required this.depthM,
    required this.runs,
    this.island,
    this.windows = const [],
    this.summary = '',
    this.palette = 'warm_walnut',
  });

  final double widthM;
  final double depthM;
  final List<RunPlan> runs;

  /// Mutable: the b20 normalizer (plan_normalizer.dart) shrinks or drops
  /// an island that would block the kitchen's walkways.
  IslandPlan? island;
  final List<WindowPlan> windows;
  final String summary;
  final String palette;

  /// Serialize for persistence (Design studio reopens the last plan).
  /// Round-trips through [fromJson] - values are already clamped.
  Map<String, dynamic> toJson() => {
        'width_m': widthM,
        'depth_m': depthM,
        'runs': [
          for (final r in runs)
            {
              'wall': r.wall.name,
              'from_m': r.a,
              'to_m': r.b,
              'sink_at_m': r.sinkAt,
              'range_at_m': r.rangeAt,
              'fridge': r.fridge,
              'uppers': r.uppers,
            }
        ],
        'island': island == null
            ? {'present': false}
            : {
                'present': true,
                'x_m': island!.x0,
                'z_m': island!.z0,
                'w_m': island!.w,
                'd_m': island!.d,
                'seating': island!.seating.name,
                'cooktop': island!.cooktop,
              },
        'windows': [
          for (final w in windows)
            {'wall': w.wall.name, 'center_m': w.center, 'width_m': w.width}
        ],
        'palette': palette,
        'summary': summary,
      };

  /// Defensive parse of AI JSON output: clamps everything, drops invalids.
  static LayoutPlan fromJson(Map<String, dynamic> j) {
    double numOf(dynamic v, double lo, double hi, double dflt) {
      final d = (v is num) ? v.toDouble() : double.tryParse('$v');
      if (d == null || d.isNaN) return dflt;
      return d.clamp(lo, hi).toDouble();
    }

    final w = numOf(j['width_m'], 2.0, 9.0, 3.5);
    final d = numOf(j['depth_m'], 2.0, 9.0, 3.5);

    final runs = <RunPlan>[];
    final rawRuns = (j['runs'] is List) ? j['runs'] as List : const [];
    for (final r in rawRuns) {
      if (r is! Map) continue;
      final wall = _wallFrom(r['wall'] as String?);
      if (wall == null) continue;
      final axisMax =
          (wall == Wall.north || wall == Wall.south) ? w : d;
      var a = numOf(r['from_m'], 0, axisMax, 0);
      var b = numOf(r['to_m'], 0, axisMax, axisMax);
      if (b < a) {
        final t = a;
        a = b;
        b = t;
      }
      a = a.clamp(0.02, axisMax - 0.02).toDouble();
      b = b.clamp(0.02, axisMax - 0.02).toDouble();
      final fr = '${r['fridge'] ?? ''}'.toLowerCase();
      final hasFridge = fr == 'start' || fr == 'end';
      // fridge-only runs (a freestanding fridge from the drag editor) are
      // exactly 0.8 m; counter runs need 0.9 m to fit a cabinet bay
      if (b - a < (hasFridge ? 0.75 : 0.9)) continue;
      double? within(dynamic v) {
        final p = numOf(v, -1, axisMax, -1);
        if (p < a + 0.42 || p > b - 0.42) return null;
        return p;
      }

      runs.add(RunPlan(
        wall: wall,
        a: a,
        b: b,
        sinkAt: r['sink_at_m'] == null ? null : within(r['sink_at_m']),
        rangeAt: r['range_at_m'] == null ? null : within(r['range_at_m']),
        fridge: hasFridge ? fr : null,
        uppers: r['uppers'] == true,
      ));
    }

    IslandPlan? island;
    final ij = j['island'];
    if (ij is Map && ij['present'] == true) {
      final iw = numOf(ij['w_m'], 0.9, w - 0.8, 1.6);
      final idd = numOf(ij['d_m'], 0.45, d - 1.2, 0.9);
      island = IslandPlan(
        x0: numOf(ij['x_m'], 0.0, w - iw, (w - iw) / 2),
        z0: numOf(ij['z_m'], 0.0, d - idd, d * 0.55),
        w: iw,
        d: idd,
        seating: _wallFrom(ij['seating'] as String?) ?? Wall.south,
        cooktop: ij['cooktop'] == true,
      );
    }

    final windows = <WindowPlan>[];
    final rawWin = (j['windows'] is List) ? j['windows'] as List : const [];
    for (final ww in rawWin) {
      if (ww is! Map) continue;
      final wall = _wallFrom(ww['wall'] as String?);
      if (wall == null) continue;
      final axisMax =
          (wall == Wall.north || wall == Wall.south) ? w : d;
      final wid = numOf(ww['width_m'], 0.5, axisMax - 0.3, 1.1);
      windows.add(WindowPlan(
        wall: wall,
        center: numOf(
            ww['center_m'], wid / 2 + 0.1, axisMax - wid / 2 - 0.1, axisMax / 2),
        width: wid,
      ));
    }

    final pal = '${j['palette'] ?? ''}';
    return LayoutPlan(
      widthM: w,
      depthM: d,
      runs: runs,
      island: island,
      windows: windows,
      summary: '${j['summary'] ?? ''}',
      palette:
          kitchenPalettes.containsKey(pal) ? pal : 'warm_walnut',
    );
  }
}

// ---------------------------------------------------------------------------
// legacy manual spec -> plan
// ---------------------------------------------------------------------------
enum KitchenLayout {
  lShape('L-shape'),
  galley('Galley (two sides)'),
  single('Single wall');

  const KitchenLayout(this.label);
  final String label;
}

class KitchenSpec {
  const KitchenSpec({
    required this.widthM,
    required this.depthM,
    required this.layout,
    required this.island,
    this.islandWM = 1.6,
    this.islandDM = 0.9,
  });

  final double widthM;
  final double depthM;
  final KitchenLayout layout;
  final bool island;
  final double islandWM;
  final double islandDM;

  LayoutPlan toPlan() {
    final runs = <RunPlan>[];
    final windows = <WindowPlan>[];
    switch (layout) {
      case KitchenLayout.lShape:
        final x0 = 0.66, x1 = widthM - 0.05;
        final span = x1 - x0;
        runs.add(RunPlan(
            wall: Wall.north,
            a: x0,
            b: x1,
            sinkAt: x0 + span * 0.30,
            rangeAt: x0 + span * 0.72,
            uppers: true));
        runs.add(RunPlan(
            wall: Wall.west,
            a: 0.02,
            b: math.min(depthM - 0.05, depthM * 0.9),
            fridge: 'start'));
        windows.add(WindowPlan(
            wall: Wall.north, center: x0 + span * 0.30, width: 1.1));
      case KitchenLayout.single:
        final x0 = 0.05, x1 = widthM - 0.85;
        final span = x1 - x0;
        runs.add(RunPlan(
            wall: Wall.north,
            a: x0,
            b: x1,
            sinkAt: x0 + span * 0.28,
            rangeAt: x0 + span * 0.70,
            fridge: 'end',
            uppers: true));
        windows.add(WindowPlan(
            wall: Wall.north, center: x0 + span * 0.28, width: 1.1));
      case KitchenLayout.galley:
        runs.add(RunPlan(
            wall: Wall.west,
            a: 0.02,
            b: depthM - 0.05,
            sinkAt: depthM * 0.55,
            fridge: 'start',
            uppers: true));
        runs.add(RunPlan(
            wall: Wall.east,
            a: 0.02,
            b: depthM - 0.05,
            rangeAt: depthM * 0.45));
    }
    return LayoutPlan(
      widthM: widthM,
      depthM: depthM,
      runs: runs,
      island: island
          ? IslandPlan(
              x0: (widthM - islandWM) / 2,
              z0: math
                  .min(depthM - islandDM - 0.5,
                      math.max(1.35, depthM * 0.52))
                  .toDouble(),
              w: islandWM,
              d: islandDM)
          : null,
      windows: windows,
      summary: '${layout.label}${island ? ' + island' : ''}',
    );
  }
}

class GeneratedKitchen {
  const GeneratedKitchen(
      {required this.model, required this.path, required this.triangles});
  final DemoModel model;
  final String path;
  final int triangles;
}

// ---------------------------------------------------------------------------
// materials + scene
// ---------------------------------------------------------------------------
const _mats = <String, List<double>>{
  'floor': [0.82, 0.76, 0.66, 0.0, 0.90],
  'wall': [0.91, 0.88, 0.82, 0.0, 0.95],
  'splash': [0.71, 0.77, 0.69, 0.0, 0.40],
  'walnut': [0.42, 0.28, 0.185, 0.0, 0.65],
  'walnut_door': [0.48, 0.325, 0.215, 0.0, 0.60],
  // Upper cabinets carry their own slots (v17) so top and bottom runs can
  // wear different finishes; defaults match walnut, so old palettes render
  // identically when a design does not override them.
  'upper': [0.42, 0.28, 0.185, 0.0, 0.65],
  'upper_door': [0.48, 0.325, 0.215, 0.0, 0.60],
  'olive': [0.275, 0.325, 0.26, 0.0, 0.55],
  'olive_door': [0.315, 0.37, 0.30, 0.0, 0.50],
  'basalt': [0.15, 0.16, 0.17, 0.05, 0.35],
  'quartz': [0.90, 0.89, 0.86, 0.0, 0.30],
  'steel': [0.74, 0.75, 0.77, 0.95, 0.35],
  'brass': [0.78, 0.62, 0.33, 1.0, 0.30],
  'black': [0.055, 0.055, 0.065, 0.0, 0.50],
  'toe': [0.10, 0.09, 0.085, 0.0, 0.80],
  'glass': [0.60, 0.74, 0.82, 0.10, 0.10],
  'frame': [0.95, 0.95, 0.94, 0.0, 0.50],
  'wood': [0.55, 0.40, 0.27, 0.0, 0.60],
  'taupe': [0.66, 0.60, 0.53, 0.0, 0.78],
  'charcoal': [0.42, 0.38, 0.35, 0.0, 0.80],
  'plant': [0.42, 0.52, 0.34, 0.0, 0.70],
};

/// Palette names the AI may answer with; each maps to a Design-studio
/// preset via [KitchenDesign.fromPalette]. Kept as the validation set for
/// [LayoutPlan.fromJson].
const kitchenPalettes = <String, Map<String, List<double>>>{
  'warm_walnut': {},
  'light_oak': {},
  'dark_modern': {},
};

/// Applies per-material overrides: [r,g,b] keeps the slot's metal/rough,
/// [r,g,b,metallic,roughness] replaces them (hardware finishes need this).
Map<String, List<double>> _effectiveMats(Map<String, List<double>> over) {
  return {
    for (final e in _mats.entries)
      e.key: !over.containsKey(e.key)
          ? e.value
          : over[e.key]!.length >= 5
              ? over[e.key]!
              : [...over[e.key]!, e.value[3], e.value[4]],
  };
}

/// Bundled neutral textures, tinted by each material's color factor in
/// glTF (final = factor x texture) - one wood serves all three palettes.
const _matTexture = <String, String>{
  'floor': 'wood_floor',
  'wall': 'plaster',
  'splash': 'tile',
  'walnut': 'wood',
  'walnut_door': 'wood',
  'upper': 'wood',
  'upper_door': 'wood',
  'olive': 'wood',
  'olive_door': 'wood',
  'wood': 'wood',
  'taupe': 'fabric',
  'charcoal': 'fabric',
  'basalt': 'stone',
  'quartz': 'quartz',
};

/// metres per texture repeat (mirrors the proven Python TEX_SCALE)
const _matTile = <String, double>{
  'floor': 0.62,
  'wall': 1.40,
  'splash': 0.60,
  'walnut': 0.85,
  'walnut_door': 0.85,
  'upper': 0.85,
  'upper_door': 0.85,
  'olive': 0.80,
  'olive_door': 0.80,
  'wood': 0.70,
  'taupe': 0.45,
  'charcoal': 0.45,
  'basalt': 0.90,
  'quartz': 1.10,
};

Map<String, Uint8List>? _texCache;

Future<Map<String, Uint8List>> _loadTextures() async {
  final cached = _texCache;
  if (cached != null) return cached;
  final out = <String, Uint8List>{};
  for (final n in _matTexture.values.toSet()) {
    final d = await rootBundle.load('assets/textures/$n.png');
    out[n] = d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
  }
  return _texCache = out;
}

class _Grp {
  final pos = <double>[];
  final nrm = <double>[];
  final uv = <double>[];
  final idx = <int>[];
}

class _Scene {
  final groups = {for (final m in _mats.keys) m: _Grp()};

  void _quad(_Grp g, List<double> n, List<List<double>> c, double tile) {
    final base = g.pos.length ~/ 3;
    for (final p in c) {
      g.pos.addAll(p);
      g.nrm.addAll(n);
      double u, v;
      if (n[1] != 0) {
        u = p[0];
        v = p[2]; // top/bottom -> plan projection
      } else if (n[2] != 0) {
        u = p[0];
        v = p[1]; // front/back
      } else {
        u = p[2];
        v = p[1]; // sides
      }
      g.uv.addAll([u / tile, v / tile]);
    }
    g.idx.addAll([base, base + 1, base + 2, base, base + 2, base + 3]);
  }

  void box(double x0, double y0, double z0, double x1, double y1, double z1,
      String mat) {
    if (!(x1 > x0 && y1 > y0 && z1 > z0)) return; // defensive: skip invalid
    final g = groups[mat]!;
    final tile = _matTile[mat] ?? 0.8;
    _quad(g, [0, 1, 0], [
      [x0, y1, z0], [x0, y1, z1], [x1, y1, z1], [x1, y1, z0]
    ], tile);
    _quad(g, [0, -1, 0], [
      [x0, y0, z0], [x1, y0, z0], [x1, y0, z1], [x0, y0, z1]
    ], tile);
    _quad(g, [0, 0, 1], [
      [x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1]
    ], tile);
    _quad(g, [0, 0, -1], [
      [x1, y0, z0], [x0, y0, z0], [x0, y1, z0], [x1, y1, z0]
    ], tile);
    _quad(g, [1, 0, 0], [
      [x1, y0, z1], [x1, y0, z0], [x1, y1, z0], [x1, y1, z1]
    ], tile);
    _quad(g, [-1, 0, 0], [
      [x0, y0, z0], [x0, y0, z1], [x0, y1, z1], [x0, y1, z0]
    ], tile);
  }

  int get triangles =>
      groups.values.fold(0, (a, g) => a + g.idx.length ~/ 3);
}

// ---------------------------------------------------------------------------
// builder: a run on any wall, in run-local coordinates mapped per wall
// ---------------------------------------------------------------------------
const _th = 0.10, _bh = 0.86, _ctop = 0.90, _bd = 0.62, _cd = 0.655;
const _uy0 = 1.50, _uy1 = 2.20, _ud = 0.35, _hCeil = 2.70, _wallT = 0.06;

/// Maps run-local (u along wall, v out from wall, y up) to world xyz.
/// u runs a->b; v=0 at the wall face, growing into the room.
///
/// b20: ONE u-origin convention everywhere, matching the AI schema and the
/// 2D plan painter - u is measured from the WEST end on north/south walls
/// and from the NORTH end on east/west walls. (Pre-b20 the south/east
/// frames counted from the opposite end, silently mirroring every
/// AI-read appliance position on those walls.)
class _Frame {
  _Frame(this.wall, this.w, this.d);
  final Wall wall;
  final double w, d;

  List<double> pt(double u, double y, double v) {
    switch (wall) {
      case Wall.north:
        return [u, y, v];
      case Wall.south:
        return [u, y, d - v];
      case Wall.west:
        return [v, y, u];
      case Wall.east:
        return [w - v, y, u];
    }
  }

  /// Axis-aligned world box from run-local extents.
  void box(_Scene s, double u0, double u1, double y0, double y1, double v0,
      double v1, String mat) {
    final p1 = pt(u0, 0, v0), p2 = pt(u1, 0, v1);
    s.box(math.min(p1[0], p2[0]), y0, math.min(p1[2], p2[2]),
        math.max(p1[0], p2[0]), y1, math.max(p1[2], p2[2]), mat);
  }
}

/// Handle on a base door/drawer front (front face at v = _bd + 0.017).
/// Coordinates frozen from tools/design_studio_proto.py.
void _baseHandle(_Scene s, _Frame f, double c, String style) {
  if (style == 'bar') {
    f.box(s, c - 0.07, c + 0.07, _bh - 0.105, _bh - 0.094, _bd + 0.021,
        _bd + 0.048, 'brass');
  } else if (style == 'knob') {
    f.box(s, c - 0.016, c + 0.016, _bh - 0.118, _bh - 0.086, _bd + 0.017,
        _bd + 0.049, 'brass');
  } // 'none': handleless - no geometry
}

/// Handle on an upper door (front face at v = _ud + 0.015).
void _upperHandle(_Scene s, _Frame f, double c, String style) {
  if (style == 'bar') {
    f.box(s, c - 0.07, c + 0.07, _uy0 + 0.054, _uy0 + 0.065, _ud + 0.019,
        _ud + 0.046, 'brass');
  } else if (style == 'knob') {
    f.box(s, c - 0.016, c + 0.016, _uy0 + 0.042, _uy0 + 0.074, _ud + 0.015,
        _ud + 0.047, 'brass');
  }
}

/// A door leaf from vBack to vFace. 'shaker' = recessed panel + 4 rails;
/// falls back to slab when the leaf is too small for a 6.5 cm frame.
void _doorFront(_Scene s, _Frame f, double u0, double u1, double y0,
    double y1, double vBack, double vFace, String mat, String style) {
  const r = 0.065;
  if (style == 'shaker' && (u1 - u0) > 2.6 * r && (y1 - y0) > 2.6 * r) {
    final vMid = vBack + (vFace - vBack) * 0.55;
    f.box(s, u0, u1, y0, y1, vBack, vMid, mat); // recessed panel
    f.box(s, u0, u0 + r, y0, y1, vMid, vFace, mat); // left rail
    f.box(s, u1 - r, u1, y0, y1, vMid, vFace, mat); // right rail
    f.box(s, u0 + r, u1 - r, y0, y0 + r, vMid, vFace, mat); // bottom rail
    f.box(s, u0 + r, u1 - r, y1 - r, y1, vMid, vFace, mat); // top rail
  } else {
    f.box(s, u0, u1, y0, y1, vBack, vFace, mat);
  }
}

void _buildRun(_Scene s, _Frame f, RunPlan r, List<WindowPlan> windows,
    KitchenDesign design) {
  var a = r.a, b = r.b;
  final handle = design.handle, door = design.door;

  // fridge consumes 0.8 m at one end
  if (r.fridge == 'start') {
    f.box(s, a, a + 0.70, 0, 1.86, 0.0, 0.75, 'steel');
    f.box(s, a, a + 0.70, 1.92, 2.20, 0.02, 0.72, 'upper');
    a += 0.80;
  } else if (r.fridge == 'end') {
    f.box(s, b - 0.70, b, 0, 1.86, 0.0, 0.75, 'steel');
    f.box(s, b - 0.70, b, 1.92, 2.20, 0.02, 0.72, 'upper');
    b -= 0.80;
  }
  if (b - a < 0.7) return;

  // carcass, toe, counter, splash
  f.box(s, a + 0.02, b - 0.02, 0, _th, 0.02, _bd - 0.05, 'toe');
  f.box(s, a, b, _th, _bh, 0.0, _bd, 'walnut');
  f.box(s, a - 0.02, b + 0.02, _bh, _ctop, 0.0, _cd, 'basalt');
  f.box(s, a, b, _ctop, 1.46, 0.0, 0.02, 'splash');

  // door bays, skipping the range slot
  final n = math.max(2, ((b - a) / 0.60).round());
  final bw = (b - a) / n;
  for (var k = 0; k < n; k++) {
    final ba = a + k * bw + 0.009, bb = a + (k + 1) * bw - 0.009;
    final c = (ba + bb) / 2;
    if (r.rangeAt != null && (c - r.rangeAt!).abs() < 0.42) continue;
    _doorFront(s, f, ba, bb, _th + 0.008, _bh - 0.008, _bd, _bd + 0.017,
        'walnut_door', door);
    _baseHandle(s, f, c, handle);
  }

  // sink + faucet
  if (r.sinkAt != null) {
    final sc = r.sinkAt!;
    f.box(s, sc - 0.34, sc + 0.34, _ctop + 0.0005, _ctop + 0.002, 0.09,
        0.50, 'black');
    f.box(s, sc - 0.36, sc + 0.36, _ctop, _ctop + 0.012, 0.07, 0.09,
        'steel');
    f.box(s, sc - 0.36, sc + 0.36, _ctop, _ctop + 0.012, 0.50, 0.52,
        'steel');
    f.box(s, sc - 0.015, sc + 0.015, _ctop, _ctop + 0.31, 0.04, 0.075,
        'steel');
    f.box(s, sc - 0.012, sc + 0.012, _ctop + 0.285, _ctop + 0.31, 0.055,
        0.25, 'steel');
  }

  // range + cooktop + hood
  if (r.rangeAt != null) {
    final rc = r.rangeAt!;
    f.box(s, rc - 0.372, rc + 0.372, _th, _bh, 0.02, _bd + 0.028, 'steel');
    f.box(s, rc - 0.33, rc + 0.33, 0.15, 0.55, _bd + 0.028, _bd + 0.037,
        'black');
    f.box(s, rc - 0.36, rc + 0.36, _ctop - 0.002, _ctop + 0.014, 0.05,
        0.57, 'black');
    f.box(s, rc - 0.43, rc + 0.43, 1.42, 1.52, 0.02, 0.53, 'steel');
    f.box(s, rc - 0.21, rc + 0.21, 1.52, _hCeil, 0.06, 0.34, 'steel');
  }

  // uppers, skipping range and window spans
  if (r.uppers) {
    final skip = <List<double>>[
      if (r.rangeAt != null) [r.rangeAt! - 0.48, r.rangeAt! + 0.48],
      for (final win in windows)
        if (win.wall == r.wall)
          [win.center - win.width / 2 - 0.1, win.center + win.width / 2 + 0.1],
    ];
    var spans = <List<double>>[
      [a + 0.02, b - 0.02]
    ];
    for (final k in skip) {
      final next = <List<double>>[];
      for (final sp in spans) {
        if (k[1] <= sp[0] || k[0] >= sp[1]) {
          next.add(sp);
        } else {
          if (k[0] - sp[0] > 0.45) next.add([sp[0], k[0]]);
          if (sp[1] - k[1] > 0.45) next.add([k[1], sp[1]]);
        }
      }
      spans = next;
    }
    for (final sp in spans) {
      f.box(s, sp[0], sp[1], _uy0, _uy1, 0.0, _ud, 'upper');
      final nd = math.max(1, ((sp[1] - sp[0]) / 0.55).round());
      final dw = (sp[1] - sp[0]) / nd;
      for (var k = 0; k < nd; k++) {
        final ba = sp[0] + k * dw + 0.008, bb = sp[0] + (k + 1) * dw - 0.008;
        _doorFront(s, f, ba, bb, _uy0 + 0.008, _uy1 - 0.008, _ud,
            _ud + 0.015, 'upper_door', door);
        _upperHandle(s, f, (ba + bb) / 2, handle);
      }
    }
  }
}

void _buildIsland(_Scene s, IslandPlan i, double w, double d) {
  final x0 = i.x0, x1 = i.x0 + i.w, z0 = i.z0, z1 = i.z0 + i.d;
  s.box(x0 + 0.05, 0, z0 + 0.05, x1 - 0.05, _th, z1 - 0.05, 'toe');
  s.box(x0, _th, z0, x1, _bh, z1, 'olive');

  // quartz top: 5 cm lip all round + 30 cm overhang on the seating side
  var tx0 = x0 - 0.05, tx1 = x1 + 0.05, tz0 = z0 - 0.05, tz1 = z1 + 0.05;
  switch (i.seating) {
    case Wall.north:
      tz0 = z0 - 0.30;
    case Wall.south:
      tz1 = z1 + 0.30;
    case Wall.west:
      tx0 = x0 - 0.30;
    case Wall.east:
      tx1 = x1 + 0.30;
  }
  s.box(tx0, _bh, tz0, tx1, _ctop, tz1, 'quartz');

  if (i.cooktop) {
    final cx = (x0 + x1) / 2, cz = (z0 + z1) / 2;
    final hw = math.min(0.36, i.w / 2 - 0.08);
    final hd = math.min(0.26, i.d / 2 - 0.06);
    s.box(cx - hw, _ctop - 0.001, cz - hd, cx + hw, _ctop + 0.014, cz + hd,
        'black');
  }

  // stools on the seating side
  final horizontal = i.seating == Wall.north || i.seating == Wall.south;
  final span = horizontal ? i.w : i.d;
  final count = span >= 1.4 ? 2 : 1;
  for (var k = 0; k < count; k++) {
    double cx, cz;
    final off = count == 1 ? span / 2 : (k == 0 ? 0.45 : span - 0.45);
    switch (i.seating) {
      case Wall.north:
        cx = x0 + off;
        cz = z0 - 0.42;
      case Wall.south:
        cx = x0 + off;
        cz = z1 + 0.42;
      case Wall.west:
        cx = x0 - 0.42;
        cz = z0 + off;
      case Wall.east:
        cx = x1 + 0.42;
        cz = z0 + off;
    }
    cx = cx.clamp(0.25, w - 0.25).toDouble();
    cz = cz.clamp(0.25, d - 0.25).toDouble();
    s.box(cx - 0.18, 0.60, cz - 0.15, cx + 0.18, 0.648, cz + 0.15, 'wood');
    for (final lx in [cx - 0.15, cx + 0.12]) {
      for (final lz in [cz - 0.12, cz + 0.09]) {
        s.box(lx, 0, lz, lx + 0.03, 0.60, lz + 0.03, 'wood');
      }
    }
  }

  // pendants over the island (skip when a hoodless cooktop sits there? keep)
  for (var k = 0; k < 2; k++) {
    final cx = k == 0 ? x0 + i.w * 0.28 : x1 - i.w * 0.28;
    final cz = (z0 + z1) / 2;
    s.box(cx - 0.008, 2.02, cz - 0.008, cx + 0.008, _hCeil, cz + 0.008,
        'brass');
    s.box(cx - 0.10, 1.87, cz - 0.10, cx + 0.10, 2.02, cz + 0.10, 'black');
  }
}

/// Walls the generator will actually build: only walls hosting cabinet
/// runs or windows, and never all four - the lowest-content wall stays
/// open so the model reads as a showroom vignette, not a closed box.
/// Used by the generator AND the plan normalizer (island clearance).
Set<Wall> planWalls(LayoutPlan p) {
  final score = <Wall, double>{};
  for (final r in p.runs) {
    score[r.wall] = (score[r.wall] ?? 0) + 2 * (r.b - r.a);
  }
  for (final win in p.windows) {
    score[win.wall] = (score[win.wall] ?? 0) + win.width;
  }
  final walls = score.keys.toSet();
  if (walls.length == 4) {
    walls.remove(
        score.entries.reduce((a, b) => a.value <= b.value ? a : b).key);
  }
  return walls;
}

/// Window glass + frame in the wall plane. b20: drawn once per BUILT wall
/// (was per run), so open walls carry no floating glass and windows work
/// on walls that host no cabinets.
void _drawWallWindows(_Scene s, _Frame f, List<WindowPlan> windows) {
  for (final win in windows) {
    if (win.wall != f.wall) continue;
    final wa = win.center - win.width / 2, wb = win.center + win.width / 2;
    f.box(s, wa, wb, 1.00, 1.90, -0.015, 0.005, 'glass');
    f.box(s, wa - 0.05, wa, 0.95, 1.95, -0.02, 0.02, 'frame');
    f.box(s, wb, wb + 0.05, 0.95, 1.95, -0.02, 0.02, 'frame');
    f.box(s, wa - 0.05, wb + 0.05, 0.95, 1.00, -0.02, 0.02, 'frame');
    f.box(s, wa - 0.05, wb + 0.05, 1.90, 1.95, -0.02, 0.02, 'frame');
  }
}

_Scene _buildPlan(LayoutPlan p, KitchenDesign design) {
  final s = _Scene();
  final w = p.widthM, d = p.depthM;
  s.box(0, -0.05, 0, w, 0.0, d, 'floor');

  final wallsUsed = planWalls(p);
  if (wallsUsed.contains(Wall.north)) s.box(0, 0, -_wallT, w, _hCeil, 0, 'wall');
  if (wallsUsed.contains(Wall.south)) s.box(0, 0, d, w, _hCeil, d + _wallT, 'wall');
  if (wallsUsed.contains(Wall.west)) s.box(-_wallT, 0, 0, 0, _hCeil, d, 'wall');
  if (wallsUsed.contains(Wall.east)) s.box(w, 0, 0, w + _wallT, _hCeil, d, 'wall');

  for (final r in p.runs) {
    _buildRun(s, _Frame(r.wall, w, d), r, p.windows, design);
  }
  for (final wall in wallsUsed) {
    _drawWallWindows(s, _Frame(wall, w, d), p.windows);
  }
  final isl = p.island;
  if (isl != null) _buildIsland(s, isl, w, d);
  return s;
}

// ---------------------------------------------------------------------------
// binary glTF writer
// ---------------------------------------------------------------------------
Uint8List _writeGlb(_Scene scene, String name, Map<String, List<double>> mats,
    {Map<String, Uint8List> textures = const {},
    Map<String, String> matTexture = _matTexture}) {
  final bin = BytesBuilder();
  final bufferViews = <Map<String, dynamic>>[];
  final accessors = <Map<String, dynamic>>[];
  final primitives = <Map<String, dynamic>>[];
  final matNames = mats.keys.toList();
  final texIndex = <String, int>{};

  int addView(Uint8List data, int target) {
    final offset = bin.length;
    bin.add(data);
    while (bin.length % 4 != 0) {
      bin.addByte(0);
    }
    bufferViews.add({
      'buffer': 0,
      'byteOffset': offset,
      'byteLength': data.length,
      if (target != 0) 'target': target
    });
    return bufferViews.length - 1;
  }

  scene.groups.forEach((mat, g) {
    if (g.idx.isEmpty) return;
    final pos = Float32List.fromList(g.pos);
    final nrm = Float32List.fromList(g.nrm);
    final idx = Uint32List.fromList(g.idx);

    final mins = [double.infinity, double.infinity, double.infinity];
    final maxs = [-double.infinity, -double.infinity, -double.infinity];
    for (var i = 0; i < pos.length; i += 3) {
      for (var c = 0; c < 3; c++) {
        mins[c] = math.min(mins[c], pos[i + c]);
        maxs[c] = math.max(maxs[c], pos[i + c]);
      }
    }

    final pv = addView(pos.buffer.asUint8List(), 34962);
    final nv = addView(nrm.buffer.asUint8List(), 34962);
    final iv = addView(idx.buffer.asUint8List(), 34963);

    accessors.add({
      'bufferView': pv,
      'componentType': 5126,
      'count': pos.length ~/ 3,
      'type': 'VEC3',
      'min': mins,
      'max': maxs
    });
    final pAcc = accessors.length - 1;
    accessors.add({
      'bufferView': nv,
      'componentType': 5126,
      'count': nrm.length ~/ 3,
      'type': 'VEC3'
    });
    final nAcc = accessors.length - 1;
    accessors.add({
      'bufferView': iv,
      'componentType': 5125,
      'count': idx.length,
      'type': 'SCALAR'
    });
    final iAcc = accessors.length - 1;

    final texName = matTexture[mat];
    int? tAcc;
    if (texName != null && textures.containsKey(texName)) {
      final uv = Float32List.fromList(g.uv);
      final tv = addView(uv.buffer.asUint8List(), 34962);
      accessors.add({
        'bufferView': tv,
        'componentType': 5126,
        'count': uv.length ~/ 2,
        'type': 'VEC2'
      });
      tAcc = accessors.length - 1;
      texIndex.putIfAbsent(texName, () => texIndex.length);
    }

    primitives.add({
      'attributes': {
        'POSITION': pAcc,
        'NORMAL': nAcc,
        if (tAcc != null) 'TEXCOORD_0': tAcc,
      },
      'indices': iAcc,
      'material': matNames.indexOf(mat),
      'mode': 4
    });
  });

  final images = <Map<String, dynamic>>[];
  for (final name in texIndex.keys) {
    final iv = addView(textures[name]!, 0);
    images.add({'bufferView': iv, 'mimeType': 'image/png', 'name': name});
  }

  final materials = [
    for (final e in mats.entries)
      {
        'name': e.key,
        'pbrMetallicRoughness': {
          'baseColorFactor': [e.value[0], e.value[1], e.value[2], 1.0],
          if (texIndex.containsKey(matTexture[e.key]))
            'baseColorTexture': {'index': texIndex[matTexture[e.key]]!},
          'metallicFactor': e.value[3],
          'roughnessFactor': e.value[4],
        },
        'doubleSided': false,
      }
  ];

  final binBytes = bin.toBytes();
  final gltf = {
    'asset': {'version': '2.0', 'generator': 'Baytak AR on-device generator'},
    'scene': 0,
    'scenes': [
      {'nodes': [0], 'name': name}
    ],
    'nodes': [
      {'mesh': 0, 'name': name}
    ],
    'meshes': [
      {'name': name, 'primitives': primitives}
    ],
    'materials': materials,
    if (texIndex.isNotEmpty)
      'samplers': [
        {
          'magFilter': 9729,
          'minFilter': 9987,
          'wrapS': 10497,
          'wrapT': 10497
        }
      ],
    if (texIndex.isNotEmpty)
      'textures': [
        for (var i = 0; i < texIndex.length; i++)
          {'sampler': 0, 'source': i}
      ],
    if (texIndex.isNotEmpty) 'images': images,
    'accessors': accessors,
    'bufferViews': bufferViews,
    'buffers': [
      {'byteLength': binBytes.length}
    ],
  };

  final jsonList = List<int>.from(utf8.encode(jsonEncode(gltf)));
  while (jsonList.length % 4 != 0) {
    jsonList.add(0x20); // pad with spaces
  }
  final jsonBytes = Uint8List.fromList(jsonList);
  final total = 12 + 8 + jsonBytes.length + 8 + binBytes.length;

  final out = BytesBuilder();
  void u32(int v) {
    final b = ByteData(4)..setUint32(0, v, Endian.little);
    out.add(b.buffer.asUint8List());
  }

  u32(0x46546C67);
  u32(2);
  u32(total);
  u32(jsonBytes.length);
  u32(0x4E4F534A);
  out.add(jsonBytes);
  u32(binBytes.length);
  u32(0x004E4942);
  out.add(binBytes);
  return out.toBytes();
}

// ---------------------------------------------------------------------------
Future<GeneratedKitchen> generateFromPlan(LayoutPlan plan,
    {String source = 'your measurements', KitchenDesign? design}) async {
  final d = design ?? KitchenDesign.fromPalette(plan.palette);
  final scene = _buildPlan(plan, d);
  Map<String, Uint8List> tex;
  try {
    tex = await _loadTextures();
  } catch (_) {
    tex = const {}; // missing assets -> flat colors, never a crash
  }
  final bytes = _writeGlb(scene, 'Kitchen_Custom',
      _effectiveMats(d.materialOverrides()),
      textures: tex,
      matTexture: {..._matTexture, ...d.textureOverrides()});

  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/generated/kitchen_custom.glb');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes, flush: true);

  final lm = plan.runs.fold<double>(0, (a, r) => a + r.length);
  final price = ((lm * 920 + (plan.island != null ? 650 : 0)) *
              d.priceFactor /
              10)
          .round() *
      10;
  final orbitR =
      (math.max(plan.widthM, plan.depthM) * 2.1).toStringAsFixed(1);
  final runsDesc = plan.runs
      .map((r) =>
          '${r.wall.name} ${r.length.toStringAsFixed(1)} m'
          '${r.sinkAt != null ? ' (sink)' : ''}'
          '${r.rangeAt != null ? ' (range)' : ''}'
          '${r.fridge != null ? ' (fridge)' : ''}')
      .join(', ');

  final model = DemoModel(
    id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
    title: 'Your Kitchen',
    category: Cat.kitchens,
    asset: 'file://${file.path}',
    thumb: 'assets/thumbs/kitchen_k01.png',
    blurb: 'Generated on this device from $source.',
    description: 'Generated on this phone from $source: '
        '${plan.widthM.toStringAsFixed(2)} × '
        '${plan.depthM.toStringAsFixed(2)} m. Runs: $runsDesc'
        '${plan.island != null ? '. Island ${plan.island!.w.toStringAsFixed(1)} × ${plan.island!.d.toStringAsFixed(1)} m${plan.island!.cooktop ? ' with cooktop' : ''}' : ''}. '
        'Finish: ${d.describe()}. Price is an automatic estimate from run '
        'length and finish.',
    wCm: (plan.widthM * 100).round(),
    dCm: (plan.depthM * 100).round(),
    hCm: 270,
    materials: d.materialsLine(),
    finishes: d.finishSwatches(),
    variants: [plan.summary.isEmpty ? 'Custom' : plan.summary],
    priceJd: price,
    cameraOrbit: '-38deg 72deg ${orbitR}m',
  );
  registerGeneratedModel(model);

  return GeneratedKitchen(
      model: model, path: file.path, triangles: scene.triangles);
}

Future<GeneratedKitchen> generateKitchen(KitchenSpec spec,
        {KitchenDesign? design}) =>
    generateFromPlan(spec.toPlan(), design: design);

// ---------------------------------------------------------------------------
// ROOM SCENES: AI-arranged furniture from the catalogue, built as one model
// (coordinates frozen from the validated Python prototype)
// ---------------------------------------------------------------------------
class _Bx {
  const _Bx(this.x0, this.y0, this.z0, this.x1, this.y1, this.z1, this.m);
  final double x0, y0, z0, x1, y1, z1;
  final String m;
}

List<_Bx> _fSofa() {
  final b = <_Bx>[];
  const hx = 1.10, hz = 0.475;
  for (final lx in [-hx + 0.09, hx - 0.13]) {
    for (final lz in [-hz + 0.07, hz - 0.11]) {
      b.add(_Bx(lx, 0, lz, lx + 0.045, 0.11, lz + 0.045, 'wood'));
    }
  }
  b.add(const _Bx(-hx, 0.11, -hz, hx, 0.34, hz, 'taupe'));
  b.add(const _Bx(-hx, 0.11, -hz, -hx + 0.16, 0.62, hz, 'taupe'));
  b.add(const _Bx(hx - 0.16, 0.11, -hz, hx, 0.62, hz, 'taupe'));
  b.add(const _Bx(
      -hx + 0.16, 0.11, -hz, hx - 0.16, 0.78, -hz + 0.16, 'taupe'));
  const seatW = (2 * hx - 0.34) / 3;
  for (var k = 0; k < 3; k++) {
    final a = -hx + 0.17 + k * seatW, bb = -hx + 0.17 + (k + 1) * seatW - 0.02;
    b.add(_Bx(a, 0.34, -hz + 0.17, bb, 0.47, hz - 0.05, 'charcoal'));
    b.add(_Bx(a, 0.44, -hz + 0.155, bb, 0.74, -hz + 0.32, 'taupe'));
  }
  return b;
}

List<_Bx> _fArmchair() {
  final b = <_Bx>[];
  const hx = 0.43, hz = 0.41;
  for (final lx in [-hx + 0.06, hx - 0.105]) {
    for (final lz in [-hz + 0.06, hz - 0.105]) {
      b.add(_Bx(lx, 0, lz, lx + 0.045, 0.10, lz + 0.045, 'wood'));
    }
  }
  b.add(const _Bx(
      -hx + 0.02, 0.10, -hz + 0.02, hx - 0.02, 0.30, hz - 0.02, 'charcoal'));
  b.add(const _Bx(-hx, 0.10, -hz, -hx + 0.10, 0.56, hz, 'walnut_door'));
  b.add(const _Bx(hx - 0.10, 0.10, -hz, hx, 0.56, hz, 'walnut_door'));
  b.add(const _Bx(
      -hx + 0.10, 0.10, -hz, hx - 0.10, 0.72, -hz + 0.08, 'walnut_door'));
  b.add(const _Bx(
      -hx + 0.11, 0.30, -hz + 0.09, hx - 0.11, 0.44, hz - 0.05, 'olive'));
  b.add(const _Bx(-hx + 0.11, 0.42, -hz + 0.085, hx - 0.11, 0.70,
      -hz + 0.24, 'olive_door'));
  return b;
}

List<_Bx> _fDining() {
  final b = <_Bx>[
    const _Bx(-0.80, 0.705, -0.45, 0.80, 0.75, 0.45, 'walnut_door'),
    const _Bx(-0.72, 0.650, -0.41, 0.72, 0.705, 0.41, 'walnut'),
  ];
  for (final lx in [-0.72, 0.655]) {
    for (final lz in [-0.38, 0.315]) {
      b.add(_Bx(lx, 0, lz, lx + 0.065, 0.705, lz + 0.065, 'wood'));
    }
  }
  void chair(double cx, int side) {
    final z0 = side > 0 ? 0.50 : -0.98;
    final z1 = side > 0 ? 0.98 : -0.50;
    final ba = side > 0 ? 0.93 : -0.98;
    final bb = side > 0 ? 0.98 : -0.93;
    for (final lx in [cx - 0.185, cx + 0.145]) {
      for (final lz in [z0 + 0.04, z1 - 0.08]) {
        b.add(_Bx(lx, 0, lz, lx + 0.04, 0.42, lz + 0.04, 'wood'));
      }
    }
    b.add(_Bx(cx - 0.22, 0.42, z0, cx + 0.22, 0.46, z1, 'walnut_door'));
    b.add(_Bx(
        cx - 0.20, 0.46, z0 + 0.03, cx + 0.20, 0.505, z1 - 0.03, 'taupe'));
    b.add(_Bx(cx - 0.22, 0.46, ba, cx + 0.22, 0.90, bb, 'walnut_door'));
  }

  for (final cx in [-0.40, 0.40]) {
    chair(cx, 1);
    chair(cx, -1);
  }
  return b;
}

List<_Bx> _fShelf() {
  const hx = 0.45, dd = 0.16;
  return const [
    _Bx(-hx, 0, -dd, -hx + 0.035, 1.80, dd, 'walnut'),
    _Bx(hx - 0.035, 0, -dd, hx, 1.80, dd, 'walnut'),
    _Bx(-hx + 0.035, 1.765, -dd, hx - 0.035, 1.80, dd, 'walnut'),
    _Bx(-hx + 0.035, 0, -dd, hx - 0.035, 0.06, dd, 'black'),
    _Bx(-hx + 0.035, 0.06, -dd, hx - 0.035, 1.765, -dd + 0.025, 'splash'),
    _Bx(-hx + 0.035, 0.42, -dd + 0.025, hx - 0.035, 0.45, dd - 0.005,
        'walnut_door'),
    _Bx(-hx + 0.035, 0.78, -dd + 0.025, hx - 0.035, 0.81, dd - 0.005,
        'walnut_door'),
    _Bx(-hx + 0.035, 1.14, -dd + 0.025, hx - 0.035, 1.17, dd - 0.005,
        'walnut_door'),
    _Bx(-hx + 0.035, 1.50, -dd + 0.025, hx - 0.035, 1.53, dd - 0.005,
        'walnut_door'),
    _Bx(-0.36, 0.45, -dd + 0.05, -0.22, 0.69, dd - 0.05, 'olive'),
    _Bx(-0.18, 0.45, -dd + 0.05, -0.06, 0.66, dd - 0.05, 'charcoal'),
    _Bx(0.10, 0.81, -0.07, 0.26, 0.97, 0.07, 'frame'),
    _Bx(-0.30, 1.17, -0.07, -0.14, 1.31, 0.07, 'frame'),
    _Bx(-0.28, 1.30, -0.05, -0.16, 1.46, 0.05, 'plant'),
    _Bx(-0.02, 1.53, -0.05, 0.10, 1.65, 0.05, 'brass'),
    _Bx(0.18, 1.17, -dd + 0.05, 0.30, 1.38, dd - 0.05, 'olive_door'),
  ];
}

const _furniture = <String, List<_Bx> Function()>{
  'sofa_dana': _fSofa,
  'armchair_rum': _fArmchair,
  'dining_ajloun': _fDining,
  'shelf_petra': _fShelf,
};

/// footprint (w, d) at rot 0
const furnitureFootprints = <String, List<double>>{
  'sofa_dana': [2.20, 0.95],
  'armchair_rum': [0.86, 0.82],
  'dining_ajloun': [1.70, 2.10],
  'shelf_petra': [0.90, 0.36],
};

List<double> _rotPt(double x, double z, int steps) {
  for (var i = 0; i < steps % 4; i++) {
    final t = x;
    x = z;
    z = -t; // rotY(+90): x' = z, z' = -x
  }
  return [x, z];
}

void _instance(_Scene s, List<_Bx> boxes, double cx, double cz, int rot) {
  final steps = (rot ~/ 90) % 4;
  for (final b in boxes) {
    final c1 = _rotPt(b.x0, b.z0, steps);
    final c2 = _rotPt(b.x1, b.z1, steps);
    s.box(
        math.min(c1[0], c2[0]) + cx,
        b.y0,
        math.min(c1[1], c2[1]) + cz,
        math.max(c1[0], c2[0]) + cx,
        b.y1,
        math.max(c1[1], c2[1]) + cz,
        b.m);
  }
}

class RoomPlacement {
  RoomPlacement(
      {required this.id, required this.x, required this.z, required this.rot});
  final String id;
  double x, z;
  int rot;
}

class RoomScenePlan {
  RoomScenePlan({
    required this.widthM,
    required this.depthM,
    required this.roomType,
    required this.notes,
    required this.placements,
  });

  final double widthM, depthM;
  final String roomType;
  final String notes;
  final List<RoomPlacement> placements;
}

Future<GeneratedKitchen> generateRoomScene(RoomScenePlan plan,
    {String style = 'Modern'}) async {
  final s = _Scene();
  final w = plan.widthM, d = plan.depthM;
  s.box(0, -0.05, 0, w, 0.0, d, 'floor');
  s.box(0, 0, -_wallT, w, _hCeil, 0, 'wall');
  s.box(-_wallT, 0, 0, 0, _hCeil, d, 'wall');

  var total = 0;
  final names = <String>[];
  for (final pl in plan.placements) {
    final builder = _furniture[pl.id];
    final foot = furnitureFootprints[pl.id];
    if (builder == null || foot == null) continue;
    final rot = ((pl.rot / 90).round() * 90) % 360;
    final hw = (rot % 180 == 0 ? foot[0] : foot[1]) / 2;
    final hd = (rot % 180 == 0 ? foot[1] : foot[0]) / 2;
    if (w < 2 * hw + 0.1 || d < 2 * hd + 0.1) continue; // cannot fit at all
    final cx = pl.x.clamp(hw + 0.05, w - hw - 0.05).toDouble();
    final cz = pl.z.clamp(hd + 0.05, d - hd - 0.05).toDouble();
    _instance(s, builder(), cx, cz, rot);
    final m = byId(pl.id);
    total += m.priceJd;
    names.add(m.title);
  }

  Map<String, Uint8List> tex;
  try {
    tex = await _loadTextures();
  } catch (_) {
    tex = const {};
  }
  final bytes = _writeGlb(s, 'Room_Redesign', _effectiveMats(const {}),
      textures: tex);
  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}/generated/room_scene.glb');
  await file.parent.create(recursive: true);
  await file.writeAsBytes(bytes, flush: true);

  final orbitR = (math.max(w, d) * 2.1).toStringAsFixed(1);
  final model = DemoModel(
    id: 'room_${DateTime.now().millisecondsSinceEpoch}',
    title: 'Your ${plan.roomType} - redesigned',
    category: Cat.living,
    asset: 'file://${file.path}',
    thumb: 'assets/thumbs/sofa_dana.png',
    blurb: 'AI-arranged from this catalogue, built on this device.',
    description: 'AI redesign of your ${plan.roomType} '
        '(${w.toStringAsFixed(1)} × ${d.toStringAsFixed(1)} m): '
        '${names.join(', ')}. ${plan.notes} '
        'Every piece is from this catalogue at true size - open in AR to '
        'walk the layout in your actual room.',
    wCm: (w * 100).round(),
    dCm: (d * 100).round(),
    hCm: 270,
    materials: const ['Arranged from this catalogue'],
    finishes: const [0xFF6B4830, 0xFF465342, 0xFF26292B],
    variants: [style],
    priceJd: total,
    cameraOrbit: '-38deg 70deg ${orbitR}m',
  );
  registerGeneratedModel(model);
  return GeneratedKitchen(
      model: model, path: file.path, triangles: s.triangles);
}
