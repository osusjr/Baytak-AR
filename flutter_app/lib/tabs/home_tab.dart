import 'package:flutter/material.dart';

import '../data/catalog.dart';
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
      length: 1 + Cat.values.length,
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
                  Text('Baytak',
                      style:
                          Baytak.display(size: 26, weight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  Text('بيتك',
                      style: text.titleSmall?.copyWith(
                          color: Baytak.olive, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Text('AR · v17', style: Baytak.mono(color: Baytak.brass)),
                ],
              ),
            ),
            TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                const Tab(text: 'Home'),
                for (final c in Cat.values) Tab(text: c.label),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  const _MainCategoryPage(),
                  for (final c in Cat.values) _CategoryPage(category: c),
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
