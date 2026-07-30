import 'package:flutter/material.dart';

import '../services/saved_designs.dart';
import '../theme.dart';
import 'design_studio_screen.dart';

/// Saved customer designs (b25): the showroom's order book. Every design
/// saved in the studio lives here - reopen it to keep styling, rebuild
/// the 3D model, or delete it. Tapping through re-enters the Design
/// studio with the exact plan + finishes the customer left with.
class SavedDesignsScreen extends StatefulWidget {
  const SavedDesignsScreen({super.key});

  @override
  State<SavedDesignsScreen> createState() => _SavedDesignsScreenState();
}

class _SavedDesignsScreenState extends State<SavedDesignsScreen> {
  List<SavedDesign>? _designs;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final all = await SavedDesigns.load();
    if (!mounted) return;
    setState(() => _designs = all);
  }

  Future<void> _delete(SavedDesign d) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${d.name}"?'),
        content: const Text('This removes the saved design permanently.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (sure != true) return;
    await SavedDesigns.remove(d.id);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final designs = _designs;
    return Scaffold(
      appBar: AppBar(title: const Text('Saved designs')),
      body: designs == null
          ? const Center(
              child: CircularProgressIndicator(color: Baytak.brass))
          : designs.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'No saved designs yet.\n\nDesign a kitchen in the '
                      'studio and tap "Save design" - every customer\'s '
                      'kitchen is kept here with its quote.',
                      textAlign: TextAlign.center,
                      style: text.bodyMedium?.copyWith(
                          color: Baytak.ink.withValues(alpha: 0.55),
                          height: 1.5),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 28),
                  itemCount: designs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final d = designs[i];
                    final p = d.plan;
                    return Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.fromLTRB(
                            16, 6, 8, 6),
                        title: Text(d.name,
                            style: text.bodyLarge
                                ?.copyWith(fontWeight: FontWeight.w800)),
                        subtitle: Text(
                          '${p.widthM.toStringAsFixed(1)} x '
                          '${p.depthM.toStringAsFixed(1)} m - '
                          '${p.runs.length} counter'
                          '${p.runs.length == 1 ? '' : 's'}'
                          '${p.island != null ? ' + island' : ''}\n'
                          '${d.savedAt.day}/${d.savedAt.month}/'
                          '${d.savedAt.year} - ${d.priceJd} JD',
                          style: text.bodySmall?.copyWith(
                              color: Baytak.ink.withValues(alpha: 0.6),
                              height: 1.35),
                        ),
                        isThreeLine: true,
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () => _delete(d),
                        ),
                        onTap: () async {
                          await Navigator.of(context).push(MaterialPageRoute(
                              builder: (_) => DesignStudioScreen(
                                    plan: d.plan,
                                    initial: d.design,
                                    source: 'the saved design "${d.name}"',
                                  )));
                          _refresh(); // may have been re-saved
                        },
                      ),
                    );
                  },
                ),
    );
  }
}
