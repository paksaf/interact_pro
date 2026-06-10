import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../../../core/error/failures.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/result.dart';

/// Wraps ML Kit's text recogniser for one-shot image OCR. Mirrors the
/// pattern used by [MlKitOcrDatasource] in the OCR feature, but doesn't
/// rasterise PDF pages — it consumes the photo directly from disk.
///
/// Script selection matters: ML Kit ships separate models for Latin,
/// Chinese, Japanese, Korean, Devanagari. Picking the wrong one produces
/// garbage, so the screen UI maps the user's chosen language to the
/// right script before calling here.
class OnDeviceTextRecognizer {
  TextRecognizer _recogniserFor(TextRecognitionScript script) {
    return TextRecognizer(script: script);
  }

  /// Convenience: run [imagePath] through ML Kit at [script]. The caller
  /// owns the recogniser lifecycle through repeat calls — we close it
  /// every time so we don't leak native handles between language
  /// switches.
  Future<Result<String>> recognise({
    required String imagePath,
    required TextRecognitionScript script,
  }) async {
    final recogniser = _recogniserFor(script);
    try {
      final input = InputImage.fromFilePath(imagePath);
      final result = await recogniser.processImage(input);
      // ML Kit returns a structured `RecognizedText.blocks/lines/elements`,
      // but the consumer here just wants the flat reading-order text.
      // `result.text` does that with newline separators between blocks
      // and lines, which lines up with what the user would type.
      return Result.ok(result.text);
    } catch (e, st) {
      appLogger.e('on-device text recognise failed',
          error: e, stackTrace: st,);
      return Result.err(OcrFailure('On-device recognition failed', cause: e));
    } finally {
      try {
        await recogniser.close();
      } catch (_) {}
    }
  }
}

/// Map the user's language tag (BCP-47-ish, same set as the digital-ink
/// screen) to ML Kit's coarse script enum. Latin is the safe default —
/// ML Kit's Latin recogniser also picks up most ASCII numerals /
/// punctuation, so wrong-language users still get something usable
/// rather than nothing.
TextRecognitionScript mlKitScriptForLanguageTag(String tag) {
  final lower = tag.toLowerCase();
  if (lower.startsWith('zh')) return TextRecognitionScript.chinese;
  if (lower.startsWith('ja')) return TextRecognitionScript.japanese;
  if (lower.startsWith('ko')) return TextRecognitionScript.korean;
  if (lower.startsWith('hi') || lower.startsWith('mr') || lower.startsWith('ne')) {
    // ML Kit has the typo `devanagiri` in its Dart enum (0.15.x).
    return TextRecognitionScript.devanagiri;
  }
  // Latin works for English, Spanish, French, Turkish, Portuguese,
  // German, Italian, Russian (Cyrillic falls back gracefully). Arabic
  // / Urdu / Persian / Punjabi don't have a dedicated ML Kit script —
  // Latin returns whatever Latin tokens are present, the user is told
  // to switch to the cloud engine for full coverage.
  return TextRecognitionScript.latin;
}
