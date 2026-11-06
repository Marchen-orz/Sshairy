import '../../../foundation/cancellation.dart';

enum InsertResult { sent, unavailable, rejected, stale, cancelled }

class InsertPreview {
  const InsertPreview(this.target, this.text, {required this.run});
  final String target, text;
  final bool run;

  String get visibleText => text.runes.map((r) {
    if (r == 10 || r == 9) return String.fromCharCode(r);
    if (r < 32) return '^${String.fromCharCode(r + 64)}';
    if (r == 127) return '^?';
    if (r >= 128 && r <= 159) return '<U+${r.toRadixString(16).toUpperCase()}>';
    return String.fromCharCode(r);
  }).join();
}

typedef ConfirmInsert = Future<bool> Function(InsertPreview preview);

bool insertNeedsConfirmation(String text, {required bool run, required bool confirmMultiline}) =>
    run ||
    text.runes.any((r) => (r < 32 && r != 9 && r != 10) || (r >= 127 && r <= 159)) ||
    (confirmMultiline && text.contains('\n'));

/// Approval is tied to the shell captured by the caller, never to a later connection.
Future<InsertResult> approveInsertion({
  required InsertPreview preview,
  required bool confirmMultiline,
  required bool Function() current,
  required void Function() send,
  ConfirmInsert? confirm,
  CancellationToken? cancel,
}) async {
  if (cancel?.isCancelled ?? false) return InsertResult.cancelled;
  if (!current()) return InsertResult.unavailable;
  if (insertNeedsConfirmation(preview.text, run: preview.run, confirmMultiline: confirmMultiline)) {
    if (confirm == null) return InsertResult.rejected;
    final approval = confirm(preview);
    final accepted = cancel == null
        ? await approval
        : await Future.any([approval, cancel.whenCancelled.then((_) => false)]);
    if (cancel?.isCancelled ?? false) return InsertResult.cancelled;
    if (!accepted) return InsertResult.rejected;
  }
  if (cancel?.isCancelled ?? false) return InsertResult.cancelled;
  if (!current()) return InsertResult.stale;
  send();
  return InsertResult.sent;
}
