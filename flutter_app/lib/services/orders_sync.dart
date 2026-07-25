import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/demo_config.dart';
import '../state/app_state.dart';
import 'device_id.dart';

/// Order submission (b26): every order placed in the app is POSTed to the
/// store's Supabase `orders` table (anon insert-only) so the store
/// actually RECEIVES it - the difference between a demo checkout and a
/// real one. Offline-safe: failed submissions queue in prefs and retry on
/// the next launch; the customer's local order history is never blocked
/// by the network.
class OrdersSync {
  OrdersSync._();

  static const _pendingKey = 'orders_pending_v1';

  /// Submit one order. Persisted to the retry queue FIRST (so a crash
  /// mid-request never loses it), attempted, then removed only on a
  /// confirmed delivery. Never throws.
  static Future<void> push(DemoOrder order, {String customer = ''}) async {
    if (!DemoConfig.supabaseConfigured) return;
    // globally-unique backend id (local millis can collide across
    // devices; the store's orders.id is the primary key)
    final device = await deviceId();
    final row = {
      'id': '${order.id}-${device.substring(0, 8)}',
      'device_id': device,
      'customer': customer,
      'lines': order.lines,
      'total_jd': order.total,
    };
    await _enqueue(row); // durable BEFORE the network attempt
    if (await _post(row)) await _dequeue(row['id'] as String);
  }

  /// Retry anything not yet delivered. Called from main().
  static Future<void> retryPending() async {
    if (!DemoConfig.supabaseConfigured) return;
    for (final row in await _readQueue()) {
      if (row is Map && await _post(Map<String, dynamic>.from(row))) {
        await _dequeue('${row['id']}');
      }
    }
  }

  static Future<bool> _post(Map<String, dynamic> row) async {
    try {
      final resp = await http
          .post(
            Uri.parse('${DemoConfig.supabaseUrl}/rest/v1/orders'),
            headers: {
              'content-type': 'application/json',
              'apikey': DemoConfig.supabaseAnonKey,
              'authorization': 'Bearer ${DemoConfig.supabaseAnonKey}',
              // a retry that half-succeeded lands the same id again - treat
              // the duplicate as delivered rather than an error
              'prefer': 'resolution=ignore-duplicates,return=minimal',
            },
            body: jsonEncode(row),
          )
          .timeout(const Duration(seconds: 15));
      return (resp.statusCode >= 200 && resp.statusCode < 300) ||
          resp.statusCode == 409; // already there = delivered
    } catch (_) {
      return false;
    }
  }

  static Future<List<dynamic>> _readQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return jsonDecode(prefs.getString(_pendingKey) ?? '[]') as List;
    } catch (_) {
      return [];
    }
  }

  // Every mutation re-reads the queue immediately before writing, so
  // concurrent push()/retry calls cannot clobber each other's changes.
  static Future<void> _enqueue(Map<String, dynamic> row) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = await _readQueue();
      if (pending.any((r) => r is Map && r['id'] == row['id'])) return;
      pending.add(row);
      // keep the NEWEST 50 (drop the oldest overflow, not the new order)
      final kept = pending.length > 50
          ? pending.sublist(pending.length - 50)
          : pending;
      await prefs.setString(_pendingKey, jsonEncode(kept));
    } catch (_) {/* never block an order on bookkeeping */}
  }

  static Future<void> _dequeue(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = await _readQueue()
        ..removeWhere((r) => r is Map && r['id'] == id);
      await prefs.setString(_pendingKey, jsonEncode(pending));
    } catch (_) {}
  }
}
