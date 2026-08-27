import 'kitchen_design.dart';
import 'kitchen_generator.dart';
import 'kitchen_materials.dart';

/// Matbakhak b35 - the cut-list engine: from the designed LayoutPlan to
/// the factory floor. Validated FIRST in tools/cutlist_proto.py (numbers
/// FROZEN from it - run the proto after rule changes):
///  1. runs -> cabinet MODULES via the same doorBays() the renderer uses
///  2. modules -> PANEL parts in real mm on real materials
///  3. parts -> SHEETS to buy (shelf nesting, first-fit decreasing,
///     rotation allowed, 4 mm kerf, 2440x1220 stock)
///  4. hardware counts, worktop metres, edging metres
///  5. price = materials x manufacture factor, shown as a +/-10 % band.
/// Pure logic, no Flutter imports - unit-tested in widget_test.dart.
class CutPart {
  const CutPart(this.name, this.material, this.wMm, this.hMm, this.qty,
      this.edgingM);
  final String name;
  final String material; // key into sheetStock
  final int wMm, hMm, qty;
  final double edgingM; // per piece
}

class Bom {
  Bom({
    required this.cabinets,
    required this.parts,
    required this.hardware,
    required this.worktopM,
    required this.splashM2,
    required this.golaM,
    required this.notes,
  });

  /// (kind label, width mm) per cabinet module.
  final List<(String, int)> cabinets;
  final List<CutPart> parts;
  final Map<String, int> hardware;
  final double worktopM;
  final double splashM2;
  final double golaM;
  final List<String> notes;

  Map<String, int> get cabinetCounts {
    final out = <String, int>{};
    for (final (kind, _) in cabinets) {
      out[kind] = (out[kind] ?? 0) + 1;
    }
    return out;
  }
}

class PriceEstimate {
  const PriceEstimate({
    required this.boards,
    required this.utilization,
    required this.edgingM,
    required this.materialsJd,
    required this.totalJd,
  });

  final Map<String, int> boards; // material -> sheets to buy
  final Map<String, double> utilization; // material -> fill 0..1
  final double edgingM;
  final double materialsJd;
  final double totalJd;

  double get lowJd => totalJd * (1 - estimateBand);
  double get highJd => totalJd * (1 + estimateBand);
}

int _mm(double v) => (v * 1000).round();

List<CutPart> _baseCabinetParts(int w, String doorMat, {bool sink = false}) {
  return [
    CutPart('side', 'mfc18', baseCarcassD, baseCarcassH, 2,
        baseCarcassH / 1000),
    CutPart('bottom', 'mfc18', w - 36, baseCarcassD, 1, (w - 36) / 1000),
    CutPart('top rail', 'mfc18', w - 36, 100, 2, 0),
    if (!sink) ...[
      CutPart('shelf', 'mfc18', w - 36, 500, 1, (w - 36) / 1000),
      CutPart('back', 'hdf3', w - 20, 740, 1, 0),
    ],
    CutPart('door', doorMat, w - 4, 740, 1, 2 * ((w - 4) + 740) / 1000),
  ];
}

List<CutPart> _upperCabinetParts(int w, String doorMat) => [
      CutPart('side', 'mfc18', upperCarcassD, upperCarcassH, 2,
          upperCarcassH / 1000),
      CutPart('top/bottom', 'mfc18', w - 36, upperCarcassD, 2,
          (w - 36) / 1000),
      CutPart('shelf', 'mfc18', w - 36, 280, 1, (w - 36) / 1000),
      CutPart('back', 'hdf3', w - 20, 680, 1, 0),
      CutPart('door', doorMat, w - 4, 684, 1, 2 * ((w - 4) + 684) / 1000),
    ];

List<CutPart> _tallCabinetParts(int w, String doorMat) => [
      CutPart('side', 'mfc18', tallCarcassD, tallCarcassH, 2,
          2 * tallCarcassH / 1000),
      CutPart('top/bottom', 'mfc18', w - 36, 560, 2, (w - 36) / 1000),
      CutPart('shelf', 'mfc18', w - 36, 560, 2, (w - 36) / 1000),
      CutPart('back', 'hdf3', w - 20, 2080, 1, 0),
      CutPart('door low', doorMat, w - 4, 1180, 1,
          2 * ((w - 4) + 1180) / 1000),
      CutPart('door high', doorMat, w - 4, 880, 1,
          2 * ((w - 4) + 880) / 1000),
    ];

