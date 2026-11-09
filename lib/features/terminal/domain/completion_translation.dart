import '../../../foundation/cancellation.dart';

abstract interface class CompletionTranslationEngine {
  /// Cancellation must release the underlying request, including its response stream.
  Future<String?> translate(String original, String target, CancellationToken cancel);
  void dispose();
}

class CompletionTranslationFailure implements Exception {
  const CompletionTranslationFailure({this.quotaExceeded = false});
  final bool quotaExceeded;
}
