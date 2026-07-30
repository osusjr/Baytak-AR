import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/demo_config.dart';
import 'device_id.dart';

/// On-device analytics with cloud sync (b26): counts product interest
/// events locally (instant, offline-safe), and when Supabase is
/// configured uploads the DELTAS since the last successful sync to the
/// analytics_events table (anon insert-only) - the store sees which
/// products customers preview and place, per device, in the dashboard.
class AppAnalytics {
  static const _key = 'analytics_v1';
  static const _syncedKey = 'analytics_synced_v1';

  /// Uploads event deltas since the last sync. Fire-and-forget from
  /// main(); failures leave the synced snapshot untouched so the deltas
  /// are retried next launch. Never throws.
  static Future<void> syncToCloud() async {
    if (!DemoConfig.supabaseConfigured) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final current = await snapshot();
      final synced = <String, int>{};
      try {
        Map<String, dynamic>.from(
                jsonDecode(prefs.getString(_syncedKey) ?? '{}') as Map)
            .forEach((k, v) => synced[k] = (v as num).toInt());
      } catch (_) {}
      final rows = <Map<String, dynamic>>[];
      final device = await deviceId();
      deltas(current, synced).forEach((k, delta) {
        final parts = k.split(':');
        rows.add({
          'device_id': device,
          'kind': parts.first,
          'product_id': parts.length > 1 ? parts.sublist(1).join(':') : null,
          // RLS caps a row at 10000; clamp so one hot counter can never
          // make the whole batch fail the check and freeze the sync
          'count': delta > 10000 ? 10000 : delta,
        });
      });
      if (rows.isEmpty) return;
      final resp = await http
          .post(
            Uri.parse(
                '${DemoConfig.supabaseUrl}/rest/v1/analytics_events'),
            headers: {
              'content-type': 'application/json',
              'apikey': DemoConfig.supabaseAnonKey,
              'authorization': 'Bearer ${DemoConfig.supabaseAnonKey}',
              'prefer': 'return=minimal',
            },
            body: jsonEncode(rows),
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        await prefs.setString(_syncedKey, jsonEncode(current));
      }
    } catch (_) {/* retried next launch */}
  }

  /// Pure helper (unit-tested): counts that grew since the last sync.
  static Map<String, int> deltas(
      Map<String, int> current, Map<String, int> synced) {
    final out = <String, int>{};
    current.forEach((k, v) {
      final d = v - (synced[k] ?? 0);
      if (d > 0) out[k] = d;
    });
    return out;
  }

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
    // also clear the synced baseline - otherwise every future count reads
    // as a negative/zero delta and cloud sync silently freezes forever
    await prefs.remove(_syncedKey);
  }
}
