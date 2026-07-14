import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/catalog.dart';
import '../services/ai_client.dart';
import '../services/analytics.dart';
import '../services/kitchen_generator.dart';
import '../services/room_ai.dart';
import '../theme.dart';
import 'blueprint_screen.dart';
import 'model_viewer_screen.dart';
import 'product_details_screen.dart';

/// Room designer (v13): photograph the empty room -> AI estimates its size
/// and picks items from the retailer's catalogue that fit the chosen style
/// -> each pick opens in AR at true scale. Live point-the-camera
/// measurement and whole-set placement arrive with in-app AR (roadmap);
/// this photo flow is the honest, working version of that experience.
class RoomDesignerScreen extends StatefulWidget {
  const RoomDesignerScreen({super.key});

  @override
  State<RoomDesignerScreen> createState() => _RoomDesignerScreenState();
}

class _RoomDesignerScreenState extends State<RoomDesignerScreen> {
  String? _photoPath;
  String _style = 'Modern';
  bool _analyzing = false;
  RoomAnalysis? _result;
  String _apiKey = '';
  AiProvider _provider = AiProvider.gemini;
  bool _building = false;
  String? _buildStage;

  static const _styles = ['Modern', 'Warm & natural', 'Minimal', 'Family'];

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final p = prefs.getString('room_photo');
    final prov = prefs.getString('ai_provider') == 'anthropic'
        ? AiProvider.anthropic
        : AiProvider.gemini;
    final k = prefs.getString(
        prov == AiProvider.gemini ? 'gemini_key' : 'anthropic_key');
    if (!mounted) return;
    setState(() {
      if (p != null && File(p).existsSync()) _photoPath = p;
      _provider = prov;
      _apiKey = (k ?? '').trim();
    });
  }

  Future<void> _pick(ImageSource src) async {
    try {
      final picked = await ImagePicker()
          .pickImage(source: src, maxWidth: 2400, imageQuality: 90);
      if (picked == null) return;
      final dir = await getApplicationDocumentsDirectory();
      final dest = File(
          '${dir.path}/rooms/room_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await dest.parent.create(recursive: true);
      await File(picked.path).copy(dest.path);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('room_photo', dest.path);
      if (!mounted) return;
      setState(() {
        _photoPath = dest.path;
        _result = null;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load that photo: $e')));
    }
  }

  Future<void> _analyze() async {
    if (_photoPath == null || _apiKey.isEmpty) return;
    setState(() {
      _analyzing = true;
      _result = null;
    });
    try {
      final res =
          await analyzeRoom(File(_photoPath!), _apiKey,
              style: _style, provider: _provider);
      if (!mounted) return;
      setState(() => _result = res);
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

  Future<void> _buildScene() async {
    final res = _result;
    if (res == null || !res.hasLayout) return;
    const stages = [
      'Planning the arrangement...',
      'Building the furniture...',
      'Assembling your room...',
      'Writing glTF model...',
    ];
    setState(() => _building = true);
    try {
      GeneratedKitchen? gen;
      for (var i = 0; i < stages.length; i++) {
        if (!mounted) return;
        setState(() => _buildStage = stages[i]);
        await Future<void>.delayed(const Duration(milliseconds: 430));
        if (i == 2) {
          gen = await generateRoomScene(res.toScenePlan(), style: _style);
        }
      }
      if (!mounted) return;
      setState(() {
        _building = false;
        _buildStage = null;
      });
      AppAnalytics.log('room_scene');
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text('Room built on this device - '
                '${gen!.triangles} triangles')));
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ModelViewerScreen(model: gen!.model)));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _building = false;
        _buildStage = null;
      });
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Could not build the room'),
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

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final res = _result;

    final cards = <Widget>[
      // 0 - intro
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('ROOM DESIGNER v16 - RENDER OK',
              style: text.labelSmall?.copyWith(
                  color: Baytak.olive, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('Design a room from one photo',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            'Photograph the empty room. The AI estimates its size, then '
            'suggests pieces from this catalogue that fit - and each one '
            'places in your room in AR at true scale. Photo estimates are '
            'approximate; live AR measurement is the production roadmap.',
            style: text.bodySmall?.copyWith(
                color: Baytak.ink.withValues(alpha: 0.65), height: 1.45),
          ),
        ],
      ),

      // 1 - photo
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Room photo',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          if (_photoPath != null)
            SizedBox(
              height: 220,
              width: double.infinity,
              child: Image.file(
                File(_photoPath!),
                fit: BoxFit.cover,
                cacheWidth: 1200,
                errorBuilder: (_, e, __) => Center(
                    child: Text('Could not display this photo.',
                        style: text.bodySmall)),
              ),
            )
          else
            Text('No photo yet - stand in a corner and capture the room.',
                style: text.bodySmall?.copyWith(
                    color: Baytak.ink.withValues(alpha: 0.55))),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _pick(ImageSource.camera),
                  child: const Text('Photograph room'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _pick(ImageSource.gallery),
                  child: const Text('From gallery'),
                ),
              ),
            ],
          ),
        ],
      ),

      // 2 - style
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Style',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          Row(
            children: [
              for (var i = 0; i < _styles.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => setState(() => _style = _styles[i]),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: _style == _styles[i]
                          ? Baytak.ink
                          : Colors.white,
                      foregroundColor: _style == _styles[i]
                          ? Baytak.sand
                          : Baytak.ink,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 10),
                    ),
                    child: Text(_styles[i],
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 11.5)),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),

      // 3 - analyze
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('AI analysis',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            _apiKey.isEmpty
                ? 'Add an AI key first: Blueprint studio -> AI setup. '
                    'Gemini keys are free (aistudio.google.com). The key '
                    'is shared with this screen.'
                : 'Uses the ${_provider.label} key saved in Blueprint '
                    'studio. Needs internet.',
            style: text.bodySmall?.copyWith(
                color: Baytak.ink.withValues(alpha: 0.65), height: 1.4),
          ),
          const SizedBox(height: 10),
          if (_apiKey.isEmpty)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () async {
                  await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const BlueprintScreen()));
                  _restore(); // key may have been saved there
                },
                child: const Text('Open Blueprint studio to add the key'),
              ),
            )
          else
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed:
                    (_photoPath != null && !_analyzing) ? _analyze : null,
                child: _analyzing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.4, color: Colors.white))
                    : const Text('Measure room & suggest furniture'),
              ),
            ),
        ],
      ),

      // 4 - results
      if (res != null)
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Your ${res.roomType}',
                style:
                    text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(
              'Estimated ${res.widthM.toStringAsFixed(1)} × '
              '${res.depthM.toStringAsFixed(1)} m, ceiling '
              '${res.heightM.toStringAsFixed(1)} m '
              '(${res.confidence} confidence).'
              '${res.observations.isEmpty ? '' : ' ${res.observations}'}',
              style: text.bodySmall?.copyWith(
                  color: Baytak.ink.withValues(alpha: 0.7), height: 1.45),
            ),
            const SizedBox(height: 12),
            if (res.picks.isEmpty)
              Text(
                'Nothing in the catalogue fits this room comfortably - '
                'try another style or a wider photo.',
                style: text.bodySmall?.copyWith(
                    color: Baytak.ink.withValues(alpha: 0.6)),
              )
            else ...[
              for (final p in res.picks) _PickRow(pick: p),
              const Divider(height: 22),
              Row(
                children: [
                  Text('Set total',
                      style: text.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w800)),
                  const Spacer(),
                  Text('${jd(res.totalJd)} JD',
                      style: text.titleSmall?.copyWith(
                          color: Baytak.walnut,
                          fontWeight: FontWeight.w800)),
                ],
              ),
              const SizedBox(height: 12),
              if (res.hasLayout) ...[
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
                        child: Text(_buildStage ?? 'Starting...',
                            style: text.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600)),
                      ),
                    ],
                  )
                else
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _buildScene,
                      child: const Text('Build my redesigned room in 3D'),
                    ),
                  ),
                const SizedBox(height: 6),
                Text(
                  'Assembles the whole arrangement into one model, built '
                  'on this phone - open it in AR to walk the layout at '
                  'true size. Individual pieces also place one at a time '
                  'above.',
                  style: text.bodySmall?.copyWith(
                      color: Baytak.ink.withValues(alpha: 0.5),
                      height: 1.35),
                ),
              ] else
                Text(
                  'Place items one at a time in AR with the buttons above.',
                  style: text.bodySmall?.copyWith(
                      color: Baytak.ink.withValues(alpha: 0.5),
                      height: 1.35),
                ),
            ],
          ],
        ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Room designer')),
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

class _PickRow extends StatelessWidget {
  const _PickRow({required this.pick});
  final RoomPick pick;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final m = pick.model;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset(m.thumb,
                width: 56, height: 56, fit: BoxFit.cover),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${m.title} · ${jd(m.priceJd)} JD',
                    style: text.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w800)),
                if (pick.placement.isNotEmpty || pick.reason.isNotEmpty)
                  Text(
                    [
                      if (pick.placement.isNotEmpty) pick.placement,
                      if (pick.reason.isNotEmpty) pick.reason,
                    ].join(' - '),
                    style: text.bodySmall?.copyWith(
                        color: Baytak.ink.withValues(alpha: 0.6),
                        height: 1.35),
                  ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    OutlinedButton(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) =>
                                  ProductDetailsScreen(model: m))),
                      style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact),
                      child: const Text('Details'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) =>
                                  ModelViewerScreen(model: m))),
                      style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          minimumSize: const Size(0, 40)),
                      child: const Text('View in AR'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
