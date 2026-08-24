import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/kitchen_design.dart';
import '../services/kitchen_generator.dart';
import '../services/plan_editor.dart';
import '../theme.dart';

/// The 3D layout editor (b24): the generated kitchen drawn as an
/// isometric CustomPaint scene - NO WebView (the one WebView stays
/// full-screen per the device landmines) - where every component is
/// draggable IKEA-planner style:
///
///  * sink / oven / fridge - grab their round chips (eager, like the 2D
///    editor) and drop them anywhere; runs are created/split/adjusted by
///    the same PlanEditor.place() rules;
///  * whole cabinet runs and the island - HOLD to lift (long-press keeps
///    page scrolling intact over the mostly-covered canvas), then drag;
///    structural apply happens once, on release;
///  * a selected run shows end handles (drag to resize), and the action
///    row offers uppers on/off + delete + undo.
///
/// Design decisions frozen from the b24 design panel (three-lens review):
/// element-level topological depth sort (scalar keys provably misorder
/// L-corners), backface-culled walls with near-wall stubs, view rotation
/// as a pure view-space transform (plan data NEVER rotated - guards the
/// b20 unified convention), grab-anchored floor inversion (no parallax
/// teleports when grabbing the tall fridge), 0.05 m quantization, and a
/// two-layer paint split so drag frames only repaint a thin overlay.
class IsoKitchenEditor extends StatefulWidget {
  const IsoKitchenEditor({
    super.key,
    required this.plan,
    required this.design,
    required this.editor,
    required this.onEdited,
    this.height = 320,
  });

  final LayoutPlan plan;
  final KitchenDesign design;
  final PlanEditor editor;
  final void Function(String what) onEdited;
  final double height;

  @override
  State<IsoKitchenEditor> createState() => _IsoKitchenEditorState();
}

// ---------------------------------------------------------------------------
// projection: plan (x,z,y) -> screen, with a frozen 90-degree-step view
// rotation applied ONLY here (plan data stays in the b20 convention)
// ---------------------------------------------------------------------------
class IsoView {
  IsoView(this.plan, this.size, this.k) {
    final w = plan.widthM, d = plan.depthM;
    // rotated room extents
    final rw = k.isEven ? w : d, rd = k.isEven ? d : w;
    // fit the projected room volume (with walls) into the canvas
    const hx = 0.87, hy = 0.5, vy = 0.62; // iso axis factors
    final sxMin = -rd * hx, sxMax = rw * hx;
    final syMin = -_wallH * vy, syMax = (rw + rd) * hy;
    final fit = math.min((size.width - 28) / (sxMax - sxMin),
        (size.height - 30) / (syMax - syMin));
    scale = fit;
    ox = 14 - sxMin * fit +
        (size.width - 28 - (sxMax - sxMin) * fit) / 2;
    oy = 20 - syMin * fit +
        (size.height - 30 - (syMax - syMin) * fit) / 2;
  }

  static const _wallH = 2.4; // editor wall height (slightly cropped)
  final LayoutPlan plan;
  final Size size;

  /// View rotation in 90-degree steps; frozen by the widget on entry and
  /// only changed by the explicit rotate button.
  final int k;

  late final double scale, ox, oy;

  /// Rotate a plan point into view space (about the room centre).
  (double, double) rot(double x, double z) {
    final w = plan.widthM, d = plan.depthM;
    switch (k & 3) {
      case 0:
        return (x, z);
      case 1:
        return (d - z, x);
      case 2:
        return (w - x, d - z);
      default:
        return (z, w - x);
    }
  }

  /// Inverse of [rot].
  (double, double) unrot(double rx, double rz) {
    final w = plan.widthM, d = plan.depthM;
    switch (k & 3) {
      case 0:
        return (rx, rz);
      case 1:
        return (rz, plan.depthM - rx);
      case 2:
        return (w - rx, d - rz);
      default:
        return (w - rz, rx);
    }
  }

  Offset project(double x, double y, double z) {
    final (rx, rz) = rot(x, z);
    return Offset(ox + (rx - rz) * 0.87 * scale,
        oy + (rx + rz) * 0.5 * scale - y * 0.62 * scale);
  }

  /// Screen point -> plan floor coordinates (y = 0 plane).
  (double, double) unprojectFloor(Offset p) {
    final u = (p.dx - ox) / (0.87 * scale);
    final v = (p.dy - oy) / (0.5 * scale);
    final rx = (v + u) / 2, rz = (v - u) / 2;
    return unrot(rx, rz);
  }

  /// Which VIEW side each plan wall lands on; the two "far" view sides
  /// (view-north = small rz, view-west = small rx) are drawn full height,
  /// near walls are culled to stubs so they never occlude the room.
  bool isFarWall(Wall wall) {
    // probe: rotate the wall's outward midpoint and compare
    final w = plan.widthM, d = plan.depthM;
    final (mx, mz) = switch (wall) {
      Wall.north => (w / 2, 0.0),
      Wall.south => (w / 2, d),
      Wall.west => (0.0, d / 2),
      Wall.east => (w, d / 2),
    };
    final (rx, rz) = rot(mx, mz);
    final (cx, cz) = rot(w / 2, d / 2);
    // far if the wall midpoint is view-north or view-west of the centre
    return (rz < cz - 1e-9) || (rx < cx - 1e-9);
  }

  /// Sign of the on-screen direction of a wall's u axis (+1 = u grows
  /// rightward). Used to decide whether a re-wall must mirror the run so
  /// the user's arrangement is preserved visually.
  int uScreenSign(Wall wall) {
    final along = switch (wall) {
      Wall.north || Wall.south => project(1, 0, 0) - project(0, 0, 0),
      _ => project(0, 0, 1) - project(0, 0, 0),
    };
    return along.dx >= 0 ? 1 : -1;
  }
}

