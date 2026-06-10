import '../../../../core/utils/result.dart';
import '../../../viewer/domain/entities/pdf_document.dart';
import '../entities/ocr_result.dart';

abstract interface class OcrRepository {
  /// PRD OCR-03: returns true if the PDF already has selectable text and
  /// OCR can be skipped.
  Future<Result<bool>> isAlreadySearchable(PdfDocument doc);

  /// PRD OCR-01 / OCR-04: run OCR on every page of `doc`. Emits per-page
  /// results so the UI can show progress (notification + side panel).
  Stream<Result<OcrPageResult>> recognise(
    PdfDocument doc, {
    required OcrAccuracyMode mode,
    required OcrLanguage language,
  });

  /// PRD OCR-05: build a new PDF with an invisible selectable text layer
  /// over the original raster pages.
  Future<Result<PdfDocument>> buildSearchablePdf(
    PdfDocument source,
    List<OcrPageResult> pages, {
    required String outputFilename,
  });

  /// PRD OCR-06: dump combined text to a `.txt` file.
  Future<Result<String>> exportPlainText(
    List<OcrPageResult> pages, {
    required String outputFilename,
  });
}
