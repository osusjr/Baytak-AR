import 'dart:convert';

/// Element-based kitchen design (v17) - the data model behind the Design
/// studio. A [KitchenDesign] picks one option per element (walls, floor,
/// worktops, upper/lower/island cabinets, backsplash, hardware, handle and
/// door style) and compiles them into the material/texture overrides the
/// on-device generator consumes.
///
/// All option tables were validated in tools/design_studio_proto.py and are
/// ported verbatim - keep the two files in sync.

class CabinetFinish {
  const CabinetFinish(this.label, this.swatch, this.carcass, this.door);
  final String label;
  final int swatch; // AARRGGBB for the UI chip
  final List<double> carcass; // rgb 0..1
  final List<double> door;
}

class SurfaceFinish {
  const SurfaceFinish(this.label, this.swatch, this.rgb, {this.texture});
  final String label;
  final int swatch;
  final List<double> rgb;
  final String? texture; // bundled texture override, or null = keep slot's
}

class HardwareFinish {
  const HardwareFinish(
      this.label, this.swatch, this.rgb, this.metallic, this.roughness);
  final String label;
  final int swatch;
  final List<double> rgb;
  final double metallic, roughness;
}

/// Cabinet finishes - usable on lower runs, upper runs and the island.
const cabinetFinishes = <String, CabinetFinish>{
  'warm_walnut': CabinetFinish('Warm walnut', 0xFF6B4830,
      [0.42, 0.28, 0.185], [0.48, 0.325, 0.215]),
  'light_oak': CabinetFinish('Light oak', 0xFFB3926A,
      [0.70, 0.57, 0.41], [0.77, 0.64, 0.47]),
  'white_satin': CabinetFinish('White satin', 0xFFE6E4DE,
      [0.88, 0.87, 0.84], [0.93, 0.92, 0.89]),
  'sand_beige': CabinetFinish('Sand beige', 0xFFC2AE8F,
      [0.74, 0.66, 0.54], [0.80, 0.72, 0.60]),
  'sage_green': CabinetFinish('Sage green', 0xFF85947F,
      [0.50, 0.56, 0.47], [0.56, 0.62, 0.53]),
  'olive_green': CabinetFinish('Olive green', 0xFF465342,
      [0.275, 0.325, 0.26], [0.315, 0.37, 0.30]),
  'navy_blue': CabinetFinish('Navy blue', 0xFF28384F,
      [0.155, 0.215, 0.31], [0.19, 0.255, 0.36]),
  'graphite': CabinetFinish('Graphite', 0xFF2A2C30,
      [0.16, 0.17, 0.19], [0.20, 0.21, 0.24]),
};

/// Worktops - applied to the run counters AND the island top. The first
/// entry keeps the per-slot default (basalt runs + white quartz island).
const worktops = <String, SurfaceFinish>{
  'basalt_quartz': SurfaceFinish('Basalt + quartz', 0xFF26292B, []),
  'white_quartz': SurfaceFinish('White quartz', 0xFFE5E3DE,
      [0.90, 0.89, 0.86], texture: 'quartz'),
  'black_granite': SurfaceFinish('Black granite', 0xFF17181A,
      [0.09, 0.095, 0.10], texture: 'stone'),
  'grey_concrete': SurfaceFinish('Grey concrete', 0xFF8C8A85,
      [0.55, 0.54, 0.51], texture: 'stone'),
  'marble_veined': SurfaceFinish('Veined marble', 0xFFE9E7E2,
      [0.92, 0.91, 0.89], texture: 'quartz'),
  'butcher_block': SurfaceFinish('Butcher block', 0xFF8C6A45,
      [0.55, 0.40, 0.27], texture: 'wood'),
};

const wallPaints = <String, SurfaceFinish>{
  'warm_white': SurfaceFinish('Warm white', 0xFFE8E1D2, [0.91, 0.88, 0.82]),
  'pure_white': SurfaceFinish('Pure white', 0xFFF2F1EC, [0.95, 0.95, 0.93]),
  'cream': SurfaceFinish('Cream', 0xFFEDE0C4, [0.93, 0.88, 0.77]),
  'sage_mist': SurfaceFinish('Sage mist', 0xFFCCD6C6, [0.80, 0.84, 0.78]),
  'sky_grey': SurfaceFinish('Sky grey', 0xFFC7CFD6, [0.78, 0.81, 0.84]),
  'terracotta': SurfaceFinish('Terracotta', 0xFFDBB79E, [0.86, 0.72, 0.62]),
  'charcoal': SurfaceFinish('Charcoal', 0xFF595C61, [0.35, 0.36, 0.38]),
};