// ---------------------------------------------------------------------------
// editor scene: a handful of ELEMENTS, each a list of simple boxes
// ---------------------------------------------------------------------------
class _EBox {
  const _EBox(this.x0, this.y0, this.z0, this.x1, this.y1, this.z1, this.c,
      {this.pick = true});
  final double x0, y0, z0, x1, y1, z1;
  final Color c;
  final bool pick; // uppers/hoods are visible but never grabbable
}

enum _EKind { run, island }

class _Element {
  _Element(this.kind, this.runRef, this.boxes);
  final _EKind kind;
  final RunPlan? runRef;
  final List<_EBox> boxes;

  late final double minX = boxes.map((b) => b.x0).reduce(math.min);
  late final double maxX = boxes.map((b) => b.x1).reduce(math.max);
  late final double minY = boxes.map((b) => b.y0).reduce(math.min);
  late final double maxY = boxes.map((b) => b.y1).reduce(math.max);
  late final double minZ = boxes.map((b) => b.z0).reduce(math.min);
  late final double maxZ = boxes.map((b) => b.z1).reduce(math.max);
}

Color _rgb(List<double> c) => Color.fromARGB(
    255, (c[0] * 255).round(), (c[1] * 255).round(), (c[2] * 255).round());

Color _shade(Color c, double f) => Color.fromARGB(c.a255, (c.r * 255 * f).round(),
    (c.g * 255 * f).round(), (c.b * 255 * f).round());

extension on Color {
  int get a255 => (a * 255).round();
}

List<_Element> _buildElements(LayoutPlan plan, KitchenDesign design) {
  final lower = _rgb(design.lowerFinish.carcass);
  final lowerDoor = _rgb(design.lowerFinish.door);
  final upper = _rgb(design.upperFinish.carcass);
  final upperDoor = _rgb(design.upperFinish.door);
  final islandC = _rgb(design.islandFinish.carcass);
  final wtRgb = design.worktopFinish.rgb;
  final worktop = wtRgb.isEmpty ? const Color(0xFF26292B) : _rgb(wtRgb);
  const steel = Color(0xFFB9BCC0);
  const dark = Color(0xFF17181A);

  final out = <_Element>[];
  for (final r in plan.runs) {
    final f = _RunFrame(r.wall, plan.widthM, plan.depthM);
    var a = r.a, b = r.b;
    final boxes = <_EBox>[];
    // b30 tall pantry: one floor-to-upper-top slab with stacked doors
    if (r.tall) {
      boxes.add(f.box(a, b, 0, 0.10, 0.02, 0.57, _shade(lower, 0.5)));
      boxes.add(f.box(a, b, 0.10, 2.20, 0, 0.62, lower));
      final n = math.max(1, ((b - a) / 0.60).round());
      final bw = (b - a) / n;
      for (var i = 0; i < n; i++) {
        final ba = a + i * bw + 0.012, bb = a + (i + 1) * bw - 0.012;
        boxes.add(f.box(ba, bb, 0.115, 1.295, 0.62, 0.638, lowerDoor));
        boxes.add(f.box(ba, bb, 1.305, 2.19, 0.62, 0.638, lowerDoor));
      }
      out.add(_Element(_EKind.run, r, boxes));
      continue;
    }
    // fridge slab + its high cabinet
    if (r.fridge == 'start') {
      boxes.add(f.box(a, a + 0.70, 0, 1.86, 0, 0.75, steel));
      boxes.add(f.box(a, a + 0.70, 1.92, 2.20, 0.02, 0.72, upper));
      a += 0.80;
    } else if (r.fridge == 'end') {
      boxes.add(f.box(b - 0.70, b, 0, 1.86, 0, 0.75, steel));
      boxes.add(f.box(b - 0.70, b, 1.92, 2.20, 0.02, 0.72, upper));
      b -= 0.80;
    }
    if (b - a >= 0.7) {
      boxes.add(f.box(a, b, 0, 0.10, 0.02, 0.57, _shade(lower, 0.5)));
      boxes.add(f.box(a, b, 0.10, 0.86, 0, 0.62, lower));
      // door bays as slightly proud fronts (b32: uniform IKEA modules)
      for (final (ba0, bb0, hasDoor) in doorBays(a, b)) {
        if (!hasDoor) continue;
        final ba = ba0 + 0.012, bb = bb0 - 0.012;
        if (r.rangeAt != null && ((ba + bb) / 2 - r.rangeAt!).abs() < 0.42) {
          continue;
        }
        boxes.add(f.box(ba, bb, 0.115, 0.85, 0.62, 0.638, lowerDoor));
      }
      // b31: corner-aware span - L-corner worktops join flush
      final (wa, wb) = worktopSpan(r, a, b, plan);
      boxes.add(f.box(wa, wb, 0.86, 0.90, 0, 0.655, worktop));
      if (r.sinkAt != null) {
        boxes.add(f.box(r.sinkAt! - 0.34, r.sinkAt! + 0.34, 0.901, 0.905,
            0.09, 0.50, dark));
      }
      if (r.rangeAt != null) {
        boxes.add(f.box(r.rangeAt! - 0.372, r.rangeAt! + 0.372, 0.10, 0.86,
            0.02, 0.65, steel));
        boxes.add(f.box(r.rangeAt! - 0.36, r.rangeAt! + 0.36, 0.898, 0.914,
            0.05, 0.57, dark));
        boxes.add(f.box(r.rangeAt! - 0.21, r.rangeAt! + 0.21, 1.52, 2.40,
            0.06, 0.34, steel, pick: false));
      }
      if (r.uppers) {
        boxes.add(
            f.box(a + 0.02, b - 0.02, 1.50, 2.20, 0, 0.35, upper, pick: false));
        final nd = math.max(1, ((b - a) / 0.55).round());
        final dw = (b - a) / nd;
        for (var i = 0; i < nd; i++) {
          final ba = a + i * dw + 0.012, bb = a + (i + 1) * dw - 0.012;
          boxes.add(f.box(ba, bb, 1.508, 2.192, 0.35, 0.365, upperDoor,
              pick: false));
        }
      }
    }
    if (boxes.isNotEmpty) out.add(_Element(_EKind.run, r, boxes));
  }

  final isl = plan.island;
  if (isl != null) {
    final x0 = isl.x0, x1 = isl.x0 + isl.w, z0 = isl.z0, z1 = isl.z0 + isl.d;
    final boxes = <_EBox>[
      _EBox(x0 + 0.05, 0, z0 + 0.05, x1 - 0.05, 0.10, z1 - 0.05,
          _shade(islandC, 0.5)),
      _EBox(x0, 0.10, z0, x1, 0.86, z1, islandC),
      _EBox(x0 - 0.05, 0.86, z0 - 0.05, x1 + 0.05, 0.90, z1 + 0.05,
          wtRgb.isEmpty ? const Color(0xFFE5E3DE) : worktop),
      if (isl.cooktop)
        _EBox((x0 + x1) / 2 - math.min(0.36, isl.w / 2 - 0.08), 0.901,
            (z0 + z1) / 2 - math.min(0.26, isl.d / 2 - 0.06),
            (x0 + x1) / 2 + math.min(0.36, isl.w / 2 - 0.08), 0.914,
            (z0 + z1) / 2 + math.min(0.26, isl.d / 2 - 0.06), dark),
    ];
    out.add(_Element(_EKind.island, null, boxes));
  }
  return out;
}

