import 'dart:io';
import 'dart:typed_data';

import 'package:cunning_document_scanner/cunning_document_scanner.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart' as pw;
import 'package:pdf/widgets.dart' as pwi;

import '../../../../core/error/failures.dart';
import '../../../../core/storage/app_paths.dart';
import '../../../../core/utils/result.dart';
import '../../domain/repositories/scanner_repository.dart';

final scannerRepositoryProvider = Provider<ScannerRepository>((Ref ref) {
  return ScannerRepositoryImpl(ref);
});

class ScannerRepositoryImpl implements ScannerRepository {
  ScannerRepositoryImpl(this._ref);
  final Ref _ref;

  @override
  Future<Result<List<String>>> capturePages() async {
    try {
      final paths = await CunningDocumentScanner.getPictures() ?? <String>[];
      return Result.ok(paths);
    } catch (e) {
      return Result.err(CameraFailure('Scanner cancelled or failed', cause: e));
    }
  }

  @override
  Future<Result<String>> buildPdf({
    required List<String> imagePaths,
    required ScanFilter filter,
    String? documentName,
  }) async {
    try {
      final pdf = pwi.Document();
      for (final path in imagePaths) {
        final bytes = await File(path).readAsBytes();
        final processed = _applyFilter(bytes, filter);
        final pdfImage = pwi.MemoryImage(processed);
        pdf.addPage(pwi.Page(
          pageFormat: pw.PdfPageFormat.a4,
          build: (_) => pwi.Center(
            child: pwi.Image(pdfImage, fit: pwi.BoxFit.contain),
          ),
        ),);
      }

      final paths = await _ref.read(appPathsProvider.future);
      final outName = '${documentName ?? 'Scan_${DateTime.now().millisecondsSinceEpoch}'}.pdf';
      final out = File(p.join(paths.pdfDir.path, outName));
      await out.writeAsBytes(await pdf.save());
      return Result.ok(out.path);
    } catch (e) {
      return Result.err(StorageFailure('Failed to build PDF', cause: e));
    }
  }

  Uint8List _applyFilter(Uint8List bytes, ScanFilter filter) {
    if (filter == ScanFilter.original) return bytes;
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;

    img.Image out;
    switch (filter) {
      case ScanFilter.grayscale:
        out = img.grayscale(decoded);
      case ScanFilter.blackAndWhite:
        out = img.luminanceThreshold(img.grayscale(decoded), threshold: 0.5);
      case ScanFilter.photo:
        out = img.adjustColor(decoded, contrast: 1.1, saturation: 1.15);
      case ScanFilter.magicColor:
        out = img.adjustColor(decoded, contrast: 1.4, brightness: 1.05, saturation: 1.2);
      case ScanFilter.original:
        out = decoded;
    }
    return Uint8List.fromList(img.encodeJpg(out, quality: 88));
  }
}
