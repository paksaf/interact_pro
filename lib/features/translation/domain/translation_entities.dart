class TranslationRequest {
  const TranslationRequest({
    required this.text,
    required this.targetLanguage,    // ISO code: 'ur', 'en', 'es', 'ar'…
    this.sourceLanguage = 'auto',
    this.preserveFormatting = true,
  });

  final String text;
  final String targetLanguage;
  final String sourceLanguage;
  final bool preserveFormatting;
}

class TranslationResult {
  const TranslationResult({
    required this.translatedText,
    required this.detectedSourceLanguage,
    required this.targetLanguage,
  });

  final String translatedText;
  final String detectedSourceLanguage;
  final String targetLanguage;
}

class SupportedLanguages {
  SupportedLanguages._();

  /// Curated set focused on Urdu + South Asian + major world languages.
  /// Add freely; the API supports far more.
  static const all = <String, String>{
    'ur': 'Urdu — اردو',
    'en': 'English',
    'ar': 'Arabic — العربية',
    'fa': 'Persian — فارسی',
    'hi': 'Hindi — हिन्दी',
    'pa': 'Punjabi — ਪੰਜਾਬੀ',
    'es': 'Spanish — Español',
    'fr': 'French — Français',
    'de': 'German — Deutsch',
    'zh': 'Chinese — 中文',
    'ja': 'Japanese — 日本語',
    'ko': 'Korean — 한국어',
    'ru': 'Russian — Русский',
    'tr': 'Turkish — Türkçe',
    'pt': 'Portuguese — Português',
    'it': 'Italian — Italiano',
  };

  static const rtlCodes = {'ur', 'ar', 'fa', 'he'};
  static bool isRtl(String code) => rtlCodes.contains(code);
}