/// Run-local -> world box (b20 unified convention, same as the generator).
class _RunFrame {
  _RunFrame(this.wall, this.w, this.d);
  final Wall wall;
  final double w, d;

  _EBox box(double u0, double u1, double y0, double y1, double v0, double v1,
      Color c,
      {bool pick = true}) {
    switch (wall) {
      case Wall.north:
        return _EBox(u0, y0, v0, u1, y1, v1, c, pick: pick);
      case Wall.south:
        return _EBox(u0, y0, d - v1, u1, y1, d - v0, c, pick: pick);
      case Wall.west:
        return _EBox(v0, y0, u0, v1, y1, u1, c, pick: pick);
      case Wall.east:
        return _EBox(w - v1, y0, u0, w - v0, y1, u1, c, pick: pick);
    }
  }
}

/// Element-level topological depth order (panel blocker fix: scalar keys
/// misorder L-corner runs). A must precede B when A lies fully on the far
/// side of B along some view axis and their screen extents can overlap.
List<int> _depthOrder(List<_Element> els, IsoView v) {
  final n = els.length;
  // rotated AABBs
  final rb = els.map((e) {
    final (ax, az) = v.rot(e.minX, e.minZ);
    final (bx, bz) = v.rot(e.maxX, e.maxZ);
    return [
      math.min(ax, bx), math.max(ax, bx), // rx range
      math.min(az, bz), math.max(az, bz), // rz range
      e.minY, e.maxY,
    ];
  }).toList();
  const eps = 1e-6;
  final after = List.generate(n, (_) => <int>[]);
  final indeg = List.filled(n, 0);
  for (var i = 0; i < n; i++) {
    for (var j = i + 1; j < n; j++) {
      final a = rb[i], b = rb[j];
      int? first; // index drawn first
      if (a[3] <= b[2] + eps) {
        first = i; // a fully view-north of b
      } else if (b[3] <= a[2] + eps) {
        first = j;
      } else if (a[1] <= b[0] + eps) {
        first = i; // a fully view-west of b
      } else if (b[1] <= a[0] + eps) {
        first = j;
      } else if (a[5] <= b[4] + eps) {
        first = i; // a fully below b
      } else if (b[5] <= a[4] + eps) {
        first = j;
      }
      if (first != null) {
        final second = first == i ? j : i;
        after[first].add(second);
        indeg[second]++;
      }
    }
  }
  // Kahn with stable order
  final order = <int>[];
  final ready = [
    for (var i = 0; i < n; i++)
      if (indeg[i] == 0) i
  ];
  while (ready.isNotEmpty) {
    final i = ready.removeAt(0);
    order.add(i);
    for (final j in after[i]) {
      if (--indeg[j] == 0) ready.add(j);
    }
  }
  for (var i = 0; i < n; i++) {
    if (!order.contains(i)) order.add(i); // cycle fallback (shouldn't occur)
  }
  return order;
}

// ---------------------------------------------------------------------------
// widget
// ---------------------------------------------------------------------------
class _IsoKitchenEditorState extends State<IsoKitchenEditor> {
  Size _size = Size.zero;
  late int _k; // frozen view rotation; only the rotate button changes it

  RunPlan? _selected;

  // live drag state (read by the overlay painter via _dragTick)
  final ValueNotifier<int> _dragTick = ValueNotifier(0);
  _DragMode? _mode;
  ApplianceKind? _chipKind;
  RunPlan? _dragRun;
  bool _handleStart = false;
  Offset _grabOffset = Offset.zero;
  Offset? _finger;
  (Wall, double)? _wallTarget;
  (double, double)? _floorTarget;
  bool _targetOk = true;

  @override
  void initState() {
    super.initState();
    // freeze the camera so drags can never spin the room (panel blocker):
    // face the open side as found on entry
    _k = _openSideK(widget.plan);
  }

  @override
  void dispose() {
    _dragTick.dispose();
    super.dispose();
  }

  static int _openSideK(LayoutPlan plan) {
    final built = planWalls(plan);
    for (final e in [
      (Wall.south, 0),
      (Wall.east, 1),
      (Wall.north, 2),
      (Wall.west, 3),
    ]) {
      if (!built.contains(e.$1)) return e.$2;
    }
    return 0;
  }

