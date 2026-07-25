import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// User-facing version label (investor-friendly wording).
const kVersionLabel = 'PROTOTYPE v1';

/// Internal build counter - bump EVERY change round. The RENDER OK strips
/// show it so stale builds on the test phone are still detectable now that
/// the marketing label stays fixed.
const kBuildNumber = 25;

/// Diagnostic stamp for the per-screen "RENDER OK" strips.
const kBuildStamp = '$kVersionLabel (b$kBuildNumber)';

/// Palette v2 - "blueprint on paper": deep navy ink, sapphire primary,
/// azure accents on white. Constant NAMES are kept from the warm palette
/// so every screen recolors from this single file:
///   walnut -> sapphire (primary: buttons, prices)
///   brass  -> azure (accents, AR badge, focus)
///   olive  -> slate blue (secondary)
///   sand   -> paper white (backgrounds, text-on-navy)
///   ink    -> deep navy (text, dark surfaces)
///   well   -> ice (image wells, viewer backdrop)
class Baytak {
  static const walnut = Color(0xFF1B4F91);
  static const brass = Color(0xFF2F6FBA);
  static const olive = Color(0xFF3E5F82);
  static const sand = Color(0xFFF3F7FC);
  static const ink = Color(0xFF10233B);
  static const basalt = Color(0xFF24374E);

  /// image wells behind product thumbnails (matches the renders' backdrop)
  static const well = Color(0xFFF5F8FC);

  /// Display face for product names & headlines.
  static TextStyle display({
    double size = 24,
    FontWeight weight = FontWeight.w600,
    Color color = ink,
    double height = 1.08,
  }) =>
      GoogleFonts.fraunces(
          fontSize: size, fontWeight: weight, color: color, height: height);

  /// Utility face for dimensions, eyebrows, prices-as-data.
  static TextStyle mono({
    double size = 11,
    Color color = ink,
    FontWeight weight = FontWeight.w500,
    double spacing = 0.6,
  }) =>
      GoogleFonts.ibmPlexMono(
          fontSize: size,
          color: color,
          fontWeight: weight,
          letterSpacing: spacing);
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: Baytak.walnut,
    primary: Baytak.walnut,
    secondary: Baytak.brass,
    tertiary: Baytak.olive,
    surface: Baytak.sand,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  final text = GoogleFonts.manropeTextTheme(base.textTheme).apply(
    bodyColor: Baytak.ink,
    displayColor: Baytak.ink,
  );

  return base.copyWith(
    // The default Zoom route transition snapshots pages on the GPU;
    // use a plain transition that never snapshots.
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
      TargetPlatform.iOS: FadeUpwardsPageTransitionsBuilder(),
    }),
    scaffoldBackgroundColor: Colors.white,
    textTheme: text,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.white,
      foregroundColor: Baytak.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle:
          text.titleMedium?.copyWith(fontWeight: FontWeight.w800),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: Baytak.ink.withValues(alpha: 0.07)),
      ),
      margin: EdgeInsets.zero,
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: Colors.white,
      side: BorderSide(color: Baytak.ink.withValues(alpha: 0.10)),
      labelStyle: text.labelMedium?.copyWith(fontWeight: FontWeight.w600),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      shape: const StadiumBorder(),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Baytak.walnut,
        foregroundColor: Colors.white,
        minimumSize: const Size(56, 52),
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w800),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Baytak.ink,
        side: BorderSide(color: Baytak.ink.withValues(alpha: 0.22)),
        shape: const StadiumBorder(),
        textStyle: text.labelMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
    ),
    dividerTheme:
        DividerThemeData(color: Baytak.ink.withValues(alpha: 0.07)),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      height: 68,
      elevation: 0,
      indicatorColor: Baytak.brass.withValues(alpha: 0.20),
      iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
          size: 24,
          color: states.contains(WidgetState.selected)
              ? Baytak.walnut
              : Baytak.ink.withValues(alpha: 0.55))),
      labelTextStyle: WidgetStateProperty.resolveWith((states) =>
          text.labelSmall!.copyWith(
              fontWeight: FontWeight.w700,
              color: states.contains(WidgetState.selected)
                  ? Baytak.ink
                  : Baytak.ink.withValues(alpha: 0.55))),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: Baytak.ink,
      unselectedLabelColor: Baytak.ink.withValues(alpha: 0.45),
      labelStyle: Baytak.display(size: 15.5, weight: FontWeight.w600),
      unselectedLabelStyle:
          Baytak.display(size: 15.5, weight: FontWeight.w600),
      indicatorColor: Baytak.brass,
      indicatorSize: TabBarIndicatorSize.label,
      dividerColor: Baytak.ink.withValues(alpha: 0.07),
    ),
    badgeTheme: const BadgeThemeData(
        backgroundColor: Baytak.walnut, textColor: Colors.white),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        side: WidgetStatePropertyAll(
            BorderSide(color: Baytak.ink.withValues(alpha: 0.15))),
        textStyle: WidgetStatePropertyAll(
            text.labelMedium?.copyWith(fontWeight: FontWeight.w700)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      hintStyle: TextStyle(color: Baytak.ink.withValues(alpha: 0.4)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Baytak.ink,
      behavior: SnackBarBehavior.floating,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}
