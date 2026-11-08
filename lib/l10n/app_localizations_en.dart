// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String deleteHostsConfirm(int count) {
    return 'Delete the selected $count hosts?';
  }

  @override
  String get hostDeleteCleanupFailed =>
      'Hosts were deleted, but some saved credentials could not be removed. Check OS secure storage.';

  @override
  String get noHosts => 'No hosts yet';

  @override
  String get noHostsInGroup => 'No hosts in this group';

  @override
  String get hostEmptyHint =>
      'Add a host or import saved connections to get started.';

  @override
  String get moveToGroup => 'Move to group…';

  @override
  String moveHostsTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Move $count hosts to group',
      one: 'Move host to group',
    );
    return '$_temp0';
  }

  @override
  String get completionLoading => 'Loading…';

  @override
  String get completionUnavailable => 'Path unavailable';

  @override
  String get completionFailed => 'Could not list this folder';

  @override
  String get completionEmpty => 'No matches';

  @override
  String get completionTruncated => 'Type more to narrow the list';

  @override
  String get openWith => 'Open with…';

  @override
  String get systemDefaultApp => 'System default';

  @override
  String get defaultApp => 'Default';

  @override
  String get chooseProgram => 'Choose another app…';

  @override
  String alwaysOpenWith(String type) {
    return 'Always use for $type';
  }

  @override
  String get errLaunchFailed => 'Could not open the local copy.';

  @override
  String get uiScale => 'Interface scale';

  @override
  String get importChooseAgain => 'Choose another source';

  @override
  String get importChooseFolder => 'Choose folder';

  @override
  String get importChooseFile => 'Choose file';

  @override
  String get importLoginOption => 'Import saved login details';

  @override
  String get importLoginStorage =>
      'Passwords stay on this device and go into OS secure storage. Existing passwords are kept.';

  @override
  String get importPasswordFound => 'Saved password available';

  @override
  String get importLoginNeeded => 'Login details needed when connecting';

  @override
  String get importCleanupFailed =>
      'Import failed and some new credentials could not be removed. Check OS secure storage before retrying.';

  @override
  String get importSourceChanged =>
      'The source changed or is unreadable. Choose it again.';

  @override
  String get importGuideOpenSsh =>
      'Choose the config file inside .ssh. Include files are read only within that configuration folder.';

  @override
  String get importGuidePutty =>
      'PuTTY sessions are detected from the Windows registry. For manual import, choose a Sessions .reg export from Registry Editor.';

  @override
  String get importGuideMoba =>
      'Choose MobaXterm.ini or a .mxtsessions export from the session list. Portable editions usually keep the configuration beside the program.';

  @override
  String get importGuideSecureCrt =>
      'Find the configuration folder in SecureCRT Global Options, then choose its Sessions folder containing .ini sessions.';

  @override
  String get importGuideXshell =>
      'Choose Xshell/Sessions under the matching NetSarang Computer version in Documents. It contains .xsh sessions.';

  @override
  String get importGuideFinalShell =>
      'Choose conn inside the FinalShell program folder, or an export folder containing *_connect_config.json files. Extract archives first. Choose portable or custom installations manually.';

  @override
  String get importGuideTabby =>
      'Choose the Tabby config.yaml configuration file.';

  @override
  String get importGuideCsv =>
      'Choose a UTF-8 CSV file with a host header. Optional columns: name, port, username, group, key.';

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
  String hostInUse(String names) {
    return 'Jump host of $names';
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
  String get accent => 'Color theme';

  @override
  String get themeNameBlue => 'Ice Blue · Mint';

  @override
  String get themeNameGreen => 'Mint Green';

  @override
  String get themeNameViolet => 'Violet';

  @override
  String get themeNameOrange => 'Sunset Orange';

  @override
  String get themeNameDeepSea => 'Deep Sea Blue';

  @override
  String get themeNamePink => 'Sakura Pink';

  @override
  String get navigationExpand => 'Expand navigation';

  @override
  String get navigationCollapse => 'Collapse navigation';

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
  String get hostKeys => 'Host keys';

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

  @override
  String get proxyPassword => 'Proxy password';

  @override
  String get errProxyAuth =>
      'Proxy authentication failed. Check the username and password.';

  @override
  String get errRouteLoop => 'The jump host chain contains a loop.';

  @override
  String get errRouteMissing =>
      'A jump host no longer exists. Edit the connection route.';

  @override
  String get errRouteTooLong =>
      'A connection route can contain at most 8 hosts.';

  @override
  String get errRouteInvalid => 'The connection route is invalid.';

  @override
  String get route => 'Connection route';

  @override
  String get jumpHost => 'Jump host';

  @override
  String get directConnection => 'Direct';

  @override
  String get proxy => 'Proxy';

  @override
  String get proxyAddress => 'Proxy address';

  @override
  String get proxyUser => 'Proxy username (optional)';

  @override
  String get legacyAlgorithms => 'Legacy algorithms';

  @override
  String get legacyAlgorithmsHint =>
      'Allow SHA-1 and CBC only for this host when a legacy server requires them.';

  @override
  String get errHostSave =>
      'Could not save this host. Check access to the data directory and secure storage.';

  @override
  String get snippets => 'Snippets';

  @override
  String get newSnippet => 'New snippet';

  @override
  String get insertSnippet => 'Insert';

  @override
  String get runSnippet => 'Run';

  @override
  String get snippetText => 'Command text';

  @override
  String get snippetUnavailable =>
      'The target terminal is unavailable. Nothing was sent.';

  @override
  String get snippetInvalid => 'Enter a name and command of at most 64 KiB.';

  @override
  String get snippetSaveFailed => 'Could not save the snippet.';

  @override
  String get importKnownHosts => 'Import known_hosts';

  @override
  String get importAction => 'Import';

  @override
  String get knownHostsNew => 'New keys';

  @override
  String get knownHostsTrusted => 'Already trusted';

  @override
  String get knownHostsConflict => 'Differs from saved key, left unchanged';

  @override
  String get knownHostsSkipped => 'Not imported';

  @override
  String get knownHostsSavedKey => 'Saved';

  @override
  String get knownHostsFileKey => 'File';

  @override
  String get knownHostsMalformed => 'Unreadable line';

  @override
  String get knownHostsMarker => 'Marker not supported';

  @override
  String get knownHostsWildcard => 'Pattern not supported';

  @override
  String get knownHostsNegation => 'Negated pattern not supported';

  @override
  String get knownHostsKeyType => 'Key type not supported';

  @override
  String get knownHostsBadKey => 'Key data invalid or does not match its type';

  @override
  String get knownHostsHashed => 'Hashed name matches no saved host';

  @override
  String get knownHostsFileConflict => 'Conflicting keys within the file';

  @override
  String knownHostsTooLarge(int mb) {
    return 'File is larger than $mb MB';
  }

  @override
  String get knownHostsUnreadable => 'Could not read the file';

  @override
  String knownHostsImported(int count) {
    return 'Imported $count keys';
  }

  @override
  String get knownHostsSaveFailed => 'Could not save the trusted keys';

  @override
  String get tsPaused => 'Paused';

  @override
  String get tsPausing => 'Pausing';

  @override
  String get pause => 'Pause';

  @override
  String get resume => 'Resume';

  @override
  String get pauseFolderUnsupported => 'Folders cannot be paused';

  @override
  String get errSourceChanged =>
      'The source changed, so the transfer cannot continue';

  @override
  String get errPartInvalid =>
      'The partial file is missing or no longer matches the source';

  @override
  String leftoverPart(String path) {
    return 'Could not remove the temporary file $path';
  }

  @override
  String editCleanupFailed(String path) {
    return 'Could not remove the local copy $path';
  }

  @override
  String get portForwarding => 'Port forwarding';

  @override
  String get fwHost => 'Host';

  @override
  String get fwLocal => 'Local';

  @override
  String get fwRemote => 'Remote';

  @override
  String get fwDynamic => 'Dynamic (SOCKS5)';

  @override
  String get fwListen => 'Listen';

  @override
  String get fwDestination => 'Destination';

  @override
  String get fwExposed => 'Exposed';

  @override
  String get fwAutoStart => 'Start with the app';

  @override
  String get fwStart => 'Start forward';

  @override
  String fwExposeConfirm(String endpoint) {
    return 'Listening on $endpoint lets other machines use this forward. Continue?';
  }

  @override
  String get fwExposeAllow => 'Allow';

  @override
  String get fwInvalid => 'Check the addresses and ports';

  @override
  String get fwSaveFailed => 'Could not save';

  @override
  String get fwBusy => 'Stop the forward first';

  @override
  String get fwNoHosts => 'Add a host first';

  @override
  String get fwErrInUse => 'Port already in use';

  @override
  String get fwErrPermission => 'Permission denied for this port';

  @override
  String get fwErrAddress => 'Address not available here';

  @override
  String get fwErrRefused => 'The server refused the forward';

  @override
  String get fwErrHost => 'The host no longer exists';

  @override
  String get fwErrLost => 'Connection lost';

  @override
  String get fwErrStop =>
      'Could not confirm the port was released; the connection is kept';

  @override
  String get fwErrTarget => 'Cannot reach the destination';

  @override
  String get fwErrTimeout => 'Timed out';

  @override
  String get fwErrSocks => 'Invalid SOCKS5 request';

  @override
  String get fwErrLimit => 'Too many connections';

  @override
  String forwardsRunning(int count) {
    return '$count forwards running';
  }

  @override
  String get quitFailed =>
      'Some changes could not be saved or work could not be stopped. Retry or return to the app. Quitting anyway may lose unsaved changes; local edit copies will be kept.';

  @override
  String get returnToApp => 'Return to app';

  @override
  String get quitAnyway => 'Quit anyway';

  @override
  String configUnavailable(String name) {
    return 'Could not safely open $name';
  }

  @override
  String get configPreserved =>
      'The file has been kept. Check or restore it in the data folder, then retry.';

  @override
  String get openDataFolder => 'Open data folder';

  @override
  String get windowMinimize => 'Minimize';

  @override
  String get windowMaximize => 'Maximize';

  @override
  String get windowRestore => 'Restore';

  @override
  String get windowClose => 'Close window';

  @override
  String get sshConfigExisting => 'Already saved';

  @override
  String get sshConfigBlocked => 'Cannot import';

  @override
  String sshConfigImported(int count) {
    return 'Imported $count hosts';
  }

  @override
  String get sshConfigMalformed => 'Invalid syntax';

  @override
  String get sshConfigUnsupported => 'Unsupported option';

  @override
  String get sshConfigMatch => 'Match block skipped';

  @override
  String get sshConfigPattern => 'Host pattern provides defaults only';

  @override
  String get sshConfigIncludeOutside =>
      'Include is outside the selected folder';

  @override
  String get sshConfigIncludeLimit =>
      'Include file, depth or size limit reached';

  @override
  String get sshConfigIncludeMissing => 'Included file could not be read';

  @override
  String get sshConfigIncludeCycle => 'Include cycle';

  @override
  String get sshConfigIncomplete => 'Config was not fully read';

  @override
  String get sshConfigProxyCommand => 'ProxyCommand requires manual setup';

  @override
  String get sshConfigInvalid => 'Invalid host settings';

  @override
  String get sshConfigJump => 'Jump host could not be resolved';

  @override
  String get sshConfigJumpCycle => 'Jump chain is cyclic or too long';

  @override
  String get sshConfigAmbiguous => 'Multiple saved hosts match';

  @override
  String get sshConfigIdentity => 'Private key path could not be resolved';

  @override
  String get sshConfigExtraIdentity =>
      'Only the first IdentityFile is supported';

  @override
  String get sshConfigHostLimit => 'Too many hosts in the config';

  @override
  String get retryAction => 'Retry';

  @override
  String get resizeToolPanel => 'Resize tool panel';

  @override
  String get resizeNavigation => 'Resize navigation';

  @override
  String get resizeMonitor => 'Resize monitor';

  @override
  String get configRestoreSnapshots => 'Restore a snapshot';

  @override
  String get configNoSnapshots => 'No valid snapshots';

  @override
  String get configRestore => 'Restore';

  @override
  String get configRestoreFailed =>
      'Could not restore the snapshot. The current file was preserved.';

  @override
  String configSnapshotRevision(int revision) {
    return 'Revision $revision';
  }

  @override
  String inheritedFrom(String source) {
    return 'Inherited from $source';
  }

  @override
  String useInherited(String source) {
    return 'Use the value from $source';
  }

  @override
  String get inheritBuiltIn => 'Default';

  @override
  String get globalDefaults => 'Global defaults';

  @override
  String get identities => 'Identities';

  @override
  String get identity => 'Identity';

  @override
  String get customLogin => 'Custom';

  @override
  String get newIdentity => 'New identity';

  @override
  String get keyThenPassword => 'Key, then password';

  @override
  String get allowInteractive => 'Keyboard-interactive';

  @override
  String get newGroup => 'New group';

  @override
  String get editGroup => 'Edit group';

  @override
  String dissolveGroupConfirm(String name) {
    return 'Dissolve $name? Its hosts move up a level and its default settings are discarded.';
  }

  @override
  String get errGroupInvalid => 'That group path is taken or invalid.';

  @override
  String deleteIdentity(String name) {
    return 'Delete identity $name?';
  }

  @override
  String get errSave =>
      'Could not save. Check access to the data directory and secure storage.';

  @override
  String get monitor => 'Server monitor';

  @override
  String get cpu => 'CPU';

  @override
  String get gpu => 'GPU';

  @override
  String get memory => 'Memory';

  @override
  String get swap => 'Swap';

  @override
  String get network => 'Network';

  @override
  String get disks => 'Disks';

  @override
  String get load => 'Load';

  @override
  String get uptime => 'Up';

  @override
  String cores(int count) {
    return '$count cores';
  }

  @override
  String uptimeDays(int days, int hours) {
    return '${days}d ${hours}h';
  }

  @override
  String uptimeHours(int hours, int minutes) {
    return '${hours}h ${minutes}m';
  }

  @override
  String get monitorUnsupported =>
      'This server has no /proc, so there is nothing to show';

  @override
  String get monitorFailed => 'Could not read stats; retrying';

  @override
  String get monitorOffline => 'Shown once connected';

  @override
  String get uiFont => 'Interface font';

  @override
  String get uiFontSize => 'Interface font size';

  @override
  String get terminalFont => 'Terminal font';

  @override
  String get defaultFont => 'Default';

  @override
  String get searchFonts => 'Search fonts';

  @override
  String get workspaceSection => 'Workspace';

  @override
  String get filesDock => 'Files panel';

  @override
  String get dockLeft => 'Left';

  @override
  String get dockRight => 'Right';

  @override
  String get dockBottom => 'Bottom';

  @override
  String get dockPosition => 'Dock position';

  @override
  String get confirmQuit => 'Confirm before quitting';

  @override
  String get quitTitle => 'Quit sshairy?';

  @override
  String sessionsOpen(int count) {
    return '$count sessions will be disconnected';
  }

  @override
  String get monitorInterval => 'Refresh interval';

  @override
  String get copyAddress => 'Copy address';

  @override
  String get monitorSystem => 'System';

  @override
  String get processes => 'Processes';

  @override
  String get showAllProcesses => 'Show all processes';

  @override
  String get allInterfaces => 'All interfaces';

  @override
  String get diskFree => 'Free / size';

  @override
  String get processUser => 'User';

  @override
  String get processResident => 'Resident';

  @override
  String get processState => 'State';

  @override
  String get processThreads => 'Threads';

  @override
  String get processElapsed => 'Running';

  @override
  String get processCommand => 'Command';

  @override
  String get searchProcesses => 'Search processes';

  @override
  String get copyPid => 'Copy PID';

  @override
  String get copyCommand => 'Copy command';

  @override
  String get terminateProcess => 'End process';

  @override
  String get killProcess => 'Force end';

  @override
  String terminateConfirm(String name, int pid) {
    return 'End $name (PID $pid)?';
  }

  @override
  String killConfirm(String name, int pid) {
    return 'Force $name (PID $pid) to end? It gets no chance to save its work.';
  }

  @override
  String signalFailed(String detail) {
    return 'Could not end the process: $detail';
  }

  @override
  String tasks(int count) {
    return '$count tasks';
  }

  @override
  String get gpuTemperature => 'Temperature';

  @override
  String get gpuPower => 'Power / limit';

  @override
  String get gpuFan => 'Fan';

  @override
  String get gpuCoreClock => 'Core clock';

  @override
  String get gpuMemoryClock => 'Memory clock';

  @override
  String get gpuMemory => 'VRAM';

  @override
  String get importHosts => 'Import hosts';

  @override
  String get importFromFile => 'From file';

  @override
  String get importNoGroup => 'No group';

  @override
  String get importChanged => 'Hosts changed; open the source again';

  @override
  String get importFailed => 'Could not read the hosts';

  @override
  String get importNotSsh => 'Not an SSH session';

  @override
  String get importNoAddress => 'No address';

  @override
  String get importUnreadable => 'Could not read this file';

  @override
  String get importPpk =>
      'PuTTY .ppk key not used; convert it to OpenSSH format first';

  @override
  String get proxies => 'Proxies';

  @override
  String get proxySearch => 'Search hosts, groups or proxies';

  @override
  String get proxyInherit => 'Inherit';

  @override
  String get proxyConfiguredHere => 'Configured here';

  @override
  String get proxyVia => 'Via jump host';

  @override
  String get proxyEditHop => 'Edit the jump host proxy';

  @override
  String get proxyNextConnection => 'Changes apply to the next connection.';

  @override
  String get proxyInvalid => 'Check the proxy address, port and username.';

  @override
  String get proxyChanged =>
      'Configuration changed. Reopen this editor and try again.';

  @override
  String get proxyCleanupFailed =>
      'The proxy configuration is saved, but old saved credentials could not be fully removed.';

  @override
  String get logs => 'Logs';

  @override
  String get logArea => 'Area';

  @override
  String get logOutcome => 'Result';

  @override
  String get logAllAreas => 'All areas';

  @override
  String get logAllOutcomes => 'All results';

  @override
  String get logCopyRecord => 'Copy selected record';

  @override
  String get logEmpty => 'No records';

  @override
  String get logDisabled => 'Diagnostic recording is off.';

  @override
  String get logWriterFailed =>
      'Diagnostic recording stopped after a write failure.';

  @override
  String get logReadFailed =>
      'Could not read diagnostic records. Refresh to retry.';

  @override
  String logSkipped(int count) {
    return 'Skipped $count invalid records.';
  }

  @override
  String logDropped(int count) {
    return 'Dropped $count queued records.';
  }

  @override
  String logElapsed(int milliseconds) {
    return '$milliseconds ms';
  }

  @override
  String get logAreaApplication => 'Application';

  @override
  String get logAreaConnection => 'Connection';

  @override
  String get logAreaTransfer => 'Transfer';

  @override
  String get logAreaConfiguration => 'Configuration';

  @override
  String get logOutcomeStarted => 'Started';

  @override
  String get logOutcomeSucceeded => 'Succeeded';

  @override
  String get logOutcomeFailed => 'Failed';

  @override
  String get logOutcomeCancelled => 'Cancelled';

  @override
  String get logOutcomeInterrupted => 'Interrupted';

  @override
  String get logActionStart => 'Start';

  @override
  String get logActionDial => 'Connect';

  @override
  String get logActionCopy => 'Transfer';

  @override
  String get logActionPause => 'Pause';

  @override
  String get logActionCancel => 'Cancel';

  @override
  String get logActionRead => 'Read';

  @override
  String get logActionWrite => 'Write';

  @override
  String get logActionRecover => 'Recover';

  @override
  String get logActionUncaught => 'Unhandled error';

  @override
  String get logActionShutdown => 'Shut down';

  @override
  String get appBackgroundImage => 'Interface background';

  @override
  String get terminalBackgroundImage => 'Terminal background';

  @override
  String get backgroundChooseImage => 'Choose image';

  @override
  String get backgroundRestoreDefault => 'Restore default background';

  @override
  String get backgroundOpacity => 'Image opacity';

  @override
  String get backgroundImageTooLarge => 'Image exceeds the size limit.';

  @override
  String get backgroundImageUnsupported => 'Choose a static PNG or JPEG image.';

  @override
  String get backgroundImageUnreadable => 'Could not read the image.';

  @override
  String get backgroundGalleryFull =>
      'Saved backgrounds are full. Remove one to add another.';

  @override
  String backgroundImageItem(int number) {
    return 'Image $number';
  }

  @override
  String get commandHistory => 'Command history';

  @override
  String get commandHistoryEmpty => 'No commands';

  @override
  String get commandHistoryInsert => 'Insert command';

  @override
  String get commandHistoryClear => 'Clear history';

  @override
  String get cmdToolCompose => 'Multi-container apps';

  @override
  String get cmdToolTmux => 'Terminal multiplexer';

  @override
  String get cmdToolScreen => 'Terminal multiplexer';

  @override
  String get cmdToolSystemctl => 'Manage services';

  @override
  String get cmdToolJournalctl => 'View system logs';

  @override
  String get cmdToolRsync => 'Sync files';

  @override
  String get cmdToolLsof => 'List open files';

  @override
  String get cmdToolSs => 'Show sockets';

  @override
  String get cmdToolJq => 'Process JSON';

  @override
  String get cmdToolTcpdump => 'Capture packets';

  @override
  String get cmdToolCrontab => 'Scheduled jobs';

  @override
  String get cmdToolWatch => 'Repeat a command';

  @override
  String get cmdToolHelm => 'Kubernetes packages';

  @override
  String get cmdQuiet => 'Quiet output';

  @override
  String get cmdRecursive => 'Include subdirectories';

  @override
  String get cmdForce => 'Force';

  @override
  String get cmdAll => 'Include all';

  @override
  String get cmdHuman => 'Human-readable';

  @override
  String get cmdFollow => 'Follow new output';

  @override
  String get cmdLines => 'Number of lines';

  @override
  String get cmdTail => 'Last N lines';

  @override
  String get cmdSince => 'Since a time';

  @override
  String get cmdBackground => 'Run in background';

  @override
  String get cmdLabel => 'Name';

  @override
  String get cmdPort => 'Port';

  @override
  String get cmdIdentity => 'Identity file';

  @override
  String get cmdJumpHost => 'Jump host';

  @override
  String get cmdFile => 'File';

  @override
  String get cmdDirectory => 'Directory';

  @override
  String get cmdOutputFile => 'Write to file';

  @override
  String get cmdDryRun => 'Preview only';

  @override
  String get cmdAssumeYes => 'Answer yes';

  @override
  String get cmdNamespace => 'Namespace';

  @override
  String get cmdTarget => 'Target';

  @override
  String get cmdUser => 'User';

  @override
  String get cmdReverse => 'Reverse order';

  @override
  String get cmdIgnoreCase => 'Ignore case';

  @override
  String get cmdConfirm => 'Ask first';

  @override
  String get cmdRunInside => 'Run a command inside';

  @override
  String get cmdUpgrade => 'Upgrade packages';

  @override
  String get cmdRefreshIndex => 'Refresh package index';

  @override
  String get cmdLongList => 'Detailed list';

  @override
  String get cmdParents => 'Create parent directories';

  @override
  String get cmdArchive => 'Archive mode';

  @override
  String get cmdInvert => 'Invert match';

  @override
  String get cmdFilesOnly => 'Only file names';

  @override
  String get cmdExtendedRegex => 'Extended regex';

  @override
  String get cmdMaxDepth => 'Maximum depth';

  @override
  String get cmdMakeExecutable => 'Make executable';

  @override
  String get cmdInPlace => 'Edit file in place';

  @override
  String get cmdExtract => 'Extract';

  @override
  String get cmdCreateArchive => 'Create archive';

  @override
  String get cmdListArchive => 'List contents';

  @override
  String get cmdAllProcesses => 'All processes';

  @override
  String get cmdForceKill => 'Force kill';

  @override
  String get cmdLocalForward => 'Forward a local port';

  @override
  String get cmdRemoteForward => 'Forward a remote port';

  @override
  String get cmdDynamicForward => 'SOCKS proxy';

  @override
  String get cmdNoCommand => 'No remote command';

  @override
  String get cmdFollowRedirects => 'Follow redirects';

  @override
  String get cmdHeadersOnly => 'Headers only';

  @override
  String get cmdMethod => 'Request method';

  @override
  String get cmdListening => 'Listening sockets';

  @override
  String get cmdKeyType => 'Key type';

  @override
  String get cmdFingerprint => 'Show fingerprint';

  @override
  String get cmdRemoveKnownHost => 'Remove a known host';

  @override
  String get cmdProgressPartial => 'Show progress, resumable';

  @override
  String get cmdUnit => 'Unit name';

  @override
  String get cmdJumpEnd => 'Jump to the end';

  @override
  String get cmdThisBoot => 'Since this boot';

  @override
  String get cmdPriority => 'Priority level';

  @override
  String get cmdDaemonReload => 'Reload unit files';

  @override
  String get cmdIsActive => 'Is it running';

  @override
  String get cmdUserScope => 'User services';

  @override
  String get cmdNow => 'Also start or stop now';

  @override
  String get cmdCommitAll => 'Include tracked changes';

  @override
  String get cmdAmend => 'Rewrite the last commit';

  @override
  String get cmdSetUpstream => 'Set upstream branch';

  @override
  String get cmdRebase => 'Rebase instead of merge';

  @override
  String get cmdFastForwardOnly => 'Fast-forward only';

  @override
  String get cmdNewBranch => 'Create a branch';

  @override
  String get cmdShowCurrent => 'Show current branch';

  @override
  String get cmdOneline => 'One line per commit';

  @override
  String get cmdStaged => 'Staged changes';

  @override
  String get cmdPrune => 'Drop deleted remote branches';

  @override
  String get cmdNoFastForward => 'Always make a merge commit';

  @override
  String get cmdSquash => 'Squash into one change';

  @override
  String get cmdContinueOp => 'Continue';

  @override
  String get cmdStashPop => 'Apply and drop latest';

  @override
  String get cmdIncludeUntracked => 'Include untracked files';

  @override
  String get cmdRunContainer => 'Run a new container';

  @override
  String get cmdRemoveOnExit => 'Remove on exit';

  @override
  String get cmdVolume => 'Mount a volume';

  @override
  String get cmdEnv => 'Environment variable';

  @override
  String get cmdRestartPolicy => 'Restart policy';

  @override
  String get cmdComposeUp => 'Create and start';

  @override
  String get cmdComposeDown => 'Stop and remove';

  @override
  String get cmdAllNamespaces => 'All namespaces';

  @override
  String get cmdSelector => 'Label selector';

  @override
  String get cmdOutputFormat => 'Output format';

  @override
  String get cmdTmuxAttach => 'Attach to a session';

  @override
  String get cmdTmuxNew => 'Create a session';

  @override
  String get cmdTmuxList => 'List sessions';

  @override
  String get cmdTmuxKillSession => 'End a session';

  @override
  String get cmdTmuxKillServer => 'End all tmux sessions';

  @override
  String get cmdTmuxDetach => 'Detach a client';

  @override
  String get cmdTmuxWindows => 'List windows';

  @override
  String get cmdTmuxNewWindow => 'Create a window';

  @override
  String get cmdTmuxSplit => 'Split a pane';

  @override
  String get cmdTmuxRename => 'Rename a session';

  @override
  String get cmdTmuxHas => 'Check for a session';

  @override
  String get cmdTmuxSource => 'Load a configuration file';

  @override
  String get cmdTmuxBind => 'Bind a key';

  @override
  String get cmdTmuxBreak => 'Move a pane to a window';
}