  IsoView get _view => IsoView(widget.plan, _size, _k);

  List<_Element> _els() => _buildElements(widget.plan, widget.design);

  // chips billboarded at appliance positions (tier-1 pick targets).
  // [atFloor] projects the SAME plan point at y=0: drag anchors must use
  // the floor projection or the y-term leaks into unprojectFloor and
  // every drop lands ~a metre behind the chip (review critical fix).
  Offset? _chipCenter(ApplianceKind kind, {bool atFloor = false}) {
    final ed = widget.editor;
    final r = ed.runWith(kind);
    final u = ed.positionOf(kind);
    if (r == null || u == null) return null;
    final f = _RunFrame(r.wall, widget.plan.widthM, widget.plan.depthM);
    final pt = f.box(u, u, 0, 0, 0.31, 0.31, Colors.white);
    return _view.project(pt.x0, atFloor ? 0 : 0.95, pt.z0);
  }

  Offset? _handleCenter(RunPlan r, bool startEnd, {bool atFloor = false}) {
    if (!widget.plan.runs.contains(r)) return null;
    final f = _RunFrame(r.wall, widget.plan.widthM, widget.plan.depthM);
    final pt =
        f.box(startEnd ? r.a : r.b, startEnd ? r.a : r.b, 0, 0, 0.31, 0.31,
            Colors.white);
    return _view.project(pt.x0, atFloor ? 0 : 0.92, pt.z0);
  }

  _Element? _elementAt(Offset p) {
    final els = _els();
    final order = _depthOrder(els, _view);
    for (final i in order.reversed) {
      final e = els[i];
      if (_hullContains(e, p, 12)) return e;
    }
    return null;
  }

  bool _hullContains(_Element e, Offset p, double inflate) {
    for (final b in e.boxes) {
      if (!b.pick) continue;
      final hull = _convexHull(_boxCorners(b));
      if (_pointInHull(p, hull, inflate)) return true;
    }
    return false;
  }

  /// Monotone-chain convex hull (n=8; degenerate/coincident points safe -
  /// panel fix for face-on boxes collapsing corners).
  static List<Offset> _convexHull(List<Offset> pts) {
    final p = [...pts]..sort((a, b) =>
        a.dx != b.dx ? a.dx.compareTo(b.dx) : a.dy.compareTo(b.dy));
    double cross(Offset o, Offset a, Offset b) =>
        (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);
    final hull = <Offset>[];
    for (final pt in p) {
      while (hull.length >= 2 &&
          cross(hull[hull.length - 2], hull.last, pt) <= 0) {
        hull.removeLast();
      }
      hull.add(pt);
    }
    final lowerLen = hull.length + 1;
    for (final pt in p.reversed) {
      while (hull.length >= lowerLen &&
          cross(hull[hull.length - 2], hull.last, pt) <= 0) {
        hull.removeLast();
      }
      hull.add(pt);
    }
    hull.removeLast();
    return hull;
  }

  /// Inside the hull, or within [inflate] px of its boundary (finger-sized
  /// forgiveness on a ~50 px/m canvas).
  static bool _pointInHull(Offset p, List<Offset> hull, double inflate) {
    if (hull.length < 3) {
      for (final h in hull) {
        if ((h - p).distance <= inflate) return true;
      }
      return false;
    }
    var inside = true;
    var minDist = double.infinity;
    for (var i = 0; i < hull.length; i++) {
      final a = hull[i], b = hull[(i + 1) % hull.length];
      final cross = (b.dx - a.dx) * (p.dy - a.dy) -
          (b.dy - a.dy) * (p.dx - a.dx);
      if (cross < 0) inside = false;
      // distance to segment ab
      final ab = b - a;
      final t = ab.distanceSquared == 0
          ? 0.0
          : (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / ab.distanceSquared)
              .clamp(0.0, 1.0);
      final proj = a + ab * t.toDouble();
      minDist = math.min(minDist, (proj - p).distance);
    }
    return inside || minDist <= inflate;
  }

  List<Offset> _boxCorners(_EBox b) {
    final v = _view;
    return [
      v.project(b.x0, b.y0, b.z0),
      v.project(b.x1, b.y0, b.z0),
      v.project(b.x0, b.y0, b.z1),
      v.project(b.x1, b.y0, b.z1),
      v.project(b.x0, b.y1, b.z0),
      v.project(b.x1, b.y1, b.z0),
      v.project(b.x0, b.y1, b.z1),
      v.project(b.x1, b.y1, b.z1),
    ];
  }

  // ------------------------------------------------------------- gestures --
  void _onChipStart(ApplianceKind kind, Offset p) {
    // anchor at the FLOOR projection of the appliance point - anchoring
    // at the chip's billboard height would leak the y-term into the
    // floor inversion and shift every drop diagonally
    final c = _chipCenter(kind, atFloor: true)!;
    _mode = _DragMode.chip;
    _chipKind = kind;
    _grabOffset = p - c;
    _finger = p;
    HapticFeedback.selectionClick();
    _dragTick.value++;
  }

  void _onHandleStart(bool startEnd, Offset p) {
    final r = _selected;
    if (r == null) return;
    _mode = _DragMode.handle;
    _handleStart = startEnd;
    _dragRun = r; // capture NOW - selection may change by release
    final c = _handleCenter(r, startEnd, atFloor: true);
    _grabOffset = c == null ? Offset.zero : p - c;
    _finger = p;
    _dragTick.value++;
  }

