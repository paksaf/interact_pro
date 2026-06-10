import '../../../../core/utils/result.dart';
import '../../../viewer/domain/entities/pdf_document.dart';
import '../entities/edit_action.dart';

/// Editor backs the PRD's EDIT-01..08 requirements.
abstract interface class EditorRepository {
  /// Apply an action to the document and persist it. Repository is
  /// responsible for translating the abstract action into actual PDF
  /// graphics calls (Syncfusion).
  Future<Result<PdfDocument>> apply(PdfDocument doc, EditAction action);

  /// Apply the inverse — used by undo. Implementations should construct
  /// the inverse command rather than restoring from a saved snapshot
  /// (snapshots blow up on large PDFs).
  Future<Result<PdfDocument>> undo(PdfDocument doc, EditAction action);
}
