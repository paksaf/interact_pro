import 'dart:io';
import 'dart:ui' show Offset, Rect, Size;

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart' as pw;
import 'package:pdf/widgets.dart' as pwi;
import 'package:pdfx/pdfx.dart' as pdfx;
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:uuid/uuid.dart';

import '../../../../core/error/failures.dart';
import '../../../../core/storage/app_database.dart' as db;
import '../../../../core/storage/app_paths.dart';
import '../../../../core/utils/logger.dart';
import '../../../../core/utils/result.dart';
import '../../../annotations/domain/entities/stamp.dart';
import '../../domain/entities/pdf_document.dart';
import '../../domain/repositories/pdf_repository.dart';

/// Default implementation. Uses Syncfusion for PDF inspection / manipulation,
/// drift for metadata persistence, and the filesystem for the bytes.
class PdfRepositoryImpl implements PdfRepository {
  PdfRepositoryImpl(this._paths, this._db);
  final AppPaths _paths;
  final db.AppDatabase _db;
  final Uuid _uuid = const Uuid();

  /// Drift row → domain entity. Single mapping point so the rest of the
  /// codebase keeps using `PdfDocument` (domain) without leaking drift types.
  PdfDocument _toDomain(db.PdfDocument row) => PdfDocument(
        id: row.id,
        path: row.path,
        title: row.title,
        pageCount: row.pageCount,
        sizeBytes: row.sizeBytes,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        driveFileId: row.driveFileId,
        thumbnailPath: row.thumbnailPath,
        isOcrApplied: row.isOcrApplied,
        isFlattened: row.isFlattened,
        isDigitallySigned: row.isDigitallySigned,
      );

  /// Domain entity → drift companion (insert/update payload).
  db.PdfDocumentsCompanion _toCompanion(PdfDocument d) =>
      db.PdfDocumentsCompanion(
        id: Value(d.id),
        path: Value(d.path),
        title: Value(d.title),
        pageCount: Value(d.pageCount),
        sizeBytes: Value(d.sizeBytes),
        createdAt: Value(d.createdAt),
        updatedAt: Value(d.updatedAt),
        driveFileId: Value(d.driveFileId),
        thumbnailPath: Value(d.thumbnailPath),
        isOcrApplied: Value(d.isOcrApplied),
        isFlattened: Value(d.isFlattened),
        isDigitallySigned: Value(d.isDigitallySigned),
      );

  @override
  Future<Result<PdfDocument>> open(String path) async {
    try {
      final File file = File(path);
      if (!file.existsSync()) {
        return Result<PdfDocument>.err(PdfFailure('File not found: $path'));
      }
      final List<int> bytes = await file.readAsBytes();
      final sf.PdfDocument pdf = sf.PdfDocument(inputBytes: bytes);
      final FileStat stat = file.statSync();

      final bool signed = List<int>.generate(
        pdf.form.fields.count,
        (int i) => i,
      )
          .map((int i) => pdf.form.fields[i])
          .whereType<sf.PdfSignatureField>()
          .any((sf.PdfSignatureField f) => f.signature != null);

      // Reuse an existing row's id when we've seen this file before so
      // annotations / sync state survive re-opens.
      final db.PdfDocument? existing = await _db.documentByPath(path);
      final String id = existing?.id ?? _uuid.v4();

      final PdfDocument doc = PdfDocument(
        id: id,
        path: path,
        title: existing?.title ?? p.basenameWithoutExtension(path),
        pageCount: pdf.pages.count,
        sizeBytes: stat.size,
        createdAt: existing?.createdAt ?? stat.changed,
        updatedAt: DateTime.now(),
        driveFileId: existing?.driveFileId,
        thumbnailPath: existing?.thumbnailPath,
        isOcrApplied: existing?.isOcrApplied ?? false,
        isFlattened: existing?.isFlattened ?? false,
        isDigitallySigned: signed,
      );

      // Upsert metadata so the document shows up in Recents.
      await _db.upsertDocument(_toCompanion(doc));

      pdf.dispose();
      return Result<PdfDocument>.ok(doc);
    } catch (e, st) {
      appLogger.e('Failed to open PDF', error: e, stackTrace: st);
      return Result<PdfDocument>.err(PdfFailure('Could not open PDF', cause: e));
    }
  }

