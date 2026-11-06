import '../../../foundation/file_system.dart';
import '../../../l10n/app_localizations.dart';
import '../application/file_ops.dart';
import '../application/transfers.dart';

String formatSize(int? bytes) {
  if (bytes == null) return '';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return u == 0 ? '$bytes B' : '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[u]}';
}

String formatTime(DateTime? t) {
  if (t == null) return '';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// `rwxr-xr-x`, as `ls -l` shows it.
String formatMode(int? mode) {
  if (mode == null) return '';
  const letters = 'rwx';
  return [for (var i = 8; i >= 0; i--) mode & (1 << i) != 0 ? letters[(8 - i) % 3] : '-'].join();
}

/// The message for a failure code from file operations, transfers and edits.
String fileErrorCode(AppLocalizations l, String code) => switch (code) {
  'notFound' => l.errFsNotFound,
  'permission' => l.errFsPermission,
  'exists' || 'conflict' => l.errFsExists,
  'unsupported' => l.errFsUnsupported,
  'lost' => l.errFsLost,
  'badName' => l.errBadName,
  'sizeMismatch' => l.errSizeMismatch,
  'targetChanged' => l.errTargetChanged,
  'replaceUnsupported' => l.errReplaceUnsupported,
  'sourceMissing' || 'hostMissing' => l.errSourceMissing,
  'tooMany' => l.errTooMany(maxScanEntries),
  'tooDeep' => l.errTooDeep(maxScanDepth),
  'stalled' => l.errStalled,
  'unsupportedType' || 'notAFile' => l.errNotRegular,
  'sourceChanged' => l.errSourceChanged,
  'partInvalid' => l.errPartInvalid,
  'tooLarge' => l.errTooLarge,
  'connect' => l.errConnect(''),
  'cancelled' => l.tsCancelled,
  _ => l.errFsFailed,
};

String fileError(AppLocalizations l, Object? e) => switch (e) {
  FsError(:final kind) => fileErrorCode(l, kind.name),
  OpFailure(:final code) => fileErrorCode(l, code),
  _ => l.errFsFailed,
};
