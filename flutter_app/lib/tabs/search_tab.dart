import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/product_cards.dart';

/// Translation of ARoom's SearchFragment: a search field over the
/// catalogue with live results and an empty state.
class SearchTab extends StatefulWidget {
  const SearchTab({super.key});

  @override
  State<SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<SearchTab> {
  final _controller = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<DemoModel> get _results {
    final q = _q.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return demoCatalog.where((m) {
      return m.title.toLowerCase().contains(q) ||
          m.category.label.toLowerCase().contains(q) ||
          m.materials.any((mat) => mat.toLowerCase().contains(q));
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    AppScope.of(context); // rebuild when the cloud catalogue swaps in
    final results = _results;
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 6),
            child: Text('Search',
                style: Baytak.display(size: 26, weight: FontWeight.w700)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 4),
            child: TextField(
              controller: _controller,
              onChanged: (v) => setState(() => _q = v),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search sofas, walnut, kitchens...',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _q.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () {
                          _controller.clear();
                          setState(() => _q = '');
                        },
                      ),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide:
                      BorderSide(color: Baytak.ink.withValues(alpha: 0.1)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide:
                      BorderSide(color: Baytak.ink.withValues(alpha: 0.1)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide:
                      const BorderSide(color: Baytak.brass, width: 1.6),
                ),
              ),
            ),
          ),
          Expanded(
            child: _q.trim().isEmpty
                ? _Empty(
                    icon: Icons.search_rounded,
                    title: 'Search the catalogue',
                    detail:
                        'Try a piece, a room, or a material -\n'
                        '"sofa", "dining", "walnut", "brass".')
                : results.isEmpty
                    ? _Empty(
                        icon: Icons.search_off_rounded,
                        title: 'No matches for "${_q.trim()}"',
                        detail: 'Check the spelling or try a broader word.')
                    : GridView.builder(
                        padding:
                            const EdgeInsets.fromLTRB(22, 12, 22, 26),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 14,
                          crossAxisSpacing: 14,
                          childAspectRatio: kGridAspect,
                        ),
                        itemCount: results.length,
                        itemBuilder: (_, i) =>
                            ProductCard(model: results[i]),
                      ),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty(
      {required this.icon, required this.title, required this.detail});
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: Baytak.ink.withValues(alpha: 0.25)),
          const SizedBox(height: 12),
          Text(title,
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(detail,
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(
                  color: Baytak.ink.withValues(alpha: 0.55), height: 1.45)),
        ],
      ),
    );
  }
}
