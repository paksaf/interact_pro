import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color, Offset, Rect;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'package:uuid/uuid.dart';

import '../../../../core/error/failures.dart';
import '../../../../core/utils/result.dart';
import '../../../sync/data/auto_sync_service.dart';
import '../../../viewer/data/repositories/pdf_repository_impl.dart';
import '../../../viewer/domain/entities/pdf_document.dart';
import '../../../viewer/domain/repositories/pdf_repository.dart';
import '../../domain/entities/annotation.dart';
import '../../domain/entities/signature.dart';
import '../../domain/entities/stamp.dart';
import '../../domain/repositories/annotation_repository.dart';

class AnnotationRepositoryImpl implements AnnotationRepository {
  AnnotationRepositoryImpl(this._pdfRepo, {AutoSyncService? autoSync})
      : _autoSync = autoSync;
  final PdfRepository _pdfRepo;
  final Uuid _uuid = const Uuid();

  /// Spike F — debounced cloud auto-upload after each save. Null when
  /// the provider couldn't construct it (rare; doesn't fail the save).
  final AutoSyncService? _autoSync;

  /// Single hook called from every `writeAsBytes` site. Idempotent
  /// when AutoSync is disabled or the doc id is empty.
  void _afterSave(String documentId) {
    if (documentId.isEmpty) return;
    // ignore: discarded_futures
    _autoSync?.triggerForDocument(documentId);
  }

  // ── Annotations ────────────────────────────────────────────────────────────
  @override
  Future<Result<PdfDocument>> addAnnotation(
    PdfDocument doc,
    Annotation annotation,
  ) async {
    try {
      final List<int> bytes = await File(doc.path).readAsBytes();
      final sf.PdfDocument pdf = sf.PdfDocument(inputBytes: bytes);
      final sf.PdfPage page = pdf.pages[annotation.pageIndex];

      switch (annotation) {
        case HighlightAnnotation(:final Color color, :final HighlightStyle style, :final String text):
          final sf.PdfTextMarkupAnnotation markup = sf.PdfTextMarkupAnnotation(
            annotation.bounds,
            text,
            _toPdfColor(color),
          );
          markup.textMarkupAnnotationType = switch (style) {
            HighlightStyle.highlight => sf.PdfTextMarkupAnnotationType.highlight,
            HighlightStyle.underline => sf.PdfTextMarkupAnnotationType.underline,
            HighlightStyle.strikeout => sf.PdfTextMarkupAnnotationType.strikethrough,
          };
          page.annotations.add(markup);

        case RedactAnnotation(:final Color fillColor):
          // Visual-only redaction: black box. True redaction (removes the
          // underlying text from the content stream) needs Syncfusion's
          // PdfRedactionAnnotation + page.applyRedaction, which is a
          // licenced feature — keep the simpler path here.
          page.graphics.drawRectangle(
            brush: sf.PdfSolidBrush(_toPdfColor(fillColor)),
            bounds: annotation.bounds,
          );

        case NoteAnnotation(:final String note):
          final sf.PdfPopupAnnotation popup = sf.PdfPopupAnnotation(
            annotation.bounds,
            note,
          );
          page.annotations.add(popup);

        // ── #256: shape primitives ─────────────────────────────────
        // Baked directly into the page graphics rather than added as
        // sf.PdfAnnotation subtypes. Reason: PdfPolygonAnnotation and
        // PdfLineAnnotation in Syncfusion don't round-trip cleanly
        // through external PDF viewers — Acrobat/Preview ignore the
        // /AP appearance stream and re-render their own which looks
        // different from what we drew. Baking via page.graphics
        // produces a single content-stream entry every viewer
        // renders identically.
        case ShapeAnnotation(
          :final ShapeKind kind,
          :final Color strokeColor,
          :final double strokeWidth,
          :final Color? fillColor,
        ):
          final pen = sf.PdfPen(
            _toPdfColor(strokeColor),
            width: strokeWidth,
          );
          final brush = fillColor == null
              ? null
              : sf.PdfSolidBrush(_toPdfColor(fillColor));
          final r = annotation.bounds;
          switch (kind) {
            case ShapeKind.circle:
            case ShapeKind.ellipse:
              page.graphics.drawEllipse(r, pen: pen, brush: brush);
            case ShapeKind.rectangle:
              page.graphics.drawRectangle(
                pen: pen,
                brush: brush,
                bounds: r,
              );
            case ShapeKind.arrow:
              // Arrow = line + filled triangle head. We orient the
              // head along bounds.topLeft → bounds.bottomRight so
              // user-drawn "from start to end" matches the diagonal
              // of the bounding rect they dragged.
              page.graphics.drawLine(
                pen,
                r.topLeft,
                r.bottomRight,
              );
              final dx = r.bottomRight.dx - r.topLeft.dx;
              final dy = r.bottomRight.dy - r.topLeft.dy;
              final len = (dx * dx + dy * dy).abs();
              final head = strokeWidth * 4;
              if (len > 0) {
                // Compute a small triangle at the bottomRight pointing
                // along the line. Simpler than full vector math:
                // just draw a tiny filled triangle perpendicular to
                // the line direction.
                final path = sf.PdfPath()
                  ..addLine(
                    r.bottomRight,
                    Rect.fromCircle(
                      center: r.bottomRight,
                      radius: head,
                    ).topLeft,
                  )
                  ..addLine(
                    r.bottomRight,
                    Rect.fromCircle(
                      center: r.bottomRight,
                      radius: head,
                    ).bottomLeft,
                  );
                page.graphics.drawPath(
                  path,
                  pen: pen,
                  brush: sf.PdfSolidBrush(_toPdfColor(strokeColor)),
                );
              }
          }

        // ── #256: freehand ink / highlighter ───────────────────────
        // Polyline through the normalised points scaled to the page's
        // bounding rect. Same rationale as ShapeAnnotation for baking
        // into graphics rather than using PdfInkAnnotation (which has
        // its own appearance-stream interop issues across viewers).
        case InkAnnotation(
          :final List<Offset> points,
          :final Color color,
          :final double strokeWidth,
          :final bool isHighlighter,
        ):
          if (points.length >= 2) {
            final r = annotation.bounds;
            // Highlighter = wider, semi-transparent. Marker = solid
            // narrow stroke. Both rendered as a connected polyline.
            final renderColor = isHighlighter
                ? Color.fromARGB(
                    (color.alpha * 0.35).round(),
                    color.red,
                    color.green,
                    color.blue,
                  )
                : color;
            final pen = sf.PdfPen(
              _toPdfColor(renderColor),
              width: isHighlighter ? strokeWidth * 4 : strokeWidth,
            );
            // Un-normalise: points are 0..1 in page space, scale to
            // the annotation bounds (which is the bbox of the stroke).
            final scaled = points
                .map((p) => Offset(
                      r.left + p.dx * r.width,
                      r.top + p.dy * r.height,
                    ),)
                .toList();
            final path = sf.PdfPath();
            for (var i = 1; i < scaled.length; i++) {
              path.addLine(scaled[i - 1], scaled[i]);
            }
            page.graphics.drawPath(path, pen: pen);
          }
      }

      final List<int> outBytes = await pdf.save();
      await File(doc.path).writeAsBytes(outBytes);
      pdf.dispose();
      _afterSave(doc.id); // Spike F — queue cloud upload
      return _pdfRepo.open(doc.path);
    } catch (e) {
      return Result<PdfDocument>.err(PdfFailure('Annotation failed', cause: e));
    }
  }

