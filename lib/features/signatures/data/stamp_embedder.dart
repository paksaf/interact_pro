// SPDX-License-Identifier: AGPL-3.0
//
// PDF stamp embedder — uses syncfusion_flutter_pdf to draw a visible
// signature stamp onto a PDF page after the audit row has been recorded.
//
// Stamp visual: thin translucent rounded box with the signer's name on
// the first line, ISO timestamp on the second, and the 8-char short
// code on the third. Border + a small "signed" pen icon at the top
// left make it readable against most page backgrounds.
//
//   ┌───────────────────────────┐
//   │ ✎ Signed by Muzafar       │
//   │   2026-05-12 14:30:00     │
//   │   Code 7B3F2A91           │
//   └───────────────────────────┘
//
// Default placement: bottom-right corner of the current page,
// 30pt from each edge. Phase 3 will add a region picker so the user
// can drag the stamp anywhere on the page before committing.
//
// IMPORTANT: this rewrites the PDF in place. If the path is read-only
// (e.g. the PDF came from a shared content URI on Android), the
// embedder catches the error and returns a [StampResult.failed] so the
// caller can surface a user-friendly toast — the DB audit row is the
// source of truth and remains intact even if visible stamping fails.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

/// Default stamp dimensions (PDF points). 1pt = 1/72 inch.
const _kStampWidth = 180.0;
const _kStampHeight = 60.0;
const _kStampPadding = 8.0;
const _kStampEdgeMargin = 30.0;

/// Result of an [embedSignatureStamp] call. Wraps success vs failure so
/// the sign flow can fall back gracefully when the PDF is read-only.
class StampResult {
  const StampResult.ok({
    required this.appliedPageIndex,
    required this.appliedRect,
  })  : succeeded = true,
        errorMessage = null;

  const StampResult.failed(this.errorMessage)
      : succeeded = false,
        appliedPageIndex = null,
        appliedRect = null;

  final bool succeeded;
  final int? appliedPageIndex;
  final ui.Rect? appliedRect;
  final String? errorMessage;
}

