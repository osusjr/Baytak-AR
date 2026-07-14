import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../tabs/cart_tab.dart';
import '../tabs/home_tab.dart';
import '../tabs/profile_tab.dart';
import '../tabs/search_tab.dart';

/// Translation of ARoom's ShoppingActivity: bottom navigation with
/// Home / Search / Cart / Profile, cart badge included.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context); // rebuilds on cart changes -> badge
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [HomeTab(), SearchTab(), CartTab(), ProfileTab()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          const NavigationDestination(
              icon: Icon(Icons.chair_outlined),
              selectedIcon: Icon(Icons.chair_rounded),
              label: 'Home'),
          const NavigationDestination(
              icon: Icon(Icons.search_rounded), label: 'Search'),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: app.cartCount > 0,
              label: Text('${app.cartCount}'),
              child: const Icon(Icons.shopping_bag_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: app.cartCount > 0,
              label: Text('${app.cartCount}'),
              child: const Icon(Icons.shopping_bag_rounded),
            ),
            label: 'Cart',
          ),
          const NavigationDestination(
              icon: Icon(Icons.person_outline_rounded),
              selectedIcon: Icon(Icons.person_rounded),
              label: 'Profile'),
        ],
      ),
    );
  }
}
