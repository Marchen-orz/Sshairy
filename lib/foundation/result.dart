/// An expected failure: a stable [code] callers can switch on, and whether trying again may help.
class AppError {
  const AppError(this.code, {this.detail = '', this.retryable = false});

  final String code;

  /// Safe to show and log: never contains secrets.
  final String detail;
  final bool retryable;

  @override
  String toString() => detail.isEmpty ? code : '$code: $detail';
}

sealed class Result<T> {
  const Result();
}

final class Ok<T> extends Result<T> {
  const Ok(this.value);
  final T value;
}

final class Err<T> extends Result<T> {
  const Err(this.error);
  final AppError error;
}