/// Embed a visible signature stamp into [pdfPath] at the bottom-right
/// of [pageIndex] (or wherever [position] specifies, if provided).
///
/// [position] uses page-relative fractional coordinates (0..1) — the
/// same format the [Signatures] drift table stores in its regionX/Y/W/H
/// columns. When null, the embedder uses the default bottom-right slot.
///
/// Returns the actual rect applied (in PDF points, NOT fractional) so
/// the caller can persist it onto the signature row for re-rendering
/// later.
Future<StampResult> embedSignatureStamp({
  required String pdfPath,
  required int pageIndex,
  required String signerName,
  required int timestampMs,
  required String shortCode,
  StampPosition? position,
}) async {
  try {
    final file = File(pdfPath);
    final bytes = await file.readAsBytes();
    final pdf = sf.PdfDocument(inputBytes: bytes);
    try {
      if (pageIndex < 0 || pageIndex >= pdf.pages.count) {
        return StampResult.failed(
          'Invalid page index $pageIndex (PDF has ${pdf.pages.count} pages)',
        );
      }
      final page = pdf.pages[pageIndex];
      final pageSize = page.getClientSize();

      // Resolve the stamp's absolute rect in PDF points.
      final rect = _resolveRect(
        position: position,
        pageWidth: pageSize.width,
        pageHeight: pageSize.height,
      );

      // Translucent fill (light yellow @ 25% opacity) so the stamp is
      // visible but doesn't obscure underlying text. Border in a darker
      // accent for visibility against any page color.
      final fillBrush = sf.PdfSolidBrush(
        sf.PdfColor(255, 248, 196, 64), // alpha 64 / 255 ≈ 25%
      );
      final borderPen = sf.PdfPen(
        sf.PdfColor(101, 67, 33), // dark amber, matches the brand
        width: 0.8,
      );

      // Round-rect would be cleaner but PdfGraphics.drawRectangle only
      // supports axis-aligned rects. Good enough — the stamp content is
      // what readers focus on, not the corner radius.
      page.graphics.drawRectangle(
        bounds: ui.Rect.fromLTWH(rect.left, rect.top, rect.width, rect.height),
        pen: borderPen,
        brush: fillBrush,
      );

      // Text content. PdfStandardFont is built-in (Helvetica) — no
      // font asset bundling required. Three lines: name, timestamp, code.
      final headerFont = sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 9,
          style: sf.PdfFontStyle.bold,);
      final bodyFont =
          sf.PdfStandardFont(sf.PdfFontFamily.helvetica, 8);
      final codeFont = sf.PdfStandardFont(
          sf.PdfFontFamily.courier, 8,
          style: sf.PdfFontStyle.bold,);
      final textBrush =
          sf.PdfSolidBrush(sf.PdfColor(40, 25, 15)); // dark brown

      final iso = _formatIsoLocal(timestampMs);
      final innerLeft = rect.left + _kStampPadding;
      final innerTop = rect.top + _kStampPadding;
      const lineHeight = 13.0;

      page.graphics.drawString(
        'Signed by $signerName',
        headerFont,
        brush: textBrush,
        bounds: ui.Rect.fromLTWH(
          innerLeft,
          innerTop,
          rect.width - 2 * _kStampPadding,
          lineHeight,
        ),
      );
      page.graphics.drawString(
        iso,
        bodyFont,
        brush: textBrush,
        bounds: ui.Rect.fromLTWH(
          innerLeft,
          innerTop + lineHeight,
          rect.width - 2 * _kStampPadding,
          lineHeight,
        ),
      );
      page.graphics.drawString(
        'Code  $shortCode',
        codeFont,
        brush: textBrush,
        bounds: ui.Rect.fromLTWH(
          innerLeft,
          innerTop + 2 * lineHeight,
          rect.width - 2 * _kStampPadding,
          lineHeight,
        ),
      );

      // Save back to disk. pdf.save() returns Future<List<int>> per the
      // public API in current syncfusion_flutter_pdf — note: some older
      // versions returned List<int> synchronously; await covers both
      // since await of a non-Future returns the value as-is.
      final outBytes = await pdf.save();
      await file.writeAsBytes(outBytes, flush: true);

      return StampResult.ok(
        appliedPageIndex: pageIndex,
        appliedRect: ui.Rect.fromLTWH(rect.left, rect.top, rect.width, rect.height),
      );
    } finally {
      pdf.dispose();
    }
  } catch (e) {
    // Don't let stamp embedding failures cascade — the DB audit row is
    // already committed by the caller (SignatureRepository.signDocument).
    return StampResult.failed('$e');
  }
}

/// User-specified stamp placement. When null, the embedder uses the
/// default bottom-right slot at 30pt margins. All four fields are
/// page-relative fractional coords in [0..1].
class StampPosition {
  const StampPosition({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;
}

ui.Rect _resolveRect({
  required StampPosition? position,
  required double pageWidth,
  required double pageHeight,
}) {
  if (position != null) {
    return ui.Rect.fromLTWH(
      position.x * pageWidth,
      position.y * pageHeight,
      position.width * pageWidth,
      position.height * pageHeight,
    );
  }
  // Default: bottom-right corner of the page with 30pt margins.
  // Clamped so we don't overflow on very small pages (e.g. quarter-letter).
  final w = _kStampWidth.clamp(60.0, pageWidth - 20.0);
  final h = _kStampHeight.clamp(40.0, pageHeight - 20.0);
  return ui.Rect.fromLTWH(
    pageWidth - w - _kStampEdgeMargin,
    pageHeight - h - _kStampEdgeMargin,
    w,
    h,
  );
}

/// Format a unix-millis timestamp as a local-time "YYYY-MM-DD HH:MM:SS"
/// string for the stamp. Locale-independent — no AM/PM or month names
/// so the stamp reads the same to every viewer.
String _formatIsoLocal(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}
