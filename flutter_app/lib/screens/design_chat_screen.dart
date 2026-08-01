import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/ai_client.dart';
import '../services/analytics.dart';
import '../services/design_chat.dart';
import '../services/kitchen_design.dart';
import '../services/kitchen_generator.dart';
import '../theme.dart';
import 'design_studio_screen.dart';

/// b28 AI designer chat. The user talks to the designer, attaches photos
/// (their empty room, materials/colours they like) and every AI answer
/// that carries a plan shows a live top-down preview + "Open in design
/// studio" - where the phone builds the 3D model for free. NO WebView
/// here (one-WebView rule); the preview is a CustomPaint.
class DesignChatScreen extends StatefulWidget {
  const DesignChatScreen({super.key, this.seedPlan, this.seedDesign});

  /// Optional: opened from the Design studio to refine the CURRENT
  /// kitchen - the conversation starts already knowing it.
  final LayoutPlan? seedPlan;
  final KitchenDesign? seedDesign;

  @override
  State<DesignChatScreen> createState() => _DesignChatScreenState();
}

class _Bubble {
  _Bubble.user(this.text, {this.photos = 0})
      : mine = true,
        plan = null,
        design = null,
        answeredBy = null;
  _Bubble.ai(this.text, {this.plan, this.design, this.answeredBy})
      : mine = false,
        photos = 0;

  final bool mine;
  final String text;
  final int photos;
  final LayoutPlan? plan;
  final KitchenDesign? design;
  final String? answeredBy;
}

class _DesignChatScreenState extends State<DesignChatScreen> {
  late final DesignChatSession _session;
  final _bubbles = <_Bubble>[];
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _pending = <XFile>[];
  bool _busy = false;
  bool? _aiReady;

  static const _maxPhotos = 2;

  @override
  void initState() {
    super.initState();
    _session = DesignChatSession(
        plan: widget.seedPlan, design: widget.seedDesign);
    _bubbles.add(_Bubble.ai(widget.seedPlan != null
        ? 'I can see your current kitchen. Tell me what to change - or '
            'send photos of materials and colours you like and I will '
            'match the finishes to them.'
        : 'Ahlan! I design kitchens. Send a photo of your empty room and '
            'type its size (for example "3.2 x 3.8 m"), plus photos of '
            'materials or kitchens you like - and I will design yours. '
            'You can also just describe what you want.'));
    aiConfigured().then((ok) {
      if (mounted) setState(() => _aiReady = ok);
    });
    AppAnalytics.log('design_chat');
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _attach(ImageSource src) async {
    if (_pending.length >= _maxPhotos) return;
    try {
      final picked = await ImagePicker()
          .pickImage(source: src, maxWidth: 3200, imageQuality: 92);
      if (picked == null || !mounted) return;
      setState(() => _pending.add(picked));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not open that: $e')));
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (_busy || (text.isEmpty && _pending.isEmpty)) return;
    final photos = List.of(_pending);
    setState(() {
      _busy = true;
      _bubbles.add(_Bubble.user(
          text.isEmpty ? 'What do you think of these?' : text,
          photos: photos.length));
      _pending.clear();
      _input.clear();
    });
    _autoscroll();
    try {
      final parts = <Map<String, dynamic>>[];
      for (final p in photos) {
        parts.add(await aiImagePart(await p.readAsBytes()));
      }
      final reply = await _session.send(
          text.isEmpty ? 'What do you think of these photos?' : text,
          imageParts: parts);
      if (!mounted) return;
      setState(() => _bubbles.add(_Bubble.ai(reply.reply,
          plan: reply.plan,
          design: reply.design,
          answeredBy: aiLastAnsweredBy)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _bubbles.add(_Bubble.ai('That did not work: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
      _autoscroll();
    }
  }

  void _autoscroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut);
      }
    });
  }

  void _openStudio() {
    final plan = _session.plan;
    if (plan == null) return;
    // the studio mutates its plan in place - hand it a COPY so the chat
    // keeps its own state if the user comes back and keeps talking
    final copy =
        LayoutPlan.fromJson(jsonDecode(jsonEncode(plan.toJson())) as Map<String, dynamic>);
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DesignStudioScreen(
              plan: copy,
              initial: _session.design,
              source: 'your chat with the AI designer',
            )));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('AI designer')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Text(
                'AI DESIGNER · $kBuildStamp - RENDER OK',
                style: text.labelSmall?.copyWith(color: scheme.outline),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
              child: Text(
                'The designer matches your photos to the catalogue finishes '
                'and builds a 3D model on this phone - approximate colours, '
                'not a photo render. Each message uses one AI credit.',
                style: text.bodySmall?.copyWith(color: scheme.outline),
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                itemCount: _bubbles.length + (_busy ? 1 : 0),
                itemBuilder: (_, i) {
                  if (i == _bubbles.length) {
                    return const Padding(
                      padding: EdgeInsets.all(12),
                      child: Row(children: [
                        SizedBox(
                            width: 18,
                            height: 18,
                            child:
                                CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 10),
                        Text('Designing...'),
                      ]),
                    );
                  }
                  return _bubbleWidget(_bubbles[i]);
                },
              ),
            ),
            if (_aiReady == false)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(aiNotConfiguredMessage,
                    style: text.bodySmall?.copyWith(color: scheme.error)),
              ),
            if (_pending.isNotEmpty)
              SizedBox(
                height: 64,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (var i = 0; i < _pending.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Stack(children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(File(_pending[i].path),
                                width: 56, height: 56, fit: BoxFit.cover),
                          ),
                          Positioned(
                            right: 0,
                            top: 0,
                            child: GestureDetector(
                              onTap: () =>
                                  setState(() => _pending.removeAt(i)),
                              child: CircleAvatar(
                                  radius: 9,
                                  backgroundColor: scheme.errorContainer,
                                  child: Icon(Icons.close,
                                      size: 12,
                                      color: scheme.onErrorContainer)),
                            ),
                          ),
                        ]),
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Attach a photo (room or materials)',
                    onPressed: _busy || _pending.length >= _maxPhotos
                        ? null
                        : () => _attach(ImageSource.gallery),
                    icon: const Icon(Icons.photo_library_outlined),
                  ),
                  IconButton(
                    tooltip: 'Take a photo',
                    onPressed: _busy || _pending.length >= _maxPhotos
                        ? null
                        : () => _attach(ImageSource.camera),
                    icon: const Icon(Icons.photo_camera_outlined),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        hintText: 'Describe your kitchen...',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(
                    tooltip: 'Send',
                    onPressed: _busy || _aiReady == false ? null : _send,
                    icon: const Icon(Icons.arrow_upward),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bubbleWidget(_Bubble b) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final bg = b.mine ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final fg = b.mine ? scheme.onPrimaryContainer : scheme.onSurface;
    return Align(
      alignment: b.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.82),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (b.photos > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('📷 ${b.photos} photo(s) attached',
                    style: text.labelSmall?.copyWith(color: fg)),
              ),
            Text(b.text, style: text.bodyMedium?.copyWith(color: fg)),
            if (b.plan != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  height: 130,
                  width: 220,
                  child: CustomPaint(
                    painter: _MiniPlanPainter(b.plan!, scheme),
                  ),
                ),
              ),
            ],
            if (b.plan != null || b.design != null) ...[
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: _openStudio,
                icon: const Icon(Icons.view_in_ar, size: 18),
                label: const Text('Open in design studio'),
              ),
            ],
            if (b.answeredBy != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('answered by ${b.answeredBy}',
                    style: text.labelSmall?.copyWith(color: scheme.outline)),
              ),
          ],
        ),
      ),
    );
  }
}

