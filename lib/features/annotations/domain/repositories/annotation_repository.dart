import '../../../../core/utils/result.dart';
import '../../../viewer/domain/entities/pdf_document.dart';
import '../entities/annotation.dart';
import '../entities/signature.dart';
import '../entities/stamp.dart';

abstract interface class AnnotationRepository {
  // Annotations (highlights, redactions, notes).
  Future<Result<PdfDocument>> addAnnotation(
    PdfDocument doc,
    Annotation annotation,
  );
  Future<Result<List<Annotation>>> listAnnotations(PdfDocument doc);
  Future<Result<void>> deleteAnnotation(String annotationId);

  // Signatures (PRD SIGN-01..06).
  Future<Result<SignaturePreset>> saveSignaturePreset(SignaturePreset preset);
  Future<Result<List<SignaturePreset>>> listSignaturePresets();
  Future<Result<void>> deleteSignaturePreset(String presetId);

  Future<Result<PdfDocument>> placeSignature(
    PdfDocument doc,
    PlacedSignature signature,
  );

  /// PRD SIGN-05.
  Future<Result<PdfDocument>> applyCertificateSignature(
    PdfDocument doc, {
    required String pkcs12Path,
    required String password,
    required int pageIndex,
  });

  /// PRD SIGN-06: validate any digital signatures already on the doc.
  Future<Result<List<DigitalSignatureValidation>>> validateSignatures(
    PdfDocument doc,
  );

  // Stamps (PRD STAMP-01..05).
  Future<Result<PdfDocument>> placeStamp(
    PdfDocument doc,
    Stamp stamp,
    PlacedStamp placement,
  );
}

class DigitalSignatureValidation {
  const DigitalSignatureValidation({
    required this.signerName,
    required this.signedAt,
    required this.isValid,
    required this.reason,
  });
  final String signerName;
  final DateTime signedAt;
  final bool isValid;
  final String reason;
}
