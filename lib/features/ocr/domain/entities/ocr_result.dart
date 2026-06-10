import 'dart:ui' show Rect;

/// Per-page OCR result. The raw block layout is kept so we can build a
/// searchable text overlay (PRD OCR-05) by re-projecting each block onto
/// the rendered page bitmap.
class OcrPageResult {
  const OcrPageResult({
    required this.pageIndex,
    required this.text,
    required this.blocks,
    required this.confidence,
  });

  final int pageIndex;
  final String text;
  final List<OcrTextBlock> blocks;
  /// 0.0 – 1.0 average confidence across blocks.
  final double confidence;
}

class OcrTextBlock {
  const OcrTextBlock({
    required this.text,
    required this.boundingBox,
    required this.language,
  });
  final String text;
  final Rect boundingBox;
  final String language;
}

/// PRD OCR-04.
enum OcrAccuracyMode { fast, accurate }

/// PRD OCR-02 — list passed to `TextRecognitionScript` on Android.
enum OcrLanguage { latin, chinese, japanese, korean, devanagari }
