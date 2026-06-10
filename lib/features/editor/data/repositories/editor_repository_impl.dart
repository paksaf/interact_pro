import 'dart:io';
import 'dart:ui' show Color, Offset, Rect;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import '../../../../core/error/failures.dart';
import '../../../../core/utils/result.dart';
import '../../../viewer/data/repositories/pdf_repository_impl.dart';
import '../../../viewer/domain/entities/pdf_document.dart';
import '../../../viewer/domain/repositories/pdf_repository.dart';
import '../../domain/entities/edit_action.dart';
import '../../domain/repositories/editor_repository.dart';

class EditorRepositoryImpl implements EditorRepository {
  EditorRepositoryImpl(this._pdfRepo);
  final PdfRepository _pdfRepo;

  @override
  Future<Result<PdfDocument>> apply(
    PdfDocument doc,
    EditAction action,
  ) async {
    try {
      // PRD edge case: refuse silently destructive edits on a signed PDF —
      // surface it instead so the UI can confirm with the user.
      if (doc.isDigitallySigned) {
        return const Result<PdfDocument>.err(
          SignedDocumentFailure(
            'This PDF is digitally signed. Editing will invalidate the '
            'signature. Confirm to proceed.',
          ),
        );
      }

      final List<int> bytes = await File(doc.path).readAsBytes();
      final sf.PdfDocument pdf = sf.PdfDocument(inputBytes: bytes);

      switch (action) {
        case InsertText(
            :final int pageIndex,
            :final String text,
            :final Offset position,
            :final double fontSize,
            :final Color color,
          ):
          final sf.PdfFont font = sf.PdfStandardFont(
            sf.PdfFontFamily.helvetica,
            fontSize,
          );
          pdf.pages[pageIndex].graphics.drawString(
                text,
                font,
                brush: sf.PdfSolidBrush(_toPdfColor(color)),
                bounds: Rect.fromLTWH(position.dx, position.dy, 500, fontSize * 1.4),
              );

        case EditExistingText():
          // Real implementation: locate the matching text fragment via
          // PdfTextExtractor's position metadata, white-out the region,
          // re-draw with the new string. Out of scope for the scaffold.
          break;

        case InsertImage(:final int pageIndex, :final String sourcePath, :final Rect position):
          final sf.PdfBitmap img =
              sf.PdfBitmap(await File(sourcePath).readAsBytes());
          pdf.pages[pageIndex].graphics.drawImage(img, position);

        case MoveImage():
          // Requires tracking inserted images by id; defer to full impl.
          break;

        case DeletePage(:final int pageIndex):
          pdf.pages.removeAt(pageIndex);

        case RotatePage(:final int pageIndex, :final int degrees, :final int? previousRotation):
          // Prefer the rotation snapshot the UI captured at click time —
          // that's the only value we *know* is correct. If absent (legacy
          // action), fall back to reading the rotation now (less reliable
          // because Syncfusion's getter has been seen returning stale data
          // after save+reopen).
          final base = previousRotation ??
              _rotationDegrees(pdf.pages[pageIndex].rotation);
          pdf.pages[pageIndex].rotation = _rot(base + degrees);
      }

      final List<int> outBytes = await pdf.save();
      // flush: true blocks until the OS actually fsync()s the bytes to disk.
      // Without this, a fast viewer reload can read the *previous* bytes from
      // the page cache. Costs ~5-50ms; correctness wins.
      await File(doc.path).writeAsBytes(outBytes, flush: true);
      pdf.dispose();
      return _pdfRepo.open(doc.path);
    } catch (e) {
      return Result<PdfDocument>.err(PdfFailure('Edit failed', cause: e));
    }
  }

  @override
  Future<Result<PdfDocument>> undo(
    PdfDocument doc,
    EditAction action,
  ) async {
    // Inverse-action approach. For the most common cases:
    //   InsertText      → erase region by overlaying white rect
    //   EditExistingText→ apply with previousText/newText swapped
    //   MoveImage       → swap from/to
    //   InsertImage     → erase region (or remove last image stamp)
    //   DeletePage      → re-import from a snapshot (only path that needs one)
    //   RotatePage      → apply -degrees
    //
    // For the scaffold we only handle RotatePage since it's pure.
    // The two branches must share a common Future return type — wrap the
    // synchronous Err in Future.value so the switch expression is uniformly
    // `Future<Result<PdfDocument>>`.
    return switch (action) {
      // Bulletproof rotate-undo: directly write back the captured pre-state.
      // No additive math, no trusting the Syncfusion getter. The UI is
      // expected to populate previousRotation on every Rotate action it
      // emits; we fall back to inverting via -degrees only for older actions
      // that don't carry the snapshot.
      RotatePage(
        :final int pageIndex,
        :final int degrees,
        :final int? previousRotation,
      ) =>
        previousRotation != null
            ? _setRotationAbsolute(doc, pageIndex, previousRotation)
            : apply(
                doc,
                RotatePage(
                  pageIndex: pageIndex,
                  timestamp: DateTime.now(),
                  degrees: -degrees,
                ),
              ),
      _ => Future<Result<PdfDocument>>.value(
          const Result<PdfDocument>.err(
            PdfFailure('Undo for this action not yet implemented'),
          ),
        ),
    };
  }

  /// Sets `pages[pageIndex].rotation` to an absolute degree value and saves.
  /// Used by Rotate undo — bypasses the additive logic in `apply()`.
  Future<Result<PdfDocument>> _setRotationAbsolute(
    PdfDocument doc,
    int pageIndex,
    int absoluteDegrees,
  ) async {
    try {
      final List<int> bytes = await File(doc.path).readAsBytes();
      final sf.PdfDocument pdf = sf.PdfDocument(inputBytes: bytes);
      pdf.pages[pageIndex].rotation = _rot(absoluteDegrees);
      final List<int> out = await pdf.save();
      await File(doc.path).writeAsBytes(out, flush: true);
      pdf.dispose();
      return _pdfRepo.open(doc.path);
    } catch (e) {
      return Result<PdfDocument>.err(PdfFailure('Rotate undo failed', cause: e));
    }
  }

  sf.PdfColor _toPdfColor(Color c) =>
      sf.PdfColor(c.red, c.green, c.blue, c.alpha);

  /// Inverse of [_rot]: read the current rotation as integer degrees so we
  /// can do additive math. Dart's `%` returns non-negative for positive
  /// divisors so `(_ + -90) % 360` rolls 0° → 270° correctly.
  int _rotationDegrees(sf.PdfPageRotateAngle r) => switch (r) {
        sf.PdfPageRotateAngle.rotateAngle90 => 90,
        sf.PdfPageRotateAngle.rotateAngle180 => 180,
        sf.PdfPageRotateAngle.rotateAngle270 => 270,
        _ => 0,
      };

  sf.PdfPageRotateAngle _rot(int d) => switch (d % 360) {
        90 => sf.PdfPageRotateAngle.rotateAngle90,
        180 => sf.PdfPageRotateAngle.rotateAngle180,
        270 => sf.PdfPageRotateAngle.rotateAngle270,
        _ => sf.PdfPageRotateAngle.rotateAngle0,
      };
}

final FutureProvider<EditorRepository> editorRepositoryProvider =
    FutureProvider<EditorRepository>((Ref ref) async {
  final PdfRepository pdfRepo = await ref.watch(pdfRepositoryProvider.future);
  return EditorRepositoryImpl(pdfRepo);
});
