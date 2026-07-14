import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../theme.dart';
import 'blueprint_screen.dart';
import 'model_viewer_screen.dart';
import 'scan_screen.dart';
import 'stores_screen.dart';

String _jd(int v) {
  final s = v.toString();
  return s.length <= 3 ? s : '${s.substring(0, s.length - 3)},${s.substring(s.length - 3)}';
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Cat? _filter; // null = All

  void _open(DemoModel m) => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => ModelViewerScreen(model: m)));

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final showHero = _filter == null || _filter == Cat.kitchens;
    final items = furnitureCatalog
        .where((m) => _filter == null || m.category == _filter)
        .toList();

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // ---------------- brand + headline ----------------
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SafeArea(
                    bottom: false,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text('Baytak',
                            style: Baytak.display(
                                size: 26, weight: FontWeight.w700)),
                        const SizedBox(width: 8),
                        Text('بيتك',
                            style: text.titleSmall?.copyWith(
                                color: Baytak.olive,
                                fontWeight: FontWeight.w700)),
                        const Spacer(),
                        Text('AR', style: Baytak.mono(color: Baytak.brass)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 26),
                  Text('AMMAN · DEMO CATALOGUE',
                      style: Baytak.mono(color: Baytak.brass, spacing: 2.2)),
                  const SizedBox(height: 10),
                  Text('See it in your room\nbefore you buy.',
                      style:
                          Baytak.display(size: 33, weight: FontWeight.w600)),
                  const SizedBox(height: 10),
                  Text(
                    'Every piece opens in 3D and places in AR at true size - '
                    'and kitchens arrive as one complete model, not one '
                    'cabinet at a time.',
                    style: text.bodyMedium?.copyWith(
                        color: Baytak.ink.withValues(alpha: 0.66),
                        height: 1.45),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _ToolPill(
                          icon: Icons.architecture_rounded,
                          label: 'From blueprint',
                          onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const BlueprintScreen()))),
                      _ToolPill(
                          icon: Icons.center_focus_strong_rounded,
                          label: 'Scan a piece',
                          onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const ScanScreen()))),
                      _ToolPill(
                          icon: Icons.storefront_rounded,
                          label: 'Stores',
                          onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const StoresScreen()))),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // ---------------- category chips ----------------
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 20, 0, 16),
              child: SizedBox(
                height: 38,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  children: [
                    _CatChip(
                        label: 'All',
                        selected: _filter == null,
                        onTap: () => setState(() => _filter = null)),
                    for (final c in Cat.values)
                      _CatChip(
                          label: c.label,
                          selected: _filter == c,
                          onTap: () => setState(() => _filter = c)),
                  ],
                ),
              ),
            ),
          ),

          // ---------------- kitchen hero ----------------
          if (showHero)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 0, 22, 18),
                child: _HeroCard(
                    model: kitchenK01, onTap: () => _open(kitchenK01)),
              ),
            ),

          // ---------------- product grid ----------------
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 8),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: 0.68,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) => _ProductCard(
                    model: items[i], onTap: () => _open(items[i])),
                childCount: items.length,
              ),
            ),
          ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 34),
              child: Center(
                child: Text('DEMO CATALOGUE · PRICES ARE PLACEHOLDERS',
                    style: Baytak.mono(
                        size: 9.5,
                        color: Baytak.ink.withValues(alpha: 0.35),
                        spacing: 1.6)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
class _ToolPill extends StatelessWidget {
  const _ToolPill(
      {required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        backgroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        visualDensity: VisualDensity.compact,
      ),
      icon: Icon(icon, size: 16, color: Baytak.walnut),
      label: Text(label),
    );
  }
}

class _CatChip extends StatelessWidget {
  const _CatChip(
      {required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: selected ? Baytak.ink : Colors.white,
        shape: StadiumBorder(
            side: BorderSide(
                color: selected
                    ? Baytak.ink
                    : Baytak.ink.withValues(alpha: 0.12))),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            child: Text(label,
                style: text.labelMedium?.copyWith(
                    color: selected ? Baytak.sand : Baytak.ink,
                    fontWeight: FontWeight.w700)),
          ),
        ),
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.model, required this.onTap});
  final DemoModel model;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: AspectRatio(
          aspectRatio: 16 / 10.4,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.asset(model.hero ?? model.thumb, fit: BoxFit.cover),
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(18, 44, 18, 16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Baytak.ink.withValues(alpha: 0),
                        Baytak.ink.withValues(alpha: 0.86),
                      ],
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('K-01 · WHOLE-KITCHEN MODEL',
                          style: Baytak.mono(
                              size: 10,
                              color: Baytak.sand.withValues(alpha: 0.85),
                              spacing: 1.8)),
                      const SizedBox(height: 6),
                      Text('Walk through the complete kitchen',
                          style: Baytak.display(
                              size: 21,
                              color: Baytak.sand,
                              weight: FontWeight.w600)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Text('${_jd(model.priceJd)} JD',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(
                                      color: Baytak.sand,
                                      fontWeight: FontWeight.w800)),
                          const Spacer(),
                          Container(
                            width: 38,
                            height: 38,
                            decoration: const BoxDecoration(
                                color: Baytak.brass, shape: BoxShape.circle),
                            child: const Icon(Icons.arrow_forward_rounded,
                                color: Colors.white, size: 20),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.model, required this.onTap});
  final DemoModel model;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(color: Baytak.well),
                  Image.asset(model.thumb, fit: BoxFit.cover),
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 4),
                      decoration: BoxDecoration(
                          color: Baytak.brass,
                          borderRadius: BorderRadius.circular(8)),
                      child: Text('AR',
                          style: Baytak.mono(
                              size: 9,
                              color: Colors.white,
                              weight: FontWeight.w700,
                              spacing: 1.2)),
                    ),
                  ),
                  Positioned(
                    left: 12,
                    bottom: 10,
                    child: Row(
                      children: [
                        Container(
                            width: 20,
                            height: 1.4,
                            color: Baytak.ink.withValues(alpha: 0.45)),
                        const SizedBox(width: 6),
                        Text('W ${model.wCm}',
                            style: Baytak.mono(
                                size: 10,
                                color:
                                    Baytak.ink.withValues(alpha: 0.6))),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(model.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Baytak.display(
                            size: 15.5, weight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(model.category.label,
                        style: text.labelSmall?.copyWith(
                            color: Baytak.ink.withValues(alpha: 0.5),
                            fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Row(
                      children: [
                        Text('${_jd(model.priceJd)} JD',
                            style: text.labelLarge?.copyWith(
                                color: Baytak.walnut,
                                fontWeight: FontWeight.w800)),
                        const Spacer(),
                        Icon(Icons.chevron_right_rounded,
                            size: 20,
                            color: Baytak.ink.withValues(alpha: 0.35)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
