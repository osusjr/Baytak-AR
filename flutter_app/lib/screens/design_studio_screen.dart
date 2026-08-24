import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/analytics.dart';
import '../services/kitchen_design.dart';
import '../services/kitchen_generator.dart';
import '../services/plan_editor.dart';
import '../services/plan_normalizer.dart';
import '../services/saved_designs.dart';
import '../theme.dart';
import '../widgets/iso_kitchen_editor.dart';
import 'design_chat_screen.dart';
import 'photo_render_screen.dart';
import 'product_details_screen.dart';

/// Design studio (b20): the generated kitchen broken into its elements.
/// Two editors in one screen, IKEA-planner style:
///  * LAYOUT - drag the sink, oven and fridge ANYWHERE: chips slide along
///    cabinets live, and dropping on a bare wall creates/extends/splits
///    runs, with the normalizer keeping every drop buildable;
///  * FINISHES - walls, floor, worktops, cabinets, backsplash, handles,
///    hardware, each swappable via swatches.
/// "Build in 3D & AR" re-extrudes the GLB on this phone in milliseconds.
class DesignStudioScreen extends StatefulWidget {
  const DesignStudioScreen({
    super.key,
    required this.plan,
    this.initial,
    this.source = 'your measurements',
    this.freshOrigin = true,
  });

  final LayoutPlan plan;
  final KitchenDesign? initial;
  final String source;

