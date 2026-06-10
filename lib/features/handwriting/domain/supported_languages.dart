/// Curated list of digital-ink languages we surface in the picker.
///
/// ML Kit ships ~300 supported language tags via its handwriting model
/// catalogue, but most users want a small, well-labelled set. This
/// matches the rest of the app's i18n footprint (en / ur / ar / hi /
/// pa / fa / zh / ja / ko / ru / tr / es / fr / de / pt / it) plus a
/// couple of high-traffic Latin-script ones (es-MX, pt-BR).
///
/// Tag must match exactly what `DigitalInkRecognizer(languageCode: ...)`
/// accepts — BCP-47 with the recogniser's hyphen convention. Validate
/// against `DigitalInkRecognitionModelIdentifier.values` if you add
/// more.
class HandwritingLanguage {
  const HandwritingLanguage({
    required this.tag,
    required this.label,
    required this.script,
    this.rtl = false,
  });

  final String tag;
  final String label;
  final String script;
  final bool rtl;

  static const presets = <HandwritingLanguage>[
    HandwritingLanguage(tag: 'en-US', label: 'English (US)', script: 'Latin'),
    HandwritingLanguage(tag: 'en-GB', label: 'English (UK)', script: 'Latin'),
    HandwritingLanguage(tag: 'ur', label: 'Urdu — اردو', script: 'Arabic', rtl: true),
    HandwritingLanguage(tag: 'ar', label: 'Arabic — العربية', script: 'Arabic', rtl: true),
    HandwritingLanguage(tag: 'fa', label: 'Persian — فارسی', script: 'Arabic', rtl: true),
    HandwritingLanguage(tag: 'hi', label: 'Hindi — हिन्दी', script: 'Devanagari'),
    HandwritingLanguage(tag: 'pa', label: 'Punjabi — ਪੰਜਾਬੀ', script: 'Gurmukhi'),
    HandwritingLanguage(tag: 'zh-Hans', label: 'Chinese (Simplified) — 中文', script: 'Han'),
    HandwritingLanguage(tag: 'zh-Hant', label: 'Chinese (Traditional) — 中文', script: 'Han'),
    HandwritingLanguage(tag: 'ja', label: 'Japanese — 日本語', script: 'Japanese'),
    HandwritingLanguage(tag: 'ko', label: 'Korean — 한국어', script: 'Hangul'),
    HandwritingLanguage(tag: 'ru', label: 'Russian — Русский', script: 'Cyrillic'),
    HandwritingLanguage(tag: 'tr', label: 'Turkish — Türkçe', script: 'Latin'),
    HandwritingLanguage(tag: 'es', label: 'Spanish — Español', script: 'Latin'),
    HandwritingLanguage(tag: 'fr', label: 'French — Français', script: 'Latin'),
    HandwritingLanguage(tag: 'de', label: 'German — Deutsch', script: 'Latin'),
    HandwritingLanguage(tag: 'pt-BR', label: 'Portuguese (Brazil) — Português', script: 'Latin'),
    HandwritingLanguage(tag: 'it', label: 'Italian — Italiano', script: 'Latin'),
  ];

  static HandwritingLanguage byTag(String tag) =>
      presets.firstWhere((l) => l.tag == tag,
          orElse: () => presets.first,);
}
