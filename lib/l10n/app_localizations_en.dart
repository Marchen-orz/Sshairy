// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get hosts => 'Hosts';

  @override
  String get newHost => 'New host';

  @override
  String get searchHint => 'Search hosts or user@host';

  @override
  String connectTo(String target) {
    return 'Connect $target';
  }

  @override
  String get connect => 'Connect';

  @override
  String get edit => 'Edit';

  @override
  String get delete => 'Delete';

  @override
  String deleteHost(String name) {
    return 'Delete $name?';
  }

  @override
  String get save => 'Save';

  @override
  String get cancel => 'Cancel';

  @override
  String get close => 'Close';

  @override
  String get retry => 'Reconnect';

  @override
  String get label => 'Name';

  @override
  String get address => 'Address';

  @override
  String get port => 'Port';

  @override
  String get username => 'Username';

  @override
  String get password => 'Password';

  @override
  String get privateKey => 'Private key';

  @override
  String get keyPath => 'Private key file';

  @override
  String get passphrase => 'Key passphrase';

  @override
  String get remember => 'Remember';

  @override
  String get required => 'Required';

  @override
  String get invalidPort => '1–65535';

  @override
  String get connecting => 'Connecting…';

  @override
  String get disconnected => 'Disconnected';

  @override
  String get hostKeyUnknown => 'Unknown host';

  @override
  String get hostKeyChanged => 'Host key changed';

  @override
  String get hostKeyChangedWarning =>
      'This may be a man-in-the-middle attack. Replace only if you know the server key was changed.';

  @override
  String get previousKey => 'Saved';

  @override
  String get currentKey => 'Received';

  @override
  String get trustOnce => 'Trust once';

  @override
  String get trustSave => 'Trust';

  @override
  String get replaceKey => 'Replace saved key';

  @override
  String errConnect(String detail) {
    return 'Cannot connect: $detail';
  }

  @override
  String get errAuth => 'Authentication failed';

  @override
  String get errHostKeyRejected => 'Host key rejected';

  @override
  String errKeyFile(String detail) {
    return 'Cannot read private key: $detail';
  }

  @override
  String get errCancelled => 'Cancelled';

  @override
  String get settings => 'Settings';

  @override
  String get theme => 'Theme';

  @override
  String get themeSystem => 'System';

  @override
  String get themeLight => 'Light';

  @override
  String get themeDark => 'Dark';

  @override
  String get fontSize => 'Terminal font size';

  @override
  String get language => 'Language';

  @override
  String get langZh => '中文';

  @override
  String get langEn => 'English';

  @override
  String get paste => 'Paste';

  @override
  String get noMatches => 'No matching hosts';

  @override
  String get more => 'More';

  @override
  String get renderer => 'Renderer';

  @override
  String get restartToApply => 'Takes effect after restart';

  @override
  String get accent => 'Accent color';

  @override
  String get accentBlue => 'Blue';

  @override
  String get accentGreen => 'Green';

  @override
  String get accentViolet => 'Violet';

  @override
  String get accentOrange => 'Orange';

  @override
  String get commandPalette => 'Command palette';

  @override
  String get paletteHint => 'Hosts, sessions, actions';

  @override
  String get split => 'Split';

  @override
  String get splitRight => 'Split right';

  @override
  String get splitDown => 'Split down';

  @override
  String get closePane => 'Close pane';

  @override
  String get newConnection => 'New connection';

  @override
  String get appearance => 'Appearance';

  @override
  String get terminal => 'Terminal';

  @override
  String get connection => 'Connection';

  @override
  String get dataSecurity => 'Data & security';

  @override
  String get about => 'About';

  @override
  String get cursorShape => 'Cursor';

  @override
  String get cursorBlock => 'Block';

  @override
  String get cursorUnderline => 'Underline';

  @override
  String get cursorBar => 'Bar';

  @override
  String get scrollback => 'Scrollback lines';

  @override
  String get copyOnSelect => 'Copy on select';

  @override
  String get rightClick => 'Right click';

  @override
  String get rightClickMenu => 'Menu';

  @override
  String get confirmPaste => 'Confirm multi-line paste';

  @override
  String get connectTimeout => 'Connect timeout';

  @override
  String get keepAlive => 'Keepalive';

  @override
  String get idleTtl => 'Keep idle connections';

  @override
  String get autoReconnect => 'Reconnect automatically';

  @override
  String get off => 'Off';

  @override
  String seconds(int n) {
    return '$n s';
  }

  @override
  String get appliesNextConnection => 'Applies to new connections';

  @override
  String get appliesNewSessions => 'Applies to new sessions';

  @override
  String get trustedKeys => 'Trusted host keys';

  @override
  String get none => 'None';

  @override
  String get remove => 'Remove';

  @override
  String get version => 'Version';

  @override
  String get dataDir => 'Data folder';

  @override
  String get open => 'Open';

  @override
  String get find => 'Find';

  @override
  String matchCount(int current, int total) {
    return '$current/$total';
  }

  @override
  String get noResults => 'No results';

  @override
  String get previous => 'Previous';

  @override
  String get next => 'Next';

  @override
  String get caseSensitive => 'Match case';

  @override
  String get regex => 'Regular expression';

  @override
  String get copy => 'Copy';

  @override
  String get selectAll => 'Select all';

  @override
  String get clearScreen => 'Clear';

  @override
  String get openLink => 'Open link';

  @override
  String get copyLink => 'Copy link';

  @override
  String get rename => 'Rename';

  @override
  String get duplicate => 'Duplicate';

  @override
  String reconnectingIn(int n) {
    return 'Reconnecting in $n s';
  }

  @override
  String get stop => 'Stop';

  @override
  String get keys => 'Keys';

  @override
  String get importKey => 'Import key';

  @override
  String get generateKey => 'Generate key';

  @override
  String get keySource => 'Private key or file path';

  @override
  String get keyFile => 'Key file';

  @override
  String get copyPublicKey => 'Copy public key';

  @override
  String keyInUse(String names) {
    return 'Used by $names';
  }

  @override
  String deleteKey(String name) {
    return 'Delete key $name? Hosts can no longer use it.';
  }

  @override
  String get errKeyUnsupported => 'Not a supported private key';

  @override
  String get errKeyNeedsPassphrase =>
      'This key is encrypted; enter its passphrase';

  @override
  String get errKeyWrongPassphrase => 'Wrong passphrase';

  @override
  String errKeyDuplicate(String name) {
    return 'Already imported as $name';
  }

  @override
  String get errKeyUnreadable => 'Cannot read the file';

  @override
  String get group => 'Group';

  @override
  String get tags => 'Tags';

  @override
  String get tagsHint => 'Comma separated';

  @override
  String get allHosts => 'All';

  @override
  String get pin => 'Pin';

  @override
  String get unpin => 'Unpin';

  @override
  String get sortName => 'By name';

  @override
  String get sortRecent => 'By recent use';

  @override
  String get gridView => 'Grid';

  @override
  String get listView => 'List';

  @override
  String copyOf(String name) {
    return '$name copy';
  }

  @override
  String get renameGroup => 'Rename group';

  @override
  String get dissolveGroup => 'Dissolve group';

  @override
  String get sftp => 'SFTP';

  @override
  String get files => 'Files';

  @override
  String get thisComputer => 'This computer';

  @override
  String get back => 'Back';

  @override
  String get forward => 'Forward';

  @override
  String get up => 'Up';

  @override
  String get refresh => 'Refresh';

  @override
  String get filter => 'Filter';

  @override
  String get editPath => 'Edit path';

  @override
  String get newFolder => 'New folder';

  @override
  String get hiddenFiles => 'Hidden files';

  @override
  String get uploadFiles => 'Upload files…';

  @override
  String get downloadTo => 'Download to…';

  @override
  String get sendToOther => 'Send to the other side';

  @override
  String get editFile => 'Edit';

  @override
  String get copyPath => 'Copy path';

  @override
  String get permissions => 'Permissions';

  @override
  String get colName => 'Name';

  @override
  String get colModified => 'Modified';

  @override
  String get colSize => 'Size';

  @override
  String get colOwner => 'Owner';

  @override
  String get emptyFolder => 'Empty';

  @override
  String deleteOne(String name) {
    return 'Delete \"$name\"?';
  }

  @override
  String deleteTree(String name, int count) {
    return 'Delete \"$name\" and the $count items in it?';
  }

  @override
  String deleteMany(int count) {
    return 'Delete $count items?';
  }

  @override
  String get permOwner => 'Owner';

  @override
  String get permGroup => 'Group';

  @override
  String get permOthers => 'Others';

  @override
  String get permRead => 'Read';

  @override
  String get permWrite => 'Write';

  @override
  String get permExecute => 'Execute';

  @override
  String get transfers => 'Transfers';

  @override
  String get clearFinished => 'Clear finished';

  @override
  String get tsQueued => 'Queued';

  @override
  String get tsWaiting => 'Waiting for your choice';

  @override
  String get tsCompleted => 'Done';

  @override
  String get tsFailed => 'Failed';

  @override
  String get tsCancelled => 'Cancelled';

  @override
  String get tsInterrupted => 'Interrupted';

  @override
  String get tsScanning => 'Scanning';

  @override
  String get tsVerifying => 'Verifying';

  @override
  String get tsPublishing => 'Finishing';

  @override
  String skippedCount(int count) {
    return '$count skipped';
  }

  @override
  String filesCount(int done, int total) {
    return '$done/$total files';
  }

  @override
  String conflictFile(String name) {
    return '\"$name\" already exists';
  }

  @override
  String conflictDir(String name) {
    return 'Folder \"$name\" already exists';
  }

  @override
  String conflictType(String name) {
    return '\"$name\" already exists as another type';
  }

  @override
  String get existingItem => 'Existing';

  @override
  String get incomingItem => 'Incoming';

  @override
  String get replace => 'Replace';

  @override
  String get merge => 'Merge';

  @override
  String get keepBoth => 'Keep both';

  @override
  String get skip => 'Skip';

  @override
  String get applyToAll => 'Same for the rest of this batch';

  @override
  String get upload => 'Upload';

  @override
  String get autoUpload => 'Upload on save';

  @override
  String get finishEdit => 'Done editing';

  @override
  String discardEdit(String name) {
    return '\"$name\" has changes that were not uploaded. Discard them?';
  }

  @override
  String get discard => 'Discard';

  @override
  String get editConflict => 'Changed on the server since it was downloaded';

  @override
  String get overwrite => 'Overwrite';

  @override
  String get uploadAsCopy => 'Upload as a copy';

  @override
  String get redownload => 'Download again';

  @override
  String get esModified => 'Not uploaded';

  @override
  String get esUploading => 'Uploading';

  @override
  String get esClean => 'Up to date';

  @override
  String get errFsNotFound => 'Not found';

  @override
  String get errFsPermission => 'Permission denied';

  @override
  String get errFsExists => 'Already exists';

  @override
  String get errFsUnsupported => 'Not supported by the server';

  @override
  String get errFsLost => 'Connection lost';

  @override
  String get errFsFailed => 'The operation failed';

  @override
  String get errBadName => 'Not a valid name';

  @override
  String get errSizeMismatch => 'Size check failed; nothing was published';

  @override
  String get errTargetChanged =>
      'The target changed meanwhile and was left alone';

  @override
  String get errReplaceUnsupported =>
      'This server cannot replace files safely; the original was kept';

  @override
  String get errSourceMissing => 'The source is gone';

  @override
  String errTooMany(int count) {
    return 'More than $count items';
  }

  @override
  String errTooDeep(int count) {
    return 'Nested deeper than $count levels';
  }

  @override
  String get errStalled => 'No progress for 30 seconds';

  @override
  String get errNotRegular => 'Not a regular file';

  @override
  String get errTooLarge => 'Over 64 MB; download it instead';

  @override
  String get transferConcurrency => 'Simultaneous transfers';

  @override
  String transfersRunning(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transfers in progress',
      one: '1 transfer in progress',
    );
    return '$_temp0';
  }

  @override
  String editsUnsaved(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count edits not uploaded',
      one: '1 edit not uploaded',
    );
    return '$_temp0';
  }

  @override
  String get quitNote =>
      'Transfers in progress are cancelled. Edits that were not uploaded stay and can be uploaded next time.';

  @override
  String get quit => 'Quit';
}
