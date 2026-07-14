import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/onboarding_screen.dart';
import 'screens/root_shell.dart';
import 'state/app_state.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Diagnostic: any widget error paints itself on-screen as readable text
  // instead of failing silently. Remove once the app is stable.
  ErrorWidget.builder = (details) => Material(
        color: const Color(0xFFB3261E),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Text(
              'WIDGET ERROR\n\n${details.exceptionAsString()}',
              style: const TextStyle(
                  color: Colors.white, fontSize: 13, height: 1.4),
            ),
          ),
        ),
      );
  final prefs = await SharedPreferences.getInstance();
  runApp(BaytakArApp(state: AppState(prefs)));
}

class BaytakArApp extends StatelessWidget {
  const BaytakArApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: MaterialApp(
        title: 'Baytak AR',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: state.onboarded ? const RootShell() : const OnboardingScreen(),
      ),
    );
  }
}
