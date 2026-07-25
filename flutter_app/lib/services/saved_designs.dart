import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'kitchen_design.dart';
import 'kitchen_generator.dart';

/// Saved customer designs (b25): every kitchen a customer builds in the
/// showroom can be kept, reopened and re-quoted - the demo stops being a
/// one-shot toy and becomes a sales tool. Stored as a JSON list in
/// shared_preferences (newest first, capped); each entry is fully
/// self-contained (plan + design + price + name), so it survives app
/// restarts and catalogue changes.
class SavedDesign {
  SavedDesign({
    required this.id,
    required this.name,
    required this.savedAt,
    required this.plan,
    required this.design,
    required this.priceJd,
  });

  final String id;
  final String name;
  final DateTime savedAt;
  final LayoutPlan plan;
  final KitchenDesign design;
  final int priceJd;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'saved_at': savedAt.toIso8601String(),
        'plan': plan.toJson(),
        'design': design.encode(),
        'price_jd': priceJd,
      };

  static SavedDesign? tryFromJson(dynamic j) {
    if (j is! Map) return null;
    try {
      final plan = LayoutPlan.fromJson(
          Map<String, dynamic>.from(j['plan'] as Map));
      final design =
          KitchenDesign.tryDecode('${j['design'] ?? ''}') ?? const KitchenDesign();
      return SavedDesign(
        id: '${j['id']}',
        name: '${j['name'] ?? 'Kitchen'}',
        savedAt:
            DateTime.tryParse('${j['saved_at']}') ?? DateTime.now(),
        plan: plan,
        design: design,
        priceJd: (j['price_jd'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null; // one corrupt entry must not sink the gallery
    }
  }
}

class SavedDesigns {
  SavedDesigns._();

  static const _key = 'saved_designs_v1';
  static const _cap = 30; // showroom day's worth; oldest drop off

  static Future<List<SavedDesign>> load() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final raw = jsonDecode(prefs.getString(_key) ?? '[]') as List;
      return [
        for (final e in raw)
          if (SavedDesign.tryFromJson(e) case final d?) d
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<void> add(SavedDesign d) async {
    final all = await load();
    all.insert(0, d);
    await _persist(all.take(_cap).toList());
  }

  static Future<void> remove(String id) async {
    final all = await load();
    all.removeWhere((d) => d.id == id);
    await _persist(all);
  }

  static Future<void> _persist(List<SavedDesign> all) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key, jsonEncode([for (final d in all) d.toJson()]));
  }
}
