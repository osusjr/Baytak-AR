import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/analytics.dart';
import '../services/kitchen_design.dart';
import '../services/kitchen_generator.dart';
import '../theme.dart';
import 'product_details_screen.dart';

/// Design studio (v17): the generated kitchen broken into its elements -
/// walls, floor, worktops, upper/lower/island cabinets, backsplash,
/// handles, hardware - each swappable IKEA-planner style. The 2D preview
/// (plan + elevation) repaints instantly; "Build in 3D & AR" re-extrudes
/// the GLB on this phone in milliseconds with the chosen finishes.
class DesignStudioScreen extends StatefulWidget {
  const DesignStudioScreen({
    super.key,
    required this.plan,
    this.initial,
    this.source = 'your measurements',
  });

  final LayoutPlan plan;
  final KitchenDesign? initial;
  final String source;

  /// Restores the last edited plan (or falls back to the demo K-01 spec)
  /// so the studio can be opened directly from the Profile tab.
  static Future<DesignStudioScreen> restoreLast() async {
    final prefs = await SharedPreferences.getInstance();
    LayoutPlan plan;
    try {
      final raw = prefs.getString('last_plan_v1');
      plan = raw == null
          ? _demoPlan()
          : LayoutPlan.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      if (plan.runs.isEmpty) plan = _demoPlan();
    } catch (_) {
      plan = _demoPlan();
    }
    final design = KitchenDesign.tryDecode(prefs.getString('kitchen_design_v1'));
    return DesignStudioScreen(
        plan: plan, initial: design, source: 'the saved plan');
  }

  static LayoutPlan _demoPlan() => const KitchenSpec(
        widthM: 4.20,
        depthM: 3.40,
        layout: KitchenLayout.lShape,
        island: true,
      ).toPlan();

  @override
  State<DesignStudioScreen> createState() => _DesignStudioScreenState();
}

class _DesignStudioScreenState extends State<DesignStudioScreen> {
  late KitchenDesign _design;
  bool _building = false;
  String? _stage;

  static const _stages = [
    'Applying your finishes...',
    'Extruding cabinetry...',
    'Writing glTF model...',
  ];

  @override
  void initState() {
    super.initState();
    _design = widget.initial ?? const KitchenDesign();
    _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('kitchen_design_v1', _design.encode());
    await prefs.setString(
        'last_plan_v1', jsonEncode(widget.plan.toJson()));
  }

  void _update(KitchenDesign next, String element) {
    setState(() => _design = next);
    AppAnalytics.log('design', element);
    _persist();
  }

