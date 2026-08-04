import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/ai_client.dart';
import '../services/analytics.dart';
import '../services/kitchen_design.dart';
import '../services/kitchen_generator.dart';
import '../services/photo_render.dart';
import '../theme.dart';

/// b29: shows the AI photo render of the designed kitchen inside the
/// customer's own room photo. Honesty rule, stated on-screen: this is an
/// AI impression for inspiration - the 3D model and the quote are the
/// accurate reference. NO WebView (one-WebView rule).
class PhotoRenderScreen extends StatefulWidget {
  const PhotoRenderScreen({
    super.key,
    required this.plan,
    required this.design,
    required this.roomPhoto,
  });

  final LayoutPlan plan;
  final KitchenDesign design;
  final Uint8List roomPhoto;

  @override
  State<PhotoRenderScreen> createState() => _PhotoRenderScreenState();
}

class _PhotoRenderScreenState extends State<PhotoRenderScreen> {
  Uint8List? _result;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _render();
  }

  Future<void> _render() async {
    setState(() {
      _result = null;
      _error = null;
    });
    try {
      final img = await renderKitchenIntoPhoto(
        plan: widget.plan,
        design: widget.design,
        roomPhotoBytes: widget.roomPhoto,
      );
      if (!mounted) return;
      AppAnalytics.log('photo_render');
      setState(() => _result = img);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _save() async {
    final img = _result;
    if (img == null || _saving) return;
    setState(() => _saving = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(
          '${dir.path}/renders/render_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(img);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved to ${file.path}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final by = aiLastAnsweredBy;
    return Scaffold(
      appBar: AppBar(title: const Text('Photo render')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Text('PHOTO RENDER · $kBuildStamp - RENDER OK',
                style: text.labelSmall?.copyWith(color: scheme.outline)),
            const SizedBox(height: 10),
            if (_result == null && _error == null) ...[
              const SizedBox(height: 60),
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  'Painting your kitchen into the photo...\n'
                  'This takes up to a minute.',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium,
                ),
              ),
            ] else if (_error != null) ...[
              const SizedBox(height: 24),
              Text('The render failed', style: text.titleMedium),
              const SizedBox(height: 8),
              Text(_error!, style: text.bodySmall),
              const SizedBox(height: 16),
              FilledButton(
                  onPressed: _render, child: const Text('Try again')),
            ] else ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(_result!, fit: BoxFit.contain),
              ),
              const SizedBox(height: 10),
              Text(
                'AI impression for inspiration - colours and proportions '
                'are approximate, not to scale. Your 3D model and the '
                'itemized quote are the accurate reference.'
                '${by == null ? '' : '\nRendered by $by.'}',
                style: text.bodySmall?.copyWith(color: scheme.outline),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _saving ? null : _save,
                      icon: const Icon(Icons.save_alt, size: 18),
                      label: Text(_saving ? 'Saving...' : 'Save picture'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _render,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Render again'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Each render uses one image credit.',
                style: text.labelSmall?.copyWith(color: scheme.outline),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
