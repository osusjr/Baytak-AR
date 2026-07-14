import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// On-device demo analytics: counts product interest events locally so the
/// retailer pitch can show "which products customers preview and place
/// most". Production version syncs these events to the retailer's backend;
/// the schema here (event kind + product id + count) is exactly what that
/// sync would carry.
class AppAnalytics {
  static const _key = 'analytics_v1';

  /// kinds: 'details' (product page opened), 'viewer' (3D/AR viewer
  /// opened), 'cart' (added to cart), 'generate' (kitchen generated)
  static Future<void> log(String kind, [String? productId]) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      final map = raw == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final k = productId == null ? kind : '$kind:$productId';
      map[k] = ((map[k] as int?) ?? 0) + 1;
      await prefs.setString(_key, jsonEncode(map));
    } catch (_) {/* analytics must never break the app */}
  }

  static Future<Map<String, int>> snapshot() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return {};
      return Map<String, dynamic>.from(jsonDecode(raw) as Map)
          .map((k, v) => MapEntry(k, (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  /// Per-product interest = details opens + viewer opens, ranked desc.
  static Future<List<MapEntry<String, int>>> productRanking() async {
    final snap = await snapshot();
    final per = <String, int>{};
    snap.forEach((k, v) {
      final parts = k.split(':');
      if (parts.length == 2 &&
          (parts[0] == 'details' || parts[0] == 'viewer')) {
        per[parts[1]] = (per[parts[1]] ?? 0) + v;
      }
    });
    final list = per.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return list;
  }

  static Future<int> total(String kind) async {
    final snap = await snapshot();
    var sum = 0;
    snap.forEach((k, v) {
      if (k == kind || k.startsWith('$kind:')) sum += v;
    });
    return sum;
  }

  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
