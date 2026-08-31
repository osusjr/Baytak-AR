import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/analytics.dart';
import '../services/auto_planner.dart';
import '../services/kitchen_design.dart';
import '../services/kitchen_generator.dart';
import '../theme.dart';
import '../widgets/iso_kitchen_editor.dart';
import 'design_studio_screen.dart';

/// b36 - the guided "New kitchen" wizard: the shop's front door for a
/// client with an empty room. Steps 1-3 of the A-Z workflow as a show:
/// slide the room size (a live top-down plan designs itself while you
/// slide - the on-device auto-planner, no AI credit), pick a style, then
/// WATCH the kitchen build: floor, walls rising, cabinets extruding one
/// by one - and land in the Design studio with everything editable.
class NewKitchenWizardScreen extends StatefulWidget {
  const NewKitchenWizardScreen({super.key});

  @override
  State<NewKitchenWizardScreen> createState() => _NewKitchenWizardScreenState();
}

class _NewKitchenWizardScreenState extends State<NewKitchenWizardScreen>
    with SingleTickerProviderStateMixin {
  double _w = 4.2, _d = 3.4;
  bool _island = true, _tall = true;
  String _palette = 'surprise';

  bool _building = false;
  bool _opened = false;
  LayoutPlan? _plan;
  KitchenDesign? _design;
  late final AnimationController _anim;
  int _lastPhase = -1;

  static const _presets = [
    ('Apartment', 3.0, 2.4),
    ('Family', 4.2, 3.4),
    ('Villa', 5.6, 4.4),
  ];

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 3800));
    _anim.addListener(_onTick);
    _anim.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        Future.delayed(const Duration(milliseconds: 420), () {
          if (mounted) _openStudio();
        });
      }
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  /// A phase-change haptic makes the build feel physical on the phone.
  void _onTick() {
    final t = _anim.value;
    final phase = t >= 1.0
        ? 3
        : t >= IsoBuildPainter.wallsEnd
            ? 2
            : t >= IsoBuildPainter.floorEnd
                ? 1
                : 0;
    if (phase != _lastPhase) {
      _lastPhase = phase;
      if (phase > 0) HapticFeedback.mediumImpact();
      setState(() {}); // caption swap
    }
  }

  void _startBuild() {
    final palette = _palette == 'surprise'
        ? KitchenDesign.presets.keys
            .elementAt(math.Random().nextInt(KitchenDesign.presets.length))
        : _palette;
    setState(() {
      _plan = autoPlan(_w, _d,
          allowIsland: _island, allowTall: _tall, palette: palette);
      _design = KitchenDesign.fromPalette(palette);
      _building = true;
      _lastPhase = -1;
    });
    HapticFeedback.lightImpact();
    _anim.forward(from: 0);
  }

  void _openStudio() {
    if (_opened || _plan == null) return;
    _opened = true;
    AppAnalytics.log('generate');
    Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => DesignStudioScreen(
              plan: _plan!,
              initial: _design,
              source: 'the wizard - designed on this phone',
            )));
  }

  // --------------------------------------------------------------- build --
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('New kitchen')),
      body: _building ? _buildStage(text) : _formStage(text),
    );
  }

  Widget _formStage(TextTheme text) {
    final preview = autoPlan(_w, _d, allowIsland: _island, allowTall: _tall);
    final layout = preview.summary.split(' - ').first;

    Widget dimRow(String label, double value, double min, double max,
        void Function(double) set) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label,
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
              const Spacer(),
              Text('${value.toStringAsFixed(1)} m',
                  style: Baytak.mono(size: 14, color: Baytak.walnut)),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: ((max - min) * 10).round(),
            activeColor: Baytak.walnut,
            onChanged: (v) =>
                setState(() => set((v * 10).roundToDouble() / 10)),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 28),
      children: [
        Text('NEW KITCHEN · $kBuildStamp - RENDER OK',
            style: text.labelSmall?.copyWith(
                color: Baytak.olive, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('The room',
                    style:
                        text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(
                  'Slide to your wall measurements - the plan below designs '
                  'itself as you slide. On this phone, instantly, no AI '
                  'credit.',
                  style: text.bodySmall?.copyWith(
                      color: Baytak.ink.withValues(alpha: 0.6), height: 1.4),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    for (final (label, pw, pd) in _presets) ...[
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => setState(() {
                            _w = pw;
                            _d = pd;
                          }),
                          style: OutlinedButton.styleFrom(
                            backgroundColor: (_w == pw && _d == pd)
                                ? Baytak.ink
                                : Colors.white,
                            foregroundColor: (_w == pw && _d == pd)
                                ? Baytak.sand
                                : Baytak.ink,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 8),
                          ),
                          child: Text('$label\n$pw × $pd',
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 11.5)),
                        ),
                      ),
                      if (label != _presets.last.$1) const SizedBox(width: 8),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                dimRow('Width (window wall)', _w, 2.2, 8.0, (v) => _w = v),
                dimRow('Depth', _d, 1.8, 8.0, (v) => _d = v),
                Row(
                  children: [
                    Expanded(
                      child: SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('Island',
                            style: text.bodySmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        value: _island,
                        activeTrackColor: Baytak.walnut,
                        onChanged: (v) => setState(() => _island = v),
                      ),
                    ),
                    Expanded(
                      child: SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('Tall pantry',
                            style: text.bodySmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        value: _tall,
                        activeTrackColor: Baytak.walnut,
                        onChanged: (v) => setState(() => _tall = v),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('Your plan',
                        style: text.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    const Spacer(),
                    Text(layout,
                        style: Baytak.mono(size: 11, color: Baytak.brass)),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 190,
                  width: double.infinity,
                  child: CustomPaint(painter: _TopPlanPainter(preview)),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('The look',
                    style:
                        text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Surprise me'),
                      selected: _palette == 'surprise',
                      onSelected: (_) =>
                          setState(() => _palette = 'surprise'),
                    ),
                    for (final e in KitchenDesign.presetLabels.entries)
                      ChoiceChip(
                        label: Text(e.value),
                        selected: _palette == e.key,
                        onSelected: (_) => setState(() => _palette = e.key),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Every finish stays swappable in the Design studio.',
                  style: text.bodySmall?.copyWith(
                      color: Baytak.ink.withValues(alpha: 0.55)),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _startBuild,
            icon: const Icon(Icons.auto_awesome, size: 20),
            label: const Text('Build my kitchen'),
          ),
        ),
      ],
    );
  }

  Widget _buildStage(TextTheme text) {
    final captions = [
      'Laying the floor...',
      'Raising the walls...',
      'Fitting your kitchen...',
      'Done - opening the studio',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('NEW KITCHEN · $kBuildStamp - RENDER OK',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Baytak.olive, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Expanded(
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: SizedBox.expand(
                  child: CustomPaint(
                    painter: IsoBuildPainter(
                        plan: _plan!, design: _design!, progress: _anim),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: _anim.isCompleted
                    ? const Icon(Icons.check_circle,
                        size: 20, color: Baytak.brass)
                    : const CircularProgressIndicator(
                        strokeWidth: 2.4, color: Baytak.brass),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  captions[_lastPhase < 0 ? 0 : _lastPhase],
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              TextButton(
                onPressed: _openStudio,
                child: const Text('Skip'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${_plan!.summary.split(' - ').first} · designed on this phone, '
            'no AI credit used',
            style: text.bodySmall
                ?.copyWith(color: Baytak.ink.withValues(alpha: 0.6)),
          ),
        ],
      ),
    );
  }
}

/// Live top-down preview for the form stage: the room outline with the
/// auto-planned counters, fridge, tall pantry, island and window - redrawn
/// on every slider tick so the plan visibly designs itself.
class _TopPlanPainter extends CustomPainter {
  _TopPlanPainter(this.plan);
  final LayoutPlan plan;

  @override
  void paint(Canvas canvas, Size size) {
    final w = plan.widthM, d = plan.depthM;
    const pad = 14.0;
    final s = math.min((size.width - pad * 2) / w, (size.height - pad * 2) / d);
    final ox = (size.width - w * s) / 2, oy = (size.height - d * s) / 2;
    Rect rect(double x0, double z0, double x1, double z1) =>
        Rect.fromLTRB(ox + x0 * s, oy + z0 * s, ox + x1 * s, oy + z1 * s);

    const ink = Baytak.ink;
    final stroke = Paint()
      ..color = ink.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawRect(rect(0, 0, w, d), Paint()..color = Baytak.sand);
    canvas.drawRect(rect(0, 0, w, d), stroke);

    Rect runRect(RunPlan r, double depth) => switch (r.wall) {
          Wall.north => rect(r.a, 0, r.b, depth),
          Wall.south => rect(r.a, d - depth, r.b, d),
          Wall.west => rect(0, r.a, depth, r.b),
          Wall.east => rect(w - depth, r.a, w, r.b),
        };

    for (final r in plan.runs) {
      final fill = r.tall ? Baytak.basalt : Baytak.walnut.withValues(alpha: 0.8);
      canvas.drawRect(runRect(r, r.tall ? 0.62 : 0.655), Paint()..color = fill);
      if (r.fridge != null) {
        final fa = r.fridge == 'start' ? r.a : r.b - 0.8;
        final fr = switch (r.wall) {
          Wall.north => rect(fa, 0, fa + 0.8, 0.75),
          Wall.south => rect(fa, d - 0.75, fa + 0.8, d),
          Wall.west => rect(0, fa, 0.75, fa + 0.8),
          Wall.east => rect(w - 0.75, fa, w, fa + 0.8),
        };
        canvas.drawRect(fr, Paint()..color = const Color(0xFFB9BCC0));
        canvas.drawRect(fr, stroke);
      }
      void dot(double? u, Color c) {
        if (u == null) return;
        final p = switch (r.wall) {
          Wall.north => Offset(ox + u * s, oy + 0.33 * s),
          Wall.south => Offset(ox + u * s, oy + (d - 0.33) * s),
          Wall.west => Offset(ox + 0.33 * s, oy + u * s),
          Wall.east => Offset(ox + (w - 0.33) * s, oy + u * s),
        };
        canvas.drawCircle(p, math.max(3, 0.16 * s), Paint()..color = c);
      }

      dot(r.sinkAt, const Color(0xFF7FA8C9));
      dot(r.rangeAt, const Color(0xFF17181A));
    }

    final isl = plan.island;
    if (isl != null) {
      final ir = rect(isl.x0, isl.z0, isl.x0 + isl.w, isl.z0 + isl.d);
      canvas.drawRect(ir, Paint()..color = Baytak.brass.withValues(alpha: 0.75));
      canvas.drawRect(ir, stroke);
    }

    // windows as sky-blue wall openings
    final winPaint = Paint()
      ..color = const Color(0xFF9CC4DA)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.butt;
    for (final win in plan.windows) {
      final a = win.center - win.width / 2, b = win.center + win.width / 2;
      final (p, q) = switch (win.wall) {
        Wall.north => (Offset(ox + a * s, oy), Offset(ox + b * s, oy)),
        Wall.south => (
            Offset(ox + a * s, oy + d * s),
            Offset(ox + b * s, oy + d * s)
          ),
        Wall.west => (Offset(ox, oy + a * s), Offset(ox, oy + b * s)),
        Wall.east => (
            Offset(ox + w * s, oy + a * s),
            Offset(ox + w * s, oy + b * s)
          ),
      };
      canvas.drawLine(p, q, winPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _TopPlanPainter old) => true;
}