  void _liftAt(Offset p) {
    final e = _elementAt(p);
    if (e == null) return;
    HapticFeedback.mediumImpact();
    if (e.kind == _EKind.island) {
      final isl = widget.plan.island!;
      _mode = _DragMode.island;
      _grabOffset =
          p - _view.project(isl.x0 + isl.w / 2, 0, isl.z0 + isl.d / 2);
    } else {
      _mode = _DragMode.run;
      _dragRun = e.runRef;
      _selected = e.runRef;
      final f =
          _RunFrame(e.runRef!.wall, widget.plan.widthM, widget.plan.depthM);
      final mid = (e.runRef!.a + e.runRef!.b) / 2;
      final box = f.box(mid, mid, 0, 0, 0.31, 0.31, Colors.white);
      _grabOffset = p - _view.project(box.x0, 0, box.z0);
    }
    _finger = p;
    setState(() {}); // selection highlight lives in the static layer
    _dragTick.value++;
  }

  void _dragUpdate(Offset p) {
    if (_mode == null) return;
    _finger = p;
    // anchored inversion: parallax-free floor point (panel fix)
    final (fx, fz) = _view.unprojectFloor(p - _grabOffset);
    const q = 0.05; // IKEA-style quantization
    double snap(double v) => (v / q).round() * q;

    switch (_mode!) {
      case _DragMode.handle:
        // a resize is pinned to the run's own wall: near a corner the
        // nearest-wall search would hijack the drag onto the other wall
        final r = _dragRun;
        if (r == null) return;
        final u = (r.wall == Wall.north || r.wall == Wall.south) ? fx : fz;
        _wallTarget = (r.wall, snap(u));
        _targetOk = true;
      case _DragMode.chip:
      case _DragMode.run:
        // nearest wall + u along it (same cost rule as the 2D editor)
        Wall? best;
        var bestCost = _mode == _DragMode.chip ? 0.75 : double.infinity;
        var bestU = 0.0;
        for (final wall in Wall.values) {
          final m = (wall == Wall.north || wall == Wall.south)
              ? widget.plan.widthM
              : widget.plan.depthM;
          double u, off;
          switch (wall) {
            case Wall.north:
              u = fx;
              off = fz - 0.31;
            case Wall.south:
              u = fx;
              off = (widget.plan.depthM - 0.31) - fz;
            case Wall.west:
              u = fz;
              off = fx - 0.31;
            case Wall.east:
              u = fz;
              off = (widget.plan.widthM - 0.31) - fx;
          }
          var cost = math.max(0.0, off.abs() - 0.31);
          if (u < 0) cost += -u;
          if (u > m) cost += u - m;
          if (cost < bestCost) {
            best = wall;
            bestCost = cost;
            bestU = u;
          }
        }
        if (best != null) {
          _wallTarget = (best, snap(bestU));
          _targetOk = _mode != _DragMode.run ||
              _wallLen(best) >= (_dragRun?.length ?? 0) + 0.04;
        } else {
          _wallTarget = null;
          _targetOk = false;
        }
      case _DragMode.island:
        _floorTarget = (snap(fx), snap(fz));
        _targetOk = true;
    }
    _dragTick.value++;
  }

  double _wallLen(Wall wall) =>
      (wall == Wall.north || wall == Wall.south)
          ? widget.plan.widthM
          : widget.plan.depthM;

  /// Abort a drag without applying anything - system-cancelled gestures
  /// must never commit, and must never leave [_mode] wedged (a wedged
  /// mode would block every future pointer via isPointerAllowed).
  void _dragAbort() {
    if (_mode == null) return;
    _mode = null;
    _chipKind = null;
    _dragRun = null;
    _wallTarget = null;
    _floorTarget = null;
    _finger = null;
    _dragTick.value++;
    setState(() {});
  }

  void _dragEnd() {
    final mode = _mode;
    _mode = null;
    if (mode == null) return;
    final ed = widget.editor;
    var what = '';
    var ok = false;
    ed.checkpoint();
    switch (mode) {
      case _DragMode.chip:
        final t = _wallTarget;
        if (t != null && _chipKind != null) {
          ok = ed.place(_chipKind!, t.$1, t.$2);
          what = 'move_${_chipKind!.name}';
        }
      case _DragMode.run:
        final t = _wallTarget;
        final r = _dragRun;
        if (t != null && r != null) {
          final mirror = t.$1 != r.wall &&
              _view.uScreenSign(t.$1) != _view.uScreenSign(r.wall);
          ok = ed.moveRun(r, t.$1, t.$2, mirror: mirror);
          what = 'move_run';
          if (ok) _selected = null; // dropped clean - clear the selection
        }
      case _DragMode.island:
        final t = _floorTarget;
        if (t != null) {
          ok = ed.moveIsland(t.$1, t.$2);
          what = 'move_island';
        }
      case _DragMode.handle:
        final t = _wallTarget;
        final r = _dragRun; // captured at gesture start, not at release
        if (t != null && r != null && widget.plan.runs.contains(r)) {
          ok = ed.resizeRun(r, startEnd: _handleStart, v: t.$2);
          what = 'resize_run';
        }
    }
    if (!ok) {
      ed.undoDiscardLast();
      HapticFeedback.heavyImpact();
    }
    _chipKind = null;
    _dragRun = null;
    _wallTarget = null;
    _floorTarget = null;
    _finger = null;
    _dragTick.value++;
    if (ok) {
      setState(() {});
      widget.onEdited(what);
    } else {
      setState(() {});
    }
  }

  void _tapAt(Offset p) {
    final e = _elementAt(p);
    setState(() {
      _selected = e?.kind == _EKind.run ? e!.runRef : null;
    });
  }

