import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme.dart';
import 'root_shell.dart';

/// Translation of ARoom's IntroductionFragment: one first-launch page.
class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(26, 18, 26, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text('Baytak',
                      style:
                          Baytak.display(size: 24, weight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  Text('بيتك',
                      style: text.titleSmall?.copyWith(
                          color: Baytak.olive, fontWeight: FontWeight.w700)),
                ],
              ),
              const SizedBox(height: 26),
              ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Image.asset('assets/thumbs/kitchen_k01_wide.png',
                    fit: BoxFit.cover),
              ),
              const SizedBox(height: 26),
              Text('AMMAN · FURNITURE IN AR',
                  style: Baytak.mono(color: Baytak.brass, spacing: 2.2)),
              const SizedBox(height: 10),
              Text('See it in your room\nbefore you buy.',
                  style: Baytak.display(size: 34, weight: FontWeight.w600)),
              const SizedBox(height: 12),
              Text(
                'Browse the catalogue in true 3D, place any piece in your '
                'home at real size, and generate whole kitchens straight '
                'from a blueprint.',
                style: text.bodyMedium?.copyWith(
                    color: Baytak.ink.withValues(alpha: 0.66), height: 1.5),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    AppScope.of(context, listen: false).setOnboarded();
                    Navigator.of(context).pushReplacement(
                        MaterialPageRoute(builder: (_) => const RootShell()));
                  },
                  child: const Text('Start browsing'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
