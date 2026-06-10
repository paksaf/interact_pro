import '../error/failures.dart';

/// Lightweight Either-style result type. Use over throwing exceptions
/// across layer boundaries:
///
/// ```dart
/// Future<Result<PdfDocument>> open(String path) async {
///   try {
///     return Result.ok(await _datasource.open(path));
///   } on PdfException catch (e) {
///     return Result.err(PdfFailure(e.message, cause: e));
///   }
/// }
/// ```
sealed class Result<T> {
  const Result();

  const factory Result.ok(T value) = Ok<T>;
  const factory Result.err(Failure failure) = Err<T>;

  bool get isOk => this is Ok<T>;
  bool get isErr => this is Err<T>;

  T? get valueOrNull => switch (this) {
        Ok<T>(:final T value) => value,
        Err<T>() => null,
      };

  Failure? get failureOrNull => switch (this) {
        Ok<T>() => null,
        Err<T>(:final Failure failure) => failure,
      };

  R fold<R>(R Function(T) onOk, R Function(Failure) onErr) => switch (this) {
        Ok<T>(:final T value) => onOk(value),
        Err<T>(:final Failure failure) => onErr(failure),
      };

  Result<R> map<R>(R Function(T) f) => switch (this) {
        Ok<T>(:final T value) => Result<R>.ok(f(value)),
        Err<T>(:final Failure failure) => Result<R>.err(failure),
      };
}

final class Ok<T> extends Result<T> {
  const Ok(this.value);
  final T value;
}

final class Err<T> extends Result<T> {
  const Err(this.failure);
  final Failure failure;
}
