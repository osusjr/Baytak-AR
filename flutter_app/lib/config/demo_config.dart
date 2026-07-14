/// Build-time demo configuration.
///
/// The investor demo runs against FREE hosted services, configured at build
/// time so nothing is typed in the app:
///
///   flutter run --dart-define=NVIDIA_API_KEY=nvapi-... \
///               --dart-define=SUPABASE_URL=https://xyz.supabase.co \
///               --dart-define=SUPABASE_ANON_KEY=eyJ...
///
///  * NVIDIA_API_KEY - free key from build.nvidia.com (no card). Powers the
///    blueprint/room vision analysis. If empty, the app looks for a key
///    published in the Supabase demo_config table (see supabase/schema.sql)
///    so a fleet of demo phones can be keyed without rebuilding.
///  * SUPABASE_URL / SUPABASE_ANON_KEY - optional cloud catalogue (products
///    + hosted GLBs). If empty, the bundled demo catalogue is used.
///
/// PRODUCTION NOTE (honesty rule): a shipped consumer app must not embed
/// API keys at all - AI calls go through the retailer's backend (e.g. a
/// Supabase Edge Function holding the key server-side). The seams are
/// documented in README "Going to production".
class DemoConfig {
  DemoConfig._();

  static const nvidiaApiKey =
      String.fromEnvironment('NVIDIA_API_KEY', defaultValue: '');
  static const supabaseUrl =
      String.fromEnvironment('SUPABASE_URL', defaultValue: '');
  static const supabaseAnonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');

  static bool get supabaseConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
