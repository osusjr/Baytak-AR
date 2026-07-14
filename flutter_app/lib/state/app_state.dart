import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/analytics.dart';

/// A placed demo order (translation of ARoom's Order - no backend).
class DemoOrder {
  DemoOrder({required this.id, required this.placedAt, required this.total,
      required this.lines});

  final String id;
  final DateTime placedAt;
  final int total;
  final Map<String, int> lines; // productId -> qty

  Map<String, dynamic> toJson() => {
        'id': id,
        'at': placedAt.toIso8601String(),
        'total': total,
        'lines': lines,
      };

  static DemoOrder fromJson(Map<String, dynamic> j) => DemoOrder(
        id: j['id'] as String,
        placedAt: DateTime.parse(j['at'] as String),
        total: j['total'] as int,
        lines: Map<String, int>.from(j['lines'] as Map),
      );
}

/// Local store state: cart, favorites, orders, profile name.
/// ARoom keeps this in Firebase; the demo keeps it on-device so the app
/// works offline in a showroom.
class AppState extends ChangeNotifier {
  AppState(this._prefs) {
    _load();
  }

  final SharedPreferences _prefs;

  final Map<String, int> cart = {};
  final Set<String> favorites = {};
  final List<DemoOrder> orders = [];
  String userName = 'Guest';
  bool get onboarded => _prefs.getBool('onboarded') ?? false;

  void _load() {
    try {
      final c = _prefs.getString('cart');
      if (c != null) cart.addAll(Map<String, int>.from(jsonDecode(c) as Map));
      favorites.addAll(_prefs.getStringList('favs') ?? const []);
      final o = _prefs.getString('orders');
      if (o != null) {
        for (final e in (jsonDecode(o) as List)) {
          orders.add(DemoOrder.fromJson(Map<String, dynamic>.from(e as Map)));
        }
      }
      userName = _prefs.getString('name') ?? 'Guest';
    } catch (_) {/* corrupted prefs -> start clean */}
  }

  Future<void> _save() async {
    await _prefs.setString('cart', jsonEncode(cart));
    await _prefs.setStringList('favs', favorites.toList());
    await _prefs.setString(
        'orders', jsonEncode([for (final o in orders) o.toJson()]));
    await _prefs.setString('name', userName);
  }

  // ---- cart ----
  int get cartCount => cart.values.fold(0, (a, b) => a + b);

  void addToCart(String id, [int qty = 1]) {
    AppAnalytics.log('cart', id);
    cart[id] = (cart[id] ?? 0) + qty;
    notifyListeners();
    _save();
  }

  void setQty(String id, int qty) {
    if (qty <= 0) {
      cart.remove(id);
    } else {
      cart[id] = qty;
    }
    notifyListeners();
    _save();
  }

  void clearCart() {
    cart.clear();
    notifyListeners();
    _save();
  }

  // ---- favorites ----
  bool isFav(String id) => favorites.contains(id);

  void toggleFav(String id) {
    favorites.contains(id) ? favorites.remove(id) : favorites.add(id);
    notifyListeners();
    _save();
  }

  // ---- orders ----
  DemoOrder placeOrder(int total) {
    final order = DemoOrder(
      id: 'BA-${DateTime.now().millisecondsSinceEpoch.toString().substring(5)}',
      placedAt: DateTime.now(),
      total: total,
      lines: Map.of(cart),
    );
    orders.insert(0, order);
    cart.clear();
    notifyListeners();
    _save();
    return order;
  }

  // ---- profile ----
  void setName(String name) {
    userName = name.trim().isEmpty ? 'Guest' : name.trim();
    notifyListeners();
    _save();
  }

  Future<void> setOnboarded() => _prefs.setBool('onboarded', true);
}

/// Inherited scope so any widget can read/watch AppState without a package.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
      : super(notifier: state);

  static AppState of(BuildContext context, {bool listen = true}) {
    final scope = listen
        ? context.dependOnInheritedWidgetOfExactType<AppScope>()
        : context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope missing above this context');
    return scope!.notifier!;
  }
}
