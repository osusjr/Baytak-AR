import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Stable anonymous install id (b26): identifies a device to the backend
/// (AI quota, analytics, orders) without any account or personal data.
/// Generated once with a secure RNG and kept in shared_preferences.
Future<String> deviceId() async {
  final prefs = await SharedPreferences.getInstance();
  final existing = prefs.getString('device_id_v1');
  if (existing != null && existing.isNotEmpty) return existing;
  final rng = Random.secure();
  final id = List.generate(16, (_) => rng.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  await prefs.setString('device_id_v1', id);
  return id;
}
