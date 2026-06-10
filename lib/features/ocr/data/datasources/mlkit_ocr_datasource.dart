import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:pdfx/pdfx.dart' as pdfx;

import '../../../../core/utils/logger.dart';
import '../../domain/entities/ocr_result.dart';

/// Wraps Google ML Kit's on-device text recogniser. Pages are rasterised
/// via `pdfx` (Pdfium) before being handed off.
///
/// PRD OCR-04 mapping (bumped 2026-05-13 after user OCR-quality complaint):
///   • `OcrAccuracyMode.fast`     → render @ 2.0× DPI (was 1.5×)
///   • `OcrAccuracyMode.accurate` → render @ 4.0× DPI (was 3.0×; slower,
///                                   noticeably better on small fonts).
///
/// Also: pass `backgroundColor: '#FFFFFFFF'` to pdfx.render — without
/// it the page comes back with no opaque background and ML Kit's
/// contrast detection can wobble on transparent regions. Same fix
/// shipped to the cast renderer the same day (see pdf_page_renderer.dart).
///
/// Tesseract fallback (for languages ML Kit doesn't cover well) belongs in
/// a sibling `tesseract_ocr_datasource.dart` and gets selected via the
/// repository implementation.
class MlKitOcrDatasource {
  TextRecognizer _recogniserFor(OcrLanguage lang) {
    final TextRecognitionScript script = switch (lang) {
      OcrLanguage.latin => TextRecognitionScript.latin,
      OcrLanguage.chinese => TextRecognitionScript.chinese,
      OcrLanguage.japanese => TextRecognitionScript.japanese,
      OcrLanguage.korean => TextRecognitionScript.korean,
      OcrLanguage.devanagari => TextRecognitionScript.devanagiri,
    };
    return TextRecognizer(script: script);
  }

  Stream<OcrPageResult> recognise(
    String pdfPath, {
    required OcrAccuracyMode mode,
    required OcrLanguage language,
  }) async* {
    final TextRecognizer recogniser = _recogniserFor(language);
    final pdfx.PdfDocument doc = await pdfx.PdfDocument.openFile(pdfPath);
    final double scale = mode == OcrAccuracyMode.fast ? 2.0 : 4.0;

    try {
      for (int i = 1; i <= doc.pagesCount; i++) {
        final pdfx.PdfPage page = await doc.getPage(i);
        final pdfx.PdfPageImage? img = await page.render(
          width: page.width * scale,
          height: page.height * scale,
          format: pdfx.PdfPageImageFormat.png,
          backgroundColor: '#FFFFFFFF',
        );
        await page.close();
        if (img == null) continue;

        // Persist temp file so InputImage.fromFilePath works on both
        // Android (which prefers file paths) and iOS reliably.
        final File tmp = File('${pdfPath}_p$i.tmp.png');
        await tmp.writeAsBytes(img.bytes);

        final InputImage input = InputImage.fromFilePath(tmp.path);
        final RecognizedText recognised =
            await recogniser.processImage(input);
        await tmp.delete();

        final List<OcrTextBlock> blocks = recognised.blocks
            .map((TextBlock b) => OcrTextBlock(
                  text: b.text,
                  boundingBox: b.boundingBox,
                  language: b.recognizedLanguages.isNotEmpty
                      ? b.recognizedLanguages.first
                      : 'und',
                ),)
            .toList();

        // ML Kit doesn't return a numeric confidence per block, but
        // we can derive a useful proxy from the structure of the
        // recognition result:
        //   - blocks: more blocks usually means more text was detected
        //   - elements per block: ML Kit splits text into lines + elements
        //     based on confidence in segmentation; sparse element counts
        //     correlate with poor recognition
        //   - character density per block area: very low density (e.g.
        //     2 chars in a huge bounding box) suggests garbage detection
        // We expose a single 0.0-1.0 proxy AND log the raw signals so
        // adb logcat lets us tune.
        final int totalElements = recognised.blocks
            .fold<int>(0, (sum, b) => sum + b.lines.fold<int>(0, (s, l) => s + l.elements.length));
        final int totalChars = recognised.text.length;
        // Map to a 0-1 score: 50+ elements + 200+ chars is "high confidence";
        // 0 elements / 0 chars is "no text detected".
        final double elementScore = (totalElements.clamp(0, 80)) / 80.0;
        final double charScore = (totalChars.clamp(0, 400)) / 400.0;
        final double confProxy = (elementScore * 0.5) + (charScore * 0.5);

        appLogger.i(
          'OCR p${i}: scale=${scale}x · blocks=${blocks.length} · '
          'elements=$totalElements · chars=$totalChars · '
          'confProxy=${confProxy.toStringAsFixed(2)} · '
          'mode=${mode.name}',
        );
        if (blocks.isEmpty) {
          appLogger.w(
            'OCR p${i}: ZERO blocks detected — page may be image-only, '
            'rotated, or use a script not in ${language.name}. Consider '
            'bumping to OcrAccuracyMode.accurate (4.0x).',
          );
        }

        yield OcrPageResult(
          pageIndex: i - 1,
          text: recognised.text,
          blocks: blocks,
          confidence: confProxy,
        );
      }
    } finally {
      await recogniser.close();
      await doc.close();
    }
  }
}