  /// b28: when true (every NEW generation - AI scan, manual measurements,
  /// AI chat, opening a saved design) the incoming plan+design are stored
  /// as THE ORIGINAL, so the "Original" action can always return to the
  /// first generated model without another AI scan. restoreLast() passes
  /// false - reopening yesterday's session must not overwrite its origin.
  final bool freshOrigin;

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
        plan: plan,
        initial: design,
        source: 'the saved plan',
        freshOrigin: false);
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
  late PlanEditor _editor;
  bool _building = false;
  bool _show3d = true; // the 3D layout editor is the headline view
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
    // every plan that reaches the studio is buildable: AI misreads and
    // old persisted plans get their overlaps/walkways fixed up front
    normalizePlan(widget.plan);
    _editor = PlanEditor(widget.plan);
    _persist();
    _saveOrigin();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('kitchen_design_v1', _design.encode());
    await prefs.setString(
        'last_plan_v1', jsonEncode(widget.plan.toJson()));
  }

  /// b28: snapshot the pristine plan+design ONCE per generation, so the
  /// user can always return to the first generated model for free (no
  /// second AI scan - the reported "I have to spend another credit to get
  /// my original back" problem).
  Future<void> _saveOrigin() async {
    final prefs = await SharedPreferences.getInstance();
    if (!widget.freshOrigin && prefs.getString('origin_plan_v1') != null) {
      return; // reopening an old session keeps its original
    }
    await prefs.setString(
        'origin_plan_v1', jsonEncode(widget.plan.toJson()));
    await prefs.setString('origin_design_v1', _design.encode());
  }

  /// b29: pick a photo of the customer's real (empty) room, then paint
  /// THIS design into it with the image AI. The last room photo from the
  /// Room designer is offered as a shortcut.
  Future<void> _photoRender() async {
    final prefs = await SharedPreferences.getInstance();
    final lastRoom = prefs.getString('room_photo');
    final hasLast = lastRoom != null && File(lastRoom).existsSync();
    if (!mounted) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Photo of your empty room',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo now'),
              onTap: () => Navigator.of(ctx).pop('camera'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.of(ctx).pop('gallery'),
            ),
            if (hasLast)
              ListTile(
                leading: const Icon(Icons.history),
                title: const Text('Use my last room photo'),
                onTap: () => Navigator.of(ctx).pop('last'),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    Uint8List bytes;
    try {
      if (choice == 'last') {
        bytes = await File(lastRoom!).readAsBytes();
      } else {
        final picked = await ImagePicker().pickImage(
            source: choice == 'camera'
                ? ImageSource.camera
                : ImageSource.gallery,
            maxWidth: 3200,
            imageQuality: 92);
        if (picked == null) return;
        bytes = await picked.readAsBytes();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not open that: $e')));
      return;
    }
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PhotoRenderScreen(
            plan: widget.plan, design: _design, roomPhoto: bytes)));
  }

  Future<void> _restoreOriginal() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('origin_plan_v1');
    LayoutPlan? plan;
    try {
      if (raw != null) {
        plan = LayoutPlan.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        if (plan.runs.isEmpty) plan = null;
      }
    } catch (_) {
      plan = null;
    }
    if (plan == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No original design stored yet - generate one '
              'from a blueprint or measurements first.')));
      return;
    }
    final design =
        KitchenDesign.tryDecode(prefs.getString('origin_design_v1'));
    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Back to the original?'),
        content: const Text(
            'This restores the first generated layout and finishes. Your '
            'current edits here are replaced (saved designs are kept).'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Keep editing')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Restore original')),
        ],
      ),
    );
    if (go != true || !mounted) return;
    // a fresh screen instead of mutating in place: widthM/depthM are
    // final, and the origin may pre-date this screen's plan object
    Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => DesignStudioScreen(
              plan: plan!,
              initial: design,
              source: 'the original generated design',
              freshOrigin: false,
            )));
  }

  void _update(KitchenDesign next, String element) {
    setState(() => _design = next);
    AppAnalytics.log('design', element);
    _persist();
  }

  void _onPlanEdited(String what) {
    setState(() {}); // painters watch _editor.revision
    AppAnalytics.log('design', what);
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

  // -------------------------------------------------------- quote + save --
  double get _runMetres =>
      widget.plan.runs.fold<double>(0, (a, r) => a + r.length);

  Widget _quoteLine(String label, double amount) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: text.bodySmall
                    ?.copyWith(color: Baytak.ink.withValues(alpha: 0.7))),
          ),
          Text('${amount.round()} JD',
              style:
                  text.bodySmall?.copyWith(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  String _quoteText() {
    final p = widget.plan;
    final runsDesc = p.runs
        .map((r) => '${r.wall.name} ${r.length.toStringAsFixed(1)} m'
            '${r.sinkAt != null ? ' (sink)' : ''}'
            '${r.rangeAt != null ? ' (oven)' : ''}'
            '${r.fridge != null ? ' (fridge)' : ''}')
        .join(', ');
    return 'Baytak kitchen quote\n'
        'Room: ${p.widthM.toStringAsFixed(2)} x '
        '${p.depthM.toStringAsFixed(2)} m\n'
        'Counters: $runsDesc\n'
        '${p.island != null ? 'Island: ${p.island!.w.toStringAsFixed(1)} x ${p.island!.d.toStringAsFixed(1)} m\n' : ''}'
        'Finish: ${_design.describe()}\n'
        'Cabinet runs: ${_runMetres.toStringAsFixed(1)} m x '
        '$kRatePerRunMetre JD = ${(_runMetres * kRatePerRunMetre).round()} JD\n'
        '${p.island != null ? 'Island: $kIslandPrice JD\n' : ''}'
        'Total estimate: ${estimatePrice(p, _design)} JD\n'
        '(Automatic demo estimate - the store issues the final quote.)';
  }

  Future<void> _copyQuote() async {
    await Clipboard.setData(ClipboardData(text: _quoteText()));
    if (!mounted) return;
    AppAnalytics.log('design', 'copy_quote');
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
          content: Text('Quote copied - paste it anywhere')));
  }

  Future<void> _saveDesign() async {
    final ctrl = TextEditingController(
        text: 'Kitchen ${DateTime.now().day}/${DateTime.now().month}');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save this design'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration:
              const InputDecoration(labelText: 'Name (e.g. the customer)'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await SavedDesigns.add(SavedDesign(
      id: 'd${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      savedAt: DateTime.now(),
      plan: widget.plan,
      design: _design,
      priceJd: estimatePrice(widget.plan, _design),
    ));
    if (!mounted) return;
    AppAnalytics.log('design', 'save_design');
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text('"$name" saved - find it in Profile > '
              'Saved designs')));
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
      // 0 - stamp + live preview + drag editor
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('DESIGN STUDIO · $kBuildStamp - RENDER OK',
              style: text.labelSmall?.copyWith(
                  color: Baytak.olive, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('Your kitchen, element by element',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            'Room ${plan.widthM.toStringAsFixed(2)} × '
            '${plan.depthM.toStringAsFixed(2)} m from ${widget.source}. '
            'Drag the round chips to move the sink, oven and fridge; tap '
            'swatches below to restyle - then build in 3D.',
            style: text.bodySmall?.copyWith(
                color: Baytak.ink.withValues(alpha: 0.65), height: 1.4),
          ),
          const SizedBox(height: 12),
          // 3D layout editor / 2D plan toggle (both pure CustomPaint -
          // the one WebView stays full-screen per the device landmines)
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('3D layout')),
              ButtonSegment(value: false, label: Text('2D plan')),
            ],
            selected: {_show3d},
            showSelectedIcon: false,
            style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            onSelectionChanged: (v) => setState(() => _show3d = v.first),
          ),
          const SizedBox(height: 10),
          if (_show3d)
            IsoKitchenEditor(
              plan: plan,
              design: _design,
              editor: _editor,
              onEdited: _onPlanEdited,
            )
          else ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: double.infinity,
                height: 170,
                child: CustomPaint(
                  painter: KitchenElevationPainter(
                      plan, _design, _editor.revision),
                ),
              ),
            ),
            const SizedBox(height: 10),
            _InteractivePlan(
              plan: plan,
              design: _design,
              editor: _editor,
              onEdited: _onPlanEdited,
            ),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.touch_app_rounded,
                  size: 14, color: Baytak.ink.withValues(alpha: 0.45)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _show3d
                      ? 'Drag the S/O/F chips anywhere. Hold a counter or '
                          'the island to move it; tap a counter for resize '
                          'handles, uppers and delete.'
                      : 'S = sink, O = oven, F = fridge. Chips snap to the '
                          'counters with real clearances.',
                  style: text.bodySmall?.copyWith(
                      color: Baytak.ink.withValues(alpha: 0.5),
                      height: 1.3),
                ),
              ),
            ],
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

      // 5 - live quote (itemized - a salesperson can defend every line)
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Estimate',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          _quoteLine(
              'Cabinet runs - ${_runMetres.toStringAsFixed(1)} m '
              'x $kRatePerRunMetre JD',
              _runMetres * kRatePerRunMetre),
          if (plan.island != null)
            _quoteLine(
                'Island ${plan.island!.w.toStringAsFixed(1)} x '
                '${plan.island!.d.toStringAsFixed(1)} m',
                kIslandPrice.toDouble()),
          if (_design.priceFactor != 1.0)
            _quoteLine(
                'Finish level (${worktops[_design.worktop]?.label ?? _design.worktop}) '
                'x${_design.priceFactor.toStringAsFixed(2)}',
                (_runMetres * kRatePerRunMetre +
                        (plan.island != null ? kIslandPrice : 0)) *
                    (_design.priceFactor - 1.0)),
          const Divider(height: 18),
          Row(
            children: [
              Expanded(
                child: Text('Total estimate',
                    style: text.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w800)),
              ),
              Text('${estimatePrice(plan, _design)} JD',
                  style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800, color: Baytak.brass)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Automatic demo estimate from run length and finish - the '
            'store issues the final quote.',
            style: text.bodySmall?.copyWith(
                color: Baytak.ink.withValues(alpha: 0.5), height: 1.3),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _saveDesign,
                  icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                  label: const Text('Save design'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _copyQuote,
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Copy quote'),
                ),
              ),
            ],
          ),
        ],
      ),

      // 6 - build
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('See it in 3D & AR',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            'This phone re-extrudes the whole kitchen with your layout and '
            'finishes in milliseconds - then walk through it at true size '
            'in AR.',
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
          else ...[
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _build,
                child: const Text('Build my kitchen in 3D & AR'),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _photoRender,
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('Photo-render into my room'),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'The 3D model is the accurate one; the photo render is an '
              'AI impression of this design inside a photo of your real '
              'room (one image credit).',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
          ],
        ],
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Design studio'),
        actions: [
          // disabled while building: _build() ends by pushing the
          // details screen and must not land it on top of another route
          IconButton(
            tooltip: 'Chat with the AI designer',
            icon: const Icon(Icons.chat_bubble_outline),
            onPressed: _building
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => DesignChatScreen(
                        seedPlan: widget.plan, seedDesign: _design))),
          ),
          IconButton(
            tooltip: 'Back to the original design',
            icon: const Icon(Icons.settings_backup_restore),
            onPressed: _building ? null : _restoreOriginal,
          ),
        ],
      ),
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
// Shared plan-canvas transform: the painter AND the gesture layer must
// agree pixel-for-pixel on where runs and appliance chips sit.
// ---------------------------------------------------------------------------
class PlanTransform {
  factory PlanTransform(LayoutPlan plan, Size size) {
    final w = plan.widthM, d = plan.depthM;
    final s = math.min((size.width - 16) / w, (size.height - 16) / d);
    return PlanTransform._(
        plan, s, (size.width - w * s) / 2, (size.height - d * s) / 2);
  }

