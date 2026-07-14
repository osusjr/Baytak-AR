import 'package:flutter/material.dart';

import '../data/stores.dart';
import '../theme.dart';

class StoresScreen extends StatelessWidget {
  const StoresScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Partner stores - Amman')),
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 28),
        itemCount: ammanStores.length + 1,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          if (i == 0) {
            return Text(
              'Prospect list compiled from public listings - verify details '
              'before outreach. Midas and Ashley are intentionally excluded: '
              'they already ship their own apps, which is the proof this '
              'market wants the product.',
              style: text.bodySmall?.copyWith(
                  color: Baytak.ink.withOpacity(0.6), height: 1.45),
            );
          }
          final s = ammanStores[i - 1];
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(s.name,
                            style: text.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w800)),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 3),
                        decoration: BoxDecoration(
                          color: s.focus == 'Kitchens'
                              ? Baytak.olive
                              : (s.focus == 'Full home'
                                  ? Baytak.brass
                                  : Baytak.basalt),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(s.focus,
                            style: text.labelSmall?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(s.area,
                      style: text.bodySmall?.copyWith(
                          color: Baytak.ink.withOpacity(0.55),
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Text(s.note,
                      style: text.bodySmall?.copyWith(
                          color: Baytak.ink.withOpacity(0.7), height: 1.4)),
                  const SizedBox(height: 6),
                  Text(s.url,
                      style: text.labelSmall
                          ?.copyWith(color: Baytak.walnut.withOpacity(0.8))),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
