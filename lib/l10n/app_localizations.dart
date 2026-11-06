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
  /// **'Accent color'**
  String get accent;

  /// No description provided for @accentBlue.
  ///
  /// In en, this message translates to:
  /// **'Blue'**
  String get accentBlue;

  /// No description provided for @accentGreen.
  ///
  /// In en, this message translates to:
  /// **'Green'**
  String get accentGreen;

  /// No description provided for @accentViolet.
  ///
  /// In en, this message translates to:
  /// **'Violet'**
  String get accentViolet;

  /// No description provided for @accentOrange.
  ///
  /// In en, this message translates to:
  /// **'Orange'**
  String get accentOrange;

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

  /// No description provided for @renameGroup.
  ///
  /// In en, this message translates to:
  /// **'Rename group'**
  String get renameGroup;

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
