import 'package:flutter/material.dart';

import '../services/cut_list.dart';
import '../services/kitchen_design.dart';
import '../services/kitchen_generator.dart';
import '../services/kitchen_materials.dart';
import '../theme.dart';

/// Matbakhak b35 - the factory breakdown: every cabinet, every panel,
/// the sheets to buy, the hardware, and the price band. This is step
/// 5-7 of the shop workflow: design agreed -> what it takes to build it.
class BomScreen extends StatelessWidget {
  const BomScreen({super.key, required this.plan, required this.design});

  final LayoutPlan plan;
  final KitchenDesign design;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final bom = buildBom(plan, design);
    final est = priceBom(bom, design);

    // aggregate identical parts for the cutting list
    final grouped = <String, (CutPart, int)>{};
    for (final p in bom.parts) {
      final key = '${p.name}|${p.material}|${p.wMm}x${p.hMm}';
      final cur = grouped[key];
      grouped[key] = (p, (cur?.$2 ?? 0) + p.qty);
    }
    final rows = grouped.values.toList()
      ..sort((x, y) => x.$1.material != y.$1.material
          ? x.$1.material.compareTo(y.$1.material)
          : (y.$1.wMm * y.$1.hMm).compareTo(x.$1.wMm * x.$1.hMm));

    Widget section(String title, List<Widget> children) => Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style:
                        text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                ...children,
              ],
            ),
          ),
        );

    Widget kv(String k, String v, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Expanded(child: Text(k, style: text.bodySmall)),
              Text(v,
                  style: text.bodySmall?.copyWith(
                      fontWeight: bold ? FontWeight.w800 : FontWeight.w600)),
            ],
          ),
        );

    final cabs = bom.cabinetCounts;
    return Scaffold(
      appBar: AppBar(title: const Text('Parts & price')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
        children: [
          Text('PARTS & PRICE · $kBuildStamp - RENDER OK',
              style: text.labelSmall?.copyWith(color: scheme.outline)),
          const SizedBox(height: 8),
          section('Cabinets in this design', [
            for (final e in cabs.entries)
              kv(e.key, '${e.value}x'),
            if (bom.notes.isNotEmpty) const SizedBox(height: 6),
            for (final n in bom.notes)
              Text('• $n',
                  style: text.bodySmall?.copyWith(color: scheme.outline)),
          ]),
          const SizedBox(height: 10),
          section('Boards to buy (standard 2440 x 1220 mm sheets)', [
            for (final e in est.boards.entries)
              kv(sheetStock[e.key]!.label,
                  '${e.value} sheets  (${((est.utilization[e.key] ?? 0) * 100).round()}% used)'),
            kv('Edge banding', '${est.edgingM.toStringAsFixed(0)} m'),
            kv('Worktop', '${bom.worktopM.toStringAsFixed(2)} m'),
            kv('Backsplash', '${bom.splashM2.toStringAsFixed(2)} m²'),
            if (bom.golaM > 0)
              kv('Hidden-handle rail', '${bom.golaM.toStringAsFixed(2)} m'),
          ]),
          const SizedBox(height: 10),
          section('Hardware', [
            kv('Soft-close hinges', '${bom.hardware['hinge']}'),
            kv('Plinth legs', '${bom.hardware['leg']}'),
            if (bom.hardware['bracket']! > 0)
              kv('Hanging brackets', '${bom.hardware['bracket']}'),
            if (bom.hardware['handle']! > 0)
              kv('Handles (${handleStyles[design.handle]})',
                  '${bom.hardware['handle']}'),
            if (bom.hardware['push_catch']! > 0)
              kv('Push-to-open catches', '${bom.hardware['push_catch']}'),
          ]),
          const SizedBox(height: 10),
          section('Cutting list', [
            for (final (p, qty) in rows)
              kv('${p.name} · ${sheetStock[p.material]!.label.split(' ').first}'
                  ' ${p.wMm} × ${p.hMm} mm',
                  '${qty}x'),
          ]),
          const SizedBox(height: 10),
          section('Price estimate', [
            kv('Raw materials & hardware',
                '${est.materialsJd.toStringAsFixed(0)} JOD'),
            kv('Cutting, edging, assembly & installation',
                '× ${manufactureFactor.toStringAsFixed(1)}'),
            const Divider(),
            kv('Estimated total',
                '${est.lowJd.toStringAsFixed(0)} - ${est.highJd.toStringAsFixed(0)} JOD',
                bold: true),
            const SizedBox(height: 6),
            Text(
              'Estimate with a ±${(estimateBand * 100).round()}% band: every '
              'workshop has its own supplier prices and labour rate. The '
              'sheet, hardware and worktop rates are a standard rate card - '
              'calibrate them to your production partner for exact quotes.',
              style: text.bodySmall?.copyWith(color: scheme.outline),
            ),
          ]),
        ],
      ),
    );
  }
}