  @override
  Future<Result<List<PdfDocument>>> listLocal() async {
    try {
      final rows = await _db.allDocumentsByRecency();
      // Show every row even when the underlying file isn't where the DB
      // remembers it. Reasons it may not exist at the recorded path:
      //   - app reinstall changed the application-documents directory hash
      //   - user moved the file outside the app (Files app, USB transfer)
      //   - Android cleared the app's cache directory between sessions
      //
      // We try a same-basename rescue (file with the same name still in
      // the canonical pdfDir) and rewrite the path if found. Otherwise
      // we keep the row but flip a flag the UI can use to render it as
      // "unavailable — tap to relocate". The previous behaviour silently
      // DELETED the row, which is exactly the "PDF vanished from recents
      // after open" bug the TV user hit.
      final List<PdfDocument> docs = [];
      for (final row in rows) {
        if (File(row.path).existsSync()) {
          docs.add(_toDomain(row));
          continue;
        }
        // Rescue: same basename in the canonical pdfDir → adopt that path.
        final basename = p.basename(row.path);
        final rescued = _paths.pdfPathFor(basename);
        if (rescued != row.path && File(rescued).existsSync()) {
          await _db.upsertDocument(_toCompanion(_toDomain(row).copyWith(path: rescued)));
          docs.add(_toDomain(row).copyWith(path: rescued));
          continue;
        }
        // Truly missing — keep the row in the list but as a placeholder
        // domain entity. UI can render with a warning chip and offer to
        // re-import. We DON'T auto-delete; that destroys user intent
        // (their annotations / sync state are tied to this row's id).
        docs.add(_toDomain(row));
      }
      return Result<List<PdfDocument>>.ok(docs);
    } catch (e, st) {
      appLogger.e('listLocal failed', error: e, stackTrace: st);
      return Result<List<PdfDocument>>.err(
        StorageFailure('Failed listing local PDFs', cause: e),
      );
    }
  }

  @override
  Future<Result<PdfDocument>> save(PdfDocument doc) async {
    try {
      final updated = doc.copyWith(updatedAt: DateTime.now());
      await _db.upsertDocument(_toCompanion(updated));
      return Result<PdfDocument>.ok(updated);
    } catch (e) {
      return Result<PdfDocument>.err(StorageFailure('Save failed', cause: e));
    }
  }