  // ---------------------------------------------------------------- build --
  @override
  Widget build(BuildContext context) {
    final ed = widget.editor;
    // normalize/undo/2D edits may have removed the selected run - a stale
    // selection would aim the action row at a ghost
    if (_selected != null && !widget.plan.runs.contains(_selected)) {
      _selected = null;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: double.infinity,
            height: widget.height,
            child: LayoutBuilder(builder: (context, c) {
              _size = Size(c.maxWidth, c.maxHeight);
              return RawGestureDetector(
                gestures: {
                  _IsoChipRecognizer:
                      GestureRecognizerFactoryWithHandlers<_IsoChipRecognizer>(
                    () => _IsoChipRecognizer(this),
                    (r) {},
                  ),
                  LongPressGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                          LongPressGestureRecognizer>(
                    () => LongPressGestureRecognizer(
                        duration: const Duration(milliseconds: 260)),
                    (r) {
                      r.onLongPressStart = (d) {
                        _liftAt(d.localPosition);
                      };
                      r.onLongPressMoveUpdate = (d) {
                        _dragUpdate(d.localPosition);
                      };
                      r.onLongPressEnd = (d) {
                        _dragEnd();
                      };
                      // a system-cancelled hold must abort, not commit,
                      // and must never leave _mode wedged
                      r.onLongPressCancel = _dragAbort;
                    },
                  ),
                  TapGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                    () => TapGestureRecognizer(),
                    (r) => r..onTapUp = (d) => _tapAt(d.localPosition),
                  ),
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    RepaintBoundary(
                      child: CustomPaint(
                        painter: _ScenePainter(this, ed.revision),
                      ),
                    ),
                    RepaintBoundary(
                      child: CustomPaint(
                        painter: _OverlayPainter(this),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: Text(
                _selected == null
                    ? 'Drag S/O/F - hold cabinets or the island to move them'
                    : 'Counter selected - drag the end dots to resize',
                style: TextStyle(
                    fontSize: 11, color: Baytak.ink.withValues(alpha: 0.55)),
              ),
            ),
            // b30: add cabinets at will - base counters or a tall pantry
            PopupMenuButton<bool>(
              tooltip: 'Add cabinets',
              icon: const Icon(Icons.add_box_outlined, size: 19),
              onSelected: (tall) {
                ed.checkpoint();
                if (ed.addRun(tall: tall)) {
                  setState(() => _selected = null);
                  widget.onEdited(tall ? 'add_tall' : 'add_run');
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      duration: const Duration(seconds: 3),
                      content: Text(tall
                          ? 'Tall cabinet added - hold it to drag it '
                              'anywhere, drag its end dots to widen it'
                          : 'Cabinets added - hold them to drag them '
                              'anywhere')));
                } else {
                  ed.undoDiscardLast();
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content:
                          Text('No wall has room - remove something first')));
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: false, child: Text('Base cabinets (1.5 m)')),
                PopupMenuItem(
                    value: true,
                    child: Text('Tall cabinet - floor to uppers (0.6 m)')),
              ],
            ),
            IconButton(
              tooltip: 'Rotate view',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.rotate_90_degrees_ccw, size: 19),
              onPressed: () => setState(() => _k = (_k + 1) & 3),
            ),
            if (_selected != null) ...[
              if (!_selected!.tall)
                IconButton(
                  tooltip: _selected!.uppers
                      ? 'Remove upper cabinets'
                      : 'Add upper cabinets',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                      _selected!.uppers
                          ? Icons.vertical_align_bottom
                          : Icons.vertical_align_top,
                      size: 19),
                  onPressed: () {
                    ed.checkpoint();
                    setState(() => _selected!.uppers = !_selected!.uppers);
                    ed.revision++;
                    widget.onEdited('toggle_uppers');
                  },
                ),
              IconButton(
                tooltip: 'Delete this counter',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline, size: 19),
                onPressed: () {
                  ed.checkpoint();
                  final r = _selected!;
                  setState(() => _selected = null);
                  if (ed.removeRun(r)) {
                    widget.onEdited('delete_run');
                  } else {
                    ed.undoDiscardLast();
                  }
                },
              ),
            ],
            IconButton(
              tooltip: 'Undo',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.undo, size: 19),
              onPressed: ed.canUndo
                  ? () {
                      setState(() {
                        ed.undo();
                        _selected = null;
                      });
                      widget.onEdited('undo');
                    }
                  : null,
            ),
          ],
        ),
      ],
    );
  }
}

enum _DragMode { chip, run, island, handle }

/// Eager recognizer for the SMALL targets only (appliance chips + resize
/// handles) - big surfaces go through long-press so page scroll survives.
/// Misses never join the arena (isPointerAllowed), so flicks over the
/// canvas scroll the page instead of dying (panel fix).
class _IsoChipRecognizer extends PanGestureRecognizer {
  _IsoChipRecognizer(this.s);
  final _IsoKitchenEditorState s;

  ApplianceKind? _pendingChip;
  bool? _pendingHandle;

  @override
  bool isPointerAllowed(PointerEvent event) {
    if (event is! PointerDownEvent) return super.isPointerAllowed(event);
    if (s._mode != null) return false; // strictly single-touch
    _pendingChip = null;
    _pendingHandle = null;
    final p = event.localPosition;
    final sel = s._selected;
    if (sel != null) {
      for (final startEnd in [true, false]) {
        final c = s._handleCenter(sel, startEnd);
        if (c != null && (c - p).distance < 22) {
          _pendingHandle = startEnd;
          return super.isPointerAllowed(event);
        }
      }
    }
    for (final kind in ApplianceKind.values) {
      final c = s._chipCenter(kind);
      if (c != null && (c - p).distance < 26) {
        _pendingChip = kind;
        return super.isPointerAllowed(event);
      }
    }
    return false; // transparent to the scrollable
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
    if (_pendingHandle != null) {
      s._onHandleStart(_pendingHandle!, event.localPosition);
    } else if (_pendingChip != null) {
      s._onChipStart(_pendingChip!, event.localPosition);
    }
    onUpdate = (d) => s._dragUpdate(d.localPosition);
    onEnd = (d) => s._dragEnd();
    onCancel = s._dragAbort; // cancelled != released: never commit
  }
}