  const PlanTransform._(this.plan, this.scale, this.ox, this.oy);

  final LayoutPlan plan;
  final double scale, ox, oy;

  double get w => plan.widthM;
  double get d => plan.depthM;

  Offset pt(double x, double z) => Offset(ox + x * scale, oy + z * scale);

  (double, double) toPlan(Offset p) =>
      ((p.dx - ox) / scale, (p.dy - oy) / scale);

  /// Canvas centre of the appliance symbol at coordinate [u] along wall
  /// (0.31 m out from the wall - the middle of the counter band).
  /// b20 unified convention: u from the west end (N/S) / north end (E/W).
  Offset wallPoint(Wall wall, double u) {
    switch (wall) {
      case Wall.north:
        return pt(u, 0.31);
      case Wall.south:
        return pt(u, d - 0.31);
      case Wall.west:
        return pt(0.31, u);
      case Wall.east:
        return pt(w - 0.31, u);
    }
  }

  Offset symbolCenter(RunPlan r, double u) => wallPoint(r.wall, u);

  /// For a canvas point: (u along [wall], plan-metre "cost" of how far the
  /// point sits from that wall's counter band). Any spot on the wall is a
  /// valid target now - runs are created/extended by the editor.
  (double, double) wallCoord(Wall wall, Offset p) {
    final (x, z) = toPlan(p);
    double u, off;
    switch (wall) {
      case Wall.north:
        u = x;
        off = z - 0.31;
      case Wall.south:
        u = x;
        off = (d - 0.31) - z;
      case Wall.west:
        u = z;
        off = x - 0.31;
      case Wall.east:
        u = z;
        off = (w - 0.31) - x;
    }
    var cost = math.max(0.0, off.abs() - 0.31);
    // walking off the wall's ends costs too
    final m = (wall == Wall.north || wall == Wall.south) ? w : d;
    if (u < 0) cost += -u;
    if (u > m) cost += u - m;
    return (u, cost);
  }

