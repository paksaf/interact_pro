/// Pure domain entity. No Isar/JSON annotations here — those live on the
/// data-layer model (`PdfDocumentEntity`) which maps to/from this.
class PdfDocument {
  const PdfDocument({
    required this.id,
    required this.path,
    required this.title,
    required this.pageCount,
    required this.sizeBytes,
    required this.createdAt,
    required this.updatedAt,
    this.driveFileId,
    this.thumbnailPath,
    this.isOcrApplied = false,
    this.isFlattened = false,
    this.isDigitallySigned = false,
  });

  final String id;
  final String path;
  final String title;
  final int pageCount;
  final int sizeBytes;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Drive file id once uploaded (PRD GDR-02).
  final String? driveFileId;
  final String? thumbnailPath;
  final bool isOcrApplied;
  final bool isFlattened;

  /// PRD edge case: warn before editing a digitally-signed PDF.
  final bool isDigitallySigned;

  PdfDocument copyWith({
    String? id,
    String? path,
    String? title,
    int? pageCount,
    int? sizeBytes,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? driveFileId,
    String? thumbnailPath,
    bool? isOcrApplied,
    bool? isFlattened,
    bool? isDigitallySigned,
  }) =>
      PdfDocument(
        id: id ?? this.id,
        path: path ?? this.path,
        title: title ?? this.title,
        pageCount: pageCount ?? this.pageCount,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        driveFileId: driveFileId ?? this.driveFileId,
        thumbnailPath: thumbnailPath ?? this.thumbnailPath,
        isOcrApplied: isOcrApplied ?? this.isOcrApplied,
        isFlattened: isFlattened ?? this.isFlattened,
        isDigitallySigned: isDigitallySigned ?? this.isDigitallySigned,
      );
}