/// Breaks the designed kitchen into cabinets, panels and hardware.
Bom buildBom(LayoutPlan plan, KitchenDesign design) {
  final doorMat = design.door == 'shaker' ? 'mdf18' : 'mfc18';
  final handle = design.handle;
  final parts = <CutPart>[];
  final hardware = <String, int>{
    'hinge': 0,
    'leg': 0,
    'bracket': 0,
    'handle': 0,
    'push_catch': 0,
  };
  final cabinets = <(String, int)>[];
  final notes = <String>{};
  var worktopM = 0.0, splashM2 = 0.0, golaM = 0.0, plinthM = 0.0;

  void countDoorHw(int doors, {bool tall = false}) {
    hardware['hinge'] = hardware['hinge']! + doors * (tall ? 3 : 2);
    if (handle == 'bar' || handle == 'knob') {
      hardware['handle'] = hardware['handle']! + doors;
    } else if (handle == 'push') {
      hardware['push_catch'] = hardware['push_catch']! + doors;
    }
  }

  for (final r in plan.runs) {
    var a = r.a, b = r.b;
    if (r.fridge == 'start') a += 0.80;
    if (r.fridge == 'end') b -= 0.80;
    if (r.fridge != null) {
      notes.add('fridge space reserved - appliance by customer');
    }
    if (r.tall) {
      for (final (ba, bb, hasDoor) in doorBays(r.a, r.b)) {
        final w = _mm(bb - ba);
        if (!hasDoor) {
          parts.add(CutPart('filler', 'mfc18', w, tallCarcassH, 1,
              tallCarcassH / 1000));
          continue;
        }
        cabinets.add(('tall', w));
        parts.addAll(_tallCabinetParts(w, doorMat));
        countDoorHw(1, tall: true);
        countDoorHw(1);
        hardware['leg'] = hardware['leg']! + 4;
      }
      continue;
    }
    if (b - a < 0.7) continue;
    final counterLen = b - a;
    worktopM += counterLen;
    splashM2 += counterLen * 0.56;
    plinthM += counterLen;
    if (handle == 'gola') golaM += counterLen;
    for (final (ba, bb, hasDoor) in doorBays(a, b)) {
      final w = _mm(bb - ba);
      final mid = (ba + bb) / 2;
      if (!hasDoor) {
        parts.add(CutPart('filler', 'mfc18', w, baseCarcassH, 1,
            baseCarcassH / 1000));
        continue;
      }
      if (r.rangeAt != null && (mid - r.rangeAt!).abs() < 0.42) {
        notes.add('cooker gap - freestanding cooker by customer');
        continue;
      }
      final sink = r.sinkAt != null && (mid - r.sinkAt!).abs() < 0.34;
      cabinets.add((sink ? 'sink base' : 'base', w));
      parts.addAll(_baseCabinetParts(w, doorMat, sink: sink));
      countDoorHw(1);
      hardware['leg'] = hardware['leg']! + 4;
    }
    if (r.uppers) {
      for (final (ba, bb, hasDoor) in doorBays(a + 0.02, b - 0.02)) {
        final w = _mm(bb - ba);
        if (!hasDoor) continue;
        cabinets.add(('upper', w));
        parts.addAll(_upperCabinetParts(w, doorMat));
        countDoorHw(1);
        hardware['bracket'] = hardware['bracket']! + 2;
      }
    }
  }

  final isl = plan.island;
  if (isl != null) {
    worktopM += isl.w + 0.10;
    plinthM += isl.w;
    if (handle == 'gola') golaM += isl.w;
    for (final (ba, bb, hasDoor) in doorBays(0.0, isl.w)) {
      final w = _mm(bb - ba);
      if (!hasDoor) {
        parts.add(CutPart('filler', 'mfc18', w, baseCarcassH, 1,
            baseCarcassH / 1000));
        continue;
      }
      cabinets.add(('island base', w));
      parts.addAll(_baseCabinetParts(w, doorMat));
      countDoorHw(1);
      hardware['leg'] = hardware['leg']! + 4;
    }
    parts.add(CutPart(
        'island back skin', 'mfc18', _mm(isl.w), baseCarcassH, 1, isl.w));
  }

  // plinth is cut in sheet-length segments (a 7 m strip is not a part)
  var remaining = _mm(plinthM);
  final seg = sheetStock['mfc18']!.wMm - 2 * sheetTrimMm - kerfMm;
  while (remaining > 0) {
    final cut = remaining < seg ? remaining : seg;
    parts.add(CutPart('plinth', 'mfc18', cut, 100, 1, cut / 1000));
    remaining -= cut;
  }

  return Bom(
    cabinets: cabinets,
    parts: parts,
    hardware: hardware,
    worktopM: worktopM,
    splashM2: splashM2,
    golaM: golaM,
    notes: notes.toList()..sort(),
  );
}

