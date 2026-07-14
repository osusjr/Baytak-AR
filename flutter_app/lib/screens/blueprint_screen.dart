import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/ai_client.dart';
import '../services/analytics.dart';
import '../services/blueprint_ai.dart';
import '../services/kitchen_generator.dart';
import '../theme.dart';
import 'product_details_screen.dart';

/// Blueprint studio v12: photo -> AI analysis (Anthropic vision API, user's
/// own key) -> LayoutPlan -> on-device generation. Manual measurements
/// remain as the offline path. Production note: shipped apps must proxy
/// API calls through their own backend instead of collecting raw keys.
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

  final _keyCtrl = TextEditingController();
  AiProvider _provider = AiProvider.gemini;
  final Map<AiProvider, String> _keys = {
    AiProvider.gemini: '',
    AiProvider.anthropic: '',
  };
  bool _analyzing = false;
  LayoutPlan? _aiPlan;

  final _wCtrl = TextEditingController(text: '4.20');
  final _dCtrl = TextEditingController(text: '3.40');
  final _iwCtrl = TextEditingController(text: '1.60');
  final _idCtrl = TextEditingController(text: '0.90');
  KitchenLayout _layout = KitchenLayout.lShape;
  bool _island = true;

  static const _stages = [
    'Reading measurements...',
    'Placing runs and appliances...',
    'Extruding cabinetry...',
    'Writing glTF model...',
  ];

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _wCtrl.dispose();
    _dCtrl.dispose();
    _iwCtrl.dispose();
    _idCtrl.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final p = prefs.getString('blueprint_path');
    _keys[AiProvider.gemini] = prefs.getString('gemini_key') ?? '';
    _keys[AiProvider.anthropic] = prefs.getString('anthropic_key') ?? '';
    final prov = prefs.getString('ai_provider');
    if (!mounted) return;
    setState(() {
      if (p != null && File(p).existsSync()) {
        _uploadedPath = p;
        _useUpload = true;
      }
      _provider =
          prov == 'anthropic' ? AiProvider.anthropic : AiProvider.gemini;
      _keyCtrl.text = _keys[_provider]!;
    });
  }

  Future<void> _setProvider(AiProvider p) async {
    _keys[_provider] = _keyCtrl.text.trim();
    setState(() {
      _provider = p;
      _keyCtrl.text = _keys[p]!;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ai_provider', p.name);
  }

  Future<void> _saveKey() async {
    _keys[_provider] = _keyCtrl.text.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gemini_key', _keys[AiProvider.gemini]!);
    await prefs.setString('anthropic_key', _keys[AiProvider.anthropic]!);
    await prefs.setString('ai_provider', _provider.name);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
          const SnackBar(content: Text('Key saved on this device')));
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

  // ------------------------------------------------------------------ AI --
  Future<void> _analyze() async {
    final key = _keyCtrl.text.trim();
    if (_uploadedPath == null || key.isEmpty) return;
    setState(() {
      _analyzing = true;
      _aiPlan = null;
    });
    try {
      final plan = await analyzeBlueprint(File(_uploadedPath!), key, provider: _provider);
      if (!mounted) return;
      setState(() => _aiPlan = plan);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text(
                'AI read ${plan.runs.length} run(s) - review, then generate')));
    } catch (e) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Analysis failed'),
          content: SingleChildScrollView(child: Text('$e')),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Close')),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _analyzing = false);
    }
  }

  Future<void> _designOneTap() async {
    final key = _keyCtrl.text.trim();
    if (_uploadedPath == null || key.isEmpty) return;
    const stages = [
      'Reading the drawing (AI)...',
      'Choosing layout & finish...',
      'Extruding cabinetry...',
      'Writing glTF model...',
    ];
    setState(() {
      _generating = true;
      _aiPlan = null;
    });
    try {
      LayoutPlan? plan;
      GeneratedKitchen? gen;
      for (var i = 0; i < stages.length; i++) {
        if (!mounted) return;
        setState(() => _stage = stages[i]);
        if (i == 0) {
          plan = await analyzeBlueprint(File(_uploadedPath!), key, provider: _provider);
        } else if (i == 2) {
          gen = await generateFromPlan(plan!,
              source: 'AI reading of your blueprint');
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 430));
        }
      }
      if (!mounted) return;
      final p = plan!;
      final g = gen!;
      setState(() {
        _generating = false;
        _stage = null;
        _aiPlan = p;
      });
      AppAnalytics.log('generate');
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text('AI designed it - ${g.triangles} triangles, '
                '${p.palette.replaceAll('_', ' ')} finish')));
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ProductDetailsScreen(model: g.model)));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _generating = false;
        _stage = null;
      });
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('AI design failed'),
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

  Future<void> _run(Future<GeneratedKitchen> Function() job) async {
    setState(() => _generating = true);
    try {
      GeneratedKitchen? gen;
      for (var i = 0; i < _stages.length; i++) {
        if (!mounted) return;
        setState(() => _stage = _stages[i]);
        await Future<void>.delayed(const Duration(milliseconds: 430));
        if (i == 2) gen = await job();
      }
      if (!mounted) return;
      setState(() {
        _generating = false;
        _stage = null;
      });
      AppAnalytics.log('generate');
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text(
                'Generated on this device - ${gen!.triangles} triangles')));
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ProductDetailsScreen(model: gen!.model)));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _generating = false;
        _stage = null;
      });
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Generation failed'),
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
    _run(() => generateKitchen(KitchenSpec(
          widthM: w!,
          depthM: d!,
          layout: _layout,
          island: _island,
          islandWM: iw ?? 1.6,
          islandDM: id ?? 0.9,
        )));
  }

  // --------------------------------------------------------------- build --
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final fileName = _uploadedPath?.split(Platform.pathSeparator).last;
    final keyReady = _keyCtrl.text.trim().isNotEmpty;

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

    Widget providerBtn(AiProvider prov) {
      final selected = _provider == prov;
      return Expanded(
        child: OutlinedButton(
          onPressed: () => _setProvider(prov),
          style: OutlinedButton.styleFrom(
            backgroundColor: selected ? Baytak.ink : Colors.white,
            foregroundColor: selected ? Baytak.sand : Baytak.ink,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          ),
          child: Text(prov.label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12)),
        ),
      );
    }

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
          Text('BLUEPRINT STUDIO v16 - RENDER OK',
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
            'One tap. The AI reads your uploaded drawing - measurements, '
            'layout, appliances - chooses a finish palette to suit it, and '
            'this phone builds the 3D kitchen. Nothing to type.',
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
                onPressed: (_uploadedPath != null && keyReady)
                    ? _designOneTap
                    : null,
                child: const Text('Design my kitchen with AI'),
              ),
            ),
          if (_uploadedPath == null || !keyReady) ...[
            const SizedBox(height: 6),
            Text(
              _uploadedPath == null
                  ? 'Upload a drawing above to enable this.'
                  : 'Add your API key below (AI setup) to enable this.',
              style: text.bodySmall?.copyWith(
                  color: Baytak.ink.withValues(alpha: 0.5)),
            ),
          ],
        ],
      ),

      // 4 - advanced: review the AI plan before generating
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Advanced: review the AI plan first',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            'The AI reads the drawing and returns the layout for the '
            'on-device generator. Pick a provider - the key is yours and '
            'stays on this phone. Needs internet.',
            style: text.bodySmall?.copyWith(
                color: Baytak.ink.withValues(alpha: 0.65), height: 1.4),
          ),
          const SizedBox(height: 10),
          Row(children: [
            providerBtn(AiProvider.gemini),
            const SizedBox(width: 8),
            providerBtn(AiProvider.anthropic),
          ]),
          const SizedBox(height: 6),
          Text(
            _provider == AiProvider.gemini
                ? 'Free key from aistudio.google.com - no card needed. '
                    'Rate-limited, but plenty for demos.'
                : 'Paid key from console.anthropic.com - production '
                    'quality, a few fils per analysis.',
            style: text.bodySmall?.copyWith(
                color: Baytak.ink.withValues(alpha: 0.55), height: 1.35),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _keyCtrl,
                  obscureText: true,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: _provider == AiProvider.gemini
                        ? 'Gemini API key (free)'
                        : 'Anthropic API key',
                    hintText: _provider == AiProvider.gemini
                        ? 'AIza... or AQ...'
                        : 'sk-ant-...',
                    isDense: true,
                    filled: true,
                    fillColor: Baytak.sand,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                  onPressed: keyReady ? _saveKey : null,
                  child: const Text('Save')),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: (_uploadedPath != null && keyReady && !_analyzing)
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
                    : () => _run(() => generateFromPlan(_aiPlan!,
                        source: 'AI analysis of your blueprint')),
                child: const Text('Generate from AI plan'),
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
            'No key or no internet? Type the numbers printed on the '
            'blueprint and generate from them.',
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
                onPressed: _generateManual,
                child: const Text('Generate from measurements'),
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
            'an island or bar - cooktop on the bar included. The on-device '
            'parametric builder then extrudes that plan into one solid '
            'glTF model in milliseconds. Every drawing produces its own '
            'kitchen.',
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
