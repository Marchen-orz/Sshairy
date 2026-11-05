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
  String get newConnection => 'New connection';
}