  Future<void> _build() async {
    setState(() => _building = true);
    try {
      GeneratedKitchen? gen;
      for (var i = 0; i < _stages.length; i++) {
        if (!mounted) return;
        setState(() => _stage = _stages[i]);
        if (i == 1) {
          gen = await generateFromPlan(widget.plan,
              source: widget.source, design: _design);
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 380));
        }
      }
      if (!mounted) return;
      setState(() {
        _building = false;
        _stage = null;
      });
      AppAnalytics.log('generate');
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text('Built on this device - '
                '${gen!.triangles} triangles')));
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ProductDetailsScreen(model: gen!.model)));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _building = false;
        _stage = null;
      });
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Could not build the kitchen'),
          content: SingleChildScrollView(child: Text('$e')),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Close')),
          ],
        ),
      );
    }
  }

  // ------------------------------------------------------------- widgets --
  Widget _swatchRow<T>({
    required String title,
    required Map<String, T> options,
    required String selected,
    required String Function(T) label,
    required int Function(T) swatch,
    required void Function(String) onPick,
  }) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(title,
                  style:
                      text.bodyMedium?.copyWith(fontWeight: FontWeight.w800)),
            ),
            Text(label(options[selected] as T),
                style: text.bodySmall?.copyWith(
                    color: Baytak.ink.withValues(alpha: 0.55),
                    fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final e in options.entries)
              _Swatch(
                color: Color(swatch(e.value)),
                selected: e.key == selected,
                tooltip: label(e.value),
                onTap: () => onPick(e.key),
              ),
          ],
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  Widget _styleRow({
    required String title,
    required Map<String, String> options,
    required String selected,
    required void Function(String) onPick,
  }) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final e in options.entries) ...[
              Expanded(
                child: OutlinedButton(
                  onPressed: () => onPick(e.key),
                  style: OutlinedButton.styleFrom(
                    backgroundColor:
                        selected == e.key ? Baytak.ink : Colors.white,
                    foregroundColor:
                        selected == e.key ? Baytak.sand : Baytak.ink,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 4, vertical: 10),
                  ),
                  child: Text(e.value,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 11.5)),
                ),
              ),
              if (e.key != options.keys.last) const SizedBox(width: 8),
            ],
          ],
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final plan = widget.plan;

    final cards = <Widget>[
      // 0 - stamp + live preview
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('DESIGN STUDIO v17 - RENDER OK',
              style: text.labelSmall?.copyWith(
                  color: Baytak.olive, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('Your kitchen, element by element',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            'Room ${plan.widthM.toStringAsFixed(2)} × '
            '${plan.depthM.toStringAsFixed(2)} m from ${widget.source}. '
            'Tap any swatch - the drawing recolors instantly; build in 3D '
            'whenever you like.',
            style: text.bodySmall?.copyWith(
                color: Baytak.ink.withValues(alpha: 0.65), height: 1.4),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: double.infinity,
              height: 190,
              child: CustomPaint(
                painter: KitchenElevationPainter(plan, _design),
              ),
            ),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: double.infinity,
              height: 150,
              child: CustomPaint(
                painter: KitchenPlanPainter(plan, _design),
              ),
            ),
          ),
        ],
      ),

      // 1 - presets
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Quick looks',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in KitchenDesign.presets.entries)
                _PresetChip(
                  label: KitchenDesign.presetLabels[e.key] ?? e.key,
                  design: e.value,
                  onTap: () => _update(e.value, 'preset'),
                ),
            ],
          ),
        ],
      ),

      // 2 - cabinets
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Cabinets',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          _swatchRow(
            title: 'Lower cabinets',
            options: cabinetFinishes,
            selected: _design.lower,
            label: (CabinetFinish f) => f.label,
            swatch: (f) => f.swatch,
            onPick: (k) => _update(_design.copyWith(lower: k), 'lower'),
          ),
          _swatchRow(
            title: 'Upper cabinets',
            options: cabinetFinishes,
            selected: _design.upper,
            label: (CabinetFinish f) => f.label,
            swatch: (f) => f.swatch,
            onPick: (k) => _update(_design.copyWith(upper: k), 'upper'),
          ),
          if (plan.island != null)
            _swatchRow(
              title: 'Island',
              options: cabinetFinishes,
              selected: _design.island,
              label: (CabinetFinish f) => f.label,
              swatch: (f) => f.swatch,
              onPick: (k) => _update(_design.copyWith(island: k), 'island'),
            ),
          _styleRow(
            title: 'Door style',
            options: doorStyles,
            selected: _design.door,
            onPick: (k) => _update(_design.copyWith(door: k), 'door'),
          ),
        ],
      ),

      // 3 - surfaces
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Surfaces',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          _swatchRow(
            title: 'Worktop',
            options: worktops,
            selected: _design.worktop,
            label: (SurfaceFinish f) => f.label,
            swatch: (f) => f.swatch,
            onPick: (k) => _update(_design.copyWith(worktop: k), 'worktop'),
          ),
          _swatchRow(
            title: 'Backsplash',
            options: backsplashes,
            selected: _design.splash,
            label: (SurfaceFinish f) => f.label,
            swatch: (f) => f.swatch,
            onPick: (k) => _update(_design.copyWith(splash: k), 'splash'),
          ),
          _swatchRow(
            title: 'Wall paint',
            options: wallPaints,
            selected: _design.wall,
            label: (SurfaceFinish f) => f.label,
            swatch: (f) => f.swatch,
            onPick: (k) => _update(_design.copyWith(wall: k), 'wall'),
          ),
          _swatchRow(
            title: 'Floor',
            options: floorFinishes,
            selected: _design.floor,
            label: (SurfaceFinish f) => f.label,
            swatch: (f) => f.swatch,
            onPick: (k) => _update(_design.copyWith(floor: k), 'floor'),
          ),
        ],
      ),

      // 4 - details
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Details',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          _swatchRow(
            title: 'Hardware',
            options: hardwareFinishes,
            selected: _design.hardware,
            label: (HardwareFinish f) => f.label,
            swatch: (f) => f.swatch,
            onPick: (k) => _update(_design.copyWith(hardware: k), 'hardware'),
          ),
          _styleRow(
            title: 'Handles',
            options: handleStyles,
            selected: _design.handle,
            onPick: (k) => _update(_design.copyWith(handle: k), 'handle'),
          ),
          Text(
            'Handles, door fronts and hardware are real geometry - they '
            'carry into the AR model, not just this drawing.',
            style: text.bodySmall?.copyWith(
                color: Baytak.ink.withValues(alpha: 0.5), height: 1.35),
          ),
        ],
      ),

      // 5 - build
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('See it in 3D & AR',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            'This phone re-extrudes the whole kitchen with your finishes in '
            'milliseconds - then walk through it at true size in AR.',
            style: text.bodySmall?.copyWith(
                color: Baytak.ink.withValues(alpha: 0.65), height: 1.4),
          ),
          const SizedBox(height: 10),
          if (_building)
            Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.4, color: Baytak.brass),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(_stage ?? 'Starting...',
                      style: text.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ),
              ],
            )
          else
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _build,
                child: const Text('Build my kitchen in 3D & AR'),
              ),
            ),
        ],
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Design studio')),
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 28),
        itemCount: cards.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) => Card(
          child: Padding(padding: const EdgeInsets.all(16), child: cards[i]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.color,
    required this.selected,
    required this.tooltip,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final luminance = color.computeLuminance();
    return Tooltip(
      message: tooltip,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? Baytak.brass
                  : Baytak.ink.withValues(alpha: 0.15),
              width: selected ? 3 : 1,
            ),
          ),
          child: selected
              ? Icon(Icons.check_rounded,
                  size: 18,
                  color: luminance > 0.5 ? Baytak.ink : Colors.white)
              : null,
        ),
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip(
      {required this.label, required this.design, required this.onTap});

  final String label;
  final KitchenDesign design;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      color: Colors.white,
      shape: StadiumBorder(
          side: BorderSide(color: Baytak.ink.withValues(alpha: 0.15))),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final c in [
                design.lowerFinish.swatch,
                design.worktopFinish.swatch,
                design.splashFinish.swatch,
              ])
                Container(
                  width: 14,
                  height: 14,
                  margin: const EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(
                    color: Color(c),
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: Baytak.ink.withValues(alpha: 0.12)),
                  ),
                ),
              const SizedBox(width: 4),
              Text(label,
                  style: text.labelMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 2D preview painters. Both read colors straight from the design so every
// swatch tap repaints them - the IKEA-planner feel without a WebView
// (the one WebView stays full-screen, per the device landmine notes).
// ---------------------------------------------------------------------------
Color _rgb(List<double> c) => Color.fromARGB(
    255, (c[0] * 255).round(), (c[1] * 255).round(), (c[2] * 255).round());

Color _darken(Color c, double f) => Color.fromARGB(255,
    (c.r * 255 * f).round(), (c.g * 255 * f).round(), (c.b * 255 * f).round());

/// Front elevation of the plan's primary run (longest one, prefers the run
/// holding the sink/range) - counters, doors, handles, uppers, appliances.
class KitchenElevationPainter extends CustomPainter {
  KitchenElevationPainter(this.plan, this.design);

  final LayoutPlan plan;
  final KitchenDesign design;

  RunPlan get _primary {
    final runs = [...plan.runs];
    runs.sort((a, b) {
      int score(RunPlan r) =>
          ((r.rangeAt != null ? 2 : 0) +
              (r.sinkAt != null ? 2 : 0) +
              (r.uppers ? 1 : 0)) *
              1000 +
          (r.length * 100).round();
      return score(b).compareTo(score(a));
    });
    return runs.first;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final r = _primary;
    final wallColor = _rgb(design.wallFinish.rgb);
    final floorColor = _rgb(design.floorFinish.rgb);
    final splashColor = _rgb(design.splashFinish.rgb);
    final lower = _rgb(design.lowerFinish.carcass);
    final lowerDoor = _rgb(design.lowerFinish.door);
    final upper = _rgb(design.upperFinish.carcass);
    final upperDoor = _rgb(design.upperFinish.door);
    final wtRgb = design.worktopFinish.rgb;
    final worktop =
        wtRgb.isEmpty ? const Color(0xFF26292B) : _rgb(wtRgb);
    final hardware = _rgb(design.hardwareFinish.rgb);
    const steel = Color(0xFFB9BCC0);
    const dark = Color(0xFF17181A);

    // metres -> pixels: elevation is runLength wide x 2.7 m tall + floor strip
    const roomH = 2.70;
    final axisMax = (r.wall == Wall.north || r.wall == Wall.south)
        ? plan.widthM
        : plan.depthM;
    final scale = size.width / axisMax;
    final vScale = (size.height - 12) / roomH;
    double sx(double m) => m * scale;
    double sy(double m) => size.height - 12 - m * vScale; // y up from floor

    Rect box(double u0, double u1, double y0, double y1) =>
        Rect.fromLTRB(sx(u0), sy(y1), sx(u1), sy(y0));

    void fill(Rect rect, Color c) =>
        canvas.drawRect(rect, Paint()..color = c);
    void outline(Rect rect, Color c, [double w = 1]) => canvas.drawRect(
        rect,
        Paint()
          ..color = c
          ..style = PaintingStyle.stroke
          ..strokeWidth = w);

    // wall + floor strip
    fill(Rect.fromLTWH(0, 0, size.width, size.height - 12), wallColor);
    fill(Rect.fromLTWH(0, size.height - 12, size.width, 12), floorColor);
    fill(Rect.fromLTWH(0, size.height - 13, size.width, 1.4),
        _darken(floorColor, 0.7));

    var a = r.a, b = r.b;
    final gapLine = _darken(lower, 0.72);

    // fridge (drawn before trimming the run, mirrors the generator)
    void fridge(double u0, double u1) {
      fill(box(u0, u1, 0, 1.86), steel);
      outline(box(u0, u1, 0, 1.86), _darken(steel, 0.75));
      canvas.drawLine(Offset(sx(u0 + (u1 - u0) * 0.55), sy(1.86)),
          Offset(sx(u0 + (u1 - u0) * 0.55), sy(0.02)),
          Paint()..color = _darken(steel, 0.75));
      fill(box(u0, u1, 1.92, 2.20), upper);
      outline(box(u0, u1, 1.92, 2.20), _darken(upper, 0.8));
    }

    if (r.fridge == 'start') {
      fridge(a, a + 0.70);
      a += 0.80;
    } else if (r.fridge == 'end') {
      fridge(b - 0.70, b);
      b -= 0.80;
    }
    if (b - a < 0.7) return;

    // backsplash band behind counters (0.90 - 1.46)
    fill(box(a, b, 0.90, 1.46), splashColor);
    // subway joint hint
    final joint = Paint()
      ..color = _darken(splashColor, 0.88)
      ..strokeWidth = 0.8;
    for (var y = 1.02; y < 1.46; y += 0.14) {
      canvas.drawLine(Offset(sx(a), sy(y)), Offset(sx(b), sy(y)), joint);
    }

    // windows on this wall
    for (final win in plan.windows.where((w) => w.wall == r.wall)) {
      final wa = win.center - win.width / 2, wb = win.center + win.width / 2;
      fill(box(wa - 0.05, wb + 0.05, 0.95, 1.95), const Color(0xFFF1F0EC));
      fill(box(wa, wb, 1.00, 1.90), const Color(0xFFAEC6D3));
      outline(box(wa, wb, 1.00, 1.90), Colors.white, 2);
    }

    // base cabinets + toe + worktop
    fill(box(a, b, 0.02, 0.10), _darken(lower, 0.35));
    fill(box(a, b, 0.10, 0.86), lower);
    // door bays (mirrors generator bay logic)
    final n = ((b - a) / 0.60).round().clamp(2, 1000);
    final bw = (b - a) / n;
    for (var k = 0; k < n; k++) {
      final ba = a + k * bw + 0.009, bb = a + (k + 1) * bw - 0.009;
      final c = (ba + bb) / 2;
      final isRange = r.rangeAt != null && (c - r.rangeAt!).abs() < 0.42;
      if (isRange) continue;
      fill(box(ba, bb, 0.108, 0.852), lowerDoor);
      outline(box(ba, bb, 0.108, 0.852), gapLine);
      if (design.door == 'shaker') {
        outline(box(ba + 0.065, bb - 0.065, 0.173, 0.787),
            _darken(lowerDoor, 0.82));
      }
      if (design.handle == 'bar') {
        fill(box(c - 0.07, c + 0.07, 0.755, 0.766), hardware);
      } else if (design.handle == 'knob') {
        canvas.drawCircle(Offset(sx(c), sy(0.76)), 2.4,
            Paint()..color = hardware);
      }
    }
    fill(box(a - 0.02, b + 0.02, 0.86, 0.90), worktop);

    // sink + faucet
    if (r.sinkAt != null) {
      final sc = r.sinkAt!;
      fill(box(sc - 0.015, sc + 0.015, 0.90, 1.21), steel);
      fill(box(sc - 0.012, sc + 0.14, 1.185, 1.21), steel);
    }

    // range + hood
    if (r.rangeAt != null) {
      final rc = r.rangeAt!;
      fill(box(rc - 0.372, rc + 0.372, 0.10, 0.86), steel);
      outline(box(rc - 0.372, rc + 0.372, 0.10, 0.86), _darken(steel, 0.75));
      fill(box(rc - 0.33, rc + 0.33, 0.25, 0.55), dark);
      fill(box(rc - 0.36, rc + 0.36, 0.898, 0.914), dark);
      fill(box(rc - 0.43, rc + 0.43, 1.42, 1.52), steel);
      fill(box(rc - 0.21, rc + 0.21, 1.52, roomH), steel);
    }

    // uppers with doors (same span-splitting as the generator)
    if (r.uppers) {
      final skip = <List<double>>[
        if (r.rangeAt != null) [r.rangeAt! - 0.48, r.rangeAt! + 0.48],
        for (final win in plan.windows)
          if (win.wall == r.wall)
            [
              win.center - win.width / 2 - 0.1,
              win.center + win.width / 2 + 0.1
            ],
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
        fill(box(sp[0], sp[1], 1.50, 2.20), upper);
        final nd = ((sp[1] - sp[0]) / 0.55).round().clamp(1, 1000);
        final dw = (sp[1] - sp[0]) / nd;
        for (var k = 0; k < nd; k++) {
          final ba = sp[0] + k * dw + 0.008,
              bb = sp[0] + (k + 1) * dw - 0.008;
          fill(box(ba, bb, 1.508, 2.192), upperDoor);
          outline(box(ba, bb, 1.508, 2.192), _darken(upper, 0.72));
          if (design.door == 'shaker') {
            outline(box(ba + 0.065, bb - 0.065, 1.573, 2.127),
                _darken(upperDoor, 0.82));
          }
          final c = (ba + bb) / 2;
          if (design.handle == 'bar') {
            fill(box(c - 0.07, c + 0.07, 1.554, 1.565), hardware);
          } else if (design.handle == 'knob') {
            canvas.drawCircle(Offset(sx(c), sy(1.558)), 2.4,
                Paint()..color = hardware);
          }
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant KitchenElevationPainter old) =>
      old.design != design || old.plan != plan;
}

/// Top-down plan: floor, runs on their walls, island, windows, appliances.
class KitchenPlanPainter extends CustomPainter {
  KitchenPlanPainter(this.plan, this.design);

  final LayoutPlan plan;
  final KitchenDesign design;

  @override
  void paint(Canvas canvas, Size size) {
    final floorColor = _rgb(design.floorFinish.rgb);
    final lower = _rgb(design.lowerFinish.carcass);
    final island = _rgb(design.islandFinish.carcass);
    final wtRgb = design.worktopFinish.rgb;
    final worktop =
        wtRgb.isEmpty ? const Color(0xFF26292B) : _rgb(wtRgb);
    final islandTopColor =
        wtRgb.isEmpty ? const Color(0xFFE5E3DE) : _rgb(wtRgb);
    const steel = Color(0xFFB9BCC0);
    const dark = Color(0xFF17181A);
    final wallPaint = Paint()
      ..color = Baytak.ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    final w = plan.widthM, d = plan.depthM;
    final scale =
        ((size.width - 16) / w < (size.height - 16) / d)
            ? (size.width - 16) / w
            : (size.height - 16) / d;
    final ox = (size.width - w * scale) / 2;
    final oy = (size.height - d * scale) / 2;
    Offset pt(double x, double z) => Offset(ox + x * scale, oy + z * scale);
    Rect rc(double x0, double z0, double x1, double z1) =>
        Rect.fromPoints(pt(x0, z0), pt(x1, z1));

    void fill(Rect r, Color c) => canvas.drawRect(r, Paint()..color = c);

    // floor + wall outline
    fill(rc(0, 0, w, d), floorColor);
    canvas.drawRect(rc(0, 0, w, d), wallPaint);

    // runs: counter band along the wall, worktop color with cabinet edge
    for (final r in plan.runs) {
      Rect runRect;
      switch (r.wall) {
        case Wall.north:
          runRect = rc(r.a, 0, r.b, 0.62);
        case Wall.south:
          runRect = rc(w - r.b, d - 0.62, w - r.a, d);
        case Wall.west:
          runRect = rc(0, r.a, 0.62, r.b);
        case Wall.east:
          runRect = rc(w - 0.62, d - r.b, w, d - r.a);
      }
      fill(runRect, worktop);
      canvas.drawRect(
          runRect,
          Paint()
            ..color = _darken(lower, 0.6)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);

      // appliances as plan symbols in run-local coords
      void symbolAt(double u, double halfW, Color c) {
        Rect s;
        switch (r.wall) {
          case Wall.north:
            s = rc(u - halfW, 0.06, u + halfW, 0.56);
          case Wall.south:
            s = rc(w - u - halfW, d - 0.56, w - u + halfW, d - 0.06);
          case Wall.west:
            s = rc(0.06, u - halfW, 0.56, u + halfW);
          case Wall.east:
            s = rc(w - 0.56, d - u - halfW, w, d - u + halfW);
        }
        fill(s.deflate(1), c);
      }

      if (r.sinkAt != null) symbolAt(r.sinkAt!, 0.34, steel);
      if (r.rangeAt != null) symbolAt(r.rangeAt!, 0.372, dark);
      if (r.fridge == 'start') symbolAt(r.a + 0.35, 0.35, steel);
      if (r.fridge == 'end') symbolAt(r.b - 0.35, 0.35, steel);
    }

    // windows: white notch on the wall line
    for (final win in plan.windows) {
      final wa = win.center - win.width / 2, wb = win.center + win.width / 2;
      final p = Paint()
        ..color = Colors.white
        ..strokeWidth = 4;
      switch (win.wall) {
        case Wall.north:
          canvas.drawLine(pt(wa, 0), pt(wb, 0), p);
        case Wall.south:
          canvas.drawLine(pt(w - wb, d), pt(w - wa, d), p);
        case Wall.west:
          canvas.drawLine(pt(0, wa), pt(0, wb), p);
        case Wall.east:
          canvas.drawLine(pt(w, d - wb), pt(w, d - wa), p);
      }
    }

    // island: cabinet + top lip + cooktop + seating ticks
    final isl = plan.island;
    if (isl != null) {
      final top = rc(isl.x0 - 0.05, isl.z0 - 0.05, isl.x0 + isl.w + 0.05,
          isl.z0 + isl.d + 0.05);
      fill(top, islandTopColor);
      fill(rc(isl.x0, isl.z0, isl.x0 + isl.w, isl.z0 + isl.d)
          .deflate(scale * 0.06), island);
      canvas.drawRect(
          top,
          Paint()
            ..color = _darken(island, 0.6)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
      if (isl.cooktop) {
        fill(
            rc(isl.x0 + isl.w / 2 - 0.3, isl.z0 + isl.d / 2 - 0.2,
                isl.x0 + isl.w / 2 + 0.3, isl.z0 + isl.d / 2 + 0.2),
            dark);
      }
    }
  }

  @override
  bool shouldRepaint(covariant KitchenPlanPainter old) =>
      old.design != design || old.plan != plan;
}
