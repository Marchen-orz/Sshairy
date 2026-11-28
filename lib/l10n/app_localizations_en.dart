// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get aiConfigTitle => 'AI';

  @override
  String get aiAgentAttach => 'Attach files';

  @override
  String get aiAgentAttachmentTooLarge =>
      'This file is too large. Choose a smaller file.';

  @override
  String aiAgentAttachmentTooMany(int count) {
    return 'A message can contain up to $count attachments.';
  }

  @override
  String aiAgentAttachmentTotalTooLarge(int size) {
    return 'Attachments in this message exceed $size MiB. Remove a file and try again.';
  }

  @override
  String get aiAgentAttachmentImageTooLarge =>
      'This image has too many pixels. Resize it and try again.';

  @override
  String aiAgentAttachmentFileError(String name, String reason) {
    return '$name: $reason';
  }

  @override
  String get aiAgentAttachmentUnsupported =>
      'Choose UTF-8 text or a PNG, JPEG or WebP image. Binary files, credentials and unsupported formats cannot be attached.';

  @override
  String get aiAgentAttachmentUnreadable =>
      'The selected file could not be read.';

  @override
  String get aiConfigEnabled => 'Enable AI';

  @override
  String get aiConfigAnthropic => 'Anthropic Messages';

  @override
  String get aiConfigOpenAi => 'OpenAI Chat Completions';

  @override
  String get aiConfigResponses => 'OpenAI Responses';

  @override
  String get aiConfigEndpoint => 'API base URL';

  @override
  String get aiConfigEndpointHint =>
      '/v1 is added when the path has no version. HTTPS or exact local loopback HTTP only.';

  @override
  String get aiConfigModel => 'Model';

  @override
  String get aiConfigTools => 'Model supports tool calls';

  @override
  String get aiConfigContextWindow => 'Context window (tokens)';

  @override
  String get aiConfigMaxOutput => 'Maximum output (tokens)';

  @override
  String get aiConfigApiKey => 'API key';

  @override
  String get aiConfigKeyLoading => 'Checking secure storage…';

  @override
  String get aiConfigKeyLoadFailed =>
      'Could not check the API key in secure storage.';

  @override
  String get aiConfigKeySaved =>
      'A key is saved for this destination. Leave the field empty to keep it.';

  @override
  String get aiConfigKeyMissing =>
      'No key saved; leave empty if this endpoint needs none.';

  @override
  String get aiConfigKeyRemoved =>
      'The saved key will be removed when you save.';

  @override
  String get aiConfigRemoveKey => 'Remove saved key';

  @override
  String get aiConfigInvalid =>
      'Check the API address, model and token limits.';

  @override
  String get aiConfigSaveFailed =>
      'AI settings were not saved. A key change may already have reached OS secure storage.';

  @override
  String get aiConfigPartialSave =>
      'The API key was updated, but AI settings could not be saved. Retry saving the settings.';

  @override
  String get aiConfigLoadFailed =>
      'AI configuration could not be read. AI is disabled and the existing file is protected.';

  @override
  String get aiConfigConflict =>
      'AI settings changed elsewhere. Cancel to reload before saving.';

  @override
  String deleteHostsConfirm(int count) {
    return 'Delete the selected $count hosts?';
  }

  @override
  String get hostDeleteCleanupFailed =>
      'Hosts were deleted, but some saved credentials could not be removed. Check OS secure storage.';

  @override
  String get closeTabsLeft => 'Close tabs to the left';

  @override
  String get closeTabsRight => 'Close tabs to the right';

  @override
  String get closeOtherTabs => 'Close other tabs';

  @override
  String get closeAll => 'Close all';

  @override
  String get closeAbove => 'Close all above';

  @override
  String get closeBelow => 'Close all below';

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
  String get completionCommand => 'Command';

  @override
  String get completionSubcommand => 'Subcommand';

  @override
  String get completionOption => 'Option';

  @override
  String get completionArgument => 'Argument value';

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
  String get motion => 'Motion';

  @override
  String get motionLight => 'Light';

  @override
  String get motionFull => 'Full';

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
  String get showPassword => 'Show password';

  @override
  String get hidePassword => 'Hide password';

  @override
  String get hostPasswordLoading => 'Loading saved password…';

  @override
  String get hostPasswordLoadFailed =>
      'Could not read the saved password. Unlock secure storage and retry.';

  @override
  String get hostPasswordRetry => 'Retry password loading';

  @override
  String get hostPasswordRemove => 'Remove saved password';

  @override
  String get hostPasswordKeep => 'Keep saved password';

  @override
  String get hostPasswordRemovalPending =>
      'The saved password will be removed when you save.';

  @override
  String get hostPasswordSaveFailed =>
      'Host settings were saved, but the password change could not be confirmed. Check secure storage and save again.';

  @override
  String get hostPasswordCleanupFailed =>
      'Host settings were saved, but old proxy credentials could not be removed. The password change has not been saved. Check secure storage and save again.';

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
  String get sshAgent => 'SSH Agent';

  @override
  String get forwardAgent => 'Forward SSH Agent';

  @override
  String errAgent(String detail) {
    return 'Cannot use the SSH agent: $detail';
  }

  @override
  String get errAgentEmpty => 'The SSH agent holds no keys';

  @override
  String get keywordHighlight => 'Highlight keywords';

  @override
  String get highlightKeywords => 'Custom keywords';

  @override
  String get highlightKeywordsHint => 'Separated by commas or spaces';

  @override
  String get localTerminal => 'Local';

  @override
  String get localTerminals => 'Local terminals';

  @override
  String get localShell => 'Shell';

  @override
  String get startDirectory => 'Start in folder';

  @override
  String get chooseFolder => 'Choose folder';

  @override
  String get noLocalShells => 'No local shell was found';

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
  String get renderer => 'Rendering';

  @override
  String get rendererPerformance => 'High performance';

  @override
  String get rendererLight => 'Lightweight';

  @override
  String get rendererPerformanceHint =>
      'Impeller engine: steadier animation, about 150 MB more memory';

  @override
  String get rendererLightHint =>
      'Skia engine: less memory, but animations may stutter the first time they appear';

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
  String get aiTextStyle => 'AI text';

  @override
  String get aiTextItalicFaint => 'Italic dim';

  @override
  String get aiTextItalic => 'Italic';

  @override
  String get aiTextFaint => 'Dim';

  @override
  String get aiTextPlain => 'Normal';

  @override
  String get aiTaskSteps => 'AI task step limit';

  @override
  String get aiCompletionDelay => 'AI completion delay';

  @override
  String milliseconds(int n) {
    return '$n ms';
  }

  @override
  String get completionTranslation =>
      'Translate completion descriptions automatically';

  @override
  String get completionTranslationHint =>
      'Sends only public command descriptions to the selected service. Cached translations remain when off.';

  @override
  String get translationService => 'Translation service';

  @override
  String get translationConcurrency => 'Concurrent translations';

  @override
  String get translationConcurrencyAuto => 'Auto (all visible)';

  @override
  String get translationProvider => 'Provider';

  @override
  String get translationMyMemory => 'MyMemory';

  @override
  String get translationDeepL => 'DeepL';

  @override
  String get translationGoogle => 'Google Cloud Translation';

  @override
  String get translationMicrosoft => 'Microsoft Translator';

  @override
  String get translationOpenAi => 'OpenAI compatible';

  @override
  String get translationMyMemoryHint =>
      'No key required · 5,000 characters/day, or 50,000 with a valid email';

  @override
  String get translationEmail => 'Email (optional)';

  @override
  String get translationEmailHint =>
      'Sent only to MyMemory so they can contact you if needed.';

  @override
  String get translationEmailInvalid =>
      'Enter a valid email address of up to 254 ASCII characters.';

  @override
  String get translationDeepLFree => 'Use DeepL API Free';

  @override
  String get translationRegion => 'Region (optional)';

  @override
  String get translationEndpoint => 'API base URL';

  @override
  String get translationEndpointHint =>
      'For example, https://api.example.com/v1 · omit /chat/completions';

  @override
  String get translationModel => 'Model';

  @override
  String get translationApiKey => 'API key';

  @override
  String get translationKeySaved => 'Key saved · leave blank to keep';

  @override
  String get translationKeyMissing => 'No saved key';

  @override
  String get translationKeyRemoved => 'Key will be removed on Save';

  @override
  String get translationRemoveKey => 'Remove saved key';

  @override
  String get translationKeyLoading => 'Checking secure storage…';

  @override
  String get translationKeyLoadFailed =>
      'Could not check secure storage. Cancel to try again.';

  @override
  String get translationEndpointInvalid =>
      'Use HTTPS, or HTTP on localhost, without credentials, query or fragment.';

  @override
  String get translationModelInvalid =>
      'Enter a model name of up to 128 letters, digits, ., _, :, / or -.';

  @override
  String get translationRegionInvalid =>
      'Use up to 64 lowercase letters, digits or hyphens.';

  @override
  String get translationConflict =>
      'Settings changed. Cancel your edits before trying again.';

  @override
  String get translationSaveFailed =>
      'Could not save. A key change may already have been saved to secure storage.';

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
  String get checkForUpdates => 'Check for updates';

  @override
  String get checkingForUpdates => 'Checking for updates…';

  @override
  String get upToDate => 'You\'re up to date';

  @override
  String get updateFailed => 'Could not check for updates';

  @override
  String updateAvailable(String version) {
    return 'Version $version is available';
  }

  @override
  String get releaseNotes => 'Release notes';

  @override
  String get openReleasePage => 'Open release page';

  @override
  String get updateDownload => 'Download update';

  @override
  String get updateDownloading => 'Downloading update…';

  @override
  String get updateVerifying => 'Checking the download…';

  @override
  String updateDownloaded(String path) {
    return 'Downloaded to $path';
  }

  @override
  String get updateLaunchFailed =>
      'Could not open the update package. Open it from Downloads.';

  @override
  String get updateViaComputer => 'Download via computer';

  @override
  String get updateInstallApk => 'Install update';

  @override
  String get updateAllowInstall =>
      'Allow Sshairy to install apps, then return and tap Install update again.';

  @override
  String get updateApkFailed =>
      'Could not install this APK. Check that it matches this device and the installed Sshairy app.';

  @override
  String get linkOfferUpdate => 'Send update to phone';

  @override
  String get linkUpdateOffered =>
      'Update sent. Confirm installation on your phone.';

  @override
  String get linkUpdateOfferFailed =>
      'Could not transfer the update. Check Device Link and try again.';

  @override
  String get updateSending => 'Sending update to phone…';

  @override
  String updateReadyToInstall(String version) {
    return 'Version $version is ready to install';
  }

  @override
  String updatePhoneAvailable(String version) {
    return 'Phone update $version available';
  }

  @override
  String updatePhonePrompt(String name, String current, String latest) {
    return '$name runs Sshairy $current; the latest is $latest.';
  }

  @override
  String get updatePush => 'Download and push';

  @override
  String get updateDownloadFailed =>
      'Download failed. Check your connection and try again.';

  @override
  String get updateNoPackage =>
      'No installable package is available for this platform. Open the release page instead.';

  @override
  String get installNow => 'Restart and update';

  @override
  String get later => 'Later';

  @override
  String get cancelDownload => 'Cancel download';

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
  String get shellIntegrationInstall => 'Install shell integration';

  @override
  String get shellIntegrationRemove => 'Remove shell integration';

  @override
  String get shellIntegrationInstalled =>
      'Installed. New terminals will use it.';

  @override
  String get shellIntegrationRemoved =>
      'Removed. New terminals will not load it.';

  @override
  String get shellIntegrationFailed => 'Shell integration change failed';

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
  String errKeyUnreadable(String detail) {
    return 'Cannot read the file: $detail';
  }

  @override
  String errKeyStore(String detail) {
    return 'Could not save the key: $detail';
  }

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
  String get bookmarks => 'Bookmarks';

  @override
  String get addBookmark => 'Bookmark this folder';

  @override
  String get removeBookmark => 'Remove bookmark';

  @override
  String get zmodemUnsupported =>
      'ZMODEM (sz/rz) is not supported yet, so the transfer was cancelled. Use the file panel instead.';

  @override
  String get editPath => 'Edit path';

  @override
  String get newFolder => 'New folder';

  @override
  String get hiddenFiles => 'Show hidden files';

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
  String uploadTo(String path) {
    return 'Upload to $path';
  }

  @override
  String get terminalDirectoryUnknown =>
      'The shell\'s current directory is unknown; nothing was uploaded';

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
  String get shortcuts => 'Keyboard shortcuts';

  @override
  String get shortcutPress => 'Press keys…';

  @override
  String get shortcutUnset => 'Unset';

  @override
  String get shortcutReset => 'Reset to default';

  @override
  String shortcutConflict(Object action) {
    return 'Already used by $action';
  }

  @override
  String get shortcutCommandPalette => 'Command palette';

  @override
  String get shortcutNewConnection => 'New connection';

  @override
  String get shortcutCloseTab => 'Close tab';

  @override
  String get shortcutSettings => 'Open settings';

  @override
  String get shortcutToggleAgent => 'Toggle Agent panel';

  @override
  String get shortcutInlineGenerate => 'Inline AI task';

  @override
  String get shortcutTerminalCopy => 'Terminal copy';

  @override
  String get shortcutTerminalPaste => 'Terminal paste';

  @override
  String get shortcutTerminalSearch => 'Terminal search';

  @override
  String get shortcutCommandHistory => 'Command history';

  @override
  String get shortcutPreviousPane => 'Previous pane';

  @override
  String get shortcutNextPane => 'Next pane';

  @override
  String get shortcutPreviousTab => 'Previous tab';

  @override
  String get shortcutNextTab => 'Next tab';

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
  String get quitTitle => 'Quit Sshairy?';

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
  String get terminalMultilineInput => 'Multiline input';

  @override
  String get terminalMultilineSend => 'Send to terminal';

  @override
  String get terminalMultilinePlaceholder => 'Enter commands…';

  @override
  String get localShellsEmpty => 'No local shells found';

  @override
  String get aiAgentTitle => 'Airy';

  @override
  String get aiAgentRail => 'Airy Agent';

  @override
  String get aiAgentClear => 'Clear conversation';

  @override
  String get aiAgentConfigure =>
      'Configure a model and enable AI in Settings to begin.';

  @override
  String get aiAgentConfigurationFailed =>
      'AI configuration could not be read. Review it in Settings.';

  @override
  String get aiAgentChooseHost => 'Choose a server';

  @override
  String get aiAgentGoal => 'Describe what you want to check or do…';

  @override
  String get aiAgentSend => 'Send';

  @override
  String get aiAgentEmpty =>
      'Only the text you send and explicitly authorized data are shared with the selected model.';

  @override
  String get aiAgentIdle => 'Ready';

  @override
  String get aiAgentPreparing => 'Preparing';

  @override
  String get aiAgentStreaming => 'Receiving response';

  @override
  String get aiAgentAwaitingApproval => 'Waiting for command approval';

  @override
  String get aiAgentExecuting => 'Running';

  @override
  String get aiAgentCompleted => 'Completed';

  @override
  String get aiAgentStopping => 'Stopping';

  @override
  String get aiAgentCancelled => 'Stopped';

  @override
  String get aiAgentFailed => 'The request could not be completed.';

  @override
  String get aiAgentOutcomeUnknown => 'Remote outcome is unknown';

  @override
  String get aiAgentDiagnostics => 'Fixed diagnostics';

  @override
  String get aiAgentToolHosts => 'List hosts';

  @override
  String get aiAgentToolHostsHint => 'View saved hosts by name and ID.';

  @override
  String get aiAgentToolTerminals => 'List terminal windows';

  @override
  String get aiAgentToolTerminalsHint =>
      'List connected tabs and splits without reading commands or output.';

  @override
  String get aiAgentToolTerminalHistory => 'Read window context';

  @override
  String get aiAgentToolTerminalHistoryHint =>
      'Read one terminal\'s known directory, recent commands and paired results.';

  @override
  String get aiAgentTerminalApproveHint =>
      'Let Airy use this terminal\'s known directory, prompt status and recent command results for this turn. Window numbers are the tab and pane positions when you sent the message. No commands will run.';

  @override
  String get aiAgentToolTerminalScreen => 'Read terminal screen';

  @override
  String get aiAgentToolTerminalScreenHint =>
      'Read the visible text of one terminal, up to 200 lines, without scrollback.';

  @override
  String get aiAgentTerminalScreenApproveHint =>
      'Let Airy read only the visible text of this terminal, up to 200 lines. Every read asks again. No commands will run.';

  @override
  String get aiAgentToolFilesList => 'List directory';

  @override
  String get aiAgentToolFilesStat => 'File info';

  @override
  String get aiAgentToolFilesRead => 'Read file';

  @override
  String get aiAgentToolFilesWrite => 'Write file';

  @override
  String get aiAgentToolFilesMkdir => 'Create directory';

  @override
  String get aiAgentToolFilesRename => 'Rename path';

  @override
  String get aiAgentToolFilesDelete => 'Delete path';

  @override
  String get aiAgentToolFilesHint =>
      'Read or change remote files and directories.';

  @override
  String get aiAgentToolTransferList => 'List transfers';

  @override
  String get aiAgentToolTransferEnqueue => 'Start transfer';

  @override
  String get aiAgentToolTransferCancel => 'Cancel transfer';

  @override
  String get aiAgentToolTransferHint => 'View or act on file transfers.';

  @override
  String get aiAgentToolSessionOpen => 'Open session';

  @override
  String get aiAgentToolSessionClose => 'Close session';

  @override
  String get aiAgentToolSessionReconnect => 'Reconnect session';

  @override
  String get aiAgentToolSessionHint =>
      'Open, close or reconnect terminal sessions.';

  @override
  String get aiAgentToolWorkspaceFocus => 'Switch window';

  @override
  String get aiAgentToolWorkspaceSplit => 'Split pane';

  @override
  String get aiAgentToolWorkspaceRename => 'Rename tab';

  @override
  String get aiAgentToolWorkspaceCloseTabs => 'Close tabs';

  @override
  String get aiAgentToolWorkspaceHint => 'Switch windows or change the layout.';

  @override
  String get aiAgentToolSettingsGet => 'Read settings';

  @override
  String get aiAgentToolSettingsPatch => 'Change settings';

  @override
  String get aiAgentToolSettingsHint => 'Read or change this app\'s settings.';

  @override
  String get aiAgentToolHostCreate => 'Add host';

  @override
  String get aiAgentToolHostUpdate => 'Update host';

  @override
  String get aiAgentToolHostMove => 'Move host';

  @override
  String get aiAgentToolHostDelete => 'Delete host';

  @override
  String get aiAgentToolHostHint => 'Add, update or delete saved hosts.';

  @override
  String get aiAgentToolForwardList => 'List forwards';

  @override
  String get aiAgentToolForwardSave => 'Save forward';

  @override
  String get aiAgentToolForwardDelete => 'Delete forward';

  @override
  String get aiAgentToolForwardStart => 'Start forward';

  @override
  String get aiAgentToolForwardStop => 'Stop forward';

  @override
  String get aiAgentToolForwardHint => 'View or act on port forwarding rules.';

  @override
  String get aiAgentToolJobStart => 'Start background job';

  @override
  String get aiAgentToolJobRead => 'Read job output';

  @override
  String get aiAgentToolJobStatus => 'Job status';

  @override
  String get aiAgentToolJobStop => 'Stop job';

  @override
  String get aiAgentToolJobHint => 'Run or inspect background jobs.';

  @override
  String get aiAgentToolDiagnostics => 'Collect diagnostics';

  @override
  String get aiAgentToolDiagnosticsHint =>
      'Collect fixed system or disk diagnostics.';

  @override
  String get aiAgentToolExecute => 'Execute command';

  @override
  String get aiAgentToolExecuteHint =>
      'Run an authorized command through a separate SSH channel.';

  @override
  String get aiAgentToolOutput => 'Read output';

  @override
  String get aiAgentToolOutputHint =>
      'Read command output that has been approved for sharing.';

  @override
  String get aiAgentDiagnosticScope =>
      'Fixed Linux diagnostics may send OS, kernel, load, memory, disk mounts and capacity to the selected model. Process arguments and environment variables are excluded.';

  @override
  String aiAgentExitCode(int code) {
    return 'Exit code: $code';
  }

  @override
  String aiAgentExecutionTimeout(int seconds) {
    return 'Execution timeout: $seconds s';
  }

  @override
  String get aiAgentTruncated => 'Output was truncated.';

  @override
  String get aiAgentShowOutput => 'Show local output';

  @override
  String get aiAgentHideOutput => 'Hide output';

  @override
  String get aiAgentShellPermission =>
      'This command runs with the SSH account\'s permissions and may change files or access the network. Approval also lets Airy use its bounded output. Stopping closes this client\'s channel; remote processes may continue.';

  @override
  String get aiAgentReject => 'Reject';

  @override
  String get aiAgentApprove => 'Approve once';

  @override
  String get aiAgentNewTask => 'New conversation';

  @override
  String get aiAgentWelcome => 'What would you like to work on?';

  @override
  String get aiAgentWelcomeHint =>
      'Uses the current terminal context by default; asks before reading another window.';

  @override
  String get aiAgentSetupTitle => 'Your SSH assistant';

  @override
  String get aiAgentConfigureAction => 'Configure AI';

  @override
  String get aiAgentExampleExplain => 'Explain a command';

  @override
  String get aiAgentExampleExplainGoal =>
      'Explain how to read a shell command and spot its side effects.';

  @override
  String get aiAgentExampleDiagnose => 'Check server health';

  @override
  String get aiAgentExampleDiagnoseGoal =>
      'Check this server\'s load, memory and disk space. Explain any missing evidence before suggesting a change.';

  @override
  String get aiAgentNoHost => 'No server';

  @override
  String get aiAgentScopeDetails => 'Data and command permissions';

  @override
  String get aiAgentScopeSummary =>
      'Fixed diagnostics allowed · commands ask first';

  @override
  String get aiAgentTextOnly => 'Text only';

  @override
  String get aiAgentSendShortcut => 'Send · Enter';

  @override
  String get aiAgentApproveTitle => 'Approve command';

  @override
  String get aiAgentExecutionFailed => 'Finished with errors';

  @override
  String get aiAgentErrorConfiguration =>
      'Review the model configuration and API key in Settings.';

  @override
  String get aiAgentErrorModelConfig =>
      'Review the endpoint and model name in Settings.';

  @override
  String get aiAgentErrorToolDefinition =>
      'This tool is unavailable because its definition is invalid. This turn has stopped.';

  @override
  String get aiAgentErrorNetwork =>
      'Could not reach the model. Check the connection and try a new task.';

  @override
  String get aiAgentErrorHttp =>
      'The model service rejected this request. Check its credentials, quota and settings.';

  @override
  String get aiAgentErrorTimeout =>
      'The request reached its time limit. Review the task before trying again.';

  @override
  String get aiAgentErrorLimit =>
      'This task reached its context, output or step limit. Start a smaller task.';

  @override
  String get aiAgentErrorScope =>
      'The model configuration or server connection changed. Start a new task to authorize the current target.';

  @override
  String get aiAgentErrorJournal =>
      'The operation record could not be saved. Review the execution status before trying another command.';

  @override
  String get aiAgentErrorProtocol =>
      'The model returned an incomplete or unsupported response. No partial tool request was executed.';

  @override
  String get aiAgentErrorUnsupported =>
      'This server does not support the current command adapter.';

  @override
  String get aiAgentErrorFileDenied =>
      'The file tool refused this path or content (sensitive location, credential-like text or policy limit).';

  @override
  String get aiAgentErrorFileSensitive =>
      'The file contains credential-like or key material and was not read. Ask the user to inspect it, or narrow the request to content that excludes it.';

  @override
  String get aiAgentErrorFileUnsupported =>
      'This file operation is unsupported: binary or non-UTF-8, larger than 256 KiB, or the server lacks private staging and atomic replace.';

  @override
  String get aiAgentErrorFileConflict =>
      'The file changed after it was read. Read it again before writing.';

  @override
  String get aiAgentErrorFileExists =>
      'The target already exists. Read it first and provide its current sha256 when overwriting.';

  @override
  String get aiAgentErrorFileNotFound =>
      'The file or directory does not exist.';

  @override
  String get aiAgentErrorFilePermission =>
      'The SSH account cannot perform this file operation.';

  @override
  String get aiAgentErrorFileInvalid =>
      'The file tool arguments were invalid; check hostId, the absolute path and paging values.';

  @override
  String get aiAgentErrorFileScope =>
      'This host is not authorized for the current task. Confirm the host before retrying.';

  @override
  String get aiReasoningEffort => 'Reasoning effort';

  @override
  String get aiReasoningDefault => 'Model default';

  @override
  String get aiReasoningOff => 'Off';

  @override
  String get aiReasoningLow => 'Low';

  @override
  String get aiReasoningMedium => 'Medium';

  @override
  String get aiReasoningHigh => 'High';

  @override
  String get aiReasoningActive => 'Thinking…';

  @override
  String get aiReasoningSummary => 'Thinking summary';

  @override
  String get aiReasoningCompleted => 'Thinking complete';

  @override
  String get aiReasoningUnsupported =>
      'This model does not have a supported reasoning setting. Choose Model default or another model.';

  @override
  String get aiConfigAdvanced => 'Model capabilities and limits';

  @override
  String get aiConfigInline => 'Inline AI tasks';

  @override
  String get aiConfigInlineHint =>
      'Type a request at the prompt, then click the AI icon or press Alt+Enter. AI fills in commands step by step in this terminal and continues from each result after you press Enter.';

  @override
  String get aiConfigCompletion => 'AI suggestions';

  @override
  String get aiConfigTerminalScope =>
      'Allow terminal input and known directory to be sent for these SSH hosts';

  @override
  String get aiConfigTerminalNoHosts =>
      'Add a host to allow SSH suggestions. Local shells can start inline AI tasks manually.';

  @override
  String get aiConfigPosix => 'These SSH terminals use Linux / POSIX shells';

  @override
  String get aiConfigPosixHint =>
      'Confirm the input environment yourself. Disable suggestions inside su, tmux or nested SSH; the client cannot verify the inner identity.';

  @override
  String get aiConfigCompletionHistory =>
      'Use recent commands from the same session';

  @override
  String get aiConfigCompletionHint =>
      'Pause after typing git st and gray text completes it to git status; press → to accept. Uses up to 8 relevant commands and their results from this session.';

  @override
  String get aiAgentErrorHostTrust =>
      'Open a normal SSH connection and review this server\'s host key before using remote tools.';

  @override
  String get aiAgentErrorAuthentication =>
      'Open a normal SSH connection to provide or update this server\'s credentials.';

  @override
  String get aiAgentErrorHostUnavailable =>
      'This server is no longer available. Select a saved server for the next task.';

  @override
  String get aiAgentErrorConnection =>
      'The SSH connection failed. Check the server with a normal connection before trying again.';

  @override
  String get aiAgentErrorExecution =>
      'The command could not be completed. Review its local output and exit status before trying again.';

  @override
  String get aiAgentHostAccessTitle => 'Allow access to another host';

  @override
  String aiAgentHostAccessPrompt(String host) {
    return 'Allow this conversation to access $host? Commands will still follow the selected permission mode.';
  }

  @override
  String get aiAgentHostAccessAllow => 'Allow access';

  @override
  String get terminalAiFix => 'Fix the last failed command';

  @override
  String get terminalAiGenerate => 'Generate command';

  @override
  String get terminalAiInstruction => 'Describe what you want to do';

  @override
  String get terminalAiAuto => 'Run automatically';

  @override
  String get terminalAiFailed => 'Could not generate a command. Try again.';

  @override
  String get terminalAiFailedTimeout => 'Generation timed out. Try again.';

  @override
  String get terminalAiFailedNetwork =>
      'Could not reach the model service. Check the network or settings.';

  @override
  String terminalAiFailedHttp(int code) {
    return 'The model service returned HTTP $code.';
  }

  @override
  String get terminalAiFailedInvalid =>
      'The model returned an invalid command. Try rephrasing.';

  @override
  String get aiAgentHistory => 'Conversation history';

  @override
  String get aiAgentHistoryEmpty => 'No conversations yet';

  @override
  String get aiAgentContinueConversation => 'Continue conversation';

  @override
  String aiAgentHistoryContinueNotice(String destination, String host) {
    return 'Continuing resends this conversation\'s retained, limited history to $destination. Current server: $host.';
  }

  @override
  String get aiAgentHistoryTargetChanged =>
      'The model destination changed. Start a new conversation.';

  @override
  String get aiAgentHistoryLoadFailed =>
      'Could not load conversation history. Try again.';

  @override
  String get aiAgentHistorySaveFailed =>
      'Conversation history could not be saved. The current content is still in memory.';

  @override
  String get aiAgentHistoryRetry => 'Retry';

  @override
  String get aiAgentHistoryTruncated =>
      'Some conversation history was trimmed to stay within storage limits.';

  @override
  String get aiAgentHistoryOutputUnavailable =>
      'Raw tool output is not saved in history.';

  @override
  String get aiAgentHistoryDelete => 'Delete conversation';

  @override
  String get aiAgentHistoryDeleteConfirm =>
      'Delete this conversation and its local history?';

  @override
  String get aiAgentHistoryBusy =>
      'Stop the current task or wait for it to finish before switching conversations.';

  @override
  String get aiAgentHistoryLocalNotice =>
      'Conversation text is saved locally and may contain sensitive information. Raw tool output is not saved.';

  @override
  String get aiModelSearch => 'Search models';

  @override
  String get aiModelsLoadFailed =>
      'Could not load models. Retry or enter a model name.';

  @override
  String aiModelsLoadHttp(String status) {
    return 'The service returned HTTP $status. Check the key and address.';
  }

  @override
  String get aiModelsLoadTimedOut =>
      'The request timed out. Retry or enter a model name.';

  @override
  String aiModelCustom(String model) {
    return 'Use $model';
  }

  @override
  String get aiModelsEmpty => 'No models found';

  @override
  String get aiModelsRefresh => 'Refresh models';

  @override
  String get aiAgentContextCompacted =>
      'Earlier context was compacted to stay within the model limit.';

  @override
  String get aiConfigAgentModel => 'Default Airy model';

  @override
  String get aiConfigReviewModel => 'Approval model';

  @override
  String get aiConfigInlineModel => 'Inline task model';

  @override
  String get aiConfigPrediction => 'Predict the next command';

  @override
  String get aiConfigPredictionHint =>
      'Back at an empty prompt, gray text suggests the next command, such as git commit after git add .; press → to accept. Needs shell integration.';

  @override
  String get aiConfigCompletionModel => 'Completion model';

  @override
  String get aiConfigContextCustom => 'Custom';

  @override
  String get aiConfigApiKeyOptional => 'API key (optional)';

  @override
  String get aiConfigFeatureAdvanced => 'Advanced';

  @override
  String get aiConfigAvailableHosts => 'Available hosts';

  @override
  String get aiConfigFeatureNoHosts =>
      'New SSH hosts will be enabled automatically.';

  @override
  String get aiAgentAutoTarget => 'Auto';

  @override
  String get aiAgentPermissionAuto => 'Full auto';

  @override
  String get aiAgentPermissionConfirm => 'Confirm';

  @override
  String get aiAgentPermissionObserve => 'Observe';

  @override
  String get aiAgentPermissionReview => 'Auto confirm';

  @override
  String get aiAgentPermissionAutoHint =>
      'Read, execute and share results automatically';

  @override
  String get aiAgentPermissionConfirmHint => 'Approve reads and commands';

  @override
  String get aiAgentPermissionObserveHint => 'Read-only tools; approve reads';

  @override
  String get aiAgentPermissionReviewHint =>
      'Model review; ask you when uncertain';

  @override
  String get aiAgentReviewing => 'Approval model reviewing…';

  @override
  String get aiAgentReadApproveTitle => 'Approve reading information';

  @override
  String get aiAgentReadApproveHint =>
      'Run a fixed read-only diagnostic and let Airy use its bounded result.';

  @override
  String get aiAgentContentApproveHint =>
      'Let Airy read this content and use its bounded result for this turn.';

  @override
  String get aiAgentActionApproveTitle => 'Approve action';

  @override
  String get aiAgentActionApproveHint =>
      'Let Airy perform this action and use its bounded result for this turn.';

  @override
  String get aiAgentDiagnosticSystem => 'System and memory';

  @override
  String get aiAgentDiagnosticStorage => 'Storage capacity';

  @override
  String get aiAgentDiagnosticProcesses => 'Process resources';

  @override
  String get aiAgentDiagnosticPorts => 'Listening ports';

  @override
  String get aiAgentDiagnosticServices => 'Service states';

  @override
  String aiAgentContextUsage(int percent, int used, int total) {
    return 'Estimated context: $percent% · $used / $total tokens';
  }

  @override
  String get aiAgentRegenerate => 'Regenerate';

  @override
  String get aiAgentRegenerateHint =>
      'Generate another answer without running commands again';

  @override
  String get aiAgentWithdraw => 'Withdraw last turn';

  @override
  String get aiAgentWithdrawHint =>
      'Restore the last question as a draft. Executed operations are not undone; clear the current draft first.';

  @override
  String get aiAgentExecutionRecord => 'Execution record';

  @override
  String get aiAgentThinkingFlow => 'Thinking steps';

  @override
  String get aiAgentCopied => 'Copied';

  @override
  String get aiAgentCopyFailed =>
      'Could not copy. Select the text and copy manually.';

  @override
  String get aiAgentToolLocalRequest => 'Request local access';

  @override
  String get aiAgentToolLocalList => 'List local folder';

  @override
  String get aiAgentToolLocalStat => 'Local file info';

  @override
  String get aiAgentToolLocalRead => 'Read local file';

  @override
  String get aiAgentToolLocalHint =>
      'Use local files and folders you granted to this conversation.';

  @override
  String get aiAgentLocalFolder => 'Folder';

  @override
  String get aiAgentLocalGrantRevoke => 'Revoke access';

  @override
  String aiAgentLocalGrantWrite(String name) {
    return '$name · writable';
  }

  @override
  String get aiAgentLocalGrantExpired =>
      'This local access has expired. Attach or grant it again.';

  @override
  String get aiAgentLocalAccessTitle => 'Allow access to local files';

  @override
  String get aiAgentLocalAccessFolder =>
      'Airy asks to read a folder in this conversation.';

  @override
  String get aiAgentLocalAccessFile =>
      'Airy asks to read a file in this conversation.';

  @override
  String get aiAgentLocalAccessWrite =>
      'Airy asks to read and write a folder in this conversation. Files from servers may be saved into it.';

  @override
  String get aiAgentLocalAccessChooseFolder => 'Choose folder';

  @override
  String get aiAgentLocalAccessChooseFile => 'Choose file';

  @override
  String get mcpTitle => 'MCP / Skills';

  @override
  String get mcpChangeFailed => 'Could not save the change.';

  @override
  String get mcpStartFailed =>
      'Could not start MCP. Check the port and system credential storage.';

  @override
  String get mcpIdleTimeout => 'Session idle timeout';

  @override
  String get mcpIdleTimeoutHint => 'Applies to new MCP sessions.';

  @override
  String mcpIdleHours(int hours) {
    String _temp0 = intl.Intl.pluralLogic(
      hours,
      locale: localeName,
      other: '$hours hours',
      one: '1 hour',
    );
    return '$_temp0';
  }

  @override
  String get mcpModeModel => 'Model review';

  @override
  String get mcpModeHost => 'Confirm hosts';

  @override
  String get mcpModeAuto => 'Automatic within scope';

  @override
  String get mcpModeModelHint =>
      'You confirm each host on its first use in a session, then the review model checks every call. Calls it denies or cannot judge are not run.';

  @override
  String get mcpModeHostHint =>
      'Confirm each host once per session. Calls on approved hosts need no per-call review.';

  @override
  String get mcpModeAutoHint =>
      'Calls on the hosts you select run without host confirmation or model review.';

  @override
  String mcpScopeHosts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hosts',
      one: '1 host',
      zero: 'No hosts',
    );
    return '$_temp0';
  }

  @override
  String get mcpAudit => 'MCP audit';

  @override
  String get mcpAuditEmpty => 'No MCP calls recorded.';

  @override
  String get mcpAuditCompleted => 'Completed';

  @override
  String get mcpAuditRunning => 'In progress';

  @override
  String get mcpAuditCancelled => 'Cancelled';

  @override
  String get mcpAuditHostDenied => 'Host not allowed';

  @override
  String get mcpAuditReviewDenied => 'Denied by the review model';

  @override
  String get mcpAuditReviewUnavailable => 'Review model unavailable';

  @override
  String get mcpAuditOutsideScope => 'Host outside scope';

  @override
  String get mcpAuditScopeChanged => 'Access changed during the call';

  @override
  String get mcpAuditNotExposed => 'Tool not available';

  @override
  String get mcpAuditInvalid => 'Invalid arguments';

  @override
  String mcpAuditFailed(String code) {
    return 'Failed ($code)';
  }

  @override
  String get mcpClientConflict => 'Existing configuration kept';

  @override
  String get mcpClientUnavailable => 'Client configuration unavailable';

  @override
  String get mcpConnectionTitle => 'Allow MCP connection';

  @override
  String mcpConnectionPrompt(String client) {
    return 'Allow $client to use the Airy tools in Sshairy?';
  }

  @override
  String mcpTerminalHistoryPrompt(String client, String terminal) {
    return 'Allow $client to read recent commands and results from $terminal in this MCP session?';
  }

  @override
  String mcpTerminalScreenPrompt(String client, String terminal, int maxLines) {
    return 'Allow $client to read up to $maxLines visible lines from $terminal now?';
  }

  @override
  String mcpWorkspacePrompt(String client, String windows) {
    return 'Allow $client to perform this action on these windows?\n$windows';
  }

  @override
  String mcpLocalPrompt(String client) {
    return '$client is requesting local file access.';
  }

  @override
  String mcpHostPrompt(String client, String host) {
    return 'Allow $client to access $host for this MCP session?';
  }

  @override
  String get mcpPortSave => 'Save port';

  @override
  String mcpScopeChanged(String host) {
    return '$host (connection changed, select again)';
  }

  @override
  String get linkTitle => 'Device Link';

  @override
  String get linkTab => 'Link';

  @override
  String get linkEnabled => 'Enable desktop link';

  @override
  String get linkPort => 'Link port';

  @override
  String get linkDiscovery => 'LAN discovery';

  @override
  String get linkDeviceName => 'Device name';

  @override
  String get linkAddresses => 'LAN addresses';

  @override
  String linkRunning(int port) {
    return 'Listening on port $port';
  }

  @override
  String get linkStopped => 'Stopped';

  @override
  String get linkStartFailed => 'Could not start link listener';

  @override
  String get linkPairDevice => 'Pair device';

  @override
  String get linkCancelPairing => 'Cancel pairing';

  @override
  String get linkPairingCode => 'Pairing code';

  @override
  String get linkCopyUri => 'Copy pairing URI';

  @override
  String get linkCopied => 'Copied';

  @override
  String get linkPairedDevices => 'Paired devices';

  @override
  String get linkNoPeers => 'No paired devices yet.';

  @override
  String get linkOnline => 'Connected';

  @override
  String get linkOffline => 'Offline';

  @override
  String get linkPermMirror => 'Terminal mirror';

  @override
  String get linkPermProxy => 'Proxy SSH';

  @override
  String get linkPermSync => 'Config sync';

  @override
  String get linkPermApproval => 'Remote approval';

  @override
  String get linkRevoke => 'Unpair';

  @override
  String get linkDisconnect => 'Disconnect';

  @override
  String get linkPushCredentials => 'Push credentials';

  @override
  String linkPushCredentialsTitle(String device) {
    return 'Push credentials to $device';
  }

  @override
  String linkPushCredentialsSent(String device) {
    return 'Encrypted credentials sent to $device';
  }

  @override
  String get linkPushCredentialsEmpty =>
      'Select at least one host password or key.';

  @override
  String get linkScanLan => 'Scan LAN';

  @override
  String get linkScanning => 'Scanning...';

  @override
  String get linkDiscoveredDesktops => 'Nearby desktops';

  @override
  String get linkSavedDesktops => 'Saved desktops';

  @override
  String get linkManualConnect => 'Pair with desktop';

  @override
  String get linkHostOrIp => 'Desktop IP / Tailscale IP';

  @override
  String get linkPasteUri => 'Paste pairing URI';

  @override
  String get linkPairNow => 'Pair';

  @override
  String get linkReconnect => 'Connect';

  @override
  String linkConnectedTo(String desktop) {
    return 'Linked with $desktop';
  }

  @override
  String get linkSyncConfig => 'Sync config';

  @override
  String linkSyncDone(int hosts, int snippets, int keys) {
    return 'Synced $hosts hosts, $snippets snippets, +$keys keys';
  }

  @override
  String get linkPendingApprovals => 'Pending approvals';

  @override
  String get linkDesktopOnlyAction => 'Complete on desktop';

  @override
  String get linkAllow => 'Allow';

  @override
  String get linkDeny => 'Deny';

  @override
  String get linkDesktopTerminals => 'Desktop terminals';

  @override
  String get linkNoDesktopTerminals => 'No open terminals on desktop.';

  @override
  String get linkDesktopLocalShells => 'Desktop local shell';

  @override
  String get linkLocalTag => 'Local';

  @override
  String linkReconnecting(String desktop) {
    return 'Reconnecting to $desktop...';
  }

  @override
  String get linkMirrorTag => 'Mirror';

  @override
  String get linkSessionPending => 'Pending';

  @override
  String get linkProxyTag => 'Via desktop';

  @override
  String get linkOpenOnDesktopMirrored => 'Open on desktop with mirror';

  @override
  String get linkDesktopOpenFailed =>
      'Could not open the terminal on the desktop.';

  @override
  String get linkDesktopHosts => 'Connect via desktop';

  @override
  String get linkNoDesktopHosts => 'No saved hosts on desktop.';

  @override
  String get linkCredentialOfferTitle => 'Desktop sent encrypted credentials';

  @override
  String linkCredentialOfferDetail(int passwords, int keys) {
    return '$passwords passwords, $keys private keys';
  }

  @override
  String get linkCredentialImport => 'Save to keystore';

  @override
  String linkCredentialImported(int count) {
    return 'Saved $count credentials';
  }

  @override
  String get linkPasswordSyncConfirmTitle => 'Confirm server password sync';

  @override
  String linkPasswordSyncConfirmBody(String device, int count) {
    return '$device requested $count saved server passwords.';
  }

  @override
  String get linkPasswordSyncAllow => 'Sync passwords';

  @override
  String get linkPasswordSyncSkip => 'Skip passwords';

  @override
  String get linkPasswordSyncWaiting => 'Confirm password sync on desktop…';

  @override
  String linkPasswordSyncImported(int count) {
    return 'Synced $count server passwords';
  }

  @override
  String get linkPasswordSyncDeclined => 'Password sync skipped on desktop';

  @override
  String get linkErrorAuth => 'Authentication failed';

  @override
  String get linkErrorCode => 'Invalid pairing code';

  @override
  String get linkErrorExpired => 'Pairing code expired';

  @override
  String get linkErrorRevoked => 'Device unpaired on desktop';

  @override
  String get linkErrorNetwork => 'Cannot reach desktop';

  @override
  String get mobileNoActiveTerminal => 'No active terminal';

  @override
  String get mobileSessions => 'Sessions';

  @override
  String get mobileTools => 'Tools';

  @override
  String get mobileTabAiry => 'Airy';

  @override
  String get mobileTabMe => 'Me';

  @override
  String get mobileScanQr => 'Scan desktop QR';

  @override
  String get mobileScanQrHint =>
      'Point at the pairing QR code on Sshairy desktop';

  @override
  String get mobileHandoffToDesktop => 'Open on desktop';

  @override
  String get mobileHandoffSent => 'Opened on desktop';

  @override
  String get mobilePushClipboard => 'Send clipboard';

  @override
  String get mobileClipboardSent => 'Sent clipboard to desktop';

  @override
  String get mobileDirectTag => 'Direct';

  @override
  String get mobileKeepScreenOn => 'Keep screen awake';

  @override
  String get mobileKeepAlive => 'Background keep-alive';

  @override
  String get mobileKeepAliveTitle => 'Sshairy active';

  @override
  String mobileKeepAliveSubtitle(int count) {
    return '$count active sessions';
  }

  @override
  String get mobileHaptics => 'Haptic feedback';

  @override
  String get mobileBiometricLock => 'Biometric lock';

  @override
  String get mobileUnlockPrompt => 'Unlock Sshairy';

  @override
  String get mobileUnlockAction => 'Unlock';

  @override
  String get mobileTrackpad => 'Trackpad';

  @override
  String get mobileDraftMode => 'Command bar';

  @override
  String get mobileDraftPlaceholder => 'Type command or ask Airy…';

  @override
  String get mobileAskAiry => 'Ask Airy';

  @override
  String get mobileSyncAiFromDesktop => 'Sync AI from desktop';

  @override
  String get mobileAiQuickSystem => 'CPU & Memory';

  @override
  String get mobileAiQuickDisk => 'Disk usage';

  @override
  String get mobileAiQuickLogs => 'Recent errors';

  @override
  String get mobileAiQuickPorts => 'Open ports';

  @override
  String get mobileFileEditor => 'Edit';

  @override
  String get mobileFileSaved => 'Saved';

  @override
  String get mobileFileTooLarge => 'File is too large for inline editor';

  @override
  String get mobileFilesExpand => 'Open full file manager';

  @override
  String get mobileSendPathToTerminal => 'Send path to terminal';

  @override
  String get mobileNewFile => 'New file';

  @override
  String get mobileNewFolder => 'New folder';

  @override
  String get mobileUploadFile => 'Upload file';

  @override
  String get mobileThisPhone => 'This phone';

  @override
  String get linkSharePhoneFiles => 'Share phone files';

  @override
  String get mobileGenerateKey => 'Generate Ed25519 key';

  @override
  String get mobilePublicKeyCopied => 'Public key copied';

  @override
  String get mobileSecuritySection => 'Security & background';

  @override
  String get mobileTerminalSection => 'Terminal & touch';

  @override
  String get mobileQuickConnect => 'Quick connect';

  @override
  String get mobileAllGroups => 'All';

  @override
  String get mobilePinned => 'Pinned';

  @override
  String get mobileSyncAiIncluded => '+ AI config';

  @override
  String get starPromptTitle => 'Enjoying Sshairy?';

  @override
  String get starPromptMessage =>
      'Your star on GitHub is the biggest motivation to keep improving Sshairy.';

  @override
  String get starPromptAction => 'Star on GitHub';

  @override
  String get starPromptNever => 'Don\'t remind me';
}
