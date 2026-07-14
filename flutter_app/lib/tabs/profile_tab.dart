import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../screens/blueprint_screen.dart';
import '../screens/room_designer_screen.dart';
import '../screens/scan_screen.dart';
import '../screens/stores_screen.dart';
import '../services/analytics.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/product_cards.dart';

/// Translation of ARoom's ProfileFragment: header + grouped option rows
/// (Settings / Orders / ...). Login/Billing need a backend, so this demo
/// keeps a local profile and adds the Baytak studio tools instead.
class ProfileTab extends StatelessWidget {
  const ProfileTab({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final app = AppScope.of(context);

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(22, 14, 22, 26),
        children: [
          Text('Profile',
              style: Baytak.display(size: 26, weight: FontWeight.w700)),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: Baytak.olive,
                    child: Text(
                      app.userName.isEmpty
                          ? 'G'
                          : app.userName[0].toUpperCase(),
                      style: Baytak.display(
                          size: 22,
                          color: Baytak.sand,
                          weight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(app.userName,
                            style: Baytak.display(
                                size: 18, weight: FontWeight.w700)),
                        Text('Edit personal details',
                            style: text.bodySmall?.copyWith(
                                color: Baytak.ink.withValues(alpha: 0.55))),
                      ],
                    ),
                  ),
                  IconButton(
                      onPressed: () => _editName(context, app),
                      icon: const Icon(Icons.edit_rounded, size: 20)),
                ],
              ),
            ),
          ),

          _Section('ORDERS'),
          _Row(
            icon: Icons.receipt_long_rounded,
            title: 'All orders',
            trailing: '${app.orders.length}',
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const OrdersScreen())),
          ),
          _Row(
            icon: Icons.favorite_rounded,
            title: 'Favorites',
            trailing: '${app.favorites.length}',
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const FavoritesScreen())),
          ),

          _Section('BAYTAK STUDIO'),
          _Row(
            icon: Icons.meeting_room_rounded,
            title: 'Room designer (AI)',
            subtitle: 'Photo -> measured room -> fitting furniture in AR',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const RoomDesignerScreen())),
          ),
          _Row(
            icon: Icons.architecture_rounded,
            title: 'Blueprint studio',
            subtitle: 'Upload a kitchen drawing, generate the 3D model',
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const BlueprintScreen())),
          ),
          _Row(
            icon: Icons.center_focus_strong_rounded,
            title: 'Scan furniture',
            subtitle: 'Guided photo orbit for 3D reconstruction',
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ScanScreen())),
          ),
          _Row(
            icon: Icons.storefront_rounded,
            title: 'Partner stores - Amman',
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const StoresScreen())),
          ),

          _Row(
            icon: Icons.insights_rounded,
            title: 'Store analytics (demo)',
            subtitle: 'Which products customers preview most',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const AnalyticsScreen())),
          ),

          _Section('ABOUT'),
          _Row(
            icon: Icons.info_outline_rounded,
            title: 'Baytak AR - demo build',
            subtitle: 'Version 0.6.0 · catalogue, cart and orders are '
                'stored on this device',
          ),
        ],
      ),
    );
  }

  void _editName(BuildContext context, AppState app) {
    final controller = TextEditingController(text: app.userName);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              app.setName(controller.text);
              Navigator.of(ctx).pop();
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 20, 2, 8),
      child:
          Text(title, style: Baytak.mono(size: 10.5, spacing: 2.0,
              color: Baytak.ink.withValues(alpha: 0.5))),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(
      {required this.icon,
      required this.title,
      this.subtitle,
      this.trailing,
      this.onTap});
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(
              children: [
                Icon(icon, size: 21, color: Baytak.walnut),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: text.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w700)),
                      if (subtitle != null)
                        Text(subtitle!,
                            style: text.bodySmall?.copyWith(
                                color: Baytak.ink.withValues(alpha: 0.55),
                                height: 1.3)),
                    ],
                  ),
                ),
                if (trailing != null)
                  Text(trailing!,
                      style: text.labelLarge?.copyWith(
                          color: Baytak.walnut,
                          fontWeight: FontWeight.w800)),
                if (onTap != null)
                  Icon(Icons.chevron_right_rounded,
                      size: 20, color: Baytak.ink.withValues(alpha: 0.35)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class OrdersScreen extends StatelessWidget {
  const OrdersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final app = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('All orders')),
      body: app.orders.isEmpty
          ? Center(
              child: Text('No orders yet',
                  style: text.bodyMedium?.copyWith(
                      color: Baytak.ink.withValues(alpha: 0.55))))
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 26),
              itemCount: app.orders.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) {
                final o = app.orders[i];
                final d = o.placedAt;
                final items = o.lines.entries
                    .map((e) => '${byId(e.key).title} ×${e.value}')
                    .join(', ');
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(o.id,
                                style: Baytak.mono(
                                    size: 12,
                                    weight: FontWeight.w700)),
                            const Spacer(),
                            Text('${jd(o.total)} JD',
                                style: text.labelLarge?.copyWith(
                                    color: Baytak.walnut,
                                    fontWeight: FontWeight.w800)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                            '${d.day.toString().padLeft(2, '0')}/'
                            '${d.month.toString().padLeft(2, '0')}/'
                            '${d.year} - $items',
                            style: text.bodySmall?.copyWith(
                                color: Baytak.ink.withValues(alpha: 0.6),
                                height: 1.35)),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class FavoritesScreen extends StatelessWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final app = AppScope.of(context);
    final items =
        demoCatalog.where((m) => app.favorites.contains(m.id)).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Favorites')),
      body: items.isEmpty
          ? Center(
              child: Text('Tap the heart on any product to save it here',
                  style: text.bodyMedium?.copyWith(
                      color: Baytak.ink.withValues(alpha: 0.55))))
          : GridView.builder(
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 26),
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
}


