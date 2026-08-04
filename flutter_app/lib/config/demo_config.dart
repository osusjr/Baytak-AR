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

  /// Optional PAID provider (platform.openai.com, pay-as-you-go - no
  /// subscription): when set, OpenAI goes FIRST in both AI chains and the
  /// free models become the fallback. OPENAI_MODEL picks the tier
  /// (gpt-5.6-sol flagship / gpt-5.6-terra / gpt-5.6-luna budget).
  static const openaiApiKey =
      String.fromEnvironment('OPENAI_API_KEY', defaultValue: '');
  static const openaiModel = String.fromEnvironment('OPENAI_MODEL',
      defaultValue: 'gpt-5.6-sol');

  /// b29 photo render: the OpenAI image-edit model used to paint the
  /// designed kitchen into the customer's room photo. Swappable without
  /// code when OpenAI ships a newer tier.
  static const openaiImageModel = String.fromEnvironment(
      'OPENAI_IMAGE_MODEL',
      defaultValue: 'gpt-image-1');

  /// Optional second FREE provider (aistudio.google.com key, no card):
  /// adds Gemini Flash to the vision fallback chain for extra reliability.
  static const geminiApiKey =
      String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');

  static const supabaseUrl =
      String.fromEnvironment('SUPABASE_URL', defaultValue: '');
  static const supabaseAnonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');

  /// PRODUCTION MODE: URL of the deployed ai-proxy Edge Function
  /// (https://xyz.functions.supabase.co/ai-proxy). When set, ALL AI calls
  /// go through the proxy and NO provider key ships in the app - this is
  /// the launch configuration. Also distributable via demo_config
  /// ('ai_proxy_url' row) so demo phones can be switched without a
  /// rebuild.
  static const aiProxyUrl =
      String.fromEnvironment('AI_PROXY_URL', defaultValue: '');

  /// Per-store license key checked by the proxy (REQUIRE_LICENSE=true).
  static const licenseKey =
      String.fromEnvironment('LICENSE_KEY', defaultValue: '');

  static bool get supabaseConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
