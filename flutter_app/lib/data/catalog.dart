/// Demo catalogue. In production these records come from the retailer's
/// product feed; each product carries a hosted .glb (and .usdz for iOS
/// Quick Look). For this demo every model - and every thumbnail - is
/// generated locally by tools/generate_assets.py and bundled as assets.
enum Cat {
  kitchens('Kitchens'),
  living('Living'),
  dining('Dining'),
  storage('Storage');

  const Cat(this.label);
  final String label;
}

class DemoModel {
  const DemoModel({
    required this.id,
    required this.title,
    required this.category,
    required this.asset,
    required this.thumb,
    required this.blurb,
    required this.description,
    required this.wCm,
    required this.dCm,
    required this.hCm,
    required this.materials,
    required this.finishes,
    required this.variants,
    required this.priceJd,
    this.cameraOrbit,
    this.hero,
    this.dealPrice,
  });

  final String id;
  final String title;
  final Cat category;
  final String asset; // bundled .glb
  final String thumb; // catalogue card render
  final String blurb; // one-liner for cards
  final String description; // details page copy
  final int wCm, dCm, hCm;
  final List<String> materials;
  final List<int> finishes; // ARGB swatches for the finish selector
  final List<String> variants; // size/layout options (visual selector)
  final int priceJd; // indicative demo price in Jordanian dinars
  final String? cameraOrbit; // initial <model-viewer> camera-orbit
  final String? hero; // wide render, kitchens only
  final int? dealPrice; // when set, shown in the "Best deals" rail

  bool get isKitchen => category == Cat.kitchens;
  String get dimsLine => 'W $wCm · D $dCm · H $hCm cm';
}

String jd(int v) {
  final s = v.toString();
  return s.length <= 3
      ? s
      : '${s.substring(0, s.length - 3)},${s.substring(s.length - 3)}';
}

const kitchenK01 = DemoModel(
  id: 'kitchen_k01',
  title: 'Kitchen K-01',
  category: Cat.kitchens,
  asset: 'assets/models/demo_kitchen.glb',
  thumb: 'assets/thumbs/kitchen_k01.png',
  hero: 'assets/thumbs/kitchen_k01_wide.png',
  blurb: 'L-shape with island, generated as one model from its blueprint.',
  description:
      'The whole kitchen as one placeable model - not cabinet by cabinet. '
      'K-01 was generated directly from its blueprint: walnut runs along '
      'two walls, an olive island with seating for two, basalt worktops '
      'with a quartz island top, brass hardware and a sage subway '
      'backsplash. Counters at 90 cm, uppers at 150 cm, true appliance '
      'clearances. Stand inside it in AR before a single cabinet is built.',
  wCm: 420,
  dCm: 340,
  hCm: 270,
  materials: [
    'Walnut cabinetry',
    'Olive island',
    'Basalt + quartz tops',
    'Brass hardware',
    'Sage backsplash',
  ],
  finishes: [0xFF6B4830, 0xFF465342, 0xFF26292B, 0xFFC79E54],
  variants: ['L-shape + island'],
  priceJd: 4850,
  cameraOrbit: '-38deg 72deg 8.4m',
);

const sofaDana = DemoModel(
  id: 'sofa_dana',
  title: 'Dana Sofa',
  category: Cat.living,
  asset: 'assets/models/sofa_rainbow.glb',
  thumb: 'assets/thumbs/sofa_dana.png',
  blurb: 'Three seats in a taupe weave with solid oak legs.',
  description:
      'A deep three-seater in a warm taupe weave with charcoal seat '
      'cushions and turned solid-oak legs. Sized generously for family '
      'rooms - place it in AR to check the walkway behind it before '
      'committing.',
  wCm: 220,
  dCm: 95,
  hCm: 86,
  materials: ['Taupe weave', 'Charcoal seats', 'Oak legs'],
  finishes: [0xFFA89482, 0xFF6B6156, 0xFF8C6A45],
  variants: ['W 180', 'W 220', 'W 260'],
  priceJd: 649,
  dealPrice: 549,
  cameraOrbit: '-30deg 78deg 4.2m',
);

const armchairRum = DemoModel(
  id: 'armchair_rum',
  title: 'Rum Armchair',
  category: Cat.living,
  asset: 'assets/models/armchair_rum.glb',
  thumb: 'assets/thumbs/armchair_rum.png',
  blurb: 'Walnut shell, olive cushions, brass foot caps.',
  description:
      'A compact lounge chair with a wrapping walnut shell, olive bouclé '
      'cushions and brass-capped legs. Made for reading corners and '
      'bedrooms - at 86 cm wide it fits where full armchairs will not.',
  wCm: 86,
  dCm: 82,
  hCm: 72,
  materials: ['Walnut shell', 'Olive bouclé', 'Brass feet'],
  finishes: [0xFF465342, 0xFF7A5337, 0xFF3A3F4A],
  variants: ['Standard'],
  priceJd: 289,
  cameraOrbit: '-30deg 76deg 2.4m',
);

const diningAjloun = DemoModel(
  id: 'dining_ajloun',
  title: 'Ajloun Dining Set',
  category: Cat.dining,
  asset: 'assets/models/dining_ajloun.glb',
  thumb: 'assets/thumbs/dining_ajloun.png',
  blurb: 'Walnut table for four with cushioned chairs.',
  description:
      'A walnut dining table with rounded solid-wood legs and four '
      'cushioned chairs. The set places in AR together, so chair pull-out '
      'space and circulation are checked in your actual room, not '
      'guessed from a tape measure.',
  wCm: 160,
  dCm: 90,
  hCm: 75,
  materials: ['Walnut top', 'Solid wood legs', 'Taupe cushions'],
  finishes: [0xFF7A5337, 0xFF26292B, 0xFFA89482],
  variants: ['Seats 4', 'Seats 6'],
  priceJd: 799,
  dealPrice: 699,
  cameraOrbit: '-32deg 74deg 4.4m',
);

const shelfPetra = DemoModel(
  id: 'shelf_petra',
  title: 'Petra Shelf',
  category: Cat.storage,
  asset: 'assets/models/shelf_petra.glb',
  thumb: 'assets/thumbs/shelf_petra.png',
  blurb: 'Open walnut shelving with a sage back panel.',
  description:
      'Open shelving in walnut with a sage back panel and a brass accent '
      'rail - shown styled, because storage is bought with its contents '
      'imagined. At 32 cm deep it sits comfortably in hallways.',
  wCm: 90,
  dCm: 32,
  hCm: 180,
  materials: ['Walnut frame', 'Sage back panel', 'Brass accent'],
  finishes: [0xFF7A5337, 0xFFB5C4B0, 0xFF26292B],
  variants: ['W 90', 'W 120'],
  priceJd: 349,
  cameraOrbit: '-24deg 82deg 3.6m',
);

/// Everything, kitchen first.
const demoCatalog = [
  kitchenK01,
  sofaDana,
  armchairRum,
  diningAjloun,
  shelfPetra,
];

/// Grid items (the kitchen leads rails/heroes instead).
const furnitureCatalog = [sofaDana, armchairRum, diningAjloun, shelfPetra];

/// Rails for the home page (translation of ARoom's sections).
const specialProducts = [kitchenK01, diningAjloun, sofaDana];
final bestDeals =
    demoCatalog.where((m) => m.dealPrice != null).toList(growable: false);

DemoModel byId(String id) => demoCatalog.firstWhere((m) => m.id == id);
