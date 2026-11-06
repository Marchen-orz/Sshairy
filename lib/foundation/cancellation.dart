import 'dart:async';

/// Cancelling must stop the work and release its resources; a timeout only stops waiting (docs/CONTRACTS.md §1).
class CancellationToken {
  final _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}
