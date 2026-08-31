import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../screens/new_kitchen_wizard.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/product_cards.dart';

/// Translation of ARoom's HomeFragment: a category TabLayout + pager.
/// Tab 0 is the MainCategoryFragment (special rail, best deals, grid);
/// the rest are BaseCategoryFragments filtered per category.
class HomeTab extends StatelessWidget {
  const HomeTab({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return DefaultTabController(
      length: 2, // Home + Kitchens (b35: kitchens-only)
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 14, 22, 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text('Matbakhak',
                      style:
                          Baytak.display(size: 26, weight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  Text('مطبخك',
                      style: text.titleSmall?.copyWith(
                          color: Baytak.olive, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Text(kVersionLabel, style: Baytak.mono(color: Baytak.brass)),
                ],
              ),
            ),
            TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                const Tab(text: 'Home'),
                const Tab(text: 'Kitchens'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  const _MainCategoryPage(),
                  const _CategoryPage(category: Cat.kitchens),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Translation of fragment_main_category:
/// special-products rail -> "Best deals" rail -> "Best products" grid.
class _MainCategoryPage extends StatelessWidget {
  const _MainCategoryPage();

  @override
  Widget build(BuildContext context) {
    AppScope.of(context); // rebuild when the cloud catalogue swaps in
    return ListView(
      padding: const EdgeInsets.only(bottom: 26),
      children: [
        const SizedBox(height: 14),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 22),
          child: _WizardHeroCard(),
        ),
        const SizedBox(height: 14),
        SizedBox(
          height: kSpecialRailHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 22),
            itemCount: specialProducts.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (_, i) => SpecialCard(model: specialProducts[i]),
          ),
        ),
        const SectionTitle('Best deals'),
        SizedBox(
          height: kDealRailHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 22),
            itemCount: bestDeals.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (_, i) => DealCard(model: bestDeals[i]),
          ),
        ),
        const SectionTitle('Best products'),
        _grid(demoCatalog),
      ],
    );
  }
}

/// Translation of BaseCategoryFragment (Chair/Table/... pages):
/// an "Offered" rail + the category grid.
class _CategoryPage extends StatelessWidget {
  const _CategoryPage({required this.category});
  final Cat category;

  @override
  Widget build(BuildContext context) {
    AppScope.of(context); // rebuild when the cloud catalogue swaps in
    final items =
        demoCatalog.where((m) => m.category == category).toList();
    return ListView(
      padding: const EdgeInsets.only(bottom: 26),
      children: [
        const SectionTitle('Offered'),
        SizedBox(
          height: kDealRailHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 22),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (_, i) => DealCard(model: items[i]),
          ),
        ),
        SectionTitle(category.label),
        _grid(items),
      ],
    );
  }
}

/// b36 - the shop's front door: straight into the guided wizard where the
/// client watches their kitchen build itself from bare dimensions.
class _WizardHeroCard extends StatelessWidget {
  const _WizardHeroCard();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Baytak.ink, Baytak.walnut],
          ),
        ),
        child: InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const NewKitchenWizardScreen())),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('New kitchen',
                          style: Baytak.display(
                              size: 20,
                              weight: FontWeight.w700,
                              color: Colors.white)),
                      const SizedBox(height: 4),
                      Text(
                        'Slide your room size and watch the kitchen '
                        'build itself - then restyle every finish.',
                        style: text.bodySmall?.copyWith(
                            color: Colors.white.withValues(alpha: 0.85),
                            height: 1.35),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Baytak.brass.withValues(alpha: 0.9),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.auto_awesome,
                      color: Colors.white, size: 22),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget _grid(List<DemoModel> items) {
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 22),
    child: GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: kGridAspect,
      ),
      itemCount: items.length,
      itemBuilder: (_, i) => ProductCard(model: items[i]),
    ),
  );
}
