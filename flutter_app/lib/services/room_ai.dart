import 'dart:convert';
import 'dart:io';

import '../data/catalog.dart';
import 'ai_client.dart';
import 'kitchen_generator.dart';

/// Sends a photo of the customer's room to a free NVIDIA-hosted vision
/// model, which estimates the room's dimensions (from visual reference
/// scales such as doors and ceiling height), identifies the room type, and
/// picks items FROM THIS RETAILER'S CATALOGUE that physically fit and match
/// the chosen style. Estimates from a single photo are approximate by
/// nature - live AR measurement is the documented in-app-AR roadmap step.
class RoomAnalysisException implements Exception {
  RoomAnalysisException(this.message);
  final String message;

  @override
  String toString() => message;
}

class RoomPick {
  RoomPick({
    required this.model,
    required this.placement,
    required this.reason,
    this.x,
    this.z,
    this.rot,
  });
  final DemoModel model;
  final String placement;
  final String reason;
  final double? x, z;
  final int? rot;
}

class RoomAnalysis {
  RoomAnalysis({
    required this.roomType,
    required this.widthM,
    required this.depthM,
    required this.heightM,
    required this.confidence,
    required this.observations,
    required this.picks,
  });

  final String roomType;
  final double widthM, depthM, heightM;
  final String confidence;
  final String observations;
  final List<RoomPick> picks;

  int get totalJd => picks.fold(0, (a, p) => a + p.model.priceJd);

  bool get hasLayout => picks.any((p) => p.x != null && p.z != null);

  RoomScenePlan toScenePlan() => RoomScenePlan(
        widthM: widthM,
        depthM: depthM,
        roomType: roomType,
        notes: observations,
        placements: [
          for (final p in picks)
            if (p.x != null && p.z != null)
              RoomPlacement(
                  id: p.model.id, x: p.x!, z: p.z!, rot: p.rot ?? 0),
        ],
      );
}

String _catalogJson() {
  final items = [
    for (final m in furnitureCatalog)
      {
        'id': m.id,
        'title': m.title,
        'category': m.category.label,
        'w_cm': m.wCm,
        'd_cm': m.dCm,
        'h_cm': m.hCm,
        'price_jd': m.priceJd,
        'footprint_w_m': (furnitureFootprints[m.id] ?? const [1, 1])[0],
        'footprint_d_m': (furnitureFootprints[m.id] ?? const [1, 1])[1],
        'about': m.blurb,
      }
  ];
  return jsonEncode(items);
}

String _prompt(String style) => '''
You are an interior advisor for a furniture retailer. Analyze the attached
photo of a customer's room.

1) Estimate the room's usable floor size in metres (width = the wall facing
the camera or the longest visible wall; depth = towards the camera) and the
ceiling height. Use visible reference scales: interior doors ~2.03 m tall,
typical ceilings 2.6-3.0 m, floor tiles often 0.6 m, power sockets ~0.3 m
above floor. Be conservative and state confidence.

2) Identify the room type.

3) From THIS catalogue (the retailer's own stock), pick the items that
physically fit the estimated room with sensible clearances (>= 0.7 m
walkways) and suit the customer's chosen style: "$style".
Pick 0-4 items; fewer is fine. Never invent items not in the catalogue.

4) ARRANGE the picks: give each a centre position x_m (from the left wall)
and z_m (from the far/back wall towards the camera), plus rot in degrees
(0, 90, 180 or 270). rot 0 = the item's front faces the camera (+z);
90/180/270 rotate it clockwise seen from above. Footprints are given at
rot 0 and swap w/d at 90/270. Rules: whole footprint inside the room with
0.1 m wall margin, no overlaps between items, >= 0.7 m walkways, sofas and
shelves back against a wall.

CATALOGUE (JSON): ${_catalogJson()}

Return JSON ONLY - no prose, no markdown fences:
{
 "room_type": "living|dining|bedroom|hallway|office|other",
 "width_m": 0.0, "depth_m": 0.0, "height_m": 0.0,
 "confidence": "low|medium|high",
 "observations": "one short sentence about the room",
 "picks": [
   {"id": "catalogue id", "placement": "where in the room",
    "reason": "why it fits (mention the measurement)",
    "x_m": 0.0, "z_m": 0.0, "rot": 0}
 ]
}
''';

Future<RoomAnalysis> analyzeRoom(File image, {required String style}) async {
  final bytes = await image.readAsBytes();
  if (bytes.length > 15 * 1024 * 1024) {
    throw RoomAnalysisException(
        'Photo is too large for analysis - re-pick it from the gallery.');
  }
  final mediaType =
      image.path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';

  String text;
  try {
    text = await visionCall(
      imageBytes: bytes,
      mediaType: mediaType,
      prompt: _prompt(style),
    );
  } on AiClientException catch (e) {
    throw RoomAnalysisException(e.message);
  }

  try {
    final j = jsonDecode(extractJsonObject(text)) as Map<String, dynamic>;

    double numOf(dynamic v, double lo, double hi, double dflt) {
      final d = (v is num) ? v.toDouble() : double.tryParse('$v');
      if (d == null || d.isNaN) return dflt;
      return d.clamp(lo, hi).toDouble();
    }

    final picks = <RoomPick>[];
    final raw = (j['picks'] is List) ? j['picks'] as List : const [];
    for (final p in raw) {
      if (p is! Map) continue;
      final id = '${p['id'] ?? ''}';
      final matches = demoCatalog.where((m) => m.id == id);
      if (matches.isEmpty) continue; // AI invented an id -> drop it
      double? coord(dynamic v) {
        final d = (v is num) ? v.toDouble() : double.tryParse('$v');
        return (d == null || d.isNaN) ? null : d;
      }

      final rotRaw = coord(p['rot']);
      picks.add(RoomPick(
        model: matches.first,
        placement: '${p['placement'] ?? ''}'.trim(),
        reason: '${p['reason'] ?? ''}'.trim(),
        x: coord(p['x_m']),
        z: coord(p['z_m']),
        rot: rotRaw == null ? null : ((rotRaw / 90).round() * 90) % 360,
      ));
    }

    return RoomAnalysis(
      roomType: '${j['room_type'] ?? 'room'}',
      widthM: numOf(j['width_m'], 1.5, 15, 3.5),
      depthM: numOf(j['depth_m'], 1.5, 15, 3.5),
      heightM: numOf(j['height_m'], 2.2, 4.5, 2.8),
      confidence: '${j['confidence'] ?? 'low'}',
      observations: '${j['observations'] ?? ''}'.trim(),
      picks: picks,
    );
  } catch (e) {
    throw RoomAnalysisException(
        'Could not parse the AI response as a room analysis.\n\n$e');
  }
}