  @override
  Future<Result<List<Annotation>>> listAnnotations(PdfDocument doc) async {
    // TODO(scaffold): pull from Isar; the Syncfusion `PdfAnnotationCollection`
    // has the rendered annotations but our domain wants metadata too
    // (author, createdAt) — store those locally on add.
    return const Result<List<Annotation>>.ok(<Annotation>[]);
  }

  @override
  Future<Result<void>> deleteAnnotation(String annotationId) async =>
      const Result<void>.ok(null); // TODO(scaffold): Isar delete + rewrite PDF.

  // ── Signatures ─────────────────────────────────────────────────────────────
  //
  // Persistence: SharedPreferences with a JSON-encoded list under the
  // single key `_kSignaturePresets`. The asset files (PNG / .p12) live
  // on disk independently — we only store the path. We deliberately
  // skipped Drift here because the table would have a single row of
  // metadata for at most 5 rows; the migration overhead and codegen
  // cost outweigh the type safety.
  //
  // PRD SIGN-03 caps the list at 5. saveSignaturePreset enforces this
  // by deleting the oldest preset (lowest `createdAt`) when full —
  // FIFO is more useful than rejecting the new save, which would
  // require a separate UI flow to ask the user which to evict.

  static const String _kSignaturePresets = 'sig_presets_v1';
  static const int _maxPresets = 5;