  /// (u along run [r], cost) - wall distance plus run-extent overshoot.
  (double, double) runCoord(RunPlan r, Offset p) {
    var (u, cost) = wallCoord(r.wall, p);
    if (u < r.a) cost += r.a - u;
    if (u > r.b) cost += u - r.b;
    return (u, cost);
  }

  /// Canvas centre of the drag chip for [kind], or null when absent.
  Offset? chipCenter(PlanEditor editor, ApplianceKind kind) {
    final r = editor.runWith(kind);
    if (r == null) return null;
    final u = editor.positionOf(kind);
    if (u == null) return null;
    return symbolCenter(r, u);
  }
}

/// The draggable 2D plan. A custom recognizer claims the touch ONLY when
/// it starts on an appliance chip, so the page keeps scrolling normally
/// everywhere else on the drawing.
class _InteractivePlan extends StatefulWidget {
  const _InteractivePlan({
    required this.plan,
    required this.design,
    required this.editor,
    required this.onEdited,
  });

  final LayoutPlan plan;
  final KitchenDesign design;
  final PlanEditor editor;
  final void Function(String what) onEdited;

  @override
  State<_InteractivePlan> createState() => _InteractivePlanState();
}

class _InteractivePlanState extends State<_InteractivePlan> {
  static const _grabRadius = 26.0;