/// Shelf nesting (first-fit decreasing, rotation allowed): how many
/// standard sheets of [material] the parts consume. Returns (sheets,
/// utilization 0..1). Mirrors the proto's nest().
(int, double) nestSheets(List<CutPart> parts, String material) {
  final spec = sheetStock[material]!;
  final usableW = spec.wMm - 2 * sheetTrimMm;
  final usableH = spec.hMm - 2 * sheetTrimMm;
  final pieces = <(int, int)>[]; // (short, long)
  for (final p in parts.where((p) => p.material == material)) {
    for (var i = 0; i < p.qty; i++) {
      final lo = p.wMm < p.hMm ? p.wMm : p.hMm;
      final hi = p.wMm < p.hMm ? p.hMm : p.wMm;
      if (hi > (usableW > usableH ? usableW : usableH) ||
          lo > (usableW < usableH ? usableW : usableH)) {
        throw ArgumentError('part ${p.name} ${p.wMm}x${p.hMm} exceeds sheet');
      }
      pieces.add((lo, hi));
    }
  }
  if (pieces.isEmpty) return (0, 0);
  pieces.sort((x, y) =>
      x.$1 != y.$1 ? y.$1.compareTo(x.$1) : y.$2.compareTo(x.$2));
  // sheets: each is a list of shelves [usedW, shelfH]
  final sheets = <List<List<int>>>[];
  for (final (lo, hi) in pieces) {
    final w = hi, h = lo; // long side along the shelf
    var placed = false;
    for (final shelves in sheets) {
      for (final sh in shelves) {
        if (sh[1] >= h + kerfMm && usableW - sh[0] >= w + kerfMm) {
          sh[0] += w + kerfMm;
          placed = true;
          break;
        }
      }
      if (placed) break;
      final usedH = shelves.fold(0, (t, s) => t + s[1]);
      if (usableH - usedH >= h + kerfMm) {
        shelves.add([w + kerfMm, h + kerfMm]);
        placed = true;
        break;
      }
    }
    if (!placed) {
      sheets.add([
        [w + kerfMm, h + kerfMm]
      ]);
    }
  }
  final area = pieces.fold<double>(0, (t, p) => t + p.$1 * p.$2);
  final total = sheets.length * spec.wMm * spec.hMm;
  return (sheets.length, total == 0 ? 0 : area / total);
}

/// Prices the BOM with the rate card: sheets + edging + worktop + splash
/// + hardware, times the manufacture factor.
PriceEstimate priceBom(Bom bom, KitchenDesign design) {
  final boards = <String, int>{};
  final utilization = <String, double>{};
  for (final mat in sheetStock.keys) {
    final (n, u) = nestSheets(bom.parts, mat);
    if (n > 0) {
      boards[mat] = n;
      utilization[mat] = u;
    }
  }
  final edgingM =
      bom.parts.fold<double>(0, (t, p) => t + p.edgingM * p.qty);
  final handlePrice = hardwarePrices[
      design.handle == 'knob' ? 'handle_knob' : 'handle_bar']!;
  final wtClass = worktopClass[design.worktop] ?? 'engineered';
  final materials = boards.entries
          .fold<double>(0, (t, e) => t + sheetStock[e.key]!.priceJd * e.value) +
      edgingM * edgingPerM +
      bom.worktopM * worktopPerM[wtClass]! +
      bom.splashM2 * splashPerM2 +
      bom.golaM * hardwarePrices['gola_profile_m']! +
      bom.hardware['hinge']! * hardwarePrices['hinge']! +
      bom.hardware['leg']! * hardwarePrices['leg']! +
      bom.hardware['bracket']! * hardwarePrices['bracket']! +
      bom.hardware['handle']! * handlePrice +
      bom.hardware['push_catch']! * hardwarePrices['push_catch']!;
  return PriceEstimate(
    boards: boards,
    utilization: utilization,
    edgingM: edgingM,
    materialsJd: materials,
    totalJd: materials * manufactureFactor,
  );
}