  @override
  Future<Result<SignaturePreset>> saveSignaturePreset(
    SignaturePreset preset,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final current = _readPresets(prefs);

      // De-dup by id — saving an existing id is an update.
      current.removeWhere((p) => p.id == preset.id);
      current.add(preset);

      // Enforce max-5 FIFO. Sort by createdAt asc, drop the head.
      if (current.length > _maxPresets) {
        current.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        while (current.length > _maxPresets) {
          final evicted = current.removeAt(0);
          // Best-effort cleanup of the orphaned asset file. We ignore
          // errors — if the file's already gone, fine; if it's locked,
          // the OS will reap it.
          // ignore: discarded_futures
          File(evicted.assetPath).delete().catchError((_) => File(evicted.assetPath));
        }
      }

      await _writePresets(prefs, current);
      return Result<SignaturePreset>.ok(preset);
    } catch (e) {
      return Result<SignaturePreset>.err(
        PdfFailure('Could not save signature preset', cause: e),
      );
    }
  }

  @override
  Future<Result<List<SignaturePreset>>> listSignaturePresets() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final presets = _readPresets(prefs);
      // Sort newest-first so the most recently saved appears at the
      // top of the Sign sheet's preset row.
      presets.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return Result<List<SignaturePreset>>.ok(presets);
    } catch (e) {
      return Result<List<SignaturePreset>>.err(
        PdfFailure('Could not load signature presets', cause: e),
      );
    }
  }

  @override
  Future<Result<void>> deleteSignaturePreset(String presetId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final current = _readPresets(prefs);
      final removed = <SignaturePreset>[];
      current.removeWhere((p) {
        if (p.id == presetId) {
          removed.add(p);
          return true;
        }
        return false;
      });
      await _writePresets(prefs, current);
      // Best-effort cleanup of asset files for the removed presets.
      for (final r in removed) {
        // ignore: discarded_futures
        File(r.assetPath).delete().catchError((_) => File(r.assetPath));
      }
      return const Result<void>.ok(null);
    } catch (e) {
      return Result<void>.err(
        PdfFailure('Could not delete signature preset', cause: e),
      );
    }
  }

  /// SharedPreferences serialisation — kept here (not on the entity)
  /// because it's storage-layer concern. If we ever migrate to Drift
  /// or Isar, only this helper changes.
  List<SignaturePreset> _readPresets(SharedPreferences prefs) {
    final raw = prefs.getString(_kSignaturePresets);
    if (raw == null || raw.isEmpty) return <SignaturePreset>[];
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return list.map(_presetFromJson).toList(growable: true);
    } catch (_) {
      // Corrupt blob (e.g., a partial write or schema drift) — return
      // empty rather than throwing. The user can re-save presets.
      return <SignaturePreset>[];
    }
  }

  Future<void> _writePresets(
    SharedPreferences prefs,
    List<SignaturePreset> presets,
  ) async {
    final list = presets.map(_presetToJson).toList();
    await prefs.setString(_kSignaturePresets, jsonEncode(list));
  }

  Map<String, dynamic> _presetToJson(SignaturePreset p) => <String, dynamic>{
        'id': p.id,
        'name': p.name,
        'kind': p.kind.name,
        'assetPath': p.assetPath,
        'createdAt': p.createdAt.toIso8601String(),
      };

  SignaturePreset _presetFromJson(Map<String, dynamic> j) => SignaturePreset(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        kind: SignatureKind.values.firstWhere(
          (e) => e.name == (j['kind'] as String? ?? 'drawn'),
          orElse: () => SignatureKind.drawn,
        ),
        assetPath: j['assetPath'] as String? ?? '',
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ??
            DateTime.now(),
      );

  @override
  Future<Result<PdfDocument>> placeSignature(
    PdfDocument doc,
    PlacedSignature signature,
  ) async {
    try {
      final List<int> bytes = await File(doc.path).readAsBytes();
      final sf.PdfDocument pdf = sf.PdfDocument(inputBytes: bytes);
      final sf.PdfPage page = pdf.pages[signature.pageIndex];

      switch (signature.preset.kind) {
        case SignatureKind.drawn:
        case SignatureKind.imported:
        case SignatureKind.typed:
          // PNG asset → draw onto the page at the chosen rect.
          final sf.PdfBitmap img = sf.PdfBitmap(
            await File(signature.preset.assetPath).readAsBytes(),
          );
          page.graphics.drawImage(img, signature.bounds);

        case SignatureKind.certificate:
          // Should be applied via `applyCertificateSignature` — falling
          // through here is a programmer error.
          throw const PdfException(
            'Use applyCertificateSignature for cert-based signing',
          );
      }

      final List<int> out = await pdf.save();
      await File(doc.path).writeAsBytes(out);
      pdf.dispose();
      _afterSave(doc.id); // Spike F — queue cloud upload
      return _pdfRepo.open(doc.path);
    } catch (e) {
      return Result<PdfDocument>.err(PdfFailure('Place signature failed', cause: e));
    }
  }

  @override
  Future<Result<PdfDocument>> applyCertificateSignature(
    PdfDocument doc, {
    required String pkcs12Path,
    required String password,
    required int pageIndex,
  }) async {
    try {
      final List<int> bytes = await File(doc.path).readAsBytes();
      final sf.PdfDocument pdf = sf.PdfDocument(inputBytes: bytes);

      final sf.PdfCertificate cert = sf.PdfCertificate(
        await File(pkcs12Path).readAsBytes(),
        password,
      );
      final sf.PdfSignatureField field = sf.PdfSignatureField(
        pdf.pages[pageIndex],
        'IP_Sig_${_uuid.v4()}',
        bounds: const Rect.fromLTWH(40, 40, 200, 60),
        signature: sf.PdfSignature(
          certificate: cert,
          contactInfo: 'Interact Pro',
          locationInfo: 'On-device',
          reason: 'Document approval',
        ),
      );
      pdf.form.fields.add(field);

      final List<int> out = await pdf.save();
      await File(doc.path).writeAsBytes(out);
      pdf.dispose();
      _afterSave(doc.id); // Spike F — queue cloud upload
      return _pdfRepo.open(doc.path);
    } catch (e) {
      return Result<PdfDocument>.err(PdfFailure('Cert signing failed', cause: e));
    }
  }

  @override
  Future<Result<List<DigitalSignatureValidation>>> validateSignatures(
    PdfDocument doc,
  ) async {
    // TODO(scaffold): iterate pdf.form.fields, filter PdfSignatureField,
    // call signature.validateSignature(...) on each, return validation rows.
    return const Result<List<DigitalSignatureValidation>>.ok(
      <DigitalSignatureValidation>[],
    );
  }

  // ── Stamps ─────────────────────────────────────────────────────────────────
  @override
  Future<Result<PdfDocument>> placeStamp(
    PdfDocument doc,
    Stamp stamp,
    PlacedStamp placement,
  ) async {
    try {
      final List<int> bytes = await File(doc.path).readAsBytes();
      final sf.PdfDocument pdf = sf.PdfDocument(inputBytes: bytes);
      final sf.PdfPage page = pdf.pages[placement.pageIndex];

      final String resolvedText = _resolveDynamicText(
        stamp,
        pageIndex: placement.pageIndex,
        documentName: doc.title,
      );

      switch (stamp.kind) {
        case StampKind.image:
          if (stamp.imagePath != null) {
            final sf.PdfBitmap img =
                sf.PdfBitmap(await File(stamp.imagePath!).readAsBytes());
            page.graphics.setTransparency(stamp.opacity);
            page.graphics.drawImage(img, placement.bounds);
            page.graphics.setTransparency(1.0);
          }

        case StampKind.predefined:
        case StampKind.customText:
        case StampKind.dynamic_:
          page.graphics.setTransparency(stamp.opacity);
          // Syncfusion 33.x removed the `helveticaBold` family — bold is now
          // a style modifier on the base family. Same render result.
          page.graphics.drawString(
            resolvedText,
            sf.PdfStandardFont(
              sf.PdfFontFamily.helvetica,
              28,
              style: sf.PdfFontStyle.bold,
            ),
            brush: sf.PdfSolidBrush(_toPdfColor(stamp.color)),
            bounds: placement.bounds,
          );
          page.graphics.setTransparency(1.0);
      }

      final List<int> out = await pdf.save();
      await File(doc.path).writeAsBytes(out);
      pdf.dispose();
      _afterSave(doc.id); // Spike F — queue cloud upload
      return _pdfRepo.open(doc.path);
    } catch (e) {
      return Result<PdfDocument>.err(PdfFailure('Place stamp failed', cause: e));
    }
  }

  String _resolveDynamicText(
    Stamp stamp, {
    required int pageIndex,
    required String documentName,
  }) {
    if (stamp.kind != StampKind.dynamic_) return stamp.text;
    final DateTime now = DateTime.now();
    String text = stamp.text;
    for (final DynamicStampField f in stamp.dynamicFields) {
      final String token = '{${f.name}}';
      final String value = switch (f) {
        DynamicStampField.date => '${now.year}-${now.month}-${now.day}',
        DynamicStampField.time =>
          '${now.hour}:${now.minute.toString().padLeft(2, '0')}',
        DynamicStampField.dateTime => now.toIso8601String(),
        DynamicStampField.user => 'You', // TODO(scaffold): pull from settings
        DynamicStampField.pageNumber => '${pageIndex + 1}',
        DynamicStampField.documentName => documentName,
      };
      text = text.replaceAll(token, value);
    }
    return text;
  }

  sf.PdfColor _toPdfColor(Color c) =>
      sf.PdfColor(c.red, c.green, c.blue, c.alpha);
}

// Minimal PdfException so we don't depend on core/error/exceptions.dart from
// data layer (tighter coupling avoided).
class PdfException implements Exception {
  const PdfException(this.message);
  final String message;
}

final FutureProvider<AnnotationRepository> annotationRepositoryProvider =
    FutureProvider<AnnotationRepository>((Ref ref) async {
  final PdfRepository pdfRepo = await ref.watch(pdfRepositoryProvider.future);
  final autoSync = ref.watch(autoSyncServiceProvider);
  return AnnotationRepositoryImpl(pdfRepo, autoSync: autoSync);
});

// Re-export Rect so the file compiles standalone above.