  ApplianceKind? _dragging;
  Size _size = Size.zero;

  // live drop target under the finger (any wall - b20 free placement)
  Wall? _targetWall;
  double _targetU = 0;
  bool _targetValid = false;
  Offset? _ghost; // chip follows the finger when off existing cabinets

  ApplianceKind? _hitChip(Offset p) {
    final t = PlanTransform(widget.plan, _size);
    ApplianceKind? best;
    var bestD = _grabRadius;
    for (final kind in ApplianceKind.values) {
      final c = t.chipCenter(widget.editor, kind);
      if (c == null) continue;
      final dist = (c - p).distance;
      if (dist < bestD) {
        best = kind;
        bestD = dist;
      }
    }
    return best;
  }

  void _onStart(DragStartDetails details) {
    final kind = _hitChip(details.localPosition);
    if (kind == null) return;
    setState(() => _dragging = kind);
  }

  void _onUpdate(DragUpdateDetails details) {
    final kind = _dragging;
    if (kind == null) return;
    final t = PlanTransform(widget.plan, _size);

    // nearest wall to the finger - ANY spot on a wall is a target now
    Wall? wall;
    var bestCost = 0.75; // metres - beyond this the drop is ignored
    var bestU = 0.0;
    for (final w in Wall.values) {
      final (u, cost) = t.wallCoord(w, details.localPosition);
      if (cost < bestCost) {
        wall = w;
        bestCost = cost;
        bestU = u;
      }
    }
    _targetWall = wall;
    _targetU = bestU;
    _targetValid = wall != null;

    // live-move while the drop stays on existing cabinets (cheap and
    // reversible); structural edits (new/extended/split runs) happen once,
    // on release, so a drag never litters the plan with fragments.
    var applied = false;
    if (wall != null) {
      for (final r in widget.plan.runs) {
        if (r.wall != wall || bestU < r.a - 0.05 || bestU > r.b + 0.05) {
          continue;
        }
        if (kind == ApplianceKind.fridge) {
          final nearEnd = (bestU - r.a) < PlanEditor.endSnap ||
              (r.b - bestU) < PlanEditor.endSnap;
          if (nearEnd) applied = widget.editor.moveFridge(r, bestU);
        } else {
          applied = widget.editor.moveAppliance(kind, r, bestU);
        }
        break;
      }
    }
    setState(() {
      _ghost = applied ? null : details.localPosition;
    });
  }

