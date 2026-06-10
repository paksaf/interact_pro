import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import '../../../../core/error/failures.dart';
import '../../../../core/storage/app_paths.dart';
import '../../../../core/utils/result.dart';
import '../../../viewer/data/repositories/pdf_repository_impl.dart';
import '../../../viewer/domain/entities/pdf_document.dart';
import '../../../viewer/domain/repositories/pdf_repository.dart';
import '../../domain/entities/ocr_result.dart';
import '../../domain/repositories/ocr_repository.dart';
import '../datasources/mlkit_ocr_datasource.dart';

class OcrRepositoryImpl implements OcrRepository {
  OcrRepositoryImpl({
    required MlKitOcrDatasource mlkit,
    required PdfRepository pdfRepo,
    required AppPaths paths,
  })  : _mlkit = mlkit,
        _pdfRepo = pdfRepo,
        _paths = paths;

  final MlKitOcrDatasource _mlkit;
  final PdfRepository _pdfRepo;
  final AppPaths _paths;

  @override
  Future<Result<bool>> isAlreadySearchable(PdfDocument doc) async {
    try {
      final List<int> bytes = await File(doc.path).readAsBytes();
      final sf.PdfDocument pdf = sf.PdfDocument(inputBytes: bytes);
      final sf.PdfTextExtractor extractor = sf.PdfTextExtractor(pdf);
      // Sample first ~3 pages: if they yield non-trivial text, it's already
      // searchable. Cheaper than scanning the whole doc.
      final int sampleEnd = pdf.pages.count > 3 ? 2 : pdf.pages.count - 1;
      final String sample = extractor.extractText(
        startPageIndex: 0,
        endPageIndex: sampleEnd,
      );
      pdf.dispose();
      return Result<bool>.ok(sample.trim().length > 50);
    } catch (e) {
      return Result<bool>.err(OcrFailure('Searchability check failed', cause: e));
    }
  }

  @override
  Stream<Result<OcrPageResult>> recognise(
    PdfDocument doc, {
    required OcrAccuracyMode mode,
    required OcrLanguage language,
  }) async* {
    try {
      await for (final OcrPageResult r in _mlkit.recognise(
        doc.path,
        mode: mode,
        language: language,
      )) {
        yield Result<OcrPageResult>.ok(r);
      }
    } catch (e) {
      yield Result<OcrPageResult>.err(OcrFailure('OCR failed', cause: e));
    }
  }

  @override
  Future<Result<PdfDocument>> buildSearchablePdf(
    PdfDocument source,
    List<OcrPageResult> pages, {
    required String outputFilename,
  }) async {
    // PRD OCR-05: overlay invisible (or low-opacity) text on top of the
    // original page graphics so search/select works while the visual
    // appearance is unchanged.
    //
    // Sketch:
    //   1. Open the source PDF with Syncfusion.
    //   2. For each page, for each OCR block, draw text at its
    //      `boundingBox` using `pdf.pages[i].graphics.drawString(...)`
    //      with `PdfPen(color: transparent)`.
    //   3. Save → return new PdfDocument.
    return const Result<PdfDocument>.err(
      OcrFailure('buildSearchablePdf not yet implemented'),
    );
  }

  @override
  Future<Result<String>> exportPlainText(
    List<OcrPageResult> pages, {
    required String outputFilename,
  }) async {
    try {
      final String combined = pages
          .map((OcrPageResult p) => '── Page ${p.pageIndex + 1} ──\n${p.text}')
          .join('\n\n');
      final File f = File('${_paths.pdfDir.path}/$outputFilename');
      await f.writeAsString(combined);
      return Result<String>.ok(f.path);
    } catch (e) {
      return Result<String>.err(StorageFailure('Export failed', cause: e));
    }
  }
}

final FutureProvider<OcrRepository> ocrRepositoryProvider =
    FutureProvider<OcrRepository>((Ref ref) async {
  final AppPaths paths = await ref.watch(appPathsProvider.future);
  final PdfRepository pdfRepo = await ref.watch(pdfRepositoryProvider.future);
  return OcrRepositoryImpl(
    mlkit: MlKitOcrDatasource(),
    pdfRepo: pdfRepo,
    paths: paths,
  );
});
