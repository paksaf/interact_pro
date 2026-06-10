import '../../../../core/utils/result.dart';

enum ScanFilter { original, blackAndWhite, grayscale, photo, magicColor }

abstract class ScannerRepository {
  /// Launches the native document scanner, returns paths to per-page images.
  Future<Result<List<String>>> capturePages();

  /// Combines scanned pages into a single PDF; returns the new PDF path.
  Future<Result<String>> buildPdf({
    required List<String> imagePaths,
    required ScanFilter filter,
    String? documentName,
  });
}
