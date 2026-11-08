import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// No description provided for @uiScale.
  ///
  /// In en, this message translates to:
  /// **'Interface scale'**
  String get uiScale;

  /// No description provided for @importChooseAgain.
  ///
  /// In en, this message translates to:
  /// **'Choose another source'**
  String get importChooseAgain;

  /// No description provided for @importChooseFolder.
  ///
  /// In en, this message translates to:
  /// **'Choose folder'**
  String get importChooseFolder;

  /// No description provided for @importChooseFile.
  ///
  /// In en, this message translates to:
  /// **'Choose file'**
  String get importChooseFile;

  /// No description provided for @importLoginOption.
  ///
  /// In en, this message translates to:
  /// **'Import saved login details'**
  String get importLoginOption;

  /// No description provided for @importLoginStorage.
  ///
  /// In en, this message translates to:
  /// **'Passwords stay on this device and go into OS secure storage. Existing passwords are kept.'**
  String get importLoginStorage;

  /// No description provided for @importPasswordFound.
  ///
  /// In en, this message translates to:
  /// **'Saved password available'**
  String get importPasswordFound;

  /// No description provided for @importLoginNeeded.
  ///
  /// In en, this message translates to:
  /// **'Login details needed when connecting'**
  String get importLoginNeeded;

  /// No description provided for @importCleanupFailed.
  ///
  /// In en, this message translates to:
  /// **'Import failed and some new credentials could not be removed. Check OS secure storage before retrying.'**
  String get importCleanupFailed;

  /// No description provided for @importSourceChanged.
  ///
  /// In en, this message translates to:
  /// **'The source changed or is unreadable. Choose it again.'**
  String get importSourceChanged;

  /// No description provided for @importGuideOpenSsh.
  ///
  /// In en, this message translates to:
  /// **'Choose the config file inside .ssh. Include files are read only within that configuration folder.'**
  String get importGuideOpenSsh;

  /// No description provided for @importGuidePutty.
  ///
  /// In en, this message translates to:
  /// **'PuTTY sessions are detected from the Windows registry. For manual import, choose a Sessions .reg export from Registry Editor.'**
  String get importGuidePutty;

  /// No description provided for @importGuideMoba.
  ///
  /// In en, this message translates to:
  /// **'Choose MobaXterm.ini or a .mxtsessions export from the session list. Portable editions usually keep the configuration beside the program.'**
  String get importGuideMoba;

  /// No description provided for @importGuideSecureCrt.
  ///
  /// In en, this message translates to:
  /// **'Find the configuration folder in SecureCRT Global Options, then choose its Sessions folder containing .ini sessions.'**
  String get importGuideSecureCrt;

  /// No description provided for @importGuideXshell.
  ///
  /// In en, this message translates to:
  /// **'Choose Xshell/Sessions under the matching NetSarang Computer version in Documents. It contains .xsh sessions.'**
  String get importGuideXshell;

  /// No description provided for @importGuideFinalShell.
  ///
  /// In en, this message translates to:
  /// **'Choose conn inside the FinalShell program folder, or an export folder containing *_connect_config.json files. Extract archives first. Choose portable or custom installations manually.'**
  String get importGuideFinalShell;

  /// No description provided for @importGuideTabby.
  ///
  /// In en, this message translates to:
  /// **'Choose the Tabby config.yaml configuration file.'**
  String get importGuideTabby;

  /// No description provided for @importGuideCsv.
  ///
  /// In en, this message translates to:
  /// **'Choose a UTF-8 CSV file with a host header. Optional columns: name, port, username, group, key.'**
  String get importGuideCsv;

  /// No description provided for @hosts.
  ///
  /// In en, this message translates to:
  /// **'Hosts'**
  String get hosts;

  /// No description provided for @newHost.
  ///
  /// In en, this message translates to:
  /// **'New host'**
  String get newHost;

  /// No description provided for @searchHint.
  ///
  /// In en, this message translates to:
  /// **'Search hosts or user@host'**
  String get searchHint;

  /// No description provided for @connectTo.
  ///
  /// In en, this message translates to:
  /// **'Connect {target}'**
  String connectTo(String target);

  /// No description provided for @connect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connect;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @deleteHost.
  ///
  /// In en, this message translates to:
  /// **'Delete {name}?'**
  String deleteHost(String name);

  /// No description provided for @hostInUse.
  ///
  /// In en, this message translates to:
  /// **'Jump host of {names}'**
  String hostInUse(String names);

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Reconnect'**
  String get retry;

  /// No description provided for @label.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get label;

  /// No description provided for @address.
  ///
  /// In en, this message translates to:
  /// **'Address'**
  String get address;

  /// No description provided for @port.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get port;

  /// No description provided for @username.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get username;

  /// No description provided for @password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// No description provided for @privateKey.
  ///
  /// In en, this message translates to:
  /// **'Private key'**
  String get privateKey;

  /// No description provided for @keyPath.
  ///
  /// In en, this message translates to:
  /// **'Private key file'**
  String get keyPath;

  /// No description provided for @passphrase.
  ///
  /// In en, this message translates to:
  /// **'Key passphrase'**
  String get passphrase;

  /// No description provided for @remember.
  ///
  /// In en, this message translates to:
  /// **'Remember'**
  String get remember;

  /// No description provided for @required.
  ///
  /// In en, this message translates to:
  /// **'Required'**
  String get required;

  /// No description provided for @invalidPort.
  ///
  /// In en, this message translates to:
  /// **'1–65535'**
  String get invalidPort;

  /// No description provided for @connecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get connecting;

  /// No description provided for @disconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get disconnected;

  /// No description provided for @hostKeyUnknown.
  ///
  /// In en, this message translates to:
  /// **'Unknown host'**
  String get hostKeyUnknown;

  /// No description provided for @hostKeyChanged.
  ///
  /// In en, this message translates to:
  /// **'Host key changed'**
  String get hostKeyChanged;

  /// No description provided for @hostKeyChangedWarning.
  ///
  /// In en, this message translates to:
  /// **'This may be a man-in-the-middle attack. Replace only if you know the server key was changed.'**
  String get hostKeyChangedWarning;

  /// No description provided for @previousKey.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get previousKey;

  /// No description provided for @currentKey.
  ///
  /// In en, this message translates to:
  /// **'Received'**
  String get currentKey;

  /// No description provided for @trustOnce.
  ///
  /// In en, this message translates to:
  /// **'Trust once'**
  String get trustOnce;

  /// No description provided for @trustSave.
  ///
  /// In en, this message translates to:
  /// **'Trust'**
  String get trustSave;

  /// No description provided for @replaceKey.
  ///
  /// In en, this message translates to:
  /// **'Replace saved key'**
  String get replaceKey;

  /// No description provided for @errConnect.
  ///
  /// In en, this message translates to:
  /// **'Cannot connect: {detail}'**
  String errConnect(String detail);

  /// No description provided for @errAuth.
  ///
  /// In en, this message translates to:
  /// **'Authentication failed'**
  String get errAuth;

  /// No description provided for @errHostKeyRejected.
  ///
  /// In en, this message translates to:
  /// **'Host key rejected'**
  String get errHostKeyRejected;

  /// No description provided for @errKeyFile.
  ///
  /// In en, this message translates to:
  /// **'Cannot read private key: {detail}'**
  String errKeyFile(String detail);

  /// No description provided for @errCancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get errCancelled;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @theme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get theme;

  /// No description provided for @themeSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get themeSystem;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// No description provided for @fontSize.
  ///
  /// In en, this message translates to:
  /// **'Terminal font size'**
  String get fontSize;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @langZh.
  ///
  /// In en, this message translates to:
  /// **'中文'**
  String get langZh;

  /// No description provided for @langEn.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get langEn;

  /// No description provided for @paste.
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get paste;

  /// No description provided for @noMatches.
  ///
  /// In en, this message translates to:
  /// **'No matching hosts'**
  String get noMatches;

  /// No description provided for @more.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get more;

  /// No description provided for @renderer.
  ///
  /// In en, this message translates to:
  /// **'Renderer'**
  String get renderer;

  /// No description provided for @restartToApply.
  ///
  /// In en, this message translates to:
  /// **'Takes effect after restart'**
  String get restartToApply;

  /// No description provided for @accent.
  ///
  /// In en, this message translates to:
  /// **'Color theme'**
  String get accent;

  /// No description provided for @themeNameBlue.
  ///
  /// In en, this message translates to:
  /// **'Ice Blue · Mint'**
  String get themeNameBlue;

  /// No description provided for @themeNameGreen.
  ///
  /// In en, this message translates to:
  /// **'Mint Green'**
  String get themeNameGreen;

  /// No description provided for @themeNameViolet.
  ///
  /// In en, this message translates to:
  /// **'Violet'**
  String get themeNameViolet;

  /// No description provided for @themeNameOrange.
  ///
  /// In en, this message translates to:
  /// **'Sunset Orange'**
  String get themeNameOrange;

  /// No description provided for @themeNameDeepSea.
  ///
  /// In en, this message translates to:
  /// **'Deep Sea Blue'**
  String get themeNameDeepSea;

  /// No description provided for @themeNamePink.
  ///
  /// In en, this message translates to:
  /// **'Sakura Pink'**
  String get themeNamePink;

  /// No description provided for @navigationExpand.
  ///
  /// In en, this message translates to:
  /// **'Expand navigation'**
  String get navigationExpand;

  /// No description provided for @navigationCollapse.
  ///
  /// In en, this message translates to:
  /// **'Collapse navigation'**
  String get navigationCollapse;

  /// No description provided for @commandPalette.
  ///
  /// In en, this message translates to:
  /// **'Command palette'**
  String get commandPalette;

  /// No description provided for @paletteHint.
  ///
  /// In en, this message translates to:
  /// **'Hosts, sessions, actions'**
  String get paletteHint;

  /// No description provided for @split.
  ///
  /// In en, this message translates to:
  /// **'Split'**
  String get split;

  /// No description provided for @splitRight.
  ///
  /// In en, this message translates to:
  /// **'Split right'**
  String get splitRight;

  /// No description provided for @splitDown.
  ///
  /// In en, this message translates to:
  /// **'Split down'**
  String get splitDown;

  /// No description provided for @closePane.
  ///
  /// In en, this message translates to:
  /// **'Close pane'**
  String get closePane;

  /// No description provided for @newConnection.
  ///
  /// In en, this message translates to:
  /// **'New connection'**
  String get newConnection;

  /// No description provided for @appearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get appearance;

  /// No description provided for @terminal.
  ///
  /// In en, this message translates to:
  /// **'Terminal'**
  String get terminal;

  /// No description provided for @connection.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get connection;

  /// No description provided for @dataSecurity.
  ///
  /// In en, this message translates to:
  /// **'Data & security'**
  String get dataSecurity;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @cursorShape.
  ///
  /// In en, this message translates to:
  /// **'Cursor'**
  String get cursorShape;

  /// No description provided for @cursorBlock.
  ///
  /// In en, this message translates to:
  /// **'Block'**
  String get cursorBlock;

  /// No description provided for @cursorUnderline.
  ///
  /// In en, this message translates to:
  /// **'Underline'**
  String get cursorUnderline;

  /// No description provided for @cursorBar.
  ///
  /// In en, this message translates to:
  /// **'Bar'**
  String get cursorBar;

  /// No description provided for @scrollback.
  ///
  /// In en, this message translates to:
  /// **'Scrollback lines'**
  String get scrollback;

  /// No description provided for @copyOnSelect.
  ///
  /// In en, this message translates to:
  /// **'Copy on select'**
  String get copyOnSelect;

  /// No description provided for @rightClick.
  ///
  /// In en, this message translates to:
  /// **'Right click'**
  String get rightClick;

  /// No description provided for @rightClickMenu.
  ///
  /// In en, this message translates to:
  /// **'Menu'**
  String get rightClickMenu;

  /// No description provided for @confirmPaste.
  ///
  /// In en, this message translates to:
  /// **'Confirm multi-line paste'**
  String get confirmPaste;

  /// No description provided for @connectTimeout.
  ///
  /// In en, this message translates to:
  /// **'Connect timeout'**
  String get connectTimeout;

  /// No description provided for @keepAlive.
  ///
  /// In en, this message translates to:
  /// **'Keepalive'**
  String get keepAlive;

  /// No description provided for @idleTtl.
  ///
  /// In en, this message translates to:
  /// **'Keep idle connections'**
  String get idleTtl;

  /// No description provided for @autoReconnect.
  ///
  /// In en, this message translates to:
  /// **'Reconnect automatically'**
  String get autoReconnect;

  /// No description provided for @off.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get off;

  /// No description provided for @seconds.
  ///
  /// In en, this message translates to:
  /// **'{n} s'**
  String seconds(int n);

  /// No description provided for @appliesNextConnection.
  ///
  /// In en, this message translates to:
  /// **'Applies to new connections'**
  String get appliesNextConnection;

  /// No description provided for @appliesNewSessions.
  ///
  /// In en, this message translates to:
  /// **'Applies to new sessions'**
  String get appliesNewSessions;

  /// No description provided for @trustedKeys.
  ///
  /// In en, this message translates to:
  /// **'Trusted host keys'**
  String get trustedKeys;

  /// No description provided for @none.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get none;

  /// No description provided for @remove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get remove;

  /// No description provided for @version.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get version;

  /// No description provided for @dataDir.
  ///
  /// In en, this message translates to:
  /// **'Data folder'**
  String get dataDir;

  /// No description provided for @open.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get open;

  /// No description provided for @find.
  ///
  /// In en, this message translates to:
  /// **'Find'**
  String get find;

  /// No description provided for @matchCount.
  ///
  /// In en, this message translates to:
  /// **'{current}/{total}'**
  String matchCount(int current, int total);

  /// No description provided for @noResults.
  ///
  /// In en, this message translates to:
  /// **'No results'**
  String get noResults;

  /// No description provided for @previous.
  ///
  /// In en, this message translates to:
  /// **'Previous'**
  String get previous;

  /// No description provided for @next.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get next;

  /// No description provided for @caseSensitive.
  ///
  /// In en, this message translates to:
  /// **'Match case'**
  String get caseSensitive;

  /// No description provided for @regex.
  ///
  /// In en, this message translates to:
  /// **'Regular expression'**
  String get regex;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @selectAll.
  ///
  /// In en, this message translates to:
  /// **'Select all'**
  String get selectAll;

  /// No description provided for @clearScreen.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get clearScreen;

  /// No description provided for @openLink.
  ///
  /// In en, this message translates to:
  /// **'Open link'**
  String get openLink;

  /// No description provided for @copyLink.
  ///
  /// In en, this message translates to:
  /// **'Copy link'**
  String get copyLink;

  /// No description provided for @rename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get rename;

  /// No description provided for @duplicate.
  ///
  /// In en, this message translates to:
  /// **'Duplicate'**
  String get duplicate;

  /// No description provided for @reconnectingIn.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting in {n} s'**
  String reconnectingIn(int n);

  /// No description provided for @stop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get stop;

  /// No description provided for @keys.
  ///
  /// In en, this message translates to:
  /// **'Keys'**
  String get keys;

  /// No description provided for @importKey.
  ///
  /// In en, this message translates to:
  /// **'Import key'**
  String get importKey;

  /// No description provided for @generateKey.
  ///
  /// In en, this message translates to:
  /// **'Generate key'**
  String get generateKey;

  /// No description provided for @keySource.
  ///
  /// In en, this message translates to:
  /// **'Private key or file path'**
  String get keySource;

  /// No description provided for @keyFile.
  ///
  /// In en, this message translates to:
  /// **'Key file'**
  String get keyFile;

  /// No description provided for @copyPublicKey.
  ///
  /// In en, this message translates to:
  /// **'Copy public key'**
  String get copyPublicKey;

  /// No description provided for @keyInUse.
  ///
  /// In en, this message translates to:
  /// **'Used by {names}'**
  String keyInUse(String names);

  /// No description provided for @deleteKey.
  ///
  /// In en, this message translates to:
  /// **'Delete key {name}? Hosts can no longer use it.'**
  String deleteKey(String name);

  /// No description provided for @errKeyUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Not a supported private key'**
  String get errKeyUnsupported;

  /// No description provided for @errKeyNeedsPassphrase.
  ///
  /// In en, this message translates to:
  /// **'This key is encrypted; enter its passphrase'**
  String get errKeyNeedsPassphrase;

  /// No description provided for @errKeyWrongPassphrase.
  ///
  /// In en, this message translates to:
  /// **'Wrong passphrase'**
  String get errKeyWrongPassphrase;

  /// No description provided for @errKeyDuplicate.
  ///
  /// In en, this message translates to:
  /// **'Already imported as {name}'**
  String errKeyDuplicate(String name);

  /// No description provided for @errKeyUnreadable.
  ///
  /// In en, this message translates to:
  /// **'Cannot read the file'**
  String get errKeyUnreadable;

  /// No description provided for @group.
  ///
  /// In en, this message translates to:
  /// **'Group'**
  String get group;

  /// No description provided for @tags.
  ///
  /// In en, this message translates to:
  /// **'Tags'**
  String get tags;

  /// No description provided for @tagsHint.
  ///
  /// In en, this message translates to:
  /// **'Comma separated'**
  String get tagsHint;

  /// No description provided for @allHosts.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get allHosts;

  /// No description provided for @pin.
  ///
  /// In en, this message translates to:
  /// **'Pin'**
  String get pin;

  /// No description provided for @unpin.
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get unpin;

  /// No description provided for @sortName.
  ///
  /// In en, this message translates to:
  /// **'By name'**
  String get sortName;

  /// No description provided for @sortRecent.
  ///
  /// In en, this message translates to:
  /// **'By recent use'**
  String get sortRecent;

  /// No description provided for @gridView.
  ///
  /// In en, this message translates to:
  /// **'Grid'**
  String get gridView;

  /// No description provided for @listView.
  ///
  /// In en, this message translates to:
  /// **'List'**
  String get listView;

  /// No description provided for @copyOf.
  ///
  /// In en, this message translates to:
  /// **'{name} copy'**
  String copyOf(String name);

  /// No description provided for @dissolveGroup.
  ///
  /// In en, this message translates to:
  /// **'Dissolve group'**
  String get dissolveGroup;

  /// No description provided for @sftp.
  ///
  /// In en, this message translates to:
  /// **'SFTP'**
  String get sftp;

  /// No description provided for @files.
  ///
  /// In en, this message translates to:
  /// **'Files'**
  String get files;

  /// No description provided for @thisComputer.
  ///
  /// In en, this message translates to:
  /// **'This computer'**
  String get thisComputer;

  /// No description provided for @back.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// No description provided for @forward.
  ///
  /// In en, this message translates to:
  /// **'Forward'**
  String get forward;

  /// No description provided for @up.
  ///
  /// In en, this message translates to:
  /// **'Up'**
  String get up;

  /// No description provided for @refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// No description provided for @filter.
  ///
  /// In en, this message translates to:
  /// **'Filter'**
  String get filter;

  /// No description provided for @editPath.
  ///
  /// In en, this message translates to:
  /// **'Edit path'**
  String get editPath;

  /// No description provided for @newFolder.
  ///
  /// In en, this message translates to:
  /// **'New folder'**
  String get newFolder;

  /// No description provided for @hiddenFiles.
  ///
  /// In en, this message translates to:
  /// **'Hidden files'**
  String get hiddenFiles;

  /// No description provided for @uploadFiles.
  ///
  /// In en, this message translates to:
  /// **'Upload files…'**
  String get uploadFiles;

  /// No description provided for @downloadTo.
  ///
  /// In en, this message translates to:
  /// **'Download to…'**
  String get downloadTo;

  /// No description provided for @sendToOther.
  ///
  /// In en, this message translates to:
  /// **'Send to the other side'**
  String get sendToOther;

  /// No description provided for @editFile.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get editFile;

  /// No description provided for @copyPath.
  ///
  /// In en, this message translates to:
  /// **'Copy path'**
  String get copyPath;

  /// No description provided for @permissions.
  ///
  /// In en, this message translates to:
  /// **'Permissions'**
  String get permissions;

  /// No description provided for @colName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get colName;

  /// No description provided for @colModified.
  ///
  /// In en, this message translates to:
  /// **'Modified'**
  String get colModified;

  /// No description provided for @colSize.
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get colSize;

  /// No description provided for @colOwner.
  ///
  /// In en, this message translates to:
  /// **'Owner'**
  String get colOwner;

  /// No description provided for @emptyFolder.
  ///
  /// In en, this message translates to:
  /// **'Empty'**
  String get emptyFolder;

  /// No description provided for @deleteOne.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\"?'**
  String deleteOne(String name);

  /// No description provided for @deleteTree.
  ///
  /// In en, this message translates to:
  /// **'Delete \"{name}\" and the {count} items in it?'**
  String deleteTree(String name, int count);

  /// No description provided for @deleteMany.
  ///
  /// In en, this message translates to:
  /// **'Delete {count} items?'**
  String deleteMany(int count);

  /// No description provided for @permOwner.
  ///
  /// In en, this message translates to:
  /// **'Owner'**
  String get permOwner;

  /// No description provided for @permGroup.
  ///
  /// In en, this message translates to:
  /// **'Group'**
  String get permGroup;

  /// No description provided for @permOthers.
  ///
  /// In en, this message translates to:
  /// **'Others'**
  String get permOthers;

  /// No description provided for @permRead.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get permRead;

  /// No description provided for @permWrite.
  ///
  /// In en, this message translates to:
  /// **'Write'**
  String get permWrite;

  /// No description provided for @permExecute.
  ///
  /// In en, this message translates to:
  /// **'Execute'**
  String get permExecute;

  /// No description provided for @transfers.
  ///
  /// In en, this message translates to:
  /// **'Transfers'**
  String get transfers;

  /// No description provided for @clearFinished.
  ///
  /// In en, this message translates to:
  /// **'Clear finished'**
  String get clearFinished;

  /// No description provided for @tsQueued.
  ///
  /// In en, this message translates to:
  /// **'Queued'**
  String get tsQueued;

  /// No description provided for @tsWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting for your choice'**
  String get tsWaiting;

  /// No description provided for @tsCompleted.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get tsCompleted;

  /// No description provided for @tsFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get tsFailed;

  /// No description provided for @tsCancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get tsCancelled;

  /// No description provided for @tsInterrupted.
  ///
  /// In en, this message translates to:
  /// **'Interrupted'**
  String get tsInterrupted;

  /// No description provided for @tsScanning.
  ///
  /// In en, this message translates to:
  /// **'Scanning'**
  String get tsScanning;

  /// No description provided for @tsVerifying.
  ///
  /// In en, this message translates to:
  /// **'Verifying'**
  String get tsVerifying;

  /// No description provided for @tsPublishing.
  ///
  /// In en, this message translates to:
  /// **'Finishing'**
  String get tsPublishing;

  /// No description provided for @skippedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} skipped'**
  String skippedCount(int count);

  /// No description provided for @filesCount.
  ///
  /// In en, this message translates to:
  /// **'{done}/{total} files'**
  String filesCount(int done, int total);

  /// No description provided for @conflictFile.
  ///
  /// In en, this message translates to:
  /// **'\"{name}\" already exists'**
  String conflictFile(String name);

  /// No description provided for @conflictDir.
  ///
  /// In en, this message translates to:
  /// **'Folder \"{name}\" already exists'**
  String conflictDir(String name);

  /// No description provided for @conflictType.
  ///
  /// In en, this message translates to:
  /// **'\"{name}\" already exists as another type'**
  String conflictType(String name);

  /// No description provided for @existingItem.
  ///
  /// In en, this message translates to:
  /// **'Existing'**
  String get existingItem;

  /// No description provided for @incomingItem.
  ///
  /// In en, this message translates to:
  /// **'Incoming'**
  String get incomingItem;

  /// No description provided for @replace.
  ///
  /// In en, this message translates to:
  /// **'Replace'**
  String get replace;

  /// No description provided for @merge.
  ///
  /// In en, this message translates to:
  /// **'Merge'**
  String get merge;

  /// No description provided for @keepBoth.
  ///
  /// In en, this message translates to:
  /// **'Keep both'**
  String get keepBoth;

  /// No description provided for @skip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get skip;

  /// No description provided for @applyToAll.
  ///
  /// In en, this message translates to:
  /// **'Same for the rest of this batch'**
  String get applyToAll;

  /// No description provided for @upload.
  ///
  /// In en, this message translates to:
  /// **'Upload'**
  String get upload;

  /// No description provided for @autoUpload.
  ///
  /// In en, this message translates to:
  /// **'Upload on save'**
  String get autoUpload;

  /// No description provided for @finishEdit.
  ///
  /// In en, this message translates to:
  /// **'Done editing'**
  String get finishEdit;

  /// No description provided for @discardEdit.
  ///
  /// In en, this message translates to:
  /// **'\"{name}\" has changes that were not uploaded. Discard them?'**
  String discardEdit(String name);

  /// No description provided for @discard.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get discard;

  /// No description provided for @editConflict.
  ///
  /// In en, this message translates to:
  /// **'Changed on the server since it was downloaded'**
  String get editConflict;

  /// No description provided for @overwrite.
  ///
  /// In en, this message translates to:
  /// **'Overwrite'**
  String get overwrite;

  /// No description provided for @uploadAsCopy.
  ///
  /// In en, this message translates to:
  /// **'Upload as a copy'**
  String get uploadAsCopy;

  /// No description provided for @redownload.
  ///
  /// In en, this message translates to:
  /// **'Download again'**
  String get redownload;

  /// No description provided for @esModified.
  ///
  /// In en, this message translates to:
  /// **'Not uploaded'**
  String get esModified;

  /// No description provided for @esUploading.
  ///
  /// In en, this message translates to:
  /// **'Uploading'**
  String get esUploading;

  /// No description provided for @esClean.
  ///
  /// In en, this message translates to:
  /// **'Up to date'**
  String get esClean;

  /// No description provided for @errFsNotFound.
  ///
  /// In en, this message translates to:
  /// **'Not found'**
  String get errFsNotFound;

  /// No description provided for @errFsPermission.
  ///
  /// In en, this message translates to:
  /// **'Permission denied'**
  String get errFsPermission;

  /// No description provided for @errFsExists.
  ///
  /// In en, this message translates to:
  /// **'Already exists'**
  String get errFsExists;

  /// No description provided for @errFsUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Not supported by the server'**
  String get errFsUnsupported;

  /// No description provided for @errFsLost.
  ///
  /// In en, this message translates to:
  /// **'Connection lost'**
  String get errFsLost;

  /// No description provided for @errFsFailed.
  ///
  /// In en, this message translates to:
  /// **'The operation failed'**
  String get errFsFailed;

  /// No description provided for @errBadName.
  ///
  /// In en, this message translates to:
  /// **'Not a valid name'**
  String get errBadName;

  /// No description provided for @errSizeMismatch.
  ///
  /// In en, this message translates to:
  /// **'Size check failed; nothing was published'**
  String get errSizeMismatch;

  /// No description provided for @errTargetChanged.
  ///
  /// In en, this message translates to:
  /// **'The target changed meanwhile and was left alone'**
  String get errTargetChanged;

  /// No description provided for @errReplaceUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This server cannot replace files safely; the original was kept'**
  String get errReplaceUnsupported;

  /// No description provided for @errSourceMissing.
  ///
  /// In en, this message translates to:
  /// **'The source is gone'**
  String get errSourceMissing;

  /// No description provided for @errTooMany.
  ///
  /// In en, this message translates to:
  /// **'More than {count} items'**
  String errTooMany(int count);

  /// No description provided for @errTooDeep.
  ///
  /// In en, this message translates to:
  /// **'Nested deeper than {count} levels'**
  String errTooDeep(int count);

  /// No description provided for @errStalled.
  ///
  /// In en, this message translates to:
  /// **'No progress for 30 seconds'**
  String get errStalled;

  /// No description provided for @errNotRegular.
  ///
  /// In en, this message translates to:
  /// **'Not a regular file'**
  String get errNotRegular;

  /// No description provided for @errTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Over 64 MB; download it instead'**
  String get errTooLarge;

  /// No description provided for @transferConcurrency.
  ///
  /// In en, this message translates to:
  /// **'Simultaneous transfers'**
  String get transferConcurrency;

  /// No description provided for @transfersRunning.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 transfer in progress} other{{count} transfers in progress}}'**
  String transfersRunning(int count);

  /// No description provided for @editsUnsaved.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 edit not uploaded} other{{count} edits not uploaded}}'**
  String editsUnsaved(int count);

  /// No description provided for @quitNote.
  ///
  /// In en, this message translates to:
  /// **'Transfers in progress are cancelled. Edits that were not uploaded stay and can be uploaded next time.'**
  String get quitNote;

  /// No description provided for @quit.
  ///
  /// In en, this message translates to:
  /// **'Quit'**
  String get quit;

  /// No description provided for @proxyPassword.
  ///
  /// In en, this message translates to:
  /// **'Proxy password'**
  String get proxyPassword;

  /// No description provided for @errProxyAuth.
  ///
  /// In en, this message translates to:
  /// **'Proxy authentication failed. Check the username and password.'**
  String get errProxyAuth;

  /// No description provided for @errRouteLoop.
  ///
  /// In en, this message translates to:
  /// **'The jump host chain contains a loop.'**
  String get errRouteLoop;

  /// No description provided for @errRouteMissing.
  ///
  /// In en, this message translates to:
  /// **'A jump host no longer exists. Edit the connection route.'**
  String get errRouteMissing;

  /// No description provided for @errRouteTooLong.
  ///
  /// In en, this message translates to:
  /// **'A connection route can contain at most 8 hosts.'**
  String get errRouteTooLong;

  /// No description provided for @errRouteInvalid.
  ///
  /// In en, this message translates to:
  /// **'The connection route is invalid.'**
  String get errRouteInvalid;

  /// No description provided for @route.
  ///
  /// In en, this message translates to:
  /// **'Connection route'**
  String get route;

  /// No description provided for @jumpHost.
  ///
  /// In en, this message translates to:
  /// **'Jump host'**
  String get jumpHost;

  /// No description provided for @directConnection.
  ///
  /// In en, this message translates to:
  /// **'Direct'**
  String get directConnection;

  /// No description provided for @proxy.
  ///
  /// In en, this message translates to:
  /// **'Proxy'**
  String get proxy;

  /// No description provided for @proxyAddress.
  ///
  /// In en, this message translates to:
  /// **'Proxy address'**
  String get proxyAddress;

  /// No description provided for @proxyUser.
  ///
  /// In en, this message translates to:
  /// **'Proxy username (optional)'**
  String get proxyUser;

  /// No description provided for @legacyAlgorithms.
  ///
  /// In en, this message translates to:
  /// **'Legacy algorithms'**
  String get legacyAlgorithms;

  /// No description provided for @legacyAlgorithmsHint.
  ///
  /// In en, this message translates to:
  /// **'Allow SHA-1 and CBC only for this host when a legacy server requires them.'**
  String get legacyAlgorithmsHint;

  /// No description provided for @errHostSave.
  ///
  /// In en, this message translates to:
  /// **'Could not save this host. Check access to the data directory and secure storage.'**
  String get errHostSave;

  /// No description provided for @snippets.
  ///
  /// In en, this message translates to:
  /// **'Snippets'**
  String get snippets;

  /// No description provided for @newSnippet.
  ///
  /// In en, this message translates to:
  /// **'New snippet'**
  String get newSnippet;

  /// No description provided for @insertSnippet.
  ///
  /// In en, this message translates to:
  /// **'Insert'**
  String get insertSnippet;

  /// No description provided for @runSnippet.
  ///
  /// In en, this message translates to:
  /// **'Run'**
  String get runSnippet;

  /// No description provided for @snippetText.
  ///
  /// In en, this message translates to:
  /// **'Command text'**
  String get snippetText;

  /// No description provided for @snippetUnavailable.
  ///
  /// In en, this message translates to:
  /// **'The target terminal is unavailable. Nothing was sent.'**
  String get snippetUnavailable;

  /// No description provided for @snippetInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a name and command of at most 64 KiB.'**
  String get snippetInvalid;

  /// No description provided for @snippetSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save the snippet.'**
  String get snippetSaveFailed;

  /// No description provided for @importKnownHosts.
  ///
  /// In en, this message translates to:
  /// **'Import known_hosts'**
  String get importKnownHosts;

  /// No description provided for @importAction.
  ///
  /// In en, this message translates to:
  /// **'Import'**
  String get importAction;

  /// No description provided for @knownHostsNew.
  ///
  /// In en, this message translates to:
  /// **'New keys'**
  String get knownHostsNew;

  /// No description provided for @knownHostsTrusted.
  ///
  /// In en, this message translates to:
  /// **'Already trusted'**
  String get knownHostsTrusted;

  /// No description provided for @knownHostsConflict.
  ///
  /// In en, this message translates to:
  /// **'Differs from saved key, left unchanged'**
  String get knownHostsConflict;

  /// No description provided for @knownHostsSkipped.
  ///
  /// In en, this message translates to:
  /// **'Not imported'**
  String get knownHostsSkipped;

  /// No description provided for @knownHostsSavedKey.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get knownHostsSavedKey;

  /// No description provided for @knownHostsFileKey.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get knownHostsFileKey;

  /// No description provided for @knownHostsMalformed.
  ///
  /// In en, this message translates to:
  /// **'Unreadable line'**
  String get knownHostsMalformed;

  /// No description provided for @knownHostsMarker.
  ///
  /// In en, this message translates to:
  /// **'Marker not supported'**
  String get knownHostsMarker;

  /// No description provided for @knownHostsWildcard.
  ///
  /// In en, this message translates to:
  /// **'Pattern not supported'**
  String get knownHostsWildcard;

  /// No description provided for @knownHostsNegation.
  ///
  /// In en, this message translates to:
  /// **'Negated pattern not supported'**
  String get knownHostsNegation;

  /// No description provided for @knownHostsKeyType.
  ///
  /// In en, this message translates to:
  /// **'Key type not supported'**
  String get knownHostsKeyType;

  /// No description provided for @knownHostsBadKey.
  ///
  /// In en, this message translates to:
  /// **'Key data invalid or does not match its type'**
  String get knownHostsBadKey;

  /// No description provided for @knownHostsHashed.
  ///
  /// In en, this message translates to:
  /// **'Hashed name matches no saved host'**
  String get knownHostsHashed;

  /// No description provided for @knownHostsFileConflict.
  ///
  /// In en, this message translates to:
  /// **'Conflicting keys within the file'**
  String get knownHostsFileConflict;

  /// No description provided for @knownHostsTooLarge.
  ///
  /// In en, this message translates to:
  /// **'File is larger than {mb} MB'**
  String knownHostsTooLarge(int mb);

  /// No description provided for @knownHostsUnreadable.
  ///
  /// In en, this message translates to:
  /// **'Could not read the file'**
  String get knownHostsUnreadable;

  /// No description provided for @knownHostsImported.
  ///
  /// In en, this message translates to:
  /// **'Imported {count} keys'**
  String knownHostsImported(int count);

  /// No description provided for @knownHostsSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save the trusted keys'**
  String get knownHostsSaveFailed;

  /// No description provided for @tsPaused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get tsPaused;

  /// No description provided for @tsPausing.
  ///
  /// In en, this message translates to:
  /// **'Pausing'**
  String get tsPausing;

  /// No description provided for @pause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get pause;

  /// No description provided for @resume.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get resume;

  /// No description provided for @pauseFolderUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Folders cannot be paused'**
  String get pauseFolderUnsupported;

  /// No description provided for @errSourceChanged.
  ///
  /// In en, this message translates to:
  /// **'The source changed, so the transfer cannot continue'**
  String get errSourceChanged;

  /// No description provided for @errPartInvalid.
  ///
  /// In en, this message translates to:
  /// **'The partial file is missing or no longer matches the source'**
  String get errPartInvalid;

  /// No description provided for @leftoverPart.
  ///
  /// In en, this message translates to:
  /// **'Could not remove the temporary file {path}'**
  String leftoverPart(String path);

  /// No description provided for @editCleanupFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not remove the local copy {path}'**
  String editCleanupFailed(String path);

  /// No description provided for @portForwarding.
  ///
  /// In en, this message translates to:
  /// **'Port forwarding'**
  String get portForwarding;

  /// No description provided for @fwHost.
  ///
  /// In en, this message translates to:
  /// **'Host'**
  String get fwHost;

  /// No description provided for @fwLocal.
  ///
  /// In en, this message translates to:
  /// **'Local'**
  String get fwLocal;

  /// No description provided for @fwRemote.
  ///
  /// In en, this message translates to:
  /// **'Remote'**
  String get fwRemote;

  /// No description provided for @fwDynamic.
  ///
  /// In en, this message translates to:
  /// **'Dynamic (SOCKS5)'**
  String get fwDynamic;

  /// No description provided for @fwListen.
  ///
  /// In en, this message translates to:
  /// **'Listen'**
  String get fwListen;

  /// No description provided for @fwDestination.
  ///
  /// In en, this message translates to:
  /// **'Destination'**
  String get fwDestination;

  /// No description provided for @fwExposed.
  ///
  /// In en, this message translates to:
  /// **'Exposed'**
  String get fwExposed;

  /// No description provided for @fwAutoStart.
  ///
  /// In en, this message translates to:
  /// **'Start with the app'**
  String get fwAutoStart;

  /// No description provided for @fwStart.
  ///
  /// In en, this message translates to:
  /// **'Start forward'**
  String get fwStart;

  /// No description provided for @fwExposeConfirm.
  ///
  /// In en, this message translates to:
  /// **'Listening on {endpoint} lets other machines use this forward. Continue?'**
  String fwExposeConfirm(String endpoint);

  /// No description provided for @fwExposeAllow.
  ///
  /// In en, this message translates to:
  /// **'Allow'**
  String get fwExposeAllow;

  /// No description provided for @fwInvalid.
  ///
  /// In en, this message translates to:
  /// **'Check the addresses and ports'**
  String get fwInvalid;

  /// No description provided for @fwSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save'**
  String get fwSaveFailed;

  /// No description provided for @fwBusy.
  ///
  /// In en, this message translates to:
  /// **'Stop the forward first'**
  String get fwBusy;

  /// No description provided for @fwNoHosts.
  ///
  /// In en, this message translates to:
  /// **'Add a host first'**
  String get fwNoHosts;

  /// No description provided for @fwErrInUse.
  ///
  /// In en, this message translates to:
  /// **'Port already in use'**
  String get fwErrInUse;

  /// No description provided for @fwErrPermission.
  ///
  /// In en, this message translates to:
  /// **'Permission denied for this port'**
  String get fwErrPermission;

  /// No description provided for @fwErrAddress.
  ///
  /// In en, this message translates to:
  /// **'Address not available here'**
  String get fwErrAddress;

  /// No description provided for @fwErrRefused.
  ///
  /// In en, this message translates to:
  /// **'The server refused the forward'**
  String get fwErrRefused;

  /// No description provided for @fwErrHost.
  ///
  /// In en, this message translates to:
  /// **'The host no longer exists'**
  String get fwErrHost;

  /// No description provided for @fwErrLost.
  ///
  /// In en, this message translates to:
  /// **'Connection lost'**
  String get fwErrLost;

  /// No description provided for @fwErrStop.
  ///
  /// In en, this message translates to:
  /// **'Could not confirm the port was released; the connection is kept'**
  String get fwErrStop;

  /// No description provided for @fwErrTarget.
  ///
  /// In en, this message translates to:
  /// **'Cannot reach the destination'**
  String get fwErrTarget;

  /// No description provided for @fwErrTimeout.
  ///
  /// In en, this message translates to:
  /// **'Timed out'**
  String get fwErrTimeout;

  /// No description provided for @fwErrSocks.
  ///
  /// In en, this message translates to:
  /// **'Invalid SOCKS5 request'**
  String get fwErrSocks;

  /// No description provided for @fwErrLimit.
  ///
  /// In en, this message translates to:
  /// **'Too many connections'**
  String get fwErrLimit;

  /// No description provided for @forwardsRunning.
  ///
  /// In en, this message translates to:
  /// **'{count} forwards running'**
  String forwardsRunning(int count);

  /// No description provided for @quitFailed.
  ///
  /// In en, this message translates to:
  /// **'Some changes could not be saved or work could not be stopped. Retry or return to the app. Quitting anyway may lose unsaved changes; local edit copies will be kept.'**
  String get quitFailed;

  /// No description provided for @returnToApp.
  ///
  /// In en, this message translates to:
  /// **'Return to app'**
  String get returnToApp;

  /// No description provided for @quitAnyway.
  ///
  /// In en, this message translates to:
  /// **'Quit anyway'**
  String get quitAnyway;

  /// No description provided for @configUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Could not safely open {name}'**
  String configUnavailable(String name);

  /// No description provided for @configPreserved.
  ///
  /// In en, this message translates to:
  /// **'The file has been kept. Check or restore it in the data folder, then retry.'**
  String get configPreserved;

  /// No description provided for @openDataFolder.
  ///
  /// In en, this message translates to:
  /// **'Open data folder'**
  String get openDataFolder;

  /// No description provided for @windowMinimize.
  ///
  /// In en, this message translates to:
  /// **'Minimize'**
  String get windowMinimize;

  /// No description provided for @windowMaximize.
  ///
  /// In en, this message translates to:
  /// **'Maximize'**
  String get windowMaximize;

  /// No description provided for @windowRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get windowRestore;

  /// No description provided for @windowClose.
  ///
  /// In en, this message translates to:
  /// **'Close window'**
  String get windowClose;

  /// No description provided for @sshConfigExisting.
  ///
  /// In en, this message translates to:
  /// **'Already saved'**
  String get sshConfigExisting;

  /// No description provided for @sshConfigBlocked.
  ///
  /// In en, this message translates to:
  /// **'Cannot import'**
  String get sshConfigBlocked;

  /// No description provided for @sshConfigImported.
  ///
  /// In en, this message translates to:
  /// **'Imported {count} hosts'**
  String sshConfigImported(int count);

  /// No description provided for @sshConfigMalformed.
  ///
  /// In en, this message translates to:
  /// **'Invalid syntax'**
  String get sshConfigMalformed;

  /// No description provided for @sshConfigUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Unsupported option'**
  String get sshConfigUnsupported;

  /// No description provided for @sshConfigMatch.
  ///
  /// In en, this message translates to:
  /// **'Match block skipped'**
  String get sshConfigMatch;

  /// No description provided for @sshConfigPattern.
  ///
  /// In en, this message translates to:
  /// **'Host pattern provides defaults only'**
  String get sshConfigPattern;

  /// No description provided for @sshConfigIncludeOutside.
  ///
  /// In en, this message translates to:
  /// **'Include is outside the selected folder'**
  String get sshConfigIncludeOutside;

  /// No description provided for @sshConfigIncludeLimit.
  ///
  /// In en, this message translates to:
  /// **'Include file, depth or size limit reached'**
  String get sshConfigIncludeLimit;

  /// No description provided for @sshConfigIncludeMissing.
  ///
  /// In en, this message translates to:
  /// **'Included file could not be read'**
  String get sshConfigIncludeMissing;

  /// No description provided for @sshConfigIncludeCycle.
  ///
  /// In en, this message translates to:
  /// **'Include cycle'**
  String get sshConfigIncludeCycle;

  /// No description provided for @sshConfigIncomplete.
  ///
  /// In en, this message translates to:
  /// **'Config was not fully read'**
  String get sshConfigIncomplete;

  /// No description provided for @sshConfigProxyCommand.
  ///
  /// In en, this message translates to:
  /// **'ProxyCommand requires manual setup'**
  String get sshConfigProxyCommand;

  /// No description provided for @sshConfigInvalid.
  ///
  /// In en, this message translates to:
  /// **'Invalid host settings'**
  String get sshConfigInvalid;

  /// No description provided for @sshConfigJump.
  ///
  /// In en, this message translates to:
  /// **'Jump host could not be resolved'**
  String get sshConfigJump;

  /// No description provided for @sshConfigJumpCycle.
  ///
  /// In en, this message translates to:
  /// **'Jump chain is cyclic or too long'**
  String get sshConfigJumpCycle;

  /// No description provided for @sshConfigAmbiguous.
  ///
  /// In en, this message translates to:
  /// **'Multiple saved hosts match'**
  String get sshConfigAmbiguous;

  /// No description provided for @sshConfigIdentity.
  ///
  /// In en, this message translates to:
  /// **'Private key path could not be resolved'**
  String get sshConfigIdentity;

  /// No description provided for @sshConfigExtraIdentity.
  ///
  /// In en, this message translates to:
  /// **'Only the first IdentityFile is supported'**
  String get sshConfigExtraIdentity;

  /// No description provided for @sshConfigHostLimit.
  ///
  /// In en, this message translates to:
  /// **'Too many hosts in the config'**
  String get sshConfigHostLimit;

  /// No description provided for @retryAction.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retryAction;

  /// No description provided for @resizeToolPanel.
  ///
  /// In en, this message translates to:
  /// **'Resize tool panel'**
  String get resizeToolPanel;

  /// No description provided for @resizeNavigation.
  ///
  /// In en, this message translates to:
  /// **'Resize navigation'**
  String get resizeNavigation;

  /// No description provided for @resizeMonitor.
  ///
  /// In en, this message translates to:
  /// **'Resize monitor'**
  String get resizeMonitor;

  /// No description provided for @configRestoreSnapshots.
  ///
  /// In en, this message translates to:
  /// **'Restore a snapshot'**
  String get configRestoreSnapshots;

  /// No description provided for @configNoSnapshots.
  ///
  /// In en, this message translates to:
  /// **'No valid snapshots'**
  String get configNoSnapshots;

  /// No description provided for @configRestore.
  ///
  /// In en, this message translates to:
  /// **'Restore'**
  String get configRestore;

  /// No description provided for @configRestoreFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not restore the snapshot. The current file was preserved.'**
  String get configRestoreFailed;

  /// No description provided for @configSnapshotRevision.
  ///
  /// In en, this message translates to:
  /// **'Revision {revision}'**
  String configSnapshotRevision(int revision);

  /// No description provided for @inheritedFrom.
  ///
  /// In en, this message translates to:
  /// **'Inherited from {source}'**
  String inheritedFrom(String source);

  /// No description provided for @useInherited.
  ///
  /// In en, this message translates to:
  /// **'Use the value from {source}'**
  String useInherited(String source);

  /// No description provided for @inheritBuiltIn.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get inheritBuiltIn;

  /// No description provided for @globalDefaults.
  ///
  /// In en, this message translates to:
  /// **'Global defaults'**
  String get globalDefaults;

  /// No description provided for @identities.
  ///
  /// In en, this message translates to:
  /// **'Identities'**
  String get identities;

  /// No description provided for @identity.
  ///
  /// In en, this message translates to:
  /// **'Identity'**
  String get identity;

  /// No description provided for @customLogin.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get customLogin;

  /// No description provided for @newIdentity.
  ///
  /// In en, this message translates to:
  /// **'New identity'**
  String get newIdentity;

  /// No description provided for @keyThenPassword.
  ///
  /// In en, this message translates to:
  /// **'Key, then password'**
  String get keyThenPassword;

  /// No description provided for @allowInteractive.
  ///
  /// In en, this message translates to:
  /// **'Keyboard-interactive'**
  String get allowInteractive;

  /// No description provided for @newGroup.
  ///
  /// In en, this message translates to:
  /// **'New group'**
  String get newGroup;

  /// No description provided for @editGroup.
  ///
  /// In en, this message translates to:
  /// **'Edit group'**
  String get editGroup;

  /// No description provided for @dissolveGroupConfirm.
  ///
  /// In en, this message translates to:
  /// **'Dissolve {name}? Its hosts move up a level and its default settings are discarded.'**
  String dissolveGroupConfirm(String name);

  /// No description provided for @errGroupInvalid.
  ///
  /// In en, this message translates to:
  /// **'That group path is taken or invalid.'**
  String get errGroupInvalid;

  /// No description provided for @deleteIdentity.
  ///
  /// In en, this message translates to:
  /// **'Delete identity {name}?'**
  String deleteIdentity(String name);

  /// No description provided for @errSave.
  ///
  /// In en, this message translates to:
  /// **'Could not save. Check access to the data directory and secure storage.'**
  String get errSave;

  /// No description provided for @monitor.
  ///
  /// In en, this message translates to:
  /// **'Server monitor'**
  String get monitor;

  /// No description provided for @cpu.
  ///
  /// In en, this message translates to:
  /// **'CPU'**
  String get cpu;

  /// No description provided for @gpu.
  ///
  /// In en, this message translates to:
  /// **'GPU'**
  String get gpu;

  /// No description provided for @memory.
  ///
  /// In en, this message translates to:
  /// **'Memory'**
  String get memory;

  /// No description provided for @swap.
  ///
  /// In en, this message translates to:
  /// **'Swap'**
  String get swap;

  /// No description provided for @network.
  ///
  /// In en, this message translates to:
  /// **'Network'**
  String get network;

  /// No description provided for @disks.
  ///
  /// In en, this message translates to:
  /// **'Disks'**
  String get disks;

  /// No description provided for @load.
  ///
  /// In en, this message translates to:
  /// **'Load'**
  String get load;

  /// No description provided for @uptime.
  ///
  /// In en, this message translates to:
  /// **'Up'**
  String get uptime;

  /// No description provided for @cores.
  ///
  /// In en, this message translates to:
  /// **'{count} cores'**
  String cores(int count);

  /// No description provided for @uptimeDays.
  ///
  /// In en, this message translates to:
  /// **'{days}d {hours}h'**
  String uptimeDays(int days, int hours);

  /// No description provided for @uptimeHours.
  ///
  /// In en, this message translates to:
  /// **'{hours}h {minutes}m'**
  String uptimeHours(int hours, int minutes);

  /// No description provided for @monitorUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This server has no /proc, so there is nothing to show'**
  String get monitorUnsupported;

  /// No description provided for @monitorFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not read stats; retrying'**
  String get monitorFailed;

  /// No description provided for @monitorOffline.
  ///
  /// In en, this message translates to:
  /// **'Shown once connected'**
  String get monitorOffline;

  /// No description provided for @uiFont.
  ///
  /// In en, this message translates to:
  /// **'Interface font'**
  String get uiFont;

  /// No description provided for @uiFontSize.
  ///
  /// In en, this message translates to:
  /// **'Interface font size'**
  String get uiFontSize;

  /// No description provided for @terminalFont.
  ///
  /// In en, this message translates to:
  /// **'Terminal font'**
  String get terminalFont;

  /// No description provided for @defaultFont.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get defaultFont;

  /// No description provided for @searchFonts.
  ///
  /// In en, this message translates to:
  /// **'Search fonts'**
  String get searchFonts;

  /// No description provided for @workspaceSection.
  ///
  /// In en, this message translates to:
  /// **'Workspace'**
  String get workspaceSection;

  /// No description provided for @filesDock.
  ///
  /// In en, this message translates to:
  /// **'Files panel'**
  String get filesDock;

  /// No description provided for @dockLeft.
  ///
  /// In en, this message translates to:
  /// **'Left'**
  String get dockLeft;

  /// No description provided for @dockRight.
  ///
  /// In en, this message translates to:
  /// **'Right'**
  String get dockRight;

  /// No description provided for @dockBottom.
  ///
  /// In en, this message translates to:
  /// **'Bottom'**
  String get dockBottom;

  /// No description provided for @dockPosition.
  ///
  /// In en, this message translates to:
  /// **'Dock position'**
  String get dockPosition;

  /// No description provided for @confirmQuit.
  ///
  /// In en, this message translates to:
  /// **'Confirm before quitting'**
  String get confirmQuit;

  /// No description provided for @quitTitle.
  ///
  /// In en, this message translates to:
  /// **'Quit sshairy?'**
  String get quitTitle;

  /// No description provided for @sessionsOpen.
  ///
  /// In en, this message translates to:
  /// **'{count} sessions will be disconnected'**
  String sessionsOpen(int count);

  /// No description provided for @monitorInterval.
  ///
  /// In en, this message translates to:
  /// **'Refresh interval'**
  String get monitorInterval;

  /// No description provided for @copyAddress.
  ///
  /// In en, this message translates to:
  /// **'Copy address'**
  String get copyAddress;

  /// No description provided for @monitorSystem.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get monitorSystem;

  /// No description provided for @processes.
  ///
  /// In en, this message translates to:
  /// **'Processes'**
  String get processes;

  /// No description provided for @showAllProcesses.
  ///
  /// In en, this message translates to:
  /// **'Show all processes'**
  String get showAllProcesses;

  /// No description provided for @allInterfaces.
  ///
  /// In en, this message translates to:
  /// **'All interfaces'**
  String get allInterfaces;

  /// No description provided for @diskFree.
  ///
  /// In en, this message translates to:
  /// **'Free / size'**
  String get diskFree;

  /// No description provided for @processUser.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get processUser;

  /// No description provided for @processResident.
  ///
  /// In en, this message translates to:
  /// **'Resident'**
  String get processResident;

  /// No description provided for @processState.
  ///
  /// In en, this message translates to:
  /// **'State'**
  String get processState;

  /// No description provided for @processThreads.
  ///
  /// In en, this message translates to:
  /// **'Threads'**
  String get processThreads;

  /// No description provided for @processElapsed.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get processElapsed;

  /// No description provided for @processCommand.
  ///
  /// In en, this message translates to:
  /// **'Command'**
  String get processCommand;

  /// No description provided for @searchProcesses.
  ///
  /// In en, this message translates to:
  /// **'Search processes'**
  String get searchProcesses;

  /// No description provided for @copyPid.
  ///
  /// In en, this message translates to:
  /// **'Copy PID'**
  String get copyPid;

  /// No description provided for @copyCommand.
  ///
  /// In en, this message translates to:
  /// **'Copy command'**
  String get copyCommand;

  /// No description provided for @terminateProcess.
  ///
  /// In en, this message translates to:
  /// **'End process'**
  String get terminateProcess;

  /// No description provided for @killProcess.
  ///
  /// In en, this message translates to:
  /// **'Force end'**
  String get killProcess;

  /// No description provided for @terminateConfirm.
  ///
  /// In en, this message translates to:
  /// **'End {name} (PID {pid})?'**
  String terminateConfirm(String name, int pid);

  /// No description provided for @killConfirm.
  ///
  /// In en, this message translates to:
  /// **'Force {name} (PID {pid}) to end? It gets no chance to save its work.'**
  String killConfirm(String name, int pid);

  /// No description provided for @signalFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not end the process: {detail}'**
  String signalFailed(String detail);

  /// No description provided for @tasks.
  ///
  /// In en, this message translates to:
  /// **'{count} tasks'**
  String tasks(int count);

  /// No description provided for @gpuTemperature.
  ///
  /// In en, this message translates to:
  /// **'Temperature'**
  String get gpuTemperature;

  /// No description provided for @gpuPower.
  ///
  /// In en, this message translates to:
  /// **'Power / limit'**
  String get gpuPower;

  /// No description provided for @gpuFan.
  ///
  /// In en, this message translates to:
  /// **'Fan'**
  String get gpuFan;

  /// No description provided for @gpuCoreClock.
  ///
  /// In en, this message translates to:
  /// **'Core clock'**
  String get gpuCoreClock;

  /// No description provided for @gpuMemoryClock.
  ///
  /// In en, this message translates to:
  /// **'Memory clock'**
  String get gpuMemoryClock;

  /// No description provided for @gpuMemory.
  ///
  /// In en, this message translates to:
  /// **'VRAM'**
  String get gpuMemory;

  /// No description provided for @importHosts.
  ///
  /// In en, this message translates to:
  /// **'Import hosts'**
  String get importHosts;

  /// No description provided for @importFromFile.
  ///
  /// In en, this message translates to:
  /// **'From file'**
  String get importFromFile;

  /// No description provided for @importNoGroup.
  ///
  /// In en, this message translates to:
  /// **'No group'**
  String get importNoGroup;

  /// No description provided for @importChanged.
  ///
  /// In en, this message translates to:
  /// **'Hosts changed; open the source again'**
  String get importChanged;

  /// No description provided for @importFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not read the hosts'**
  String get importFailed;

  /// No description provided for @importNotSsh.
  ///
  /// In en, this message translates to:
  /// **'Not an SSH session'**
  String get importNotSsh;

  /// No description provided for @importNoAddress.
  ///
  /// In en, this message translates to:
  /// **'No address'**
  String get importNoAddress;

  /// No description provided for @importUnreadable.
  ///
  /// In en, this message translates to:
  /// **'Could not read this file'**
  String get importUnreadable;

  /// No description provided for @importPpk.
  ///
  /// In en, this message translates to:
  /// **'PuTTY .ppk key not used; convert it to OpenSSH format first'**
  String get importPpk;

  /// No description provided for @proxies.
  ///
  /// In en, this message translates to:
  /// **'Proxies'**
  String get proxies;

  /// No description provided for @proxySearch.
  ///
  /// In en, this message translates to:
  /// **'Search hosts, groups or proxies'**
  String get proxySearch;

  /// No description provided for @proxyInherit.
  ///
  /// In en, this message translates to:
  /// **'Inherit'**
  String get proxyInherit;

  /// No description provided for @proxyConfiguredHere.
  ///
  /// In en, this message translates to:
  /// **'Configured here'**
  String get proxyConfiguredHere;

  /// No description provided for @proxyVia.
  ///
  /// In en, this message translates to:
  /// **'Via jump host'**
  String get proxyVia;

  /// No description provided for @proxyEditHop.
  ///
  /// In en, this message translates to:
  /// **'Edit the jump host proxy'**
  String get proxyEditHop;

  /// No description provided for @proxyNextConnection.
  ///
  /// In en, this message translates to:
  /// **'Changes apply to the next connection.'**
  String get proxyNextConnection;

  /// No description provided for @proxyInvalid.
  ///
  /// In en, this message translates to:
  /// **'Check the proxy address, port and username.'**
  String get proxyInvalid;

  /// No description provided for @proxyChanged.
  ///
  /// In en, this message translates to:
  /// **'Configuration changed. Reopen this editor and try again.'**
  String get proxyChanged;

  /// No description provided for @proxyCleanupFailed.
  ///
  /// In en, this message translates to:
  /// **'The proxy configuration is saved, but old saved credentials could not be fully removed.'**
  String get proxyCleanupFailed;

  /// No description provided for @logs.
  ///
  /// In en, this message translates to:
  /// **'Logs'**
  String get logs;

  /// No description provided for @logArea.
  ///
  /// In en, this message translates to:
  /// **'Area'**
  String get logArea;

  /// No description provided for @logOutcome.
  ///
  /// In en, this message translates to:
  /// **'Result'**
  String get logOutcome;

  /// No description provided for @logAllAreas.
  ///
  /// In en, this message translates to:
  /// **'All areas'**
  String get logAllAreas;

  /// No description provided for @logAllOutcomes.
  ///
  /// In en, this message translates to:
  /// **'All results'**
  String get logAllOutcomes;

  /// No description provided for @logCopyRecord.
  ///
  /// In en, this message translates to:
  /// **'Copy selected record'**
  String get logCopyRecord;

  /// No description provided for @logEmpty.
  ///
  /// In en, this message translates to:
  /// **'No records'**
  String get logEmpty;

  /// No description provided for @logDisabled.
  ///
  /// In en, this message translates to:
  /// **'Diagnostic recording is off.'**
  String get logDisabled;

  /// No description provided for @logWriterFailed.
  ///
  /// In en, this message translates to:
  /// **'Diagnostic recording stopped after a write failure.'**
  String get logWriterFailed;

  /// No description provided for @logReadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not read diagnostic records. Refresh to retry.'**
  String get logReadFailed;

  /// No description provided for @logSkipped.
  ///
  /// In en, this message translates to:
  /// **'Skipped {count} invalid records.'**
  String logSkipped(int count);

  /// No description provided for @logDropped.
  ///
  /// In en, this message translates to:
  /// **'Dropped {count} queued records.'**
  String logDropped(int count);

  /// No description provided for @logElapsed.
  ///
  /// In en, this message translates to:
  /// **'{milliseconds} ms'**
  String logElapsed(int milliseconds);

  /// No description provided for @logAreaApplication.
  ///
  /// In en, this message translates to:
  /// **'Application'**
  String get logAreaApplication;

  /// No description provided for @logAreaConnection.
  ///
  /// In en, this message translates to:
  /// **'Connection'**
  String get logAreaConnection;

  /// No description provided for @logAreaTransfer.
  ///
  /// In en, this message translates to:
  /// **'Transfer'**
  String get logAreaTransfer;

  /// No description provided for @logAreaConfiguration.
  ///
  /// In en, this message translates to:
  /// **'Configuration'**
  String get logAreaConfiguration;

  /// No description provided for @logOutcomeStarted.
  ///
  /// In en, this message translates to:
  /// **'Started'**
  String get logOutcomeStarted;

  /// No description provided for @logOutcomeSucceeded.
  ///
  /// In en, this message translates to:
  /// **'Succeeded'**
  String get logOutcomeSucceeded;

  /// No description provided for @logOutcomeFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed'**
  String get logOutcomeFailed;

  /// No description provided for @logOutcomeCancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get logOutcomeCancelled;

  /// No description provided for @logOutcomeInterrupted.
  ///
  /// In en, this message translates to:
  /// **'Interrupted'**
  String get logOutcomeInterrupted;

  /// No description provided for @logActionStart.
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get logActionStart;

  /// No description provided for @logActionDial.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get logActionDial;

  /// No description provided for @logActionCopy.
  ///
  /// In en, this message translates to:
  /// **'Transfer'**
  String get logActionCopy;

  /// No description provided for @logActionPause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get logActionPause;

  /// No description provided for @logActionCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get logActionCancel;

  /// No description provided for @logActionRead.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get logActionRead;

  /// No description provided for @logActionWrite.
  ///
  /// In en, this message translates to:
  /// **'Write'**
  String get logActionWrite;

  /// No description provided for @logActionRecover.
  ///
  /// In en, this message translates to:
  /// **'Recover'**
  String get logActionRecover;

  /// No description provided for @logActionUncaught.
  ///
  /// In en, this message translates to:
  /// **'Unhandled error'**
  String get logActionUncaught;

  /// No description provided for @logActionShutdown.
  ///
  /// In en, this message translates to:
  /// **'Shut down'**
  String get logActionShutdown;

  /// No description provided for @appBackgroundImage.
  ///
  /// In en, this message translates to:
  /// **'Interface background'**
  String get appBackgroundImage;

  /// No description provided for @terminalBackgroundImage.
  ///
  /// In en, this message translates to:
  /// **'Terminal background'**
  String get terminalBackgroundImage;

  /// No description provided for @backgroundChooseImage.
  ///
  /// In en, this message translates to:
  /// **'Choose image'**
  String get backgroundChooseImage;

  /// No description provided for @backgroundRestoreDefault.
  ///
  /// In en, this message translates to:
  /// **'Restore default background'**
  String get backgroundRestoreDefault;

  /// No description provided for @backgroundOpacity.
  ///
  /// In en, this message translates to:
  /// **'Image opacity'**
  String get backgroundOpacity;

  /// No description provided for @backgroundImageTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Image exceeds the size limit.'**
  String get backgroundImageTooLarge;

  /// No description provided for @backgroundImageUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Choose a static PNG or JPEG image.'**
  String get backgroundImageUnsupported;

  /// No description provided for @backgroundImageUnreadable.
  ///
  /// In en, this message translates to:
  /// **'Could not read the image.'**
  String get backgroundImageUnreadable;

  /// No description provided for @commandHistory.
  ///
  /// In en, this message translates to:
  /// **'Command history'**
  String get commandHistory;

  /// No description provided for @commandHistoryEmpty.
  ///
  /// In en, this message translates to:
  /// **'No commands'**
  String get commandHistoryEmpty;

  /// No description provided for @commandHistoryInsert.
  ///
  /// In en, this message translates to:
  /// **'Insert command'**
  String get commandHistoryInsert;

  /// No description provided for @commandHistoryClear.
  ///
  /// In en, this message translates to:
  /// **'Clear history'**
  String get commandHistoryClear;
  /// No description provided for @cmdToolCompose.
  ///
  /// In en, this message translates to:
  /// **'Multi-container apps'**
  String get cmdToolCompose;

  /// No description provided for @cmdToolTmux.
  ///
  /// In en, this message translates to:
  /// **'Terminal multiplexer'**
  String get cmdToolTmux;

  /// No description provided for @cmdToolScreen.
  ///
  /// In en, this message translates to:
  /// **'Terminal multiplexer'**
  String get cmdToolScreen;

  /// No description provided for @cmdToolSystemctl.
  ///
  /// In en, this message translates to:
  /// **'Manage services'**
  String get cmdToolSystemctl;

  /// No description provided for @cmdToolJournalctl.
  ///
  /// In en, this message translates to:
  /// **'View system logs'**
  String get cmdToolJournalctl;

  /// No description provided for @cmdToolRsync.
  ///
  /// In en, this message translates to:
  /// **'Sync files'**
  String get cmdToolRsync;

  /// No description provided for @cmdToolLsof.
  ///
  /// In en, this message translates to:
  /// **'List open files'**
  String get cmdToolLsof;

  /// No description provided for @cmdToolSs.
  ///
  /// In en, this message translates to:
  /// **'Show sockets'**
  String get cmdToolSs;

  /// No description provided for @cmdToolJq.
  ///
  /// In en, this message translates to:
  /// **'Process JSON'**
  String get cmdToolJq;

  /// No description provided for @cmdToolTcpdump.
  ///
  /// In en, this message translates to:
  /// **'Capture packets'**
  String get cmdToolTcpdump;

  /// No description provided for @cmdToolCrontab.
  ///
  /// In en, this message translates to:
  /// **'Scheduled jobs'**
  String get cmdToolCrontab;

  /// No description provided for @cmdToolWatch.
  ///
  /// In en, this message translates to:
  /// **'Repeat a command'**
  String get cmdToolWatch;

  /// No description provided for @cmdToolHelm.
  ///
  /// In en, this message translates to:
  /// **'Kubernetes packages'**
  String get cmdToolHelm;

  /// No description provided for @cmdQuiet.
  ///
  /// In en, this message translates to:
  /// **'Quiet output'**
  String get cmdQuiet;

  /// No description provided for @cmdRecursive.
  ///
  /// In en, this message translates to:
  /// **'Include subdirectories'**
  String get cmdRecursive;

  /// No description provided for @cmdForce.
  ///
  /// In en, this message translates to:
  /// **'Force'**
  String get cmdForce;

  /// No description provided for @cmdAll.
  ///
  /// In en, this message translates to:
  /// **'Include all'**
  String get cmdAll;

  /// No description provided for @cmdHuman.
  ///
  /// In en, this message translates to:
  /// **'Human-readable'**
  String get cmdHuman;

  /// No description provided for @cmdFollow.
  ///
  /// In en, this message translates to:
  /// **'Follow new output'**
  String get cmdFollow;

  /// No description provided for @cmdLines.
  ///
  /// In en, this message translates to:
  /// **'Number of lines'**
  String get cmdLines;

  /// No description provided for @cmdTail.
  ///
  /// In en, this message translates to:
  /// **'Last N lines'**
  String get cmdTail;

  /// No description provided for @cmdSince.
  ///
  /// In en, this message translates to:
  /// **'Since a time'**
  String get cmdSince;

  /// No description provided for @cmdBackground.
  ///
  /// In en, this message translates to:
  /// **'Run in background'**
  String get cmdBackground;

  /// No description provided for @cmdLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get cmdLabel;

  /// No description provided for @cmdPort.
  ///
  /// In en, this message translates to:
  /// **'Port'**
  String get cmdPort;

  /// No description provided for @cmdIdentity.
  ///
  /// In en, this message translates to:
  /// **'Identity file'**
  String get cmdIdentity;

  /// No description provided for @cmdJumpHost.
  ///
  /// In en, this message translates to:
  /// **'Jump host'**
  String get cmdJumpHost;

  /// No description provided for @cmdFile.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get cmdFile;

  /// No description provided for @cmdDirectory.
  ///
  /// In en, this message translates to:
  /// **'Directory'**
  String get cmdDirectory;

  /// No description provided for @cmdOutputFile.
  ///
  /// In en, this message translates to:
  /// **'Write to file'**
  String get cmdOutputFile;

  /// No description provided for @cmdDryRun.
  ///
  /// In en, this message translates to:
  /// **'Preview only'**
  String get cmdDryRun;

  /// No description provided for @cmdAssumeYes.
  ///
  /// In en, this message translates to:
  /// **'Answer yes'**
  String get cmdAssumeYes;

  /// No description provided for @cmdNamespace.
  ///
  /// In en, this message translates to:
  /// **'Namespace'**
  String get cmdNamespace;

  /// No description provided for @cmdTarget.
  ///
  /// In en, this message translates to:
  /// **'Target'**
  String get cmdTarget;

  /// No description provided for @cmdUser.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get cmdUser;

  /// No description provided for @cmdReverse.
  ///
  /// In en, this message translates to:
  /// **'Reverse order'**
  String get cmdReverse;

  /// No description provided for @cmdIgnoreCase.
  ///
  /// In en, this message translates to:
  /// **'Ignore case'**
  String get cmdIgnoreCase;

  /// No description provided for @cmdConfirm.
  ///
  /// In en, this message translates to:
  /// **'Ask first'**
  String get cmdConfirm;

  /// No description provided for @cmdRunInside.
  ///
  /// In en, this message translates to:
  /// **'Run a command inside'**
  String get cmdRunInside;

  /// No description provided for @cmdUpgrade.
  ///
  /// In en, this message translates to:
  /// **'Upgrade packages'**
  String get cmdUpgrade;

  /// No description provided for @cmdRefreshIndex.
  ///
  /// In en, this message translates to:
  /// **'Refresh package index'**
  String get cmdRefreshIndex;

  /// No description provided for @cmdLongList.
  ///
  /// In en, this message translates to:
  /// **'Detailed list'**
  String get cmdLongList;

  /// No description provided for @cmdParents.
  ///
  /// In en, this message translates to:
  /// **'Create parent directories'**
  String get cmdParents;

  /// No description provided for @cmdArchive.
  ///
  /// In en, this message translates to:
  /// **'Archive mode'**
  String get cmdArchive;

  /// No description provided for @cmdInvert.
  ///
  /// In en, this message translates to:
  /// **'Invert match'**
  String get cmdInvert;

  /// No description provided for @cmdFilesOnly.
  ///
  /// In en, this message translates to:
  /// **'Only file names'**
  String get cmdFilesOnly;

  /// No description provided for @cmdExtendedRegex.
  ///
  /// In en, this message translates to:
  /// **'Extended regex'**
  String get cmdExtendedRegex;

  /// No description provided for @cmdMaxDepth.
  ///
  /// In en, this message translates to:
  /// **'Maximum depth'**
  String get cmdMaxDepth;

  /// No description provided for @cmdMakeExecutable.
  ///
  /// In en, this message translates to:
  /// **'Make executable'**
  String get cmdMakeExecutable;

  /// No description provided for @cmdInPlace.
  ///
  /// In en, this message translates to:
  /// **'Edit file in place'**
  String get cmdInPlace;

  /// No description provided for @cmdExtract.
  ///
  /// In en, this message translates to:
  /// **'Extract'**
  String get cmdExtract;

  /// No description provided for @cmdCreateArchive.
  ///
  /// In en, this message translates to:
  /// **'Create archive'**
  String get cmdCreateArchive;

  /// No description provided for @cmdListArchive.
  ///
  /// In en, this message translates to:
  /// **'List contents'**
  String get cmdListArchive;

  /// No description provided for @cmdAllProcesses.
  ///
  /// In en, this message translates to:
  /// **'All processes'**
  String get cmdAllProcesses;

  /// No description provided for @cmdForceKill.
  ///
  /// In en, this message translates to:
  /// **'Force kill'**
  String get cmdForceKill;

  /// No description provided for @cmdLocalForward.
  ///
  /// In en, this message translates to:
  /// **'Forward a local port'**
  String get cmdLocalForward;

  /// No description provided for @cmdRemoteForward.
  ///
  /// In en, this message translates to:
  /// **'Forward a remote port'**
  String get cmdRemoteForward;

  /// No description provided for @cmdDynamicForward.
  ///
  /// In en, this message translates to:
  /// **'SOCKS proxy'**
  String get cmdDynamicForward;

  /// No description provided for @cmdNoCommand.
  ///
  /// In en, this message translates to:
  /// **'No remote command'**
  String get cmdNoCommand;

  /// No description provided for @cmdFollowRedirects.
  ///
  /// In en, this message translates to:
  /// **'Follow redirects'**
  String get cmdFollowRedirects;

  /// No description provided for @cmdHeadersOnly.
  ///
  /// In en, this message translates to:
  /// **'Headers only'**
  String get cmdHeadersOnly;

  /// No description provided for @cmdMethod.
  ///
  /// In en, this message translates to:
  /// **'Request method'**
  String get cmdMethod;

  /// No description provided for @cmdListening.
  ///
  /// In en, this message translates to:
  /// **'Listening sockets'**
  String get cmdListening;

  /// No description provided for @cmdKeyType.
  ///
  /// In en, this message translates to:
  /// **'Key type'**
  String get cmdKeyType;

  /// No description provided for @cmdFingerprint.
  ///
  /// In en, this message translates to:
  /// **'Show fingerprint'**
  String get cmdFingerprint;

  /// No description provided for @cmdRemoveKnownHost.
  ///
  /// In en, this message translates to:
  /// **'Remove a known host'**
  String get cmdRemoveKnownHost;

  /// No description provided for @cmdProgressPartial.
  ///
  /// In en, this message translates to:
  /// **'Show progress, resumable'**
  String get cmdProgressPartial;

  /// No description provided for @cmdUnit.
  ///
  /// In en, this message translates to:
  /// **'Unit name'**
  String get cmdUnit;

  /// No description provided for @cmdJumpEnd.
  ///
  /// In en, this message translates to:
  /// **'Jump to the end'**
  String get cmdJumpEnd;

  /// No description provided for @cmdThisBoot.
  ///
  /// In en, this message translates to:
  /// **'Since this boot'**
  String get cmdThisBoot;

  /// No description provided for @cmdPriority.
  ///
  /// In en, this message translates to:
  /// **'Priority level'**
  String get cmdPriority;

  /// No description provided for @cmdDaemonReload.
  ///
  /// In en, this message translates to:
  /// **'Reload unit files'**
  String get cmdDaemonReload;

  /// No description provided for @cmdIsActive.
  ///
  /// In en, this message translates to:
  /// **'Is it running'**
  String get cmdIsActive;

  /// No description provided for @cmdUserScope.
  ///
  /// In en, this message translates to:
  /// **'User services'**
  String get cmdUserScope;

  /// No description provided for @cmdNow.
  ///
  /// In en, this message translates to:
  /// **'Also start or stop now'**
  String get cmdNow;

  /// No description provided for @cmdCommitAll.
  ///
  /// In en, this message translates to:
  /// **'Include tracked changes'**
  String get cmdCommitAll;

  /// No description provided for @cmdAmend.
  ///
  /// In en, this message translates to:
  /// **'Rewrite the last commit'**
  String get cmdAmend;

  /// No description provided for @cmdSetUpstream.
  ///
  /// In en, this message translates to:
  /// **'Set upstream branch'**
  String get cmdSetUpstream;

  /// No description provided for @cmdRebase.
  ///
  /// In en, this message translates to:
  /// **'Rebase instead of merge'**
  String get cmdRebase;

  /// No description provided for @cmdFastForwardOnly.
  ///
  /// In en, this message translates to:
  /// **'Fast-forward only'**
  String get cmdFastForwardOnly;

  /// No description provided for @cmdNewBranch.
  ///
  /// In en, this message translates to:
  /// **'Create a branch'**
  String get cmdNewBranch;

  /// No description provided for @cmdShowCurrent.
  ///
  /// In en, this message translates to:
  /// **'Show current branch'**
  String get cmdShowCurrent;

  /// No description provided for @cmdOneline.
  ///
  /// In en, this message translates to:
  /// **'One line per commit'**
  String get cmdOneline;

  /// No description provided for @cmdStaged.
  ///
  /// In en, this message translates to:
  /// **'Staged changes'**
  String get cmdStaged;

  /// No description provided for @cmdPrune.
  ///
  /// In en, this message translates to:
  /// **'Drop deleted remote branches'**
  String get cmdPrune;

  /// No description provided for @cmdNoFastForward.
  ///
  /// In en, this message translates to:
  /// **'Always make a merge commit'**
  String get cmdNoFastForward;

  /// No description provided for @cmdSquash.
  ///
  /// In en, this message translates to:
  /// **'Squash into one change'**
  String get cmdSquash;

  /// No description provided for @cmdContinueOp.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get cmdContinueOp;

  /// No description provided for @cmdStashPop.
  ///
  /// In en, this message translates to:
  /// **'Apply and drop latest'**
  String get cmdStashPop;

  /// No description provided for @cmdIncludeUntracked.
  ///
  /// In en, this message translates to:
  /// **'Include untracked files'**
  String get cmdIncludeUntracked;

  /// No description provided for @cmdRunContainer.
  ///
  /// In en, this message translates to:
  /// **'Run a new container'**
  String get cmdRunContainer;

  /// No description provided for @cmdRemoveOnExit.
  ///
  /// In en, this message translates to:
  /// **'Remove on exit'**
  String get cmdRemoveOnExit;

  /// No description provided for @cmdVolume.
  ///
  /// In en, this message translates to:
  /// **'Mount a volume'**
  String get cmdVolume;

  /// No description provided for @cmdEnv.
  ///
  /// In en, this message translates to:
  /// **'Environment variable'**
  String get cmdEnv;

  /// No description provided for @cmdRestartPolicy.
  ///
  /// In en, this message translates to:
  /// **'Restart policy'**
  String get cmdRestartPolicy;

  /// No description provided for @cmdComposeUp.
  ///
  /// In en, this message translates to:
  /// **'Create and start'**
  String get cmdComposeUp;

  /// No description provided for @cmdComposeDown.
  ///
  /// In en, this message translates to:
  /// **'Stop and remove'**
  String get cmdComposeDown;

  /// No description provided for @cmdAllNamespaces.
  ///
  /// In en, this message translates to:
  /// **'All namespaces'**
  String get cmdAllNamespaces;

  /// No description provided for @cmdSelector.
  ///
  /// In en, this message translates to:
  /// **'Label selector'**
  String get cmdSelector;

  /// No description provided for @cmdOutputFormat.
  ///
  /// In en, this message translates to:
  /// **'Output format'**
  String get cmdOutputFormat;

  /// No description provided for @cmdTmuxAttach.
  ///
  /// In en, this message translates to:
  /// **'Attach to a session'**
  String get cmdTmuxAttach;

  /// No description provided for @cmdTmuxNew.
  ///
  /// In en, this message translates to:
  /// **'Create a session'**
  String get cmdTmuxNew;

  /// No description provided for @cmdTmuxList.
  ///
  /// In en, this message translates to:
  /// **'List sessions'**
  String get cmdTmuxList;

  /// No description provided for @cmdTmuxKillSession.
  ///
  /// In en, this message translates to:
  /// **'End a session'**
  String get cmdTmuxKillSession;

  /// No description provided for @cmdTmuxKillServer.
  ///
  /// In en, this message translates to:
  /// **'End all tmux sessions'**
  String get cmdTmuxKillServer;

  /// No description provided for @cmdTmuxDetach.
  ///
  /// In en, this message translates to:
  /// **'Detach a client'**
  String get cmdTmuxDetach;

  /// No description provided for @cmdTmuxWindows.
  ///
  /// In en, this message translates to:
  /// **'List windows'**
  String get cmdTmuxWindows;

  /// No description provided for @cmdTmuxNewWindow.
  ///
  /// In en, this message translates to:
  /// **'Create a window'**
  String get cmdTmuxNewWindow;

  /// No description provided for @cmdTmuxSplit.
  ///
  /// In en, this message translates to:
  /// **'Split a pane'**
  String get cmdTmuxSplit;

  /// No description provided for @cmdTmuxRename.
  ///
  /// In en, this message translates to:
  /// **'Rename a session'**
  String get cmdTmuxRename;

  /// No description provided for @cmdTmuxHas.
  ///
  /// In en, this message translates to:
  /// **'Check for a session'**
  String get cmdTmuxHas;

  /// No description provided for @cmdTmuxSource.
  ///
  /// In en, this message translates to:
  /// **'Load a configuration file'**
  String get cmdTmuxSource;

  /// No description provided for @cmdTmuxBind.
  ///
  /// In en, this message translates to:
  /// **'Bind a key'**
  String get cmdTmuxBind;

  /// No description provided for @cmdTmuxBreak.
  ///
  /// In en, this message translates to:
  /// **'Move a pane to a window'**
  String get cmdTmuxBreak;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
