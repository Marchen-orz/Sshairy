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
}
