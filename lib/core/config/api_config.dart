/// Centralized read-only configuration for outbound API integrations.
///
/// Keys are sourced via `--dart-define` at build / run time so they never
/// land in source control. Example:
///
/// ```bash
/// flutter run \
///   --dart-define=DEEPSEEK_API_KEY=sk-... \
///   --dart-define=DEEPSEEK_PROXY_URL=https://api.example.com/translate \
///   --dart-define=GOOGLE_WEB_CLIENT_ID=xxx.apps.googleusercontent.com
/// ```
///
/// In production, prefer [deepSeekProxyUrl] (your backend injects the key
/// server-side) over shipping [deepSeekApiKey] inside the binary.
class ApiConfig {
  ApiConfig._();

  /// DeepSeek API key. Empty if not provided. Used only when [deepSeekProxyUrl]
  /// is empty (i.e., calling DeepSeek directly from the device).
  static const String deepSeekApiKey =
      String.fromEnvironment('DEEPSEEK_API_KEY');

  /// Optional backend proxy URL. When set, the DeepSeek client posts here
  /// instead of api.deepseek.com and the key never ships with the app.
  static const String deepSeekProxyUrl =
      String.fromEnvironment('DEEPSEEK_PROXY_URL');

  /// Shared secret the proxy expects in the `X-App-Token` header. Stops
  /// random callers from racking up a DeepSeek bill on our paid endpoint.
  /// Empty disables the header — leave empty if `APP_SHARED_SECRET` isn't
  /// set on the proxy. Server side: `/etc/interact/translate.env`.
  static const String appTranslateToken =
      String.fromEnvironment('APP_TRANSLATE_TOKEN');

  /// OAuth client id used by Google Sign-In on web/iOS configurations that
  /// require explicit client identification.
  static const String googleWebClientId =
      String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');

  /// Convenience: true iff we have *something* the DeepSeek client can use.
  static bool get hasTranslationCredentials =>
      deepSeekApiKey.isNotEmpty || deepSeekProxyUrl.isNotEmpty;

  /// True if shipping a real key in the binary. Use to gate production warnings.
  static bool get usesDirectApiKey =>
      deepSeekApiKey.isNotEmpty && deepSeekProxyUrl.isEmpty;

  /// Backend endpoint that ingests anonymized analytics events. Empty
  /// disables remote analytics entirely (events are kept in-memory only
  /// for the current session — useful in dev / for local debugging).
  static const String analyticsEndpointUrl =
      String.fromEnvironment('ANALYTICS_ENDPOINT_URL');

  /// Public marketing site base URL — drives Settings → Help & Feedback,
  /// Privacy Policy, and TOS deep links.
  static const String websiteBaseUrl = String.fromEnvironment(
    'WEBSITE_BASE_URL',
    defaultValue: 'https://interactpak.com',
  );

  static String get supportUrl => '$websiteBaseUrl/support';
  static String get privacyPolicyUrl => '$websiteBaseUrl/privacy';
  static String get termsUrl => '$websiteBaseUrl/terms';
  static String get feedbackUrl => '$websiteBaseUrl/feedback';
}
