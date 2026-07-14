import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../screens/product_details_screen.dart';
import '../state/app_state.dart';
import '../theme.dart';

/// Shared grid geometry - loose enough for real font metrics on
/// narrow screens (fixes 'bottom overflowed by N pixels').
const kGridAspect = 0.70;
const kDealRailHeight = 240.0;
const kSpecialRailHeight = 252.0;

void openProduct(BuildContext context, DemoModel m) =>
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ProductDetailsScreen(model: m)));

/// Grid card - translation of ARoom's product_rv_item
/// (image, name + favorite, price) with the Baytak dimension-rule signature.
class ProductCard extends StatelessWidget {
  const ProductCard({super.key, required this.model});
  final DemoModel model;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final app = AppScope.of(context);
    final fav = app.isFav(model.id);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openProduct(context, model),
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
                    top: 6,
                    left: 6,
                    child: IconButton(
                      onPressed: () => app.toggleFav(model.id),
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        fav ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        size: 20,
                        color: fav
                            ? Baytak.walnut
                            : Baytak.ink.withValues(alpha: 0.45),
                      ),
                    ),
                  ),
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
                                color: Baytak.ink.withValues(alpha: 0.6))),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 9),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(model.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Baytak.display(
                            size: 15, weight: FontWeight.w600,
                            height: 1.0)),
                    const SizedBox(height: 2),
                    Text(model.category.label,
                        style: text.labelSmall?.copyWith(
                            color: Baytak.ink.withValues(alpha: 0.5),
                            fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Row(
                      children: [
                        Text('${jd(model.priceJd)} JD',
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

/// Wide rail card - translation of ARoom's special_rv_item
/// (image, name, price, "Add to cart").
class SpecialCard extends StatelessWidget {
  const SpecialCard({super.key, required this.model});
  final DemoModel model;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final app = AppScope.of(context, listen: false);
    return SizedBox(
      width: 296,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openProduct(context, model),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 16 / 9.4,
                child: Image.asset(model.hero ?? model.thumb,
                    fit: BoxFit.cover),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(model.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Baytak.display(
                                  size: 17, weight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text('${jd(model.priceJd)} JD',
                              style: text.labelLarge?.copyWith(
                                  color: Baytak.walnut,
                                  fontWeight: FontWeight.w800)),
                        ],
                      ),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 42),
                          padding:
                              const EdgeInsets.symmetric(horizontal: 14)),
                      onPressed: () {
                        app.addToCart(model.id);
                        ScaffoldMessenger.of(context)
                          ..hideCurrentSnackBar()
                          ..showSnackBar(SnackBar(
                              content:
                                  Text('${model.title} added to cart')));
                      },
                      child: const Text('Add to cart'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Deal rail card - translation of ARoom's best_deals_rv_item
/// (image, name, struck old price, deal price, "See product").
class DealCard extends StatelessWidget {
  const DealCard({super.key, required this.model});
  final DemoModel model;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final deal = model.dealPrice ?? model.priceJd;
    return SizedBox(
      width: 196,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openProduct(context, model),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 1.35,
                child: Image.asset(model.thumb, fit: BoxFit.cover),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 7, 12, 8),
                  child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(model.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Baytak.display(
                            size: 14.5, weight: FontWeight.w600,
                            height: 1.0)),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Text('${jd(model.priceJd)}',
                            style: text.labelSmall?.copyWith(
                                color: Baytak.ink.withValues(alpha: 0.4),
                                decoration: TextDecoration.lineThrough)),
                        const SizedBox(width: 6),
                        Text('${jd(deal)} JD',
                            style: text.labelLarge?.copyWith(
                                color: Baytak.walnut,
                                fontWeight: FontWeight.w800)),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text('See product',
                        style: text.labelSmall?.copyWith(
                            color: Baytak.brass,
                            fontWeight: FontWeight.w700)),
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

/// Section header used across the home rails ("Best deals", ...).
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 10),
      child: Text(title,
          style: Baytak.display(size: 19, weight: FontWeight.w600)),
    );
  }
}
