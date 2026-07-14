import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/ai_client.dart';
import '../services/analytics.dart';
import '../services/blueprint_ai.dart';
import '../services/kitchen_design.dart';
import '../services/kitchen_generator.dart';
import '../theme.dart';
import 'design_studio_screen.dart';

/// Blueprint studio v17: photo -> AI analysis (free NVIDIA-hosted vision
/// models, zero setup in-app) -> LayoutPlan -> the Design studio, where
/// every element (walls, floor, worktops, cabinets, handles) is swappable
/// before the phone extrudes the 3D model. Manual measurements remain as
/// the offline path. Production note: shipped apps proxy AI calls through
/// their own backend - see README "Going to production".
class BlueprintScreen extends StatefulWidget {
  const BlueprintScreen({super.key});

  @override
  State<BlueprintScreen> createState() => _BlueprintScreenState();
}

class _BlueprintScreenState extends State<BlueprintScreen> {
  bool _useUpload = false;
  String? _uploadedPath;
  bool _generating = false;
  String? _stage;

  bool? _aiReady; // null = still checking
  bool _analyzing = false;
  LayoutPlan? _aiPlan;

  final _wCtrl = TextEditingController(text: '4.20');
  final _dCtrl = TextEditingController(text: '3.40');
  final _iwCtrl = TextEditingController(text: '1.60');
  final _idCtrl = TextEditingController(text: '0.90');
  KitchenLayout _layout = KitchenLayout.lShape;
  bool _island = true;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    _wCtrl.dispose();
    _dCtrl.dispose();
    _iwCtrl.dispose();
    _idCtrl.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final p = prefs.getString('blueprint_path');
    final ready = await aiConfigured();
    if (!mounted) return;
    setState(() {
      if (p != null && File(p).existsSync()) {
        _uploadedPath = p;
        _useUpload = true;
      }
      _aiReady = ready;
    });
  }

  Future<void> _pick(ImageSource src) async {
    try {
      final picked = await ImagePicker()
          .pickImage(source: src, maxWidth: 3200, imageQuality: 92);
      if (picked == null) return;
      final dir = await getApplicationDocumentsDirectory();
      final dest = File(
          '${dir.path}/blueprints/upload_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await dest.parent.create(recursive: true);
      await File(picked.path).copy(dest.path);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('blueprint_path', dest.path);
      if (!mounted) return;
      setState(() {
        _uploadedPath = dest.path;
        _useUpload = true;
        _aiPlan = null; // new drawing -> old analysis is stale
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load that image: $e')));
    }
  }

  void _applyDemoValues() {
    _wCtrl.text = '4.20';
    _dCtrl.text = '3.40';
    _iwCtrl.text = '1.60';
    _idCtrl.text = '0.90';
    setState(() {
      _layout = KitchenLayout.lShape;
      _island = true;
      _useUpload = false;
    });
  }

  void _openStudio(LayoutPlan plan, String source) {
    AppAnalytics.log('generate');
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DesignStudioScreen(
              plan: plan,
              initial: KitchenDesign.fromPalette(plan.palette),
              source: source,
            )));
  }

  // ------------------------------------------------------------------ AI --
  Future<void> _analyze() async {
    if (_uploadedPath == null) return;
    setState(() {
      _analyzing = true;
      _aiPlan = null;
    });
    try {
      final plan = await analyzeBlueprint(File(_uploadedPath!));
      if (!mounted) return;
      setState(() => _aiPlan = plan);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text(
                'AI read ${plan.runs.length} run(s) - review, then open '
                'the studio')));
    } catch (e) {
      if (!mounted) return;
      _showError('Analysis failed', e);
    } finally {
      if (mounted) setState(() => _analyzing = false);
    }
  }

  Future<void> _designOneTap() async {
    if (_uploadedPath == null) return;
    const stages = [
      'Reading the drawing (free NVIDIA AI)...',
      'Choosing layout & finish...',
      'Opening the design studio...',
    ];
    setState(() {
      _generating = true;
      _aiPlan = null;
    });
    try {
      LayoutPlan? plan;
      for (var i = 0; i < stages.length; i++) {
        if (!mounted) return;
        setState(() => _stage = stages[i]);
        if (i == 0) {
          plan = await analyzeBlueprint(File(_uploadedPath!));
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 380));
        }
      }
      if (!mounted) return;
      final p = plan!;
      setState(() {
        _generating = false;
        _stage = null;
        _aiPlan = p;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text('AI chose a ${KitchenDesign.presetLabels[p.palette] ?? p.palette} '
                'look - now make it yours')));
      _openStudio(p, 'the AI reading of your blueprint');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _generating = false;
        _stage = null;
      });
      _showError('AI design failed', e);
    }
  }

  void _showError(String title, Object e) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text('$e')),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close')),
        ],
      ),
    );
  }

  String _planText(LayoutPlan p) {
    final b = StringBuffer();
    if (p.summary.isNotEmpty) b.writeln(p.summary);
    b.writeln(
        'Room ${p.widthM.toStringAsFixed(2)} × ${p.depthM.toStringAsFixed(2)} m');
    for (final r in p.runs) {
      final bits = <String>[];
      if (r.sinkAt != null) bits.add('sink');
      if (r.rangeAt != null) bits.add('range');
      if (r.fridge != null) bits.add('fridge');
      if (r.uppers) bits.add('uppers');
      b.writeln('• ${r.wall.name} run '
          '${r.a.toStringAsFixed(1)}-${r.b.toStringAsFixed(1)} m'
          '${bits.isEmpty ? '' : ' (${bits.join(', ')})'}');
    }
    final isl = p.island;
    if (isl != null) {
      b.writeln('• island/bar ${isl.w.toStringAsFixed(1)} × '
          '${isl.d.toStringAsFixed(1)} m, seating ${isl.seating.name}'
          '${isl.cooktop ? ', cooktop' : ''}');
    }
    for (final w in p.windows) {
      b.writeln('• window on ${w.wall.name}, '
          '${w.width.toStringAsFixed(1)} m');
    }
    return b.toString().trimRight();
  }

  // -------------------------------------------------------------- manual --
  double? _parse(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(',', '.'));

  String? _validate(double? w, double? d, double? iw, double? id) {
    if (w == null || d == null) return 'Width and depth must be numbers.';
    if (w < 2.2 || w > 8 || d < 1.8 || d > 8) {
      return 'Room size must be between 2.2 and 8.0 metres per side.';
    }
    switch (_layout) {
      case KitchenLayout.lShape:
        if (w < 2.6 || d < 2.2) {
          return 'An L-shape needs at least 2.6 × 2.2 m.';
        }
      case KitchenLayout.single:
        if (w < 2.6) return 'A single wall needs at least 2.6 m of width.';
      case KitchenLayout.galley:
        if (w < 2.2 || d < 2.4) {
          return 'A galley needs at least 2.2 m width and 2.4 m depth.';
        }
    }
    if (_island) {
      if (iw == null || id == null) {
        return 'Island size must be numbers (or turn the island off).';
      }
      if (iw < 0.9 || iw > w - 1.2 || id < 0.5 || id > d - 2.2) {
        return 'That island does not fit: max '
            '${(w - 1.2).toStringAsFixed(1)} × '
            '${(d - 2.2).toStringAsFixed(1)} m for this room.';
      }
    }
    return null;
  }

  void _generateManual() {
    final w = _parse(_wCtrl), d = _parse(_dCtrl);
    final iw = _parse(_iwCtrl), id = _parse(_idCtrl);
    final err = _validate(w, d, iw, id);
    if (err != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    final plan = KitchenSpec(
      widthM: w!,
      depthM: d!,
      layout: _layout,
      island: _island,
      islandWM: iw ?? 1.6,
      islandDM: id ?? 0.9,
    ).toPlan();
    _openStudio(plan, 'your measurements');
  }

  // --------------------------------------------------------------- build --
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final fileName = _uploadedPath?.split(Platform.pathSeparator).last;
    final aiReady = _aiReady == true;

    Widget numField(TextEditingController c, String label) => TextField(
          controller: c,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: label,
            isDense: true,
            filled: true,
            fillColor: Baytak.sand,
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );

    Widget layoutBtn(KitchenLayout l) {
      final selected = _layout == l;
      return Expanded(
        child: OutlinedButton(
          onPressed: () => setState(() => _layout = l),
          style: OutlinedButton.styleFrom(
            backgroundColor: selected ? Baytak.ink : Colors.white,
            foregroundColor: selected ? Baytak.sand : Baytak.ink,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          ),
          child: Text(l.label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12)),
        ),
      );
    }

    final cards = <Widget>[
      // 0 - source
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('BLUEPRINT STUDIO v17 - RENDER OK',
              style: text.labelSmall?.copyWith(
                  color: Baytak.olive, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('Source drawing',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            _useUpload
                ? (fileName != null
                    ? 'Your blueprint: $fileName'
                    : 'Your blueprint: none uploaded yet.')
                : 'Demo blueprint K-01 - 4.20 × 3.40 m L-shape + island.',
            style: text.bodySmall?.copyWith(
                color: Baytak.ink.withValues(alpha: 0.65), height: 1.4),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _useUpload ? _applyDemoValues : null,
                  child: const Text('Use demo K-01'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: !_useUpload && _uploadedPath != null
                      ? () => setState(() => _useUpload = true)
                      : null,
                  child: const Text('Use my upload'),
                ),
              ),
            ],
          ),
        ],
      ),

      // 1 - preview
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Preview',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          SizedBox(
            height: 250,
            width: double.infinity,
            child: (_useUpload && _uploadedPath != null)
                ? Image.file(
                    File(_uploadedPath!),
                    fit: BoxFit.contain,
                    cacheWidth: 1400,
                    errorBuilder: (_, e, __) => Center(
                        child: Text('Could not display this image.',
                            style: text.bodySmall)),
                  )
                : Image.asset(
                    'assets/blueprints/demo_blueprint.png',
                    fit: BoxFit.contain,
                    errorBuilder: (_, e, __) => Center(
                        child: Text('Could not display the demo drawing.',
                            style: text.bodySmall)),
                  ),
          ),
        ],
      ),

      // 2 - upload
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Bring your kitchen drawing',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text('A photo of a paper plan works too.',
              style: text.bodySmall?.copyWith(
                  color: Baytak.ink.withValues(alpha: 0.6))),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _pick(ImageSource.gallery),
                  child: const Text('From gallery'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _pick(ImageSource.camera),
                  child: const Text('Photograph it'),
                ),
              ),
            ],
          ),
        ],
      ),

      // 3 - one-tap AI design (the headline flow)
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Design my kitchen with AI',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            'One tap. A free NVIDIA-hosted vision model reads your uploaded '
            'drawing - measurements, layout, appliances - picks a starting '
            'look, and the Design studio opens so you can restyle every '
            'element before this phone builds the 3D kitchen. Nothing to '
            'type, no account, no key.',
            style: text.bodySmall?.copyWith(
                color: Baytak.ink.withValues(alpha: 0.65), height: 1.45),
          ),
          const SizedBox(height: 10),
          if (_generating)
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
                onPressed: (_uploadedPath != null && aiReady)
                    ? _designOneTap
                    : null,
                child: const Text('Design my kitchen with AI'),
              ),
            ),
          if (_uploadedPath == null || !aiReady) ...[
            const SizedBox(height: 6),
            Text(
              _uploadedPath == null
                  ? 'Upload a drawing above to enable this.'
                  : (_aiReady == null
                      ? 'Checking AI availability...'
                      : aiNotConfiguredMessage),
              style: text.bodySmall?.copyWith(
                  color: Baytak.ink.withValues(alpha: 0.5), height: 1.35),
            ),
          ],
        ],
      ),

      // 4 - advanced: review the AI plan before opening the studio
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Advanced: review the AI plan first',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            'The AI reads the drawing and returns the layout for the '
            'on-device generator. Runs on free NVIDIA-hosted models '
            '(${aiVisionModels.first} first). Needs internet.',
            style: text.bodySmall?.copyWith(
                color: Baytak.ink.withValues(alpha: 0.65), height: 1.4),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: (_uploadedPath != null && aiReady && !_analyzing)
                  ? _analyze
                  : null,
              child: _analyzing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.4, color: Colors.white))
                  : const Text('Analyze blueprint with AI'),
            ),
          ),
          if (_aiPlan != null) ...[
            const SizedBox(height: 12),
            Text('AI read this layout:',
                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(_planText(_aiPlan!),
                style: text.bodySmall?.copyWith(
                    color: Baytak.ink.withValues(alpha: 0.7), height: 1.5)),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _generating
                    ? null
                    : () => _openStudio(
                        _aiPlan!, 'the AI analysis of your blueprint'),
                child: const Text('Open in Design studio'),
              ),
            ),
          ],
        ],
      ),

      // 5 - manual measurements
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Manual measurements (offline)',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            'No internet? Type the numbers printed on the blueprint - the '
            'Design studio and 3D build run entirely on this phone.',
            style: text.bodySmall?.copyWith(
                color: Baytak.ink.withValues(alpha: 0.65), height: 1.4),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: numField(_wCtrl, 'Width (m)')),
              const SizedBox(width: 10),
              Expanded(child: numField(_dCtrl, 'Depth (m)')),
            ],
          ),
          const SizedBox(height: 12),
          Row(children: [for (final l in KitchenLayout.values) layoutBtn(l)]
              .expand((w) => [w, const SizedBox(width: 8)])
              .toList()
            ..removeLast()),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text('Island / bar counter',
                    style: text.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              Switch(
                value: _island,
                activeTrackColor: Baytak.walnut,
                onChanged: (v) => setState(() => _island = v),
              ),
            ],
          ),
          if (_island)
            Row(
              children: [
                Expanded(child: numField(_iwCtrl, 'Island length (m)')),
                const SizedBox(width: 10),
                Expanded(child: numField(_idCtrl, 'Island depth (m)')),
              ],
            ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _generateManual,
              child: const Text('Open in Design studio'),
            ),
          ),
        ],
      ),

      // 6 - how it works
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('How the pipeline works',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            'The AI (or your typed numbers) produces a layout plan: runs on '
            'any wall with positioned sink, range and fridge, windows, and '
            'an island or bar. The Design studio then breaks that plan into '
            'elements - walls, floor, worktops, upper and lower cabinets, '
            'handles - and the on-device parametric builder extrudes your '
            'exact choices into one solid glTF model in milliseconds.',
            style: text.bodySmall?.copyWith(
                color: Baytak.ink.withValues(alpha: 0.7), height: 1.45),
          ),
        ],
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Blueprint studio')),
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
