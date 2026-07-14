import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../services/photogrammetry_service.dart';
import '../theme.dart';

const _targetShots = 24;

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  CameraController? _controller;
  String? _error;
  final List<XFile> _shots = [];
  bool _busy = false;

  static const _hints = [
    'Keep the whole piece in frame.',
    'Step sideways ~15° between shots.',
    'Hold height steady on the first lap.',
    'Add a few higher, downward angles.',
    'Avoid harsh reflections if you can.',
  ];

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        setState(() => _error = 'No camera available on this device.');
        return;
      }
      final back = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      final ctrl =
          CameraController(back, ResolutionPreset.high, enableAudio: false);
      await ctrl.initialize();
      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      setState(() => _controller = ctrl);
    } on CameraException catch (e) {
      setState(() => _error = e.description ?? e.code);
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> _capture() async {
    final ctrl = _controller;
    if (ctrl == null || _busy || _shots.length >= _targetShots) return;
    setState(() => _busy = true);
    try {
      final shot = await ctrl.takePicture();
      _shots.add(shot);
    } on CameraException catch (e) {
      _snack('Capture failed: ${e.description ?? e.code}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (_shots.length >= _targetShots) _finish();
  }

  Future<void> _finish() async {
    if (_shots.isEmpty) return;
    setState(() => _busy = true);
    final result = await PhotogrammetryService.instance.persist(_shots);
    if (!mounted) return;
    setState(() => _busy = false);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => _ResultSheet(result: result),
    );
    if (mounted) Navigator.of(context).pop();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final hint = _hints[(_shots.length ~/ 5) % _hints.length];

    Widget body;
    if (_error != null) {
      body = _Message(
        icon: Icons.no_photography_outlined,
        title: 'Camera unavailable',
        detail: '$_error\n\nOn a real device, grant camera permission and '
            'reopen this screen. (Emulators often expose no camera.)',
      );
    } else if (_controller == null) {
      body = const Center(
          child: CircularProgressIndicator(color: Baytak.brass));
    } else {
      body = Stack(
        fit: StackFit.expand,
        children: [
          Center(child: CameraPreview(_controller!)),
          // orbit progress ring
          IgnorePointer(
            child: Center(
              child: CustomPaint(
                size: const Size(280, 280),
                painter:
                    _OrbitRingPainter(done: _shots.length, total: _targetShots),
              ),
            ),
          ),
          // top guidance
          Positioned(
            top: 14,
            left: 16,
            right: 16,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'Orbit the piece - ${_shots.length} / $_targetShots\n$hint',
                textAlign: TextAlign.center,
                style: text.bodySmall
                    ?.copyWith(color: Colors.white, height: 1.35),
              ),
            ),
          ),
          // controls
          Positioned(
            bottom: 26,
            left: 0,
            right: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_shots.length >= 8)
                  TextButton(
                    onPressed: _busy ? null : _finish,
                    child: const Text('Finish early',
                        style: TextStyle(color: Colors.white)),
                  ),
                const SizedBox(width: 18),
                GestureDetector(
                  onTap: _capture,
                  child: Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _busy ? Colors.white38 : Colors.white,
                      border: Border.all(color: Baytak.brass, width: 5),
                    ),
                    child: const Icon(Icons.camera_alt_rounded,
                        color: Baytak.ink, size: 30),
                  ),
                ),
                const SizedBox(width: 18),
                const SizedBox(width: 96), // balance the row
              ],
            ),
          ),
        ],
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan furniture'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: body,
    );
  }
}

class _OrbitRingPainter extends CustomPainter {
  _OrbitRingPainter({required this.done, required this.total});
  final int done;
  final int total;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 8;
    for (var i = 0; i < total; i++) {
      final a = -math.pi / 2 + i * 2 * math.pi / total;
      final p1 = center + Offset(math.cos(a), math.sin(a)) * (radius - 12);
      final p2 = center + Offset(math.cos(a), math.sin(a)) * radius;
      final paint = Paint()
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..color = i < done ? Baytak.brass : Colors.white.withOpacity(0.35);
      canvas.drawLine(p1, p2, paint);
    }
  }

  @override
  bool shouldRepaint(_OrbitRingPainter old) =>
      old.done != done || old.total != total;
}

class _ResultSheet extends StatelessWidget {
  const _ResultSheet({required this.result});
  final ScanResult result;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Scan captured - ${result.photoCount} photos',
              style:
                  text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(
            'Saved with a manifest to:\n${result.directory}',
            style: text.bodySmall?.copyWith(
                color: Baytak.ink.withOpacity(0.65), height: 1.4),
          ),
          const SizedBox(height: 12),
          Text(
            'Next step in the pipeline: this photo orbit is exactly the '
            'input a reconstruction backend needs. Wire '
            'PhotogrammetryService to Apple Object Capture (on-device, '
            'iOS 17+) or a cloud photogrammetry API for Android + iOS - '
            'the returned .glb drops straight into the same viewer used '
            'for Kitchen K-01.',
            style: text.bodySmall?.copyWith(
                color: Baytak.ink.withOpacity(0.65), height: 1.45),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(
      {required this.icon, required this.title, required this.detail});
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Colors.white54),
            const SizedBox(height: 14),
            Text(title,
                style: text.titleMedium?.copyWith(
                    color: Colors.white, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(detail,
                textAlign: TextAlign.center,
                style: text.bodySmall
                    ?.copyWith(color: Colors.white70, height: 1.4)),
          ],
        ),
      ),
    );
  }
}
