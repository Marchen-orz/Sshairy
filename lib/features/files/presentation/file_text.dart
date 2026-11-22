import '../../../design/format.dart';
import '../../../foundation/file_system.dart';
import '../../../l10n/app_localizations.dart';
import '../application/file_ops.dart';
import '../application/transfers.dart';

String formatSize(int? bytes) => bytes == null ? '' : formatFileSize(bytes);

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
  'badName' || 'invalidName' => l.errBadName,
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
  'launchFailed' => l.errLaunchFailed,
  'saveFailed' => l.errSave,
  'connect' => l.errConnect(''),
  'cancelled' => l.tsCancelled,
  _ => l.errFsFailed,
};

String fileError(AppLocalizations l, Object? e) => switch (e) {
  FsError(:final kind) => fileErrorCode(l, kind.name),
  OpFailure(:final code) => fileErrorCode(l, code),
  _ => l.errFsFailed,
};
