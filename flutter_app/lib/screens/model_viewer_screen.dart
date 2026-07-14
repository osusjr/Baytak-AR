import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';

import '../data/catalog.dart';
import '../services/analytics.dart';
import '../theme.dart';

/// Product page: the .glb full-bleed, orbitable, with the AR button
/// provided by <model-viewer>. On ARCore Androids the AR button hands the
/// model to Scene Viewer at true scale; iOS Quick Look additionally needs
/// a .usdz passed via `iosSrc` (one-time conversion - see README "iOS AR").
class ModelViewerScreen extends StatefulWidget {
  const ModelViewerScreen({super.key, required this.model});

  final DemoModel model;

  @override
  State<ModelViewerScreen> createState() => _ModelViewerScreenState();

  /// Branded AR launch button injected into <model-viewer>. It is placed in
  /// the "ar-button" slot, so model-viewer shows it ONLY when the device can
  /// actually do AR (ARCore present) and hides it otherwise.
  static const arButtonHtml = '''
<button slot="ar-button" style="
  position:absolute; top:16px; left:50%; transform:translateX(-50%);
  display:flex; align-items:center; gap:8px;
  background:#1B4F91; color:#fff; border:none; border-radius:999px;
  padding:12px 20px; font:700 14px system-ui,-apple-system,sans-serif;
  letter-spacing:.2px; box-shadow:0 6px 18px rgba(16,35,59,.28);">
  <svg width="16" height="16" viewBox="0 0 24 24" fill="none"
       stroke="white" stroke-width="2" stroke-linejoin="round">
    <path d="M12 2 3 7v10l9 5 9-5V7z"/><path d="M12 22V12"/>
    <path d="M3 7l9 5 9-5"/></svg>
  View in your room
</button>''';

}

class _ModelViewerScreenState extends State<ModelViewerScreen> {
  DemoModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    AppAnalytics.log('viewer', model.id);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Baytak.well,
      body: Stack(
        children: [
          Positioned.fill(
            child: ModelViewer(
              key: ValueKey(model.id),
              src: model.asset,
              alt: '3D model of ${model.title}',
              ar: true,
              arModes: const ['scene-viewer', 'webxr', 'quick-look'],
              arScale: ArScale.fixed, // true size - no accidental scaling
              arPlacement: ArPlacement.floor, // floor only - no wall placement
              // iosSrc: 'https://your.cdn/${model.id}.usdz', // iOS Quick Look
              autoRotate: true,
              cameraControls: true,
              cameraOrbit: model.cameraOrbit,
              shadowIntensity: 1,
              shadowSoftness: 1,
              exposure: 1.0,
              backgroundColor: Baytak.well,
              innerModelViewerHtml: ModelViewerScreen.arButtonHtml,
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  _CircleButton(
                    icon: Icons.arrow_back_rounded,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                        color: Baytak.ink.withValues(alpha: 0.78),
                        borderRadius: BorderRadius.circular(10)),
                    child: Text('DRAG TO ORBIT',
                        style: Baytak.mono(
                            size: 9,
                            color: Baytak.sand,
                            spacing: 1.6)),
                  ),
                ],
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: _ProductPanel(model: model),
          ),
        ],
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.92),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 42,
          height: 42,
          child: Icon(icon, size: 21, color: Baytak.ink),
        ),
      ),
    );
  }
}

class _ProductPanel extends StatelessWidget {
  const _ProductPanel({required this.model});
  final DemoModel model;

  String _jd(int v) {
    final s = v.toString();
    return s.length <= 3
        ? s
        : '${s.substring(0, s.length - 3)},${s.substring(s.length - 3)}';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: const BoxDecoration(
        boxShadow: [
          BoxShadow(
              color: Color(0x1810233B),
              blurRadius: 18,
              offset: Offset(0, -4))
        ],
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                    color: Baytak.ink.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(4)),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(model.title,
                      style: Baytak.display(
                          size: 22, weight: FontWeight.w700)),
                ),
                const SizedBox(width: 12),
                Text('${_jd(model.priceJd)} JD',
                    style: text.titleSmall?.copyWith(
                        color: Baytak.walnut, fontWeight: FontWeight.w800)),
              ],
            ),
            const SizedBox(height: 6),
            Text(model.blurb,
                style: text.bodySmall?.copyWith(
                    color: Baytak.ink.withValues(alpha: 0.62),
                    height: 1.45)),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.straighten_rounded,
                    size: 15, color: Baytak.ink.withValues(alpha: 0.45)),
                const SizedBox(width: 8),
                Text(model.dimsLine,
                    style: Baytak.mono(
                        size: 11.5,
                        color: Baytak.ink.withValues(alpha: 0.7))),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final m in model.materials)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: Baytak.ink.withValues(alpha: 0.12)),
                    ),
                    child: Text(m,
                        style: text.labelSmall?.copyWith(
                            color: Baytak.ink.withValues(alpha: 0.7),
                            fontWeight: FontWeight.w600)),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: const BoxDecoration(
                      color: Baytak.brass, shape: BoxShape.circle),
                  child: const Icon(Icons.view_in_ar_rounded,
                      color: Colors.white, size: 18),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    model.isKitchen
                        ? "Tap 'View in your room' at the top to stand in "
                            "this kitchen at full scale. No button there? "
                            "Install 'Google Play Services for AR' from the "
                            "Play Store, then reopen this page."
                        : "Tap 'View in your room' at the top to place this "
                            "piece at true size. No button there? Install "
                            "'Google Play Services for AR' from the Play "
                            "Store, then reopen this page.",
                    style: text.bodySmall?.copyWith(
                        color: Baytak.ink.withValues(alpha: 0.6),
                        height: 1.35),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
