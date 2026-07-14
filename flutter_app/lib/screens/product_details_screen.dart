import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../services/analytics.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'model_viewer_screen.dart';

/// DIAGNOSTIC BUILD (v9): this page is intentionally a structural clone of
/// StoresScreen - the pushed page confirmed to render on the test device -
/// using only the widgets that screen uses (AppBar, ListView.separated,
/// Card, Padding, Text via the standard textTheme, buttons). No images,
/// no display/mono fonts, no bottom bar, no chips. All features preserved.
/// Once this renders, styling is reintroduced stepwise to expose the
/// culprit of the blank-page defect.
class ProductDetailsScreen extends StatefulWidget {
  const ProductDetailsScreen({super.key, required this.model});
  final DemoModel model;

  @override
  State<ProductDetailsScreen> createState() => _ProductDetailsScreenState();
}

class _ProductDetailsScreenState extends State<ProductDetailsScreen> {
  int _qty = 1;

  @override
  void initState() {
    super.initState();
    AppAnalytics.log('details', widget.model.id);
  }

  DemoModel get m => widget.model;

  void _open3d() => Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ModelViewerScreen(model: m)));

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final app = AppScope.of(context);
    final fav = app.isFav(m.id);

    final cards = <Widget>[
      // 0 - diagnostic marker + name/price/dims
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('DETAILS v17 - RENDER OK',
              style: text.labelSmall?.copyWith(
                  color: Baytak.olive, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(m.title,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('${jd(m.priceJd)} JD',
              style: text.titleSmall?.copyWith(
                  color: Baytak.walnut, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(m.dimsLine,
              style: text.bodySmall?.copyWith(
                  color: Baytak.ink.withValues(alpha: 0.6))),
        ],
      ),

      // 1 - 3D / AR
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('See it at true size',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(
            'Opens the live 3D model; the "View in your room" button inside '
            'places it in AR. AR needs Google Play Services for AR '
            '(free, Play Store).',
            style: text.bodySmall?.copyWith(
                color: Baytak.ink.withValues(alpha: 0.65), height: 1.4),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _open3d,
              child: const Text('View in 3D & AR'),
            ),
          ),
        ],
      ),

      // 2 - description
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('About this piece',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(m.description,
              style: text.bodySmall?.copyWith(
                  color: Baytak.ink.withValues(alpha: 0.7), height: 1.45)),
          const SizedBox(height: 8),
          Text('Materials: ${m.materials.join(' · ')}',
              style: text.bodySmall?.copyWith(
                  color: Baytak.ink.withValues(alpha: 0.55))),
        ],
      ),

      // 3 - quantity + add to cart
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Order',
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton(
                onPressed: () =>
                    setState(() => _qty = _qty > 1 ? _qty - 1 : 1),
                child: const Text('-'),
              ),
              SizedBox(
                width: 44,
                child: Center(
                  child: Text('$_qty',
                      style: text.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w800)),
                ),
              ),
              OutlinedButton(
                onPressed: () => setState(() => _qty += 1),
                child: const Text('+'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () {
                AppScope.of(context, listen: false).addToCart(m.id, _qty);
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(
                      content: Text('$_qty × ${m.title} added to cart')));
              },
              child: Text('Add to cart · ${jd(m.priceJd * _qty)} JD'),
            ),
          ),
        ],
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(m.title),
        actions: [
          IconButton(
            onPressed: () => app.toggleFav(m.id),
            icon: Icon(
              fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              color: fav ? Baytak.walnut : Baytak.ink,
            ),
          ),
          const SizedBox(width: 6),
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