const floorFinishes = <String, SurfaceFinish>{
  'travertine': SurfaceFinish('Travertine', 0xFFD1C2A8, [0.82, 0.76, 0.66]),
  'light_oak': SurfaceFinish('Light oak', 0xFFCCB28C, [0.80, 0.70, 0.55]),
  'honey_oak': SurfaceFinish('Honey oak', 0xFFB88F61, [0.72, 0.56, 0.38]),
  'grey_wood': SurfaceFinish('Grey wood', 0xFF9E9A94, [0.62, 0.60, 0.58]),
  'dark_walnut': SurfaceFinish('Dark walnut', 0xFF73573D, [0.45, 0.34, 0.24]),
  'stone_tile': SurfaceFinish('Stone tile', 0xFFBFBAB0,
      [0.75, 0.73, 0.68], texture: 'stone'),
  'slate_tile': SurfaceFinish('Slate tile', 0xFF595A5E,
      [0.35, 0.35, 0.37], texture: 'stone'),
};

const backsplashes = <String, SurfaceFinish>{
  'sage_subway': SurfaceFinish('Sage subway', 0xFFB5C4B0, [0.71, 0.77, 0.69]),
  'white_subway':
      SurfaceFinish('White subway', 0xFFE0E5E2, [0.88, 0.90, 0.89]),
  'smoke_grey': SurfaceFinish('Smoke grey', 0xFF4D545C, [0.30, 0.33, 0.36]),
  'deep_navy': SurfaceFinish('Deep navy', 0xFF33425C, [0.20, 0.26, 0.36]),
  'terracotta': SurfaceFinish('Terracotta', 0xFFB87A61, [0.72, 0.48, 0.38]),
  'marble_slab': SurfaceFinish('Marble slab', 0xFFE6E4DF,
      [0.90, 0.89, 0.87], texture: 'quartz'),
};

const hardwareFinishes = <String, HardwareFinish>{
  'brass': HardwareFinish('Brass', 0xFFC79E54, [0.78, 0.62, 0.33], 1.0, 0.30),
  'steel':
      HardwareFinish('Steel', 0xFFBDBFC2, [0.74, 0.75, 0.77], 0.95, 0.35),
  'black': HardwareFinish(
      'Matte black', 0xFF232326, [0.06, 0.06, 0.07], 0.40, 0.60),
};

const handleStyles = <String, String>{
  'bar': 'Bar pull',
  'knob': 'Knob',
  'none': 'Handleless',
};

const doorStyles = <String, String>{
  'slab': 'Flat slab',
  'shaker': 'Shaker frame',
};

/// Price factor per worktop (applied to the automatic estimate).
const _worktopPriceFactor = <String, double>{
  'basalt_quartz': 1.0,
  'white_quartz': 1.0,
  'black_granite': 1.08,
  'grey_concrete': 0.97,
  'marble_veined': 1.12,
  'butcher_block': 0.92,
};

String _key<T>(Map<String, T> table, String? v, String dflt) =>
    (v != null && table.containsKey(v)) ? v : dflt;

/// One choice per element. Immutable; edit via [copyWith].
class KitchenDesign {
  const KitchenDesign({
    this.lower = 'warm_walnut',
    this.upper = 'warm_walnut',
    this.island = 'olive_green',
    this.worktop = 'basalt_quartz',
    this.wall = 'warm_white',
    this.floor = 'travertine',
    this.splash = 'sage_subway',
    this.hardware = 'brass',
    this.handle = 'bar',
    this.door = 'slab',
  });

  final String lower, upper, island, worktop, wall, floor, splash;
  final String hardware, handle, door;

  KitchenDesign copyWith({
    String? lower,
    String? upper,
    String? island,
    String? worktop,
    String? wall,
    String? floor,
    String? splash,
    String? hardware,
    String? handle,
    String? door,
  }) =>
      KitchenDesign(
        lower: lower ?? this.lower,
        upper: upper ?? this.upper,
        island: island ?? this.island,
        worktop: worktop ?? this.worktop,
        wall: wall ?? this.wall,
        floor: floor ?? this.floor,
        splash: splash ?? this.splash,
        hardware: hardware ?? this.hardware,
        handle: handle ?? this.handle,
        door: door ?? this.door,
      );

  Map<String, dynamic> toJson() => {
        'lower': lower, 'upper': upper, 'island': island,
        'worktop': worktop, 'wall': wall, 'floor': floor, 'splash': splash,
        'hardware': hardware, 'handle': handle, 'door': door,
      };

  /// Defensive parse: any unknown/missing key falls back to the default.
  static KitchenDesign fromJson(Map<String, dynamic> j) => KitchenDesign(
        lower: _key(cabinetFinishes, j['lower'] as String?, 'warm_walnut'),
        upper: _key(cabinetFinishes, j['upper'] as String?, 'warm_walnut'),
        island: _key(cabinetFinishes, j['island'] as String?, 'olive_green'),
        worktop: _key(worktops, j['worktop'] as String?, 'basalt_quartz'),
        wall: _key(wallPaints, j['wall'] as String?, 'warm_white'),
        floor: _key(floorFinishes, j['floor'] as String?, 'travertine'),
        splash: _key(backsplashes, j['splash'] as String?, 'sage_subway'),
        hardware: _key(hardwareFinishes, j['hardware'] as String?, 'brass'),
        handle: _key(handleStyles, j['handle'] as String?, 'bar'),
        door: _key(doorStyles, j['door'] as String?, 'slab'),
      );

