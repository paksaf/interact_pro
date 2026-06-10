import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart' as pdfx;

import '../../../core/error/failures.dart';
import '../../../core/utils/logger.dart';
import '../../../core/utils/result.dart';

/// Rasterises one page of a PDF to a PNG file on disk. Used by the cast
/// pipeline to turn the current viewer page into something a screen
/// receiver can display.
///
/// We render at 2.0× device-independent scale by default — high enough
/// for a 1080p TV to show legible body text, low enough that the resulting
/// PNG is in the 1–3MB range and ships over Wi-Fi instantly. The OCR
/// pipeline already uses 1.5×/3.0× and we sit in between deliberately.
final pdfPageRendererProvider = Provider<PdfPageRenderer>((ref) {
  return PdfPageRenderer();
});

class PdfPageRenderer {
  /// 1-indexed page number. Returns the absolute path to a PNG in the
  /// app's temp directory. Caller may delete it; the renderer doesn't track
  /// cleanup beyond overwriting on next render.
  Future<Result<File>> renderPage({
    required String pdfPath,
    required int pageNumber,
    double scale = 2.0,
  }) async {
    pdfx.PdfDocument? doc;
    try {
      doc = await pdfx.PdfDocument.openFile(pdfPath);
      if (pageNumber < 1 || pageNumber > doc.pagesCount) {
        return Result.err(
          CastFailure('Page $pageNumber out of range (1..${doc.pagesCount})'),
        );
      }
      final pdfx.PdfPage page = await doc.getPage(pageNumber);
      // backgroundColor='#FFFFFFFF' is critical — without it, pdfx
      // renders the page with no opaque background, which means any
      // receiver that doesn't fill behind transparent regions
      // displays the cast PNG with a black background (PDF body text
      // becomes white on black, like a dark-mode inversion). Pre-
      // 2026-05-13 this was unset and caused exactly that symptom on
      // Chromecast / Default Media Receiver / TV image viewers.
      final pdfx.PdfPageImage? rendered = await page.render(
        width: page.width * scale,
        height: page.height * scale,
        format: pdfx.PdfPageImageFormat.png,
        backgroundColor: '#FFFFFFFF',
      );
      await page.close();

      if (rendered == null) {
        return Result.err(CastFailure('Page $pageNumber rendered to null'));
      }

      final tmpDir = await getTemporaryDirectory();
      final fileName =
          '${p.basenameWithoutExtension(pdfPath)}_p${pageNumber}_cast.png';
      final out = File(p.join(tmpDir.path, fileName));
      await out.writeAsBytes(rendered.bytes, flush: true);
      return Result.ok(out);
    } catch (e, st) {
      appLogger.e('PdfPageRenderer.renderPage failed', error: e, stackTrace: st);
      return Result.err(CastFailure('Could not render page $pageNumber', cause: e));
    } finally {
      await doc?.close();
    }
  }

  /// Render-to-bytes variant, when the caller wants the PNG bytes directly
  /// (e.g. to stream over an HTTP response without writing to disk first).
  Future<Result<Uint8List>> renderPageBytes({
    required String pdfPath,
    required int pageNumber,
    double scale = 2.0,
  }) async {
    pdfx.PdfDocument? doc;
    try {
      doc = await pdfx.PdfDocument.openFile(pdfPath);
      if (pageNumber < 1 || pageNumber > doc.pagesCount) {
        return Result.err(
          CastFailure('Page $pageNumber out of range (1..${doc.pagesCount})'),
        );
      }
      final pdfx.PdfPage page = await doc.getPage(pageNumber);
      // backgroundColor='#FFFFFFFF' is critical — without it, pdfx
      // renders the page with no opaque background, which means any
      // receiver that doesn't fill behind transparent regions
      // displays the cast PNG with a black background (PDF body text
      // becomes white on black, like a dark-mode inversion). Pre-
      // 2026-05-13 this was unset and caused exactly that symptom on
      // Chromecast / Default Media Receiver / TV image viewers.
      final pdfx.PdfPageImage? rendered = await page.render(
        width: page.width * scale,
        height: page.height * scale,
        format: pdfx.PdfPageImageFormat.png,
        backgroundColor: '#FFFFFFFF',
      );
      await page.close();

      if (rendered == null) {
        return Result.err(CastFailure('Page $pageNumber rendered to null'));
      }
      return Result.ok(rendered.bytes);
    } catch (e, st) {
      appLogger.e('PdfPageRenderer.renderPageBytes failed', error: e, stackTrace: st);
      return Result.err(CastFailure('Could not render page $pageNumber', cause: e));
    } finally {
      await doc?.close();
    }
  }
}
