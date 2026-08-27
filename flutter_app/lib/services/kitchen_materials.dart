/// Matbakhak b35 - the materials database + rate card.
///
/// THE calibration surface for the whole cut-list/pricing engine: every
/// workshop pays different supplier prices, so these defaults (JOD,
/// Amman market ballpark, researched 2026-08) are meant to be adjusted
/// per shop. Sizes are worldwide standards:
///  * carcass sheets: 2440 x 1220 mm ("4x8" - the global stock size),
///    18 mm melamine-faced chipboard; 3 mm HDF backs; 18 mm MDF for
///    painted shaker doors
///  * worktop blanks: 3000-4100 x 600-635 x 38 mm, priced per linear m
/// Mirrored in tools/cutlist_proto.py - keep in sync.
library;

class SheetSpec {
  const SheetSpec(this.label, this.wMm, this.hMm, this.priceJd);
  final String label;
  final int wMm, hMm;
  final double priceJd;
}

const sheetStock = <String, SheetSpec>{
  'mfc18': SheetSpec('Melamine chipboard 18 mm', 2440, 1220, 23.0),
  'mdf18': SheetSpec('MDF 18 mm (painted doors)', 2440, 1220, 30.0),
  'hdf3': SheetSpec('HDF back panel 3 mm', 2440, 1220, 8.0),
};

/// Saw kerf and unusable sheet edge, mm.
const kerfMm = 4;
const sheetTrimMm = 10;

const hardwarePrices = <String, double>{
  'hinge': 1.8, // soft-close concealed, each
  'leg': 0.45, // adjustable plinth leg
  'bracket': 0.8, // upper-cabinet hanging bracket
  'handle_bar': 3.5,
  'handle_knob': 2.5,
  'push_catch': 1.6, // push-to-open catch, per door
  'gola_profile_m': 12.0, // hidden-handle aluminium rail, per metre
};

const edgingPerM = 0.30; // 0.4 mm ABS edge banding applied, per metre

/// Worktop price classes, per linear metre (600-635 mm deep, supplied
/// and cut). The design's worktop option id maps onto a class below.
const worktopPerM = <String, double>{
  'laminate': 28.0,
  'wood': 45.0,
  'engineered': 60.0,
  'concrete': 55.0,
  'granite': 70.0,
  'quartz': 85.0,
};

const worktopClass = <String, String>{
  'basalt_quartz': 'engineered',
  'white_quartz': 'quartz',
  'black_granite': 'granite',
  'grey_concrete': 'concrete',
  'marble_veined': 'quartz',
  'butcher_block': 'wood',
};

const splashPerM2 = 18.0;

/// Cutting + edging + assembly + install + workshop margin, applied over
/// raw materials. "Every production company has their price" - this is
/// the knob a shop turns.
const manufactureFactor = 1.7;

/// The estimate is presented as a +/-10 % band, per the product spec.
const estimateBand = 0.10;

/// Carcass geometry (mm) - mirrors the generator's frozen dimensions.
const baseCarcassH = 760, baseCarcassD = 580;
const upperCarcassH = 700, upperCarcassD = 330;
const tallCarcassH = 2100, tallCarcassD = 580;
