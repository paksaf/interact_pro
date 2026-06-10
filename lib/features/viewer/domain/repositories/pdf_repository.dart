import 'dart:ui' show Rect;

import '../../../../core/utils/result.dart';
import '../../../annotations/domain/entities/stamp.dart';
import '../entities/pdf_document.dart';

/// Domain-level contract. The viewer/editor/ocr/scanner features all depend
/// on this — never on the concrete `PdfRepositoryImpl`.
abstract interface class PdfRepository {
  Future<Result<PdfDocument>> open(String path);
  Future<Result<List<PdfDocument>>> listLocal();
  Future<Result<PdfDocument>> save(PdfDocument doc);
  Future<Result<void>> delete(String id);

  /// PRD EDIT-05: extract pages.
  Future<Result<PdfDocument>> extractPages(
    PdfDocument source,
    List<int> pageIndexes, {
    required String outputFilename,
  });

  /// PRD EDIT-06: rotate single page.
  Future<Result<PdfDocument>> rotatePage(
    PdfDocument doc,
    int pageIndex,
    int degrees,
  );

  /// PRD EDIT-08: flatten layers into one non-editable PDF for sharing.
  Future<Result<PdfDocument>> flatten(PdfDocument doc);

  /// PRD: detect existing digital signatures so we can warn before editing.
  Future<Result<bool>> hasDigitalSignature(String path);

  /// Stamps an image (typically a transparent-background signature PNG) onto
  /// the given page at the given rect, in PDF coordinate space (points,
  /// origin at top-left as drawn by Syncfusion). The mutation is in-place
  /// against [doc.path] and the returned document reflects the new bytes.
  Future<Result<PdfDocument>> placeSignature({
    required PdfDocument doc,
    required int pageIndex,
    required Rect position,
    required String imagePath,
  });

  /// Places a [Stamp] (predefined / custom text / image / dynamic) onto
  /// [pageIndex] at [position] in PDF point space. Dynamic fields are
  /// resolved against [docName] and DateTime.now() at the call site.
  ///
  /// Text stamps render as a rounded coloured border with the stamp text
  /// inside — the standard "rubber stamp" look. Image stamps draw the
  /// PNG/JPEG with the stamp's opacity applied via a PdfGraphicsState.
  Future<Result<PdfDocument>> placeStamp({
    required PdfDocument doc,
    required int pageIndex,
    required Rect position,
    required Stamp stamp,
    required String docName,
  });

  /// Combine [sources] into a single PDF, preserving page order across
  /// the input list. Returns the merged document, indexed in drift like
  /// any other.
  Future<Result<PdfDocument>> mergePdfs(
    List<PdfDocument> sources, {
    required String outputFilename,
  });

  /// Render [text] (or an image at [imagePath]) as a watermark on every
  /// page of [doc]. Provide one or the other — both null = no-op error.
  ///
  /// Watermark renders centred on each page with optional rotation and
  /// opacity. Text uses the stamp colour; image uses its own pixels with
  /// the opacity applied via PdfGraphicsState. Mutates [doc.path] in
  /// place; returns the same doc with refreshed metadata.
  Future<Result<PdfDocument>> addWatermark({
    required PdfDocument doc,
    String? text,
    String? imagePath,
    double opacity = 0.18,
    double rotationDegrees = -45,
    int fontSize = 64,
  });
}