  void _onEnd(DragEndDetails details) {
    final kind = _dragging;
    if (kind == null) return;
    final wall = _targetWall;
    if (_targetValid && wall != null) {
      // the structural drop: creates/extends/splits runs + normalizes.
      // checkpoint so the 3D editor's Undo also covers 2D edits.
      widget.editor.checkpoint();
      if (!widget.editor.place(kind, wall, _targetU)) {
        widget.editor.undoDiscardLast();
      }
    }
    setState(() {
      _dragging = null;
      _ghost = null;
      _targetValid = false;
    });
    widget.onEdited('move_${kind.name}');
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: double.infinity,
        height: 235,
        child: LayoutBuilder(builder: (context, constraints) {
          _size = Size(constraints.maxWidth, constraints.maxHeight);
          return RawGestureDetector(
            gestures: {
              _ChipPanRecognizer:
                  GestureRecognizerFactoryWithHandlers<_ChipPanRecognizer>(
                () => _ChipPanRecognizer(
                    () => _size, widget.plan, widget.editor),
                (r) => r
                  ..onStart = _onStart
                  ..onUpdate = _onUpdate
                  ..onEnd = _onEnd,
              ),
            },
            child: CustomPaint(
              painter: KitchenPlanPainter(
                widget.plan,
                widget.design,
                widget.editor.revision,
                editor: widget.editor,
                dragging: _dragging,
                ghost: _ghost,
                ghostWall: _targetValid ? _targetWall : null,
                ghostU: _targetU,
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// Pan recognizer that wins the arena immediately - but only for touches
/// that begin on an appliance chip; everything else stays with the list.
class _ChipPanRecognizer extends PanGestureRecognizer {
  _ChipPanRecognizer(this.sizeOf, this.plan, this.editor);

  final Size Function() sizeOf;
  final LayoutPlan plan;
  final PlanEditor editor;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    final t = PlanTransform(plan, sizeOf());
    for (final kind in ApplianceKind.values) {
      final c = t.chipCenter(editor, kind);
      if (c != null && (c - event.localPosition).distance < 26.0) {
        resolve(GestureDisposition.accepted);
        return;
      }
    }
  }
}

// ---------------------------------------------------------------------------
// 2D preview painters. Both read colors straight from the design and
// geometry straight from the (drag-editable) plan - no WebView involved
// (the one WebView stays full-screen, per the device landmine notes).
// ---------------------------------------------------------------------------
Color _rgb(List<double> c) => Color.fromARGB(
    255, (c[0] * 255).round(), (c[1] * 255).round(), (c[2] * 255).round());

Color _darken(Color c, double f) => Color.fromARGB(255,
    (c.r * 255 * f).round(), (c.g * 255 * f).round(), (c.b * 255 * f).round());

/// Front elevation of the plan's primary run (longest one, prefers the run
/// holding the sink/range) - counters, doors, handles, uppers, appliances.
class KitchenElevationPainter extends CustomPainter {
  KitchenElevationPainter(this.plan, this.design, this.revision);

  final LayoutPlan plan;
  final KitchenDesign design;
  final int revision;

  RunPlan get _primary {
    // the elevation shows a COUNTER run; tall pantries render in 3D/plan
    final counters = plan.runs.where((r) => !r.tall).toList();
    final runs = counters.isEmpty ? [...plan.runs] : counters;
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
    if (plan.runs.isEmpty) return; // all counters deleted - nothing to draw
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
      old.design != design || old.plan != plan || old.revision != revision;
}

/// Top-down plan: floor, runs on their walls, island, windows, appliances -
/// plus the round S/O/F drag chips when an [editor] is attached.
class KitchenPlanPainter extends CustomPainter {
  KitchenPlanPainter(this.plan, this.design, this.revision,
      {this.editor, this.dragging, this.ghost, this.ghostWall, this.ghostU = 0});

  final LayoutPlan plan;
  final KitchenDesign design;
  final int revision;
  final PlanEditor? editor;
  final ApplianceKind? dragging;

  /// While a drag hovers over empty floor/bare wall the chip follows the
  /// finger ([ghost]) and the label previews the landing wall+position.
  final Offset? ghost;
  final Wall? ghostWall;
  final double ghostU;

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

    final t = PlanTransform(plan, size);
    final w = plan.widthM, d = plan.depthM;
    Rect rc(double x0, double z0, double x1, double z1) =>
        Rect.fromPoints(t.pt(x0, z0), t.pt(x1, z1));

    void fill(Rect r, Color c) => canvas.drawRect(r, Paint()..color = c);

    // floor + wall outline
    fill(rc(0, 0, w, d), floorColor);
    canvas.drawRect(rc(0, 0, w, d), wallPaint);

    // runs: counter band along the wall, worktop color with cabinet edge
    // (b20 unified convention: u from west end on N/S, north end on E/W)
    for (final r in plan.runs) {
      Rect runRect;
      switch (r.wall) {
        case Wall.north:
          runRect = rc(r.a, 0, r.b, 0.62);
        case Wall.south:
          runRect = rc(r.a, d - 0.62, r.b, d);
        case Wall.west:
          runRect = rc(0, r.a, 0.62, r.b);
        case Wall.east:
          runRect = rc(w - 0.62, r.a, w, r.b);
      }
      // tall pantry units have no worktop - show them in cabinet colour
      fill(runRect, r.tall ? lower : worktop);
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
            s = rc(u - halfW, d - 0.56, u + halfW, d - 0.06);
          case Wall.west:
            s = rc(0.06, u - halfW, 0.56, u + halfW);
          case Wall.east:
            s = rc(w - 0.56, u - halfW, w, u + halfW);
        }
        fill(s.deflate(1), c);
      }

      if (r.sinkAt != null) symbolAt(r.sinkAt!, 0.34, steel);
      if (r.rangeAt != null) symbolAt(r.rangeAt!, 0.372, dark);
      if (r.fridge == 'start') symbolAt(r.a + 0.4, 0.38, steel);
      if (r.fridge == 'end') symbolAt(r.b - 0.4, 0.38, steel);
    }

    // windows: white notch on the wall line
    for (final win in plan.windows) {
      final wa = win.center - win.width / 2, wb = win.center + win.width / 2;
      final p = Paint()
        ..color = Colors.white
        ..strokeWidth = 4;
      switch (win.wall) {
        case Wall.north:
          canvas.drawLine(t.pt(wa, 0), t.pt(wb, 0), p);
        case Wall.south:
          canvas.drawLine(t.pt(wa, d), t.pt(wb, d), p);
        case Wall.west:
          canvas.drawLine(t.pt(0, wa), t.pt(0, wb), p);
        case Wall.east:
          canvas.drawLine(t.pt(w, wa), t.pt(w, wb), p);
      }
    }

    // island: cabinet + top lip + cooktop
    final isl = plan.island;
    if (isl != null) {
      final top = rc(isl.x0 - 0.05, isl.z0 - 0.05, isl.x0 + isl.w + 0.05,
          isl.z0 + isl.d + 0.05);
      fill(top, islandTopColor);
      fill(rc(isl.x0, isl.z0, isl.x0 + isl.w, isl.z0 + isl.d)
          .deflate(t.scale * 0.06), island);
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

    // --------------------------------------------------------- drag chips
    final ed = editor;
    if (ed == null) return;
    const labels = {
      ApplianceKind.sink: 'S',
      ApplianceKind.range: 'O',
      ApplianceKind.fridge: 'F',
    };
    void chipLabel(Offset c, double radius, String label) {
      final lp = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(
              color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final pos = Offset(
        (c.dx - lp.width / 2)
            .clamp(4.0, size.width - lp.width - 4)
            .toDouble(),
        (c.dy - radius - 24).clamp(4.0, size.height - 18).toDouble(),
      );
      final bg =
          Rect.fromLTWH(pos.dx - 6, pos.dy - 4, lp.width + 12, lp.height + 8);
      canvas.drawRRect(RRect.fromRectAndRadius(bg, const Radius.circular(6)),
          Paint()..color = Baytak.ink.withValues(alpha: 0.85));
      lp.paint(canvas, pos);
    }

    for (final kind in ApplianceKind.values) {
      final active = dragging == kind;
      // while hovering off the cabinets the chip follows the finger
      final c = active && ghost != null ? ghost! : t.chipCenter(ed, kind);
      if (c == null) continue;
      final radius = active ? 17.0 : 14.0;
      canvas.drawCircle(
          c,
          radius + 2,
          Paint()
            ..color = active ? Baytak.brass : Baytak.ink
            ..style = PaintingStyle.stroke
            ..strokeWidth = active ? 3 : 1.6);
      canvas.drawCircle(
          c, radius, Paint()..color = Colors.white.withValues(alpha: 0.94));
      final tp = TextPainter(
        text: TextSpan(
          text: labels[kind],
          style: TextStyle(
            color: active ? Baytak.brass : Baytak.ink,
            fontSize: active ? 15 : 13,
            fontWeight: FontWeight.w800,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));

      // position readout while dragging
      if (!active) continue;
      if (ghost != null && ghostWall != null) {
        // previewing a free drop: cabinets will be added/adjusted here
        chipLabel(c, radius,
            '${ghostU.toStringAsFixed(2)} m on the ${ghostWall!.name} wall');
      } else if (kind != ApplianceKind.fridge) {
        final u = ed.positionOf(kind);
        final r = ed.runWith(kind);
        if (u != null && r != null) {
          chipLabel(c, radius,
              '${(u - r.a).toStringAsFixed(2)} m from ${r.wall.name} run start');
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant KitchenPlanPainter old) =>
      old.design != design ||
      old.plan != plan ||
      old.revision != revision ||
      old.dragging != dragging ||
      old.ghost != ghost;
}
