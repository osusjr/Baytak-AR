import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'kitchen_generator.dart';

/// b28 scan cache: the FIRST successful AI reading of a blueprint is
/// stored keyed on the image bytes, so re-analyzing the same drawing
/// costs nothing - the user gets their original model back instantly and
/// no AI credit is spent. A "Re-scan with AI" action forces a fresh call
/// when they really want a second opinion.
///
/// Key = FNV-1a 64-bit over the raw picked bytes (content-addressed: the
/// same drawing re-picked from gallery, WhatsApp or a copy hits the same
/// entry; a different photo of the same paper does not - that is a new
/// scan and honestly costs a credit). Pure logic + prefs, unit-tested.
class ScanCache {
  ScanCache._();

  static const _key = 'scan_cache_v1';
  static const _cap = 12;

  /// FNV-1a 64-bit, hex string. Dart ints are 64-bit; multiplication
  /// wraps, which is exactly what FNV wants. Formatted from unsigned
  /// 32-bit halves - toRadixString on the raw (signed) value would emit
  /// a minus sign.
  static String hashBytes(List<int> bytes) {
    var h = 0xcbf29ce484222325;
    for (final b in bytes) {
      h ^= b & 0xff;
      h *= 0x100000001b3;
    }
    final hi = (h >>> 32).toRadixString(16).padLeft(8, '0');
    final lo = (h & 0xffffffff).toRadixString(16).padLeft(8, '0');
    return '$hi$lo';
  }

  static Future<Map<String, dynamic>> _load(SharedPreferences prefs) async {
    try {
      return Map<String, dynamic>.from(
          jsonDecode(prefs.getString(_key) ?? '{}') as Map);
    } catch (_) {
      return {};
    }
  }

  /// The cached plan for these image bytes, or null on a miss.
  static Future<LayoutPlan?> lookup(List<int> bytes) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final all = await _load(prefs);
      final entry = all[hashBytes(bytes)];
      if (entry is! Map) return null;
      final plan = LayoutPlan.fromJson(
          Map<String, dynamic>.from(entry['plan'] as Map));
      return plan.runs.isEmpty ? null : plan;
    } catch (_) {
      return null;
    }
  }

  /// Stores a fresh AI result. Keeps the newest [_cap] entries.
  static Future<void> store(List<int> bytes, LayoutPlan plan) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final all = await _load(prefs);
      all[hashBytes(bytes)] = {
        'plan': plan.toJson(),
        'at': DateTime.now().toIso8601String(),
      };
      if (all.length > _cap) {
        final keys = all.keys.toList()
          ..sort((x, y) => '${(all[y] as Map)['at']}'
              .compareTo('${(all[x] as Map)['at']}'));
        for (final k in keys.skip(_cap)) {
          all.remove(k);
        }
      }
      await prefs.setString(_key, jsonEncode(all));
    } catch (_) {/* cache is best-effort - never break a scan */}
  }
}