  @override
  Future<Result<void>> delete(String id) async {
    try {
      // Best-effort file removal; row delete is the source of truth.
      final db.PdfDocument? row = await (_db.select(_db.pdfDocuments)
            ..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (row != null) {
        try {
          final f = File(row.path);
          if (f.existsSync()) await f.delete();
        } catch (e) {
          appLogger.w('Failed to delete file at ${row.path}: $e');
        }
      }
      await _db.deleteDocument(id);
      return const Result<void>.ok(null);
    } catch (e) {
      return Result<void>.err(StorageFailure('Delete failed', cause: e));
    }
  }

  @override
  Future<Result<PdfDocument>> extractPages(
    PdfDocument source,
    List<int> pageIndexes, {
    required String outputFilename,
  }) async {
    try {
      final List<int> bytes = await File(source.path).readAsBytes();
      final sf.PdfDocument src = sf.PdfDocument(inputBytes: bytes);
      final sf.PdfDocument out = sf.PdfDocument();

      for (final int i in pageIndexes) {
        if (i < 0 || i >= src.pages.count) continue;
        out.pages.add().graphics.drawPdfTemplate(
              src.pages[i].createTemplate(),
              const Offset(0, 0),
            );
      }

      final List<int> outBytes = await out.save();
      final String outPath = _paths.pdfPathFor(outputFilename);
      await File(outPath).writeAsBytes(outBytes, flush: true);
      src.dispose();
      out.dispose();
      return open(outPath);
    } catch (e) {
      return Result<PdfDocument>.err(PdfFailure('Extract failed', cause: e));
    }
  }

  @override
  Future<Result<PdfDocument>> rotatePage(
    PdfDocument doc,
    int pageIndex,
    int degrees,
  ) async {
    try {
      final List<int> bytes = await File(doc.path).readAsBytes();
      final sf.PdfDocument pdf = sf.PdfDocument(inputBytes: bytes);
      pdf.pages[pageIndex].rotation = _toRotation(degrees);
      final List<int> outBytes = await pdf.save();
      await File(doc.path).writeAsBytes(outBytes, flush: true);
      pdf.dispose();
      return open(doc.path);
    } catch (e) {
      return Result<PdfDocument>.err(PdfFailure('Rotate failed', cause: e));
    }
  }

  sf.PdfPageRotateAngle _toRotation(int degrees) => switch (degrees % 360) {
        90 => sf.PdfPageRotateAngle.rotateAngle90,
        180 => sf.PdfPageRotateAngle.rotateAngle180,
        270 => sf.PdfPageRotateAngle.rotateAngle270,
        _ => sf.PdfPageRotateAngle.rotateAngle0,
      };

  @override
  Future<Result<PdfDocument>> flatten(PdfDocument doc) async {
    pdfx.PdfDocument? src;
    try {
      // 1) Open the source via pdfx (separate from Syncfusion — pdfx renders
      //    pages to bitmap, Syncfusion can't).
      src = await pdfx.PdfDocument.openFile(doc.path);

      // 2) Re-render each page to a PNG and lay it back into a fresh PDF
      //    via the `pdf` package. The result has no selectable text, no
      //    annotations, no form fields — just images per page. That's the
      //    contract: post-flatten the document is read-only by design.
      final out = pwi.Document();
      for (var i = 1; i <= src.pagesCount; i++) {
        final page = await src.getPage(i);
        final image = await page.render(
          // 2x device DPI keeps fonts crisp without exploding file size.
          // 144 DPI is roughly twice the default screen rendering and is
          // the standard "high quality reprint" target.
          width: page.width * 2,
          height: page.height * 2,
          format: pdfx.PdfPageImageFormat.png,
        );
        await page.close();
        if (image == null) continue;

        final memImage = pwi.MemoryImage(image.bytes);
        out.addPage(pwi.Page(
          pageFormat: pw.PdfPageFormat(
            page.width.toDouble(),
            page.height.toDouble(),
            marginAll: 0,
          ),
          build: (_) => pwi.Image(memImage, fit: pwi.BoxFit.fill),
        ),);
      }
      await src.close();
      src = null;

      // 3) Overwrite the original file. The viewer's ValueKey-on-change
      //    pattern will force re-render with the new content.
      final outBytes = await out.save();
      await File(doc.path).writeAsBytes(outBytes, flush: true);

      // 4) Update the metadata flag and persist.
      final updated = doc.copyWith(
        isFlattened: true,
        sizeBytes: outBytes.length,
        updatedAt: DateTime.now(),
      );
      await _db.upsertDocument(_toCompanion(updated));
      return Result<PdfDocument>.ok(updated);
    } catch (e, st) {
      appLogger.e('Flatten failed', error: e, stackTrace: st);
      return Result<PdfDocument>.err(PdfFailure('Flatten failed', cause: e));
    } finally {
      // Make sure pdfx releases native handles even if we threw mid-loop.
      await src?.close().catchError((_) {});
    }
  }

  @override
  Future<Result<bool>> hasDigitalSignature(String path) async {
    final Result<PdfDocument> r = await open(path);
    return r.map((PdfDocument d) => d.isDigitallySigned);
  }

  @override
  Future<Result<PdfDocument>> mergePdfs(
    List<PdfDocument> sources, {
    required String outputFilename,
  }) async {
    if (sources.isEmpty) {
      return const Result<PdfDocument>.err(
        PdfFailure('Merge needs at least one source PDF.'),
      );
    }
    sf.PdfDocument? out;
    final opened = <sf.PdfDocument>[];
    try {
      out = sf.PdfDocument();
      // Open every source first so a load failure on the 5th file aborts
      // before we've half-written the merged output.
      for (final s in sources) {
        final bytes = await File(s.path).readAsBytes();
        opened.add(sf.PdfDocument(inputBytes: bytes));
      }

      // drawPdfTemplate copies a page's full graphics into a new page.
      // Preserves text, images, annotations, vectors — Syncfusion handles
      // resource-dictionary rewiring under the hood.
      for (final src in opened) {
        for (var i = 0; i < src.pages.count; i++) {
          final srcPage = src.pages[i];
          final size = srcPage.size;
          final newPage = out.pages.add();
          newPage.graphics.drawPdfTemplate(
            srcPage.createTemplate(),
            const Offset(0, 0),
            Size(size.width, size.height),
          );
        }
      }

      final outBytes = await out.save();
      final outPath = _paths.pdfPathFor(outputFilename);
      await File(outPath).writeAsBytes(outBytes, flush: true);
      return open(outPath);
    } catch (e, st) {
      appLogger.e('mergePdfs failed', error: e, stackTrace: st);
      return Result<PdfDocument>.err(PdfFailure('Merge failed', cause: e));
    } finally {
      for (final d in opened) {
        try {
          d.dispose();
        } catch (_) {/* best-effort */}
      }
      try {
        out?.dispose();
      } catch (_) {/* best-effort */}
    }
  }

  @override
  Future<Result<PdfDocument>> addWatermark({
    required PdfDocument doc,
    String? text,
    String? imagePath,
    double opacity = 0.18,
    double rotationDegrees = -45,
    int fontSize = 64,
  }) async {
    if ((text == null || text.trim().isEmpty) &&
        (imagePath == null || imagePath.isEmpty)) {
      return const Result<PdfDocument>.err(
        PdfFailure('Watermark needs either text or an image.'),
      );
    }

    sf.PdfDocument? pdf;
    try {
      final bytes = await File(doc.path).readAsBytes();
      pdf = sf.PdfDocument(inputBytes: bytes);

      // Pre-compute reusable resources outside the page loop. Saves a
      // few ms per page on long documents.
      sf.PdfBitmap? stampImg;
      if (imagePath != null && imagePath.isNotEmpty) {
        stampImg = sf.PdfBitmap(await File(imagePath).readAsBytes());
      }
      final font = sf.PdfStandardFont(
        sf.PdfFontFamily.helvetica,
        fontSize.toDouble(),
        style: sf.PdfFontStyle.bold,
      );
      final brush = sf.PdfSolidBrush(sf.PdfColor(60, 60, 60));

      for (var i = 0; i < pdf.pages.count; i++) {
        final page = pdf.pages[i];
        final g = page.graphics;
        final pageW = page.size.width;
        final pageH = page.size.height;

        // Save graphics state so opacity + transform don't bleed into
        // any other drawing on the page (e.g. existing annotations).
        g.save();
        g.setTransparency(opacity.clamp(0.05, 1.0));

        if (stampImg != null) {
          // Image watermark: scale to ~60% of shorter page side, centred.
          final shorter = pageW < pageH ? pageW : pageH;
          final wmSize = shorter * 0.6;
          final left = (pageW - wmSize) / 2.0;
          final top = (pageH - wmSize) / 2.0;
          g.drawImage(stampImg, Rect.fromLTWH(left, top, wmSize, wmSize));
        } else {
          // Text watermark: rotate around page centre, draw the string
          // along that rotation. PDF's translate-rotate-translate idiom.
          final t = text!.trim();
          g.translateTransform(pageW / 2.0, pageH / 2.0);
          g.rotateTransform(rotationDegrees);
          // Draw centred about the rotation origin (which we just moved
          // to page centre). Empirical bounding box is roughly font-size
          // × text-length × 0.55 — good enough for visual centring.
          final approxW = t.length * fontSize * 0.55;
          g.drawString(
            t,
            font,
            brush: brush,
            bounds: Rect.fromLTWH(-approxW / 2, -fontSize.toDouble() / 2, approxW, fontSize.toDouble() * 1.4),
            format: sf.PdfStringFormat(
              alignment: sf.PdfTextAlignment.center,
              lineAlignment: sf.PdfVerticalAlignment.middle,
            ),
          );
        }

        g.restore();
      }

      final outBytes = await pdf.save();
      await File(doc.path).writeAsBytes(outBytes, flush: true);
      return open(doc.path);
    } catch (e, st) {
      appLogger.e('addWatermark failed', error: e, stackTrace: st);
      return Result<PdfDocument>.err(
        PdfFailure('Could not add watermark', cause: e),
      );
    } finally {
      try {
        pdf?.dispose();
      } catch (_) {/* best-effort */}
    }
  }

  @override
  Future<Result<PdfDocument>> placeStamp({
    required PdfDocument doc,
    required int pageIndex,
    required Rect position,
    required Stamp stamp,
    required String docName,
  }) async {
    try {
      final pdfBytes = await File(doc.path).readAsBytes();
      final pdf = sf.PdfDocument(inputBytes: pdfBytes);
      if (pageIndex < 0 || pageIndex >= pdf.pages.count) {
        pdf.dispose();
        return Result<PdfDocument>.err(
          PdfFailure('Page $pageIndex out of range.'),
        );
      }

      final graphics = pdf.pages[pageIndex].graphics;

      // Apply stamp opacity via a transparency state. Syncfusion
      // re-applies the previous state after we draw — caller doesn't
      // need to undo it manually.
      graphics.save();
      graphics.setTransparency(stamp.opacity);

      switch (stamp.kind) {
        case StampKind.image:
          // Image stamps just draw the bitmap inside the rect with the
          // stamp's opacity applied via the graphics state above.
          final imagePath = stamp.imagePath;
          if (imagePath == null || imagePath.isEmpty) {
            graphics.restore();
            pdf.dispose();
            return const Result<PdfDocument>.err(
              PdfFailure('Image stamp is missing its image path.'),
            );
          }
          final stampImg = sf.PdfBitmap(await File(imagePath).readAsBytes());
          graphics.drawImage(stampImg, position);

        case StampKind.predefined:
        case StampKind.customText:
        case StampKind.dynamic_:
          // Resolve dynamic placeholders against the now/document context
          // before rendering. PRD STAMP-03.
          final resolved = _resolveDynamicText(stamp, docName);

          final pdfColor = sf.PdfColor(
            stamp.color.red,
            stamp.color.green,
            stamp.color.blue,
            stamp.color.alpha,
          );
          final pen = sf.PdfPen(pdfColor, width: 2);
          final brush = sf.PdfSolidBrush(pdfColor);

          // Auto-size the text to fit the rect height, with a small
          // inset so the border doesn't clip the glyphs.
          const inset = 6.0;
          final inner = Rect.fromLTWH(
            position.left + inset,
            position.top + inset,
            position.width - inset * 2,
            position.height - inset * 2,
          );
          final fontSize = (inner.height * 0.55).clamp(10.0, 96.0);
          final font = sf.PdfStandardFont(
            sf.PdfFontFamily.helvetica,
            fontSize,
            style: sf.PdfFontStyle.bold,
          );

          // Rounded border + text inside. We mimic the "rubber stamp"
          // look — a thick coloured rectangle with the text centered.
          graphics.drawRectangle(pen: pen, bounds: position);
          graphics.drawString(
            resolved,
            font,
            brush: brush,
            bounds: inner,
            format: sf.PdfStringFormat(
              alignment: sf.PdfTextAlignment.center,
              lineAlignment: sf.PdfVerticalAlignment.middle,
            ),
          );
      }

      graphics.restore();

      final outBytes = await pdf.save();
      await File(doc.path).writeAsBytes(outBytes, flush: true);
      pdf.dispose();
      return open(doc.path);
    } catch (e, st) {
      appLogger.e('placeStamp failed', error: e, stackTrace: st);
      return Result<PdfDocument>.err(
        PdfFailure('Could not place stamp', cause: e),
      );
    }
  }

  /// Substitute dynamic placeholders inside [stamp.text]. Predefined and
  /// custom-text stamps return their text as-is; dynamic stamps may have
  /// {date}, {time}, {datetime}, {user}, {page}, {document} tokens.
  String _resolveDynamicText(Stamp stamp, String docName) {
    var text = stamp.text;
    if (stamp.dynamicFields.isEmpty) return text;

    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final dateStr =
        '${now.year}-${two(now.month)}-${two(now.day)}';
    final timeStr = '${two(now.hour)}:${two(now.minute)}';

    for (final field in stamp.dynamicFields) {
      switch (field) {
        case DynamicStampField.date:
          text = text.replaceAll('{date}', dateStr);
        case DynamicStampField.time:
          text = text.replaceAll('{time}', timeStr);
        case DynamicStampField.dateTime:
          text = text.replaceAll('{datetime}', '$dateStr $timeStr');
        case DynamicStampField.user:
          // We don't track per-user identity in the app yet; fall back
          // to the literal token so the placement is still legible.
          text = text.replaceAll('{user}', 'User');
        case DynamicStampField.pageNumber:
          // Page number isn't known here — caller's responsibility to
          // pre-substitute. We leave the token visible so a misuse is
          // obvious rather than silently wrong.
          break;
        case DynamicStampField.documentName:
          text = text.replaceAll('{document}', docName);
      }
    }
    return text;
  }

  @override
  Future<Result<PdfDocument>> placeSignature({
    required PdfDocument doc,
    required int pageIndex,
    required Rect position,
    required String imagePath,
  }) async {
    try {
      final pdfBytes = await File(doc.path).readAsBytes();
      final pdf = sf.PdfDocument(inputBytes: pdfBytes);
      if (pageIndex < 0 || pageIndex >= pdf.pages.count) {
        pdf.dispose();
        return Result<PdfDocument>.err(
          PdfFailure('Page $pageIndex out of range.'),
        );
      }

      final imageBytes = await File(imagePath).readAsBytes();
      // PdfBitmap accepts PNG / JPEG bytes and preserves alpha for PNG —
      // exactly what we want so the signature's transparent background
      // doesn't paint a white box over the page.
      final stamp = sf.PdfBitmap(imageBytes);

      pdf.pages[pageIndex].graphics.drawImage(
        stamp,
        position,
      );

      final outBytes = await pdf.save();
      await File(doc.path).writeAsBytes(outBytes, flush: true);
      pdf.dispose();

      return open(doc.path);
    } catch (e, st) {
      appLogger.e('placeSignature failed', error: e, stackTrace: st);
      return Result<PdfDocument>.err(
        PdfFailure('Could not place signature', cause: e),
      );
    }
  }
}

final FutureProvider<PdfRepository> pdfRepositoryProvider =
    FutureProvider<PdfRepository>((Ref ref) async {
  final AppPaths paths = await ref.watch(appPathsProvider.future);
  final database = ref.watch(db.appDatabaseProvider);
  return PdfRepositoryImpl(paths, database);
});