  static KitchenDesign? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  String encode() => jsonEncode(toJson());

  /// Bridges the AI's palette field (and the legacy palettes) into a design.
  static KitchenDesign fromPalette(String palette) =>
      presets[palette] ?? presets['warm_walnut']!;

  /// Named starting points shown in the studio. The first three keys match
  /// the AI palette vocabulary so an AI-chosen palette lands on a preset.
  static const presets = <String, KitchenDesign>{
    'warm_walnut': KitchenDesign(),
    'light_oak': KitchenDesign(
      lower: 'light_oak',
      upper: 'light_oak',
      island: 'sage_green',
      worktop: 'white_quartz',
      wall: 'pure_white',
      splash: 'white_subway',
      hardware: 'steel',
    ),
    'dark_modern': KitchenDesign(
      lower: 'graphite',
      upper: 'graphite',
      worktop: 'basalt_quartz',
      floor: 'grey_wood',
      splash: 'smoke_grey',
      hardware: 'black',
    ),
    'all_light': KitchenDesign(
      lower: 'white_satin',
      upper: 'white_satin',
      island: 'light_oak',
      worktop: 'white_quartz',
      wall: 'pure_white',
      floor: 'light_oak',
      splash: 'white_subway',
      hardware: 'steel',
      door: 'shaker',
    ),
    'all_dark': KitchenDesign(
      lower: 'graphite',
      upper: 'graphite',
      island: 'graphite',
      worktop: 'black_granite',
      wall: 'charcoal',
      floor: 'grey_wood',
      splash: 'smoke_grey',
      hardware: 'black',
      handle: 'none',
    ),
  };

  static const presetLabels = <String, String>{
    'warm_walnut': 'Signature walnut',
    'light_oak': 'Light oak',
    'dark_modern': 'Dark modern',
    'all_light': 'All light',
    'all_dark': 'All dark',
  };

  CabinetFinish get lowerFinish => cabinetFinishes[lower]!;
  CabinetFinish get upperFinish => cabinetFinishes[upper]!;
  CabinetFinish get islandFinish => cabinetFinishes[island]!;
  SurfaceFinish get worktopFinish => worktops[worktop]!;
  SurfaceFinish get wallFinish => wallPaints[wall]!;
  SurfaceFinish get floorFinish => floorFinishes[floor]!;
  SurfaceFinish get splashFinish => backsplashes[splash]!;
  HardwareFinish get hardwareFinish => hardwareFinishes[hardware]!;

  double get priceFactor => _worktopPriceFactor[worktop] ?? 1.0;

  /// Material colour overrides for the generator: material slot ->
  /// [r,g,b] (keep slot metal/rough) or [r,g,b,metallic,roughness].
  Map<String, List<double>> materialOverrides() {
    List<double> dim(List<double> rgb) =>
        [for (final c in rgb) (c * 0.35).clamp(0.0, 1.0).toDouble()];
    final wt = worktopFinish;
    return {
      'walnut': lowerFinish.carcass,
      'walnut_door': lowerFinish.door,
      'upper': upperFinish.carcass,
      'upper_door': upperFinish.door,
      'olive': islandFinish.carcass,
      'olive_door': islandFinish.door,
      'wall': wallFinish.rgb,
      'floor': floorFinish.rgb,
      'splash': splashFinish.rgb,
      if (wt.rgb.isNotEmpty) 'basalt': wt.rgb,
      if (wt.rgb.isNotEmpty) 'quartz': wt.rgb,
      'brass': [
        ...hardwareFinish.rgb,
        hardwareFinish.metallic,
        hardwareFinish.roughness,
      ],
      'toe': dim(lowerFinish.carcass),
    };
  }

  /// Texture overrides: material slot -> bundled texture name.
  Map<String, String> textureOverrides() => {
        if (floorFinish.texture != null) 'floor': floorFinish.texture!,
        if (worktopFinish.texture != null) 'basalt': worktopFinish.texture!,
        if (worktopFinish.texture != null) 'quartz': worktopFinish.texture!,
        if (splashFinish.texture != null) 'splash': splashFinish.texture!,
      };

  /// Chips for the product page ("Materials").
  List<String> materialsLine() => [
        '${lowerFinish.label} lowers',
        '${upperFinish.label} uppers',
        '${worktopFinish.label} worktop',
        '${splashFinish.label} splash',
        '${hardwareFinish.label} · ${handleStyles[handle]!.toLowerCase()}',
      ];

  /// Finish swatches for the product page selector.
  List<int> finishSwatches() => [
        lowerFinish.swatch,
        upperFinish.swatch,
        worktopFinish.swatch,
        splashFinish.swatch,
        hardwareFinish.swatch,
      ];

  /// One line for descriptions/snackbars.
  String describe() =>
      '${lowerFinish.label} lowers, ${upperFinish.label} uppers, '
      '${worktopFinish.label} worktop, ${doorStyles[door]!.toLowerCase()} '
      'doors (${handleStyles[handle]!.toLowerCase()}), '
      '${hardwareFinish.label.toLowerCase()} hardware';
}
