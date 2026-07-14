import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/product_cards.dart';

/// Translation of ARoom's CartFragment: line items with quantity steppers,
/// a total bar, and checkout. ARoom's billing goes to Firebase; here
/// checkout is an explicit DEMO confirmation that records a local order.
class CartTab extends StatelessWidget {
  const CartTab({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final app = AppScope.of(context);
    final ids = app.cart.keys.toList();
    final total = app.cart.entries
        .fold<int>(0, (a, e) => a + byId(e.key).priceJd * e.value);

    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 6),
            child: Text('My cart',
                style: Baytak.display(size: 26, weight: FontWeight.w700)),
          ),
          if (ids.isEmpty)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.shopping_bag_outlined,
                        size: 44,
                        color: Baytak.ink.withValues(alpha: 0.25)),
                    const SizedBox(height: 12),
                    Text('Your shopping cart is empty',
                        style: text.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text('Anything you add appears here.',
                        style: text.bodySmall?.copyWith(
                            color: Baytak.ink.withValues(alpha: 0.55))),
                  ],
                ),
              ),
            )
          else ...[
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(22, 10, 22, 10),
                itemCount: ids.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) =>
                    _CartRow(model: byId(ids[i]), qty: app.cart[ids[i]]!),
              ),
            ),
            _TotalBar(total: total),
          ],
        ],
      ),
    );
  }
}

/// Translation of cart_product_item: thumb, name+price, qty stepper.
class _CartRow extends StatelessWidget {
  const _CartRow({required this.model, required this.qty});
  final DemoModel model;
  final int qty;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final app = AppScope.of(context, listen: false);
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => openProduct(context, model),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.asset(model.thumb,
                    width: 74, height: 74, fit: BoxFit.cover),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(model.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Baytak.display(
                            size: 15.5, weight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text('${jd(model.priceJd)} JD',
                        style: text.labelLarge?.copyWith(
                            color: Baytak.walnut,
                            fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                children: [
                  Row(
                    children: [
                      _StepBtn(
                          icon: Icons.remove_rounded,
                          onTap: () => app.setQty(model.id, qty - 1)),
                      SizedBox(
                        width: 30,
                        child: Center(
                          child: Text('$qty',
                              style: text.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w800)),
                        ),
                      ),
                      _StepBtn(
                          icon: Icons.add_rounded,
                          onTap: () => app.setQty(model.id, qty + 1)),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepBtn extends StatelessWidget {
  const _StepBtn({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Baytak.sand,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
            width: 32,
            height: 32,
            child: Icon(icon, size: 18, color: Baytak.ink)),
      ),
    );
  }
}

class _TotalBar extends StatelessWidget {
  const _TotalBar({required this.total});
  final int total;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 14),
      decoration: const BoxDecoration(
        boxShadow: [
          BoxShadow(
              color: Color(0x1810233B),
              blurRadius: 18,
              offset: Offset(0, -4))
        ],
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Total',
                  style: text.labelSmall?.copyWith(
                      color: Baytak.ink.withValues(alpha: 0.5),
                      fontWeight: FontWeight.w700)),
              Text('${jd(total)} JD',
                  style:
                      Baytak.display(size: 21, weight: FontWeight.w700)),
            ],
          ),
          const Spacer(),
          FilledButton(
            onPressed: () => _checkout(context, total),
            child: const Text('Check out'),
          ),
        ],
      ),
    );
  }

  void _checkout(BuildContext context, int total) {
    final app = AppScope.of(context, listen: false);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final text = Theme.of(ctx).textTheme;
        final lines = app.cart.entries.toList();
        return Padding(
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Order summary',
                  style: Baytak.display(size: 20, weight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('Demo checkout - no payment is taken.',
                  style: text.bodySmall?.copyWith(
                      color: Baytak.ink.withValues(alpha: 0.55))),
              const SizedBox(height: 12),
              for (final e in lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(
                          child: Text('${byId(e.key).title}  ×${e.value}',
                              style: text.bodyMedium)),
                      Text('${jd(byId(e.key).priceJd * e.value)} JD',
                          style: text.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              const Divider(height: 22),
              Row(
                children: [
                  Text('Total',
                      style: text.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w800)),
                  const Spacer(),
                  Text('${jd(total)} JD',
                      style: text.titleSmall?.copyWith(
                          color: Baytak.walnut,
                          fontWeight: FontWeight.w800)),
                ],
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    final order = app.placeOrder(total);
                    Navigator.of(ctx).pop();
                    showDialog<void>(
                      context: context,
                      builder: (dctx) => AlertDialog(
                        icon: const Icon(Icons.check_circle_rounded,
                            color: Baytak.olive, size: 40),
                        title: const Text('Order placed'),
                        content: Text(
                            '${order.id} saved to your orders '
                            '(demo - stored on this device).'),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.of(dctx).pop(),
                              child: const Text('Done')),
                        ],
                      ),
                    );
                  },
                  child: const Text('Place order (demo)'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
