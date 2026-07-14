import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/demo_config.dart';
import '../data/catalog.dart';
import '../state/app_state.dart';

/// Cloud catalogue (v17): products + hosted GLBs/thumbnails live in the
/// retailer's Supabase project (see supabase/schema.sql +
/// tools/upload_catalog.py) instead of inside the APK. On launch the app:
///
///   1. reads demo_config (may carry the demo NVIDIA key so a fleet of
///      demo phones can be keyed without rebuilding),
///   2. fetches the products table,
///   3. downloads new/changed GLBs + images into the documents dir
///      (cached by updated_at - unchanged files are never re-downloaded),
///   4. swaps the live catalogue in and notifies the UI.
///
/// Any failure leaves the bundled catalogue in place - the showroom demo
/// never breaks because a network is down. That fallback IS the pitch:
/// stores update products server-side, the app keeps working offline.
class RemoteCatalog {
  RemoteCatalog._();

  /// Shown in Profile > About ("where is this catalogue from?").
  static String status = DemoConfig.supabaseConfigured
      ? 'Cloud catalogue configured - syncing...'
      : 'Bundled demo catalogue (no cloud configured)';

  static bool get isLive => _live;
  static bool _live = false;

  static Map<String, String> get _headers => {
        'apikey': DemoConfig.supabaseAnonKey,
        'authorization': 'Bearer ${DemoConfig.supabaseAnonKey}',
      };

  static Uri _rest(String pathAndQuery) =>
      Uri.parse('${DemoConfig.supabaseUrl}/rest/v1/$pathAndQuery');

  static Uri _publicObject(String bucket, String path) => Uri.parse(
      '${DemoConfig.supabaseUrl}/storage/v1/object/public/$bucket/$path');

  /// Fire-and-forget from main(); safe to call again (pull-to-refresh).
  static Future<void> sync(AppState state) async {
    if (!DemoConfig.supabaseConfigured) return;
    try {
      await _cacheDemoConfig();
      final items = await _fetchProducts();
      if (items.isNotEmpty) {
        installCatalog(items);
        _live = true;
        status = 'Cloud catalogue - ${items.length} products from Supabase';
      } else {
        status = 'Cloud catalogue empty - using the bundled demo set';
      }
    } catch (e) {
      status = 'Cloud sync failed (${e.runtimeType}) - using the bundled '
          'demo set';
    }
    // repaint product lists AND the Profile status row in every outcome
    state.catalogUpdated();
  }

  /// demo_config rows -> shared prefs (currently: the demo NVIDIA key).
  /// Deleting the row server-side revokes the cached key on next sync.
  static Future<void> _cacheDemoConfig() async {
    final resp = await http
        .get(_rest('demo_config?select=key,value'), headers: _headers)
        .timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) return; // table optional
    final rows = jsonDecode(resp.body) as List;
    final prefs = await SharedPreferences.getInstance();
    const keys = {
      'nvidia_api_key': 'cfg_nvidia_key',
      'gemini_api_key': 'cfg_gemini_key',
      'openai_api_key': 'cfg_openai_key',
    };
    final seen = <String>{};
    for (final r in rows) {
      if (r is! Map) continue;
      final pref = keys['${r['key']}'];
      if (pref != null) {
        seen.add(pref);
        await prefs.setString(pref, '${r['value']}'.trim());
      }
    }
    for (final pref in keys.values) {
      if (!seen.contains(pref)) await prefs.remove(pref);
    }
  }

  static Future<List<DemoModel>> _fetchProducts() async {
    final resp = await http
        .get(_rest('products?select=*&order=sort_order.asc'),
            headers: _headers)
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw HttpException('products fetch ${resp.statusCode}');
    }
    final rows = jsonDecode(resp.body) as List;

    final docs = await getApplicationDocumentsDirectory();
    final cacheDir = Directory('${docs.path}/remote_catalog');
    await cacheDir.create(recursive: true);

    final items = <DemoModel>[];
    for (final raw in rows) {
      if (raw is! Map) continue;
      final r = Map<String, dynamic>.from(raw);
      try {
        items.add(await _toModel(r, cacheDir));
      } catch (_) {
        // one broken row/download must not sink the whole catalogue
      }
    }
    return items;
  }

  /// Downloads bucket:path to the cache unless the manifest says the local
  /// copy is current. Returns the local file path.
  static Future<String> _cached(String bucket, String path, String stamp,
      Directory cacheDir) async {
    final safe = path.replaceAll('/', '_');
    final file = File('${cacheDir.path}/${bucket}_$safe');
    final key = '$bucket/$path';
    final prefs = await SharedPreferences.getInstance();
    final manifest = <String, dynamic>{};
    try {
      manifest.addAll(Map<String, dynamic>.from(
          jsonDecode(prefs.getString('remote_manifest') ?? '{}') as Map));
    } catch (_) {}
    if (manifest['$key@'] == stamp && file.existsSync()) return file.path;

    final resp = await http
        .get(_publicObject(bucket, path))
        .timeout(const Duration(seconds: 60));
    if (resp.statusCode != 200) {
      throw HttpException('$key download ${resp.statusCode}');
    }
    await file.writeAsBytes(resp.bodyBytes, flush: true);
    manifest['$key@'] = stamp;
    await prefs.setString('remote_manifest', jsonEncode(manifest));
    return file.path;
  }

  static Future<DemoModel> _toModel(
      Map<String, dynamic> r, Directory cacheDir) async {
    final stamp = '${r['updated_at'] ?? ''}';
    final id = '${r['id']}';

    final assetPath =
        await _cached('models', '${r['asset_path']}', stamp, cacheDir);
    final thumbPath =
        await _cached('thumbs', '${r['thumb_path']}', stamp, cacheDir);
    String? heroPath;
    final hero = r['hero_path'];
    if (hero is String && hero.isNotEmpty) {
      heroPath = await _cached('thumbs', hero, stamp, cacheDir);
    }

    List<T> listOf<T>(dynamic v, T Function(dynamic) f) =>
        v is List ? [for (final e in v) f(e)] : <T>[];

    final cat = Cat.values.firstWhere(
        (c) => c.name == '${r['category']}' || c.label == '${r['category']}',
        orElse: () => Cat.living);

    return DemoModel(
      id: id,
      title: '${r['title'] ?? id}',
      category: cat,
      asset: 'file://$assetPath',
      thumb: thumbPath,
      hero: heroPath,
      blurb: '${r['blurb'] ?? ''}',
      description: '${r['description'] ?? ''}',
      wCm: (r['w_cm'] as num?)?.toInt() ?? 0,
      dCm: (r['d_cm'] as num?)?.toInt() ?? 0,
      hCm: (r['h_cm'] as num?)?.toInt() ?? 0,
      materials: listOf(r['materials'], (e) => '$e'),
      finishes: listOf(r['finishes'], (e) => (e as num).toInt()),
      variants: listOf(r['variants'], (e) => '$e'),
      priceJd: (r['price_jd'] as num?)?.toInt() ?? 0,
      dealPrice: (r['deal_price_jd'] as num?)?.toInt(),
      cameraOrbit: r['camera_orbit'] as String?,
    );
  }
}
