import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';

/// Furniture-scan seam.
///
/// WHAT IS REAL TODAY
///   The guided capture flow saves an orbit of photos + a manifest to the
///   app's documents directory. That photo set is exactly the input every
///   photogrammetry backend expects.
///
/// WHAT PLUGS IN HERE (README "Scanning roadmap" has details)
///   A. On-device, iOS 17+: Apple Object Capture via a MethodChannel
///      ('baytak/object_capture') - highest quality, LiDAR-assisted.
///   B. Room scanning, iOS LiDAR devices: Apple RoomPlan -> parametric
///      room JSON -> feed the SAME kitchen extruder used for blueprints.
///   C. Cross-platform cloud: upload [ScanResult.directory] to a
///      photogrammetry API (e.g. Luma AI, Polycam, KIRI Engine) and poll
///      for the returned .glb. Works on Android too.
class PhotogrammetryService {
  PhotogrammetryService._();
  static final instance = PhotogrammetryService._();

  Future<ScanResult> persist(List<XFile> shots) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(
        '${docs.path}/scans/scan_${DateTime.now().millisecondsSinceEpoch}');
    await dir.create(recursive: true);

    final names = <String>[];
    for (var i = 0; i < shots.length; i++) {
      final name = 'img_${i.toString().padLeft(2, '0')}.jpg';
      await shots[i].saveTo('${dir.path}/$name');
      names.add(name);
    }

    final manifest = {
      'createdAt': DateTime.now().toIso8601String(),
      'photoCount': names.length,
      'files': names,
      'nextStep': 'Send this directory to a reconstruction backend '
          '(Object Capture bridge or cloud photogrammetry API).',
    };
    await File('${dir.path}/manifest.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));

    return ScanResult(directory: dir.path, photoCount: names.length);
  }
}

class ScanResult {
  const ScanResult({required this.directory, required this.photoCount});
  final String directory;
  final int photoCount;
}