// ---------------------------------------------------------------------------
// painters: static scene (repaints on revision) + thin drag overlay
// ---------------------------------------------------------------------------
class _ScenePainter extends CustomPainter {
  _ScenePainter(this.s, this.revision)
      : k = s._k,
        selected = s._selected,
        mode = s._mode,
        design = s.widget.design;
  final _IsoKitchenEditorState s;
  final int revision;
  // repaint keys captured BY VALUE - the State instance is shared between
  // successive painters, so reading them through `s` in shouldRepaint
  // would always compare equal and freeze the layer
  final int k;
  final RunPlan? selected;
  final _DragMode? mode;
  final KitchenDesign design;

  @override
  void paint(Canvas canvas, Size size) {
    final plan = s.widget.plan;
    final design = s.widget.design;
    final v = IsoView(plan, size, s._k);
    final w = plan.widthM, d = plan.depthM;
    final ink = Baytak.ink;
    final stroke = Paint()
      ..color = ink.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    // floor
    final floor = _rgb(design.floorFinish.rgb);
    _quad(canvas, [
      v.project(0, 0, 0),
      v.project(w, 0, 0),
      v.project(w, 0, d),
      v.project(0, 0, d),
    ], floor, stroke);

    // walls: far walls full height, near BUILT walls as low stubs so they
    // stay visible drop targets without occluding the room (panel fix)
    final built = planWalls(plan);
    final wallC = _rgb(design.wallFinish.rgb);
    for (final wall in Wall.values) {
      if (!built.contains(wall)) continue;
      final far = v.isFarWall(wall);
      final h = far ? IsoView._wallH : 0.14;
      final c = far ? wallC : _shade(wallC, 0.9);
      final (p, q) = switch (wall) {
        Wall.north => ((0.0, 0.0), (w, 0.0)),
        Wall.south => ((0.0, d), (w, d)),
        Wall.west => ((0.0, 0.0), (0.0, d)),
        Wall.east => ((w, 0.0), (w, d)),
      };
      _quad(canvas, [
        v.project(p.$1, 0, p.$2),
        v.project(q.$1, 0, q.$2),
        v.project(q.$1, h, q.$2),
        v.project(p.$1, h, p.$2),
      ], c, stroke);
      if (far) {
        // windows on this wall, in the wall plane
        for (final win in plan.windows.where((x) => x.wall == wall)) {
          final f = _RunFrame(wall, w, d);
          final a = f.box(win.center - win.width / 2, win.center + win.width / 2,
              1.0, 1.9, 0, 0, Colors.white);
          _quad(canvas, [
            v.project(a.x0, 1.0, a.z0),
            v.project(a.x1, 1.0, a.z1),
            v.project(a.x1, 1.9, a.z1),
            v.project(a.x0, 1.9, a.z0),
          ], const Color(0xFFB7CFDA), stroke);
        }
      }
    }

    // contents, topologically ordered
    final els = _buildElements(plan, design);
    final order = _depthOrder(els, v);
    for (final i in order) {
      final e = els[i];
      final selected = e.kind == _EKind.run && identical(e.runRef, s._selected);
      final hidden = s._mode == _DragMode.run &&
          e.kind == _EKind.run &&
          identical(e.runRef, s._dragRun);
      final island = s._mode == _DragMode.island && e.kind == _EKind.island;
      final ghosted = hidden || island;
      for (final b in e.boxes) {
        _drawBox(canvas, v, b, stroke,
            alpha: ghosted ? 0.25 : 1.0, highlight: selected);
      }
    }

    // resize handles for the selected run
    final sel = s._selected;
    if (sel != null && s.widget.plan.runs.contains(sel)) {
      for (final startEnd in [true, false]) {
        final c = s._handleCenter(sel, startEnd);
        if (c == null) continue;
        canvas.drawCircle(c, 9, Paint()..color = Baytak.brass);
        canvas.drawCircle(
            c,
            9,
            Paint()
              ..color = Colors.white
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2);
      }
    }
  }

  void _drawBox(Canvas canvas, IsoView v, _EBox b, Paint stroke,
      {double alpha = 1.0, bool highlight = false}) {
    final base = highlight
        ? Color.lerp(b.c, Baytak.brass, 0.25)!
        : b.c;
    // three visible faces of an axis-aligned box under this projection:
    // top, view-south, view-east. Compute via rotated corners.
    final c000 = v.project(b.x0, b.y0, b.z0);
    final c100 = v.project(b.x1, b.y0, b.z0);
    final c010 = v.project(b.x0, b.y0, b.z1);
    final c110 = v.project(b.x1, b.y0, b.z1);
    final t000 = v.project(b.x0, b.y1, b.z0);
    final t100 = v.project(b.x1, b.y1, b.z0);
    final t010 = v.project(b.x0, b.y1, b.z1);
    final t110 = v.project(b.x1, b.y1, b.z1);

    // top face
    _quad(canvas, [t000, t100, t110, t010], _withA(base, alpha), stroke);
    // the two near vertical faces: those whose outward normal points
    // toward the viewer = faces with the LARGEST projected bottom-edge y
    final faces = [
      ([c000, c100, t100, t000], (c000.dy + c100.dy)), // z0 face
      ([c010, c110, t110, t010], (c010.dy + c110.dy)), // z1 face
      ([c000, c010, t010, t000], (c000.dy + c010.dy)), // x0 face
      ([c100, c110, t110, t100], (c100.dy + c110.dy)), // x1 face
    ]..sort((a, bb) => bb.$2.compareTo(a.$2));
    _quad(canvas, faces[0].$1, _withA(_shade(base, 0.78), alpha), stroke);
    _quad(canvas, faces[1].$1, _withA(_shade(base, 0.62), alpha), stroke);
  }