class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  Map<String, int> _totals = const {};
  List<MapEntry<String, int>> _ranking = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final details = await AppAnalytics.total('details');
    final viewer = await AppAnalytics.total('viewer');
    final cartN = await AppAnalytics.total('cart');
    final gen = await AppAnalytics.total('generate');
    final rank = await AppAnalytics.productRanking();
    if (!mounted) return;
    setState(() {
      _totals = {
        'Product pages opened': details,
        '3D / AR viewer opened': viewer,
        'Added to cart': cartN,
        'Kitchens generated': gen,
      };
      _ranking = rank;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final maxCount =
        _ranking.isEmpty ? 1 : _ranking.first.value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Store analytics (demo)'),
        actions: [
          IconButton(
            onPressed: () async {
              await AppAnalytics.reset();
              _load();
            },
            icon: const Icon(Icons.restart_alt_rounded),
            tooltip: 'Reset (for demos)',
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Baytak.brass))
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 28),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('This device, all sessions',
                            style: text.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 10),
                        for (final e in _totals.entries)
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                Expanded(
                                    child: Text(e.key,
                                        style: text.bodyMedium)),
                                Text('${e.value}',
                                    style: text.bodyMedium?.copyWith(
                                        color: Baytak.walnut,
                                        fontWeight: FontWeight.w800)),
                              ],
                            ),
                          ),
                        const SizedBox(height: 6),
                        Text(
                          'Demo analytics stored on this device. In '
                          'production these events sync to the '
                          'retailer\'s dashboard.',
                          style: text.bodySmall?.copyWith(
                              color: Baytak.ink.withValues(alpha: 0.5),
                              height: 1.35),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Most previewed products',
                            style: text.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 10),
                        if (_ranking.isEmpty)
                          Text('No product activity yet - browse a few '
                              'pieces and come back.',
                              style: text.bodySmall?.copyWith(
                                  color:
                                      Baytak.ink.withValues(alpha: 0.55)))
                        else
                          for (final e in _ranking)
                            Padding(
                              padding:
                                  const EdgeInsets.only(bottom: 10),
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(byId(e.key).title,
                                            style: text.bodyMedium
                                                ?.copyWith(
                                                    fontWeight:
                                                        FontWeight.w700)),
                                      ),
                                      Text('${e.value}',
                                          style: text.bodyMedium?.copyWith(
                                              color: Baytak.walnut,
                                              fontWeight:
                                                  FontWeight.w800)),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Container(
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: Baytak.sand,
                                      borderRadius:
                                          BorderRadius.circular(6),
                                    ),
                                    child: FractionallySizedBox(
                                      alignment: Alignment.centerLeft,
                                      widthFactor: (e.value / maxCount)
                                          .clamp(0.05, 1.0)
                                          .toDouble(),
                                      child: Container(
                                        decoration: BoxDecoration(
                                          color: Baytak.walnut,
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
