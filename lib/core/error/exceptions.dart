/// Thrown by datasources. Repositories catch these and convert to
/// `Failure` types in `failures.dart`.
class StorageException implements Exception {
  StorageException(this.message);
  final String message;
  @override
  String toString() => 'StorageException: $message';
}

class NetworkException implements Exception {
  NetworkException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'NetworkException($statusCode): $message';
}

class AuthException implements Exception {
  AuthException(this.message);
  final String message;
  @override
  String toString() => 'AuthException: $message';
}

class PdfException implements Exception {
  PdfException(this.message);
  final String message;
  @override
  String toString() => 'PdfException: $message';
}

class OcrException implements Exception {
  OcrException(this.message);
  final String message;
  @override
  String toString() => 'OcrException: $message';
}