/// Compact top-down preview of a LayoutPlan: room outline, cabinet runs
/// (fridge slot darker), island. Enough to see WHERE everything is before
/// opening the studio - the studio's editors stay the real views.
class _MiniPlanPainter extends CustomPainter {
  _MiniPlanPainter(this.plan, this.scheme);

  final LayoutPlan plan;
  final ColorScheme scheme;

  static const _counterD = 0.655;
  static const _fridgeD = 0.75;
  static const _fridgeSpan = 0.8;

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 8.0;
    final sx = (size.width - pad * 2) / plan.widthM;
    final sy = (size.height - pad * 2) / plan.depthM;
    final s = sx < sy ? sx : sy;
    final ox = (size.width - plan.widthM * s) / 2;
    final oy = (size.height - plan.depthM * s) / 2;
    Rect world(double x0, double z0, double x1, double z1) =>
        Rect.fromLTRB(ox + x0 * s, oy + z0 * s, ox + x1 * s, oy + z1 * s);

    canvas.drawRect(
        world(0, 0, plan.widthM, plan.depthM),
        Paint()
          ..style = PaintingStyle.fill
          ..color = scheme.surface);
    canvas.drawRect(
        world(0, 0, plan.widthM, plan.depthM),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = scheme.outline);

    final runPaint = Paint()..color = scheme.primary.withValues(alpha: 0.65);
    final fridgePaint = Paint()..color = scheme.tertiary;
    for (final r in plan.runs) {
      final depth = r.fridge != null ? _fridgeD : _counterD;
      final rect = switch (r.wall) {
        Wall.north => world(r.a, 0, r.b, depth),
        Wall.south => world(r.a, plan.depthM - depth, r.b, plan.depthM),
        Wall.west => world(0, r.a, depth, r.b),
        Wall.east => world(plan.widthM - depth, r.a, plan.widthM, r.b),
      };
      canvas.drawRect(rect, runPaint);
      if (r.fridge != null) {
        final fa = r.fridge == 'start' ? r.a : r.b - _fridgeSpan;
        final fb = r.fridge == 'start' ? r.a + _fridgeSpan : r.b;
        final fr = switch (r.wall) {
          Wall.north => world(fa, 0, fb, _fridgeD),
          Wall.south => world(fa, plan.depthM - _fridgeD, fb, plan.depthM),
          Wall.west => world(0, fa, _fridgeD, fb),
          Wall.east => world(plan.widthM - _fridgeD, fa, plan.widthM, fb),
        };
        canvas.drawRect(fr, fridgePaint);
      }
    }
    final isl = plan.island;
    if (isl != null) {
      canvas.drawRect(
          world(isl.x0, isl.z0, isl.x0 + isl.w, isl.z0 + isl.d),
          Paint()..color = scheme.secondary.withValues(alpha: 0.7));
    }
  }

  @override
  bool shouldRepaint(_MiniPlanPainter old) =>
      old.plan != plan || old.scheme != scheme;
}
