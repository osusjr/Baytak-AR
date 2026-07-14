/// Prospect directory for the pitch: furniture & kitchen retailers in Amman,
/// compiled from public listings. Verify details before outreach.
///
/// Per the project brief, Midas Furniture and Ashley Furniture are excluded
/// (they already ship their own visualization apps).
class Store {
  const Store({
    required this.name,
    required this.focus,
    required this.area,
    required this.note,
    required this.url,
  });

  final String name;
  final String focus; // 'Kitchens' | 'Full home' | 'Custom / boutique'
  final String area;
  final String note;
  final String url;
}

const ammanStores = <Store>[
  Store(
    name: 'Abdin Kitchens',
    focus: 'Kitchens',
    area: 'Amman',
    note: 'Family-owned custom kitchen maker since 1978 - the exact '
        '"see your whole kitchen before we build it" use case.',
    url: 'https://www.abdin.jo',
  ),
  Store(
    name: 'JWICO (Jordan Wood Industries)',
    focus: 'Kitchens',
    area: 'Mecca St., Amman',
    note: 'Kitchens, bedrooms and wardrobes since 1975; large showroom '
        'traffic to demo AR on.',
    url: 'https://www.jwico.com',
  ),
  Store(
    name: 'Universal Kitchen',
    focus: 'Kitchens',
    area: 'Tabarbour, Amman',
    note: 'Kitchen manufacturer since 1995 with its own carpentry - '
        'good fit for blueprint-driven previews.',
    url: 'https://www.universal-kitchen.com',
  ),
  Store(
    name: 'Maadat Kitchen',
    focus: 'Kitchens',
    area: 'Amman',
    note: 'Positions itself on fast custom kitchen delivery; AR preview '
        'shortens the decision step.',
    url: 'https://www.maadatkitchen.com',
  ),
  Store(
    name: 'Home Centre',
    focus: 'Full home',
    area: 'Amman (multiple branches)',
    note: 'Regional full-home retailer with a strong Amman presence; '
        'single-item AR placement fits their sofa/dining range.',
    url: 'https://www.homecentre.com',
  ),
  Store(
    name: 'THE One',
    focus: 'Full home',
    area: 'Zara Centre, Wadi Saqra',
    note: 'Home-fashion retailer; AR try-before-buy suits their styled sets.',
    url: 'https://www.theone.com',
  ),
  Store(
    name: 'Fathallah Furniture',
    focus: 'Custom / boutique',
    area: 'Amman',
    note: 'Local and imported luxury furniture since 1972.',
    url: 'https://fathallahfurniture.com',
  ),
  Store(
    name: 'Kuka Home Jordan',
    focus: 'Full home',
    area: 'Amman',
    note: 'Upholstered seating specialist - sofas are the highest-return '
        'single-item AR category.',
    url: 'https://kukahomejordan.com',
  ),
  Store(
    name: 'Seray Jordan',
    focus: 'Full home',
    area: 'Mecca St., Amman',
    note: 'Sofa sets and dining collections.',
    url: 'https://www.facebook.com/serayjordan',
  ),
  Store(
    name: 'Flamant Jordan',
    focus: 'Custom / boutique',
    area: 'Abdoun',
    note: 'Belgian interiors flagship - high-ticket clients who expect '
        'visualization.',
    url: 'https://www.flamant.com',
  ),
];