  Color _withA(Color c, double a) =>
      a >= 1.0 ? c : c.withValues(alpha: a);

  void _quad(Canvas canvas, List<Offset> pts, Color fill, Paint stroke) {
    final path = Path()..addPolygon(pts, true);
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(covariant _ScenePainter old) =>
      old.revision != revision ||
      old.k != k ||
      !identical(old.selected, selected) ||
      old.mode != mode ||
      !identical(old.design, design);
}

class _OverlayPainter extends CustomPainter {
  _OverlayPainter(this.s) : super(repaint: s._dragTick);
  final _IsoKitchenEditorState s;

  @override
  void paint(Canvas canvas, Size size) {
    final v = IsoView(s.widget.plan, size, s._k);

    // chips (always on top; follow the drag live)
    const labels = {
      ApplianceKind.sink: 'S',
      ApplianceKind.range: 'O',
      ApplianceKind.fridge: 'F',
    };
    for (final kind in ApplianceKind.values) {
      var c = s._chipCenter(kind);
      final active = s._mode == _DragMode.chip && s._chipKind == kind;
      if (active && s._finger != null) {
        // the grab offset is floor-anchored (drop math needs y=0); add
        // the billboard lift back so the chip doesn't ride at floor level
        c = (s._finger! - s._grabOffset)
            .translate(0, -0.95 * 0.62 * v.scale);
      }
      if (c == null) continue;
      final radius = active ? 16.0 : 13.0;
      canvas.drawCircle(
          c,
          radius + 2,
          Paint()
            ..color = active ? Baytak.brass : Baytak.ink
            ..style = PaintingStyle.stroke
            ..strokeWidth = active ? 3 : 1.4);
      canvas.drawCircle(
          c, radius, Paint()..color = Colors.white.withValues(alpha: 0.95));
      final tp = TextPainter(
        text: TextSpan(
          text: labels[kind],
          style: TextStyle(
            color: active ? Baytak.brass : Baytak.ink,
            fontSize: active ? 14 : 12,
            fontWeight: FontWeight.w800,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
    }

    // ghost + landing label for run/island drags
    if ((s._mode == _DragMode.run || s._mode == _DragMode.island) &&
        s._finger != null) {
      final tint = s._targetOk
          ? Baytak.brass.withValues(alpha: 0.45)
          : Colors.redAccent.withValues(alpha: 0.45);
      Rect footprint;
      if (s._mode == _DragMode.run && s._dragRun != null) {
        final t = s._wallTarget;
        final r = s._dragRun!;
        if (t == null) return;
        final len = r.length;
        final m = s._wallLen(t.$1);
        final a = (t.$2 - len / 2).clamp(0.02, math.max(0.02, m - len - 0.02));
        final f = _RunFrame(t.$1, s.widget.plan.widthM, s.widget.plan.depthM);
        final box = f.box(a.toDouble(), a + len, 0, 0.9, 0, 0.65, Colors.white);
        footprint = Rect.fromLTRB(box.x0, box.z0, box.x1, box.z1);
      } else {
        final t = s._floorTarget;
        final isl = s.widget.plan.island;
        if (t == null || isl == null) return;
        footprint = Rect.fromCenter(
            center: Offset(t.$1, t.$2), width: isl.w, height: isl.d);
      }
      final path = Path()
        ..addPolygon([
          v.project(footprint.left, 0.02, footprint.top),
          v.project(footprint.right, 0.02, footprint.top),
          v.project(footprint.right, 0.02, footprint.bottom),
          v.project(footprint.left, 0.02, footprint.bottom),
        ], true);
      canvas.drawPath(path, Paint()..color = tint);
      canvas.drawPath(
          path,
          Paint()
            ..color = s._targetOk ? Baytak.brass : Colors.redAccent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);

      // label (b32: IKEA-style live measurements - gaps to the nearest
      // neighbour/wall on each side update every drag tick)
      String text;
      if (s._mode == _DragMode.run) {
        final t = s._wallTarget!;
        final r = s._dragRun!;
        final len = r.length;
        final m = s._wallLen(t.$1);
        final ga = (t.$2 - len / 2)
            .clamp(0.02, math.max(0.02, m - len - 0.02))
            .toDouble();
        var leftAt = 0.0, rightAt = m;
        for (final q in s.widget.plan.runs) {
          if (identical(q, r) || q.wall != t.$1) continue;
          if (q.b <= ga + 0.01 && q.b > leftAt) leftAt = q.b;
          if (q.a >= ga + len - 0.01 && q.a < rightAt) rightAt = q.a;
        }
        final lg = math.max(0.0, ga - leftAt);
        final rg = math.max(0.0, rightAt - (ga + len));
        text = '${lg.toStringAsFixed(2)} ◀ ${len.toStringAsFixed(2)} m '
            '▶ ${rg.toStringAsFixed(2)}';
      } else {
        final t = s._floorTarget!;
        text = 'island at ${t.$1.toStringAsFixed(2)} × '
            '${t.$2.toStringAsFixed(2)} m';
      }
      final lp = TextPainter(
        text: TextSpan(
          text: text,
          style: const TextStyle(
              color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final f = s._finger!;
      final pos = Offset(
        (f.dx - lp.width / 2).clamp(4.0, size.width - lp.width - 4),
        (f.dy - 52).clamp(4.0, size.height - 18),
      );
      final bg =
          Rect.fromLTWH(pos.dx - 6, pos.dy - 4, lp.width + 12, lp.height + 8);
      canvas.drawRRect(RRect.fromRectAndRadius(bg, const Radius.circular(6)),
          Paint()..color = Baytak.ink.withValues(alpha: 0.85));
      lp.paint(canvas, pos);
    }
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter old) => true;
}
