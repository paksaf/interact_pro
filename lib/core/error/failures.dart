/// Sealed failure hierarchy. Repositories return `Result<T>` (see `result.dart`)
/// containing one of these on the error branch instead of throwing across
/// layers — keeps presentation code free of try/catch.
sealed class Failure {
  const Failure(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => '$runtimeType($message)';
}

class StorageFailure extends Failure {
  const StorageFailure(super.message, {super.cause});
}

class NetworkFailure extends Failure {
  const NetworkFailure(super.message, {super.cause});
}

class AuthFailure extends Failure {
  const AuthFailure(super.message, {super.cause});
}

class PdfFailure extends Failure {
  const PdfFailure(super.message, {super.cause});
}

class OcrFailure extends Failure {
  const OcrFailure(super.message, {super.cause});
}

class CameraFailure extends Failure {
  const CameraFailure(super.message, {super.cause});
}

class PermissionFailure extends Failure {
  const PermissionFailure(super.message, {super.cause});
}

class DriveQuotaFailure extends Failure {
  const DriveQuotaFailure(super.message, {super.cause});
}

class SignedDocumentFailure extends Failure {
  /// Thrown when the user tries to edit a digitally-signed PDF (PRD edge case).
  const SignedDocumentFailure(super.message, {super.cause});
}

class UnknownFailure extends Failure {
  const UnknownFailure(super.message, {super.cause});
}

/// Feature isn't available on the current OS / build (e.g. iCloud on Android).
class PlatformNotSupportedFailure extends Failure {
  const PlatformNotSupportedFailure(super.message, {super.cause});
}

/// LAN discovery / transfer / pairing failed (network, permission, mismatch).
class LanFailure extends Failure {
  const LanFailure(super.message, {super.cause});
}

/// Pair handshake rejected — wrong PIN, expired challenge, peer denied.
class PairingFailure extends Failure {
  const PairingFailure(super.message, {super.cause});
}

/// Casting / screen mirroring failed — no receiver picked, OS share sheet
/// dismissed, page render failed, or the receiver protocol returned an error.
class CastFailure extends Failure {
  const CastFailure(super.message, {super.cause});
}
