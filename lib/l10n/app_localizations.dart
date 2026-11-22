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

  /// No description provided for @aiConfigTitle.
  ///
  /// In en, this message translates to:
  /// **'AI'**
  String get aiConfigTitle;

  /// No description provided for @aiAgentAttach.
  ///
  /// In en, this message translates to:
  /// **'Attach files'**
  String get aiAgentAttach;

  /// No description provided for @aiAgentAttachmentTooLarge.
  ///
  /// In en, this message translates to:
  /// **'This file is too large. Choose a smaller file.'**
  String get aiAgentAttachmentTooLarge;

  /// No description provided for @aiAgentAttachmentTooMany.
  ///
  /// In en, this message translates to:
  /// **'A message can contain up to {count} attachments.'**
  String aiAgentAttachmentTooMany(int count);

  /// No description provided for @aiAgentAttachmentTotalTooLarge.
  ///
  /// In en, this message translates to:
  /// **'Attachments in this message exceed {size} MiB. Remove a file and try again.'**
  String aiAgentAttachmentTotalTooLarge(int size);

  /// No description provided for @aiAgentAttachmentImageTooLarge.
  ///
  /// In en, this message translates to:
  /// **'This image has too many pixels. Resize it and try again.'**
  String get aiAgentAttachmentImageTooLarge;

  /// No description provided for @aiAgentAttachmentFileError.
  ///
  /// In en, this message translates to:
  /// **'{name}: {reason}'**
  String aiAgentAttachmentFileError(String name, String reason);

  /// No description provided for @aiAgentAttachmentUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Choose UTF-8 text or a PNG, JPEG or WebP image. Binary files, credentials and unsupported formats cannot be attached.'**
  String get aiAgentAttachmentUnsupported;

  /// No description provided for @aiAgentAttachmentUnreadable.
  ///
  /// In en, this message translates to:
  /// **'The selected file could not be read.'**
  String get aiAgentAttachmentUnreadable;

  /// No description provided for @aiConfigEnabled.
  ///
  /// In en, this message translates to:
  /// **'Enable AI'**
  String get aiConfigEnabled;

  /// No description provided for @aiConfigAnthropic.
  ///
  /// In en, this message translates to:
  /// **'Anthropic Messages'**
  String get aiConfigAnthropic;

  /// No description provided for @aiConfigOpenAi.
  ///
  /// In en, this message translates to:
  /// **'OpenAI Chat Completions'**
  String get aiConfigOpenAi;

  /// No description provided for @aiConfigResponses.
  ///
  /// In en, this message translates to:
  /// **'OpenAI Responses'**
  String get aiConfigResponses;

  /// No description provided for @aiConfigEndpoint.
  ///
  /// In en, this message translates to:
  /// **'API base URL'**
  String get aiConfigEndpoint;

  /// No description provided for @aiConfigEndpointHint.
  ///
  /// In en, this message translates to:
  /// **'/v1 is added when the path has no version. HTTPS or exact local loopback HTTP only.'**
  String get aiConfigEndpointHint;

  /// No description provided for @aiConfigModel.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get aiConfigModel;

  /// No description provided for @aiConfigTools.
  ///
  /// In en, this message translates to:
  /// **'Model supports tool calls'**
  String get aiConfigTools;

  /// No description provided for @aiConfigContextWindow.
  ///
  /// In en, this message translates to:
  /// **'Context window (tokens)'**
  String get aiConfigContextWindow;

  /// No description provided for @aiConfigMaxOutput.
  ///
  /// In en, this message translates to:
  /// **'Maximum output (tokens)'**
  String get aiConfigMaxOutput;

  /// No description provided for @aiConfigApiKey.
  ///
  /// In en, this message translates to:
  /// **'API key'**
  String get aiConfigApiKey;

  /// No description provided for @aiConfigKeyLoading.
  ///
  /// In en, this message translates to:
  /// **'Checking secure storage…'**
  String get aiConfigKeyLoading;

  /// No description provided for @aiConfigKeyLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not check the API key in secure storage.'**
  String get aiConfigKeyLoadFailed;

  /// No description provided for @aiConfigKeySaved.
  ///
  /// In en, this message translates to:
  /// **'A key is saved for this destination. Leave the field empty to keep it.'**
  String get aiConfigKeySaved;

  /// No description provided for @aiConfigKeyMissing.
  ///
  /// In en, this message translates to:
  /// **'No key saved; leave empty if this endpoint needs none.'**
  String get aiConfigKeyMissing;

  /// No description provided for @aiConfigKeyRemoved.
  ///
  /// In en, this message translates to:
  /// **'The saved key will be removed when you save.'**
  String get aiConfigKeyRemoved;

  /// No description provided for @aiConfigRemoveKey.
  ///
  /// In en, this message translates to:
  /// **'Remove saved key'**
  String get aiConfigRemoveKey;

  /// No description provided for @aiConfigInvalid.
  ///
  /// In en, this message translates to:
  /// **'Check the API address, model and token limits.'**
  String get aiConfigInvalid;

  /// No description provided for @aiConfigSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'AI settings were not saved. A key change may already have reached OS secure storage.'**
  String get aiConfigSaveFailed;

  /// No description provided for @aiConfigPartialSave.
  ///
  /// In en, this message translates to:
  /// **'The API key was updated, but AI settings could not be saved. Retry saving the settings.'**
  String get aiConfigPartialSave;

  /// No description provided for @aiConfigLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'AI configuration could not be read. AI is disabled and the existing file is protected.'**
  String get aiConfigLoadFailed;

  /// No description provided for @aiConfigConflict.
  ///
  /// In en, this message translates to:
  /// **'AI settings changed elsewhere. Cancel to reload before saving.'**
  String get aiConfigConflict;

  /// No description provided for @deleteHostsConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete the selected {count} hosts?'**
  String deleteHostsConfirm(int count);

  /// No description provided for @hostDeleteCleanupFailed.
  ///
  /// In en, this message translates to:
  /// **'Hosts were deleted, but some saved credentials could not be removed. Check OS secure storage.'**
  String get hostDeleteCleanupFailed;

  /// No description provided for @closeTabsLeft.
  ///
  /// In en, this message translates to:
  /// **'Close tabs to the left'**
  String get closeTabsLeft;

  /// No description provided for @closeTabsRight.
  ///
  /// In en, this message translates to:
  /// **'Close tabs to the right'**
  String get closeTabsRight;

  /// No description provided for @closeOtherTabs.
  ///
  /// In en, this message translates to:
  /// **'Close other tabs'**
  String get closeOtherTabs;

  /// No description provided for @closeAll.
  ///
  /// In en, this message translates to:
  /// **'Close all'**
  String get closeAll;

  /// No description provided for @closeAbove.
  ///
  /// In en, this message translates to:
  /// **'Close all above'**
  String get closeAbove;

  /// No description provided for @closeBelow.
  ///
  /// In en, this message translates to:
  /// **'Close all below'**
  String get closeBelow;

  /// No description provided for @noHosts.
  ///
  /// In en, this message translates to:
  /// **'No hosts yet'**
  String get noHosts;

  /// No description provided for @noHostsInGroup.
  ///
  /// In en, this message translates to:
  /// **'No hosts in this group'**
  String get noHostsInGroup;

  /// No description provided for @hostEmptyHint.
  ///
  /// In en, this message translates to:
  /// **'Add a host or import saved connections to get started.'**
  String get hostEmptyHint;

  /// No description provided for @moveToGroup.
  ///
  /// In en, this message translates to:
  /// **'Move to group…'**
  String get moveToGroup;

  /// No description provided for @moveHostsTitle.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{Move host to group} other{Move {count} hosts to group}}'**
  String moveHostsTitle(int count);

  /// No description provided for @completionLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading…'**
  String get completionLoading;

  /// No description provided for @completionUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Path unavailable'**
  String get completionUnavailable;

  /// No description provided for @completionFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not list this folder'**
  String get completionFailed;

  /// No description provided for @completionEmpty.
  ///
  /// In en, this message translates to:
  /// **'No matches'**
  String get completionEmpty;

  /// No description provided for @completionTruncated.
  ///
  /// In en, this message translates to:
  /// **'Type more to narrow the list'**
  String get completionTruncated;

  /// No description provided for @completionCommand.
  ///
  /// In en, this message translates to:
  /// **'Command'**
  String get completionCommand;

  /// No description provided for @completionSubcommand.
  ///
  /// In en, this message translates to:
  /// **'Subcommand'**
  String get completionSubcommand;

  /// No description provided for @completionOption.
  ///
  /// In en, this message translates to:
  /// **'Option'**
  String get completionOption;

  /// No description provided for @completionArgument.
  ///
  /// In en, this message translates to:
  /// **'Argument value'**
  String get completionArgument;

  /// No description provided for @openWith.
  ///
  /// In en, this message translates to:
  /// **'Open with…'**
  String get openWith;

  /// No description provided for @systemDefaultApp.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get systemDefaultApp;

  /// No description provided for @defaultApp.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get defaultApp;

  /// No description provided for @chooseProgram.
  ///
  /// In en, this message translates to:
  /// **'Choose another app…'**
  String get chooseProgram;

  /// No description provided for @alwaysOpenWith.
  ///
  /// In en, this message translates to:
  /// **'Always use for {type}'**
  String alwaysOpenWith(String type);

  /// No description provided for @errLaunchFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open the local copy.'**
  String get errLaunchFailed;

  /// No description provided for @uiScale.
  ///
  /// In en, this message translates to:
  /// **'Interface scale'**
  String get uiScale;

  /// No description provided for @motion.
  ///
  /// In en, this message translates to:
  /// **'Motion'**
  String get motion;

  /// No description provided for @motionLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get motionLight;

  /// No description provided for @motionFull.
  ///
  /// In en, this message translates to:
  /// **'Full'**
  String get motionFull;

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

  /// No description provided for @showPassword.
  ///
  /// In en, this message translates to:
  /// **'Show password'**
  String get showPassword;

  /// No description provided for @hidePassword.
  ///
  /// In en, this message translates to:
  /// **'Hide password'**
  String get hidePassword;

  /// No description provided for @hostPasswordLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading saved password…'**
  String get hostPasswordLoading;

  /// No description provided for @hostPasswordLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not read the saved password. Unlock secure storage and retry.'**
  String get hostPasswordLoadFailed;

  /// No description provided for @hostPasswordRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry password loading'**
  String get hostPasswordRetry;

  /// No description provided for @hostPasswordRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove saved password'**
  String get hostPasswordRemove;

  /// No description provided for @hostPasswordKeep.
  ///
  /// In en, this message translates to:
  /// **'Keep saved password'**
  String get hostPasswordKeep;

  /// No description provided for @hostPasswordRemovalPending.
  ///
  /// In en, this message translates to:
  /// **'The saved password will be removed when you save.'**
  String get hostPasswordRemovalPending;

  /// No description provided for @hostPasswordSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Host settings were saved, but the password change could not be confirmed. Check secure storage and save again.'**
  String get hostPasswordSaveFailed;

  /// No description provided for @hostPasswordCleanupFailed.
  ///
  /// In en, this message translates to:
  /// **'Host settings were saved, but old proxy credentials could not be removed. The password change has not been saved. Check secure storage and save again.'**
  String get hostPasswordCleanupFailed;

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
  /// **'Rendering'**
  String get renderer;

  /// No description provided for @rendererPerformance.
  ///
  /// In en, this message translates to:
  /// **'High performance'**
  String get rendererPerformance;

  /// No description provided for @rendererLight.
  ///
  /// In en, this message translates to:
  /// **'Lightweight'**
  String get rendererLight;

  /// No description provided for @rendererPerformanceHint.
  ///
  /// In en, this message translates to:
  /// **'Impeller engine: steadier animation, about 150 MB more memory'**
  String get rendererPerformanceHint;

  /// No description provided for @rendererLightHint.
  ///
  /// In en, this message translates to:
  /// **'Skia engine: less memory, but animations may stutter the first time they appear'**
  String get rendererLightHint;

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

  /// No description provided for @aiTextStyle.
  ///
  /// In en, this message translates to:
  /// **'AI text'**
  String get aiTextStyle;

  /// No description provided for @aiTextItalicFaint.
  ///
  /// In en, this message translates to:
  /// **'Italic dim'**
  String get aiTextItalicFaint;

  /// No description provided for @aiTextItalic.
  ///
  /// In en, this message translates to:
  /// **'Italic'**
  String get aiTextItalic;

  /// No description provided for @aiTextFaint.
  ///
  /// In en, this message translates to:
  /// **'Dim'**
  String get aiTextFaint;

  /// No description provided for @aiTextPlain.
  ///
  /// In en, this message translates to:
  /// **'Normal'**
  String get aiTextPlain;

  /// No description provided for @aiTaskSteps.
  ///
  /// In en, this message translates to:
  /// **'AI task step limit'**
  String get aiTaskSteps;

  /// No description provided for @aiCompletionDelay.
  ///
  /// In en, this message translates to:
  /// **'AI completion delay'**
  String get aiCompletionDelay;

  /// No description provided for @milliseconds.
  ///
  /// In en, this message translates to:
  /// **'{n} ms'**
  String milliseconds(int n);

  /// No description provided for @completionTranslation.
  ///
  /// In en, this message translates to:
  /// **'Translate completion descriptions automatically'**
  String get completionTranslation;

  /// No description provided for @completionTranslationHint.
  ///
  /// In en, this message translates to:
  /// **'Sends only public command descriptions to the selected service. Cached translations remain when off.'**
  String get completionTranslationHint;

  /// No description provided for @translationService.
  ///
  /// In en, this message translates to:
  /// **'Translation service'**
  String get translationService;

  /// No description provided for @translationConcurrency.
  ///
  /// In en, this message translates to:
  /// **'Concurrent translations'**
  String get translationConcurrency;

  /// No description provided for @translationConcurrencyAuto.
  ///
  /// In en, this message translates to:
  /// **'Auto (all visible)'**
  String get translationConcurrencyAuto;

  /// No description provided for @translationProvider.
  ///
  /// In en, this message translates to:
  /// **'Provider'**
  String get translationProvider;

  /// No description provided for @translationMyMemory.
  ///
  /// In en, this message translates to:
  /// **'MyMemory'**
  String get translationMyMemory;

  /// No description provided for @translationDeepL.
  ///
  /// In en, this message translates to:
  /// **'DeepL'**
  String get translationDeepL;

  /// No description provided for @translationGoogle.
  ///
  /// In en, this message translates to:
  /// **'Google Cloud Translation'**
  String get translationGoogle;

  /// No description provided for @translationMicrosoft.
  ///
  /// In en, this message translates to:
  /// **'Microsoft Translator'**
  String get translationMicrosoft;

  /// No description provided for @translationOpenAi.
  ///
  /// In en, this message translates to:
  /// **'OpenAI compatible'**
  String get translationOpenAi;

  /// No description provided for @translationMyMemoryHint.
  ///
  /// In en, this message translates to:
  /// **'No key required · 5,000 characters/day, or 50,000 with a valid email'**
  String get translationMyMemoryHint;

  /// No description provided for @translationEmail.
  ///
  /// In en, this message translates to:
  /// **'Email (optional)'**
  String get translationEmail;

  /// No description provided for @translationEmailHint.
  ///
  /// In en, this message translates to:
  /// **'Sent only to MyMemory so they can contact you if needed.'**
  String get translationEmailHint;

  /// No description provided for @translationEmailInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid email address of up to 254 ASCII characters.'**
  String get translationEmailInvalid;

  /// No description provided for @translationDeepLFree.
  ///
  /// In en, this message translates to:
  /// **'Use DeepL API Free'**
  String get translationDeepLFree;

  /// No description provided for @translationRegion.
  ///
  /// In en, this message translates to:
  /// **'Region (optional)'**
  String get translationRegion;

  /// No description provided for @translationEndpoint.
  ///
  /// In en, this message translates to:
  /// **'API base URL'**
  String get translationEndpoint;

  /// No description provided for @translationEndpointHint.
  ///
  /// In en, this message translates to:
  /// **'For example, https://api.example.com/v1 · omit /chat/completions'**
  String get translationEndpointHint;

  /// No description provided for @translationModel.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get translationModel;

  /// No description provided for @translationApiKey.
  ///
  /// In en, this message translates to:
  /// **'API key'**
  String get translationApiKey;

  /// No description provided for @translationKeySaved.
  ///
  /// In en, this message translates to:
  /// **'Key saved · leave blank to keep'**
  String get translationKeySaved;

  /// No description provided for @translationKeyMissing.
  ///
  /// In en, this message translates to:
  /// **'No saved key'**
  String get translationKeyMissing;

  /// No description provided for @translationKeyRemoved.
  ///
  /// In en, this message translates to:
  /// **'Key will be removed on Save'**
  String get translationKeyRemoved;

  /// No description provided for @translationRemoveKey.
  ///
  /// In en, this message translates to:
  /// **'Remove saved key'**
  String get translationRemoveKey;

  /// No description provided for @translationKeyLoading.
  ///
  /// In en, this message translates to:
  /// **'Checking secure storage…'**
  String get translationKeyLoading;

  /// No description provided for @translationKeyLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not check secure storage. Cancel to try again.'**
  String get translationKeyLoadFailed;

  /// No description provided for @translationEndpointInvalid.
  ///
  /// In en, this message translates to:
  /// **'Use HTTPS, or HTTP on localhost, without credentials, query or fragment.'**
  String get translationEndpointInvalid;

  /// No description provided for @translationModelInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a model name of up to 128 letters, digits, ., _, :, / or -.'**
  String get translationModelInvalid;

  /// No description provided for @translationRegionInvalid.
  ///
  /// In en, this message translates to:
  /// **'Use up to 64 lowercase letters, digits or hyphens.'**
  String get translationRegionInvalid;

  /// No description provided for @translationConflict.
  ///
  /// In en, this message translates to:
  /// **'Settings changed. Cancel your edits before trying again.'**
  String get translationConflict;

  /// No description provided for @translationSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save. A key change may already have been saved to secure storage.'**
  String get translationSaveFailed;

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

  /// No description provided for @hostKeys.
  ///
  /// In en, this message translates to:
  /// **'Host keys'**
  String get hostKeys;

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

  /// No description provided for @checkForUpdates.
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get checkForUpdates;

  /// No description provided for @checkingForUpdates.
  ///
  /// In en, this message translates to:
  /// **'Checking for updates…'**
  String get checkingForUpdates;

  /// No description provided for @upToDate.
  ///
  /// In en, this message translates to:
  /// **'You\'re up to date'**
  String get upToDate;

  /// No description provided for @updateFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not check for updates'**
  String get updateFailed;

  /// No description provided for @updateAvailable.
  ///
  /// In en, this message translates to:
  /// **'Version {version} is available'**
  String updateAvailable(String version);

  /// No description provided for @releaseNotes.
  ///
  /// In en, this message translates to:
  /// **'Release notes'**
  String get releaseNotes;

  /// No description provided for @openReleasePage.
  ///
  /// In en, this message translates to:
  /// **'Open release page'**
  String get openReleasePage;

  /// No description provided for @updateDownload.
  ///
  /// In en, this message translates to:
  /// **'Download update'**
  String get updateDownload;

  /// No description provided for @updateDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading update…'**
  String get updateDownloading;

  /// No description provided for @updateVerifying.
  ///
  /// In en, this message translates to:
  /// **'Checking the download…'**
  String get updateVerifying;

  /// No description provided for @updateDownloaded.
  ///
  /// In en, this message translates to:
  /// **'Downloaded to {path}'**
  String updateDownloaded(String path);

  /// No description provided for @updateInstallPrompt.
  ///
  /// In en, this message translates to:
  /// **'Install it now? The app will close first.'**
  String get updateInstallPrompt;

  /// No description provided for @updateDownloadFailed.
  ///
  /// In en, this message translates to:
  /// **'Download failed. Check your connection and try again.'**
  String get updateDownloadFailed;

  /// No description provided for @updateNoPackage.
  ///
  /// In en, this message translates to:
  /// **'No installable package is available for this platform. Open the release page instead.'**
  String get updateNoPackage;

  /// No description provided for @installNow.
  ///
  /// In en, this message translates to:
  /// **'Install now'**
  String get installNow;

  /// No description provided for @later.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get later;

  /// No description provided for @cancelDownload.
  ///
  /// In en, this message translates to:
  /// **'Cancel download'**
  String get cancelDownload;

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

  /// No description provided for @shellIntegrationInstall.
  ///
  /// In en, this message translates to:
  /// **'Install shell integration'**
  String get shellIntegrationInstall;

  /// No description provided for @shellIntegrationRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove shell integration'**
  String get shellIntegrationRemove;

  /// No description provided for @shellIntegrationInstalled.
  ///
  /// In en, this message translates to:
  /// **'Installed. New terminals will use it.'**
  String get shellIntegrationInstalled;

  /// No description provided for @shellIntegrationRemoved.
  ///
  /// In en, this message translates to:
  /// **'Removed. New terminals will not load it.'**
  String get shellIntegrationRemoved;

  /// No description provided for @shellIntegrationFailed.
  ///
  /// In en, this message translates to:
  /// **'Shell integration change failed'**
  String get shellIntegrationFailed;

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
  /// **'Show hidden files'**
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

  /// No description provided for @shortcuts.
  ///
  /// In en, this message translates to:
  /// **'Keyboard shortcuts'**
  String get shortcuts;

  /// No description provided for @shortcutPress.
  ///
  /// In en, this message translates to:
  /// **'Press keys…'**
  String get shortcutPress;

  /// No description provided for @shortcutUnset.
  ///
  /// In en, this message translates to:
  /// **'Unset'**
  String get shortcutUnset;

  /// No description provided for @shortcutReset.
  ///
  /// In en, this message translates to:
  /// **'Reset to default'**
  String get shortcutReset;

  /// No description provided for @shortcutConflict.
  ///
  /// In en, this message translates to:
  /// **'Already used by {action}'**
  String shortcutConflict(Object action);

  /// No description provided for @shortcutCommandPalette.
  ///
  /// In en, this message translates to:
  /// **'Command palette'**
  String get shortcutCommandPalette;

  /// No description provided for @shortcutNewConnection.
  ///
  /// In en, this message translates to:
  /// **'New connection'**
  String get shortcutNewConnection;

  /// No description provided for @shortcutCloseTab.
  ///
  /// In en, this message translates to:
  /// **'Close tab'**
  String get shortcutCloseTab;

  /// No description provided for @shortcutSettings.
  ///
  /// In en, this message translates to:
  /// **'Open settings'**
  String get shortcutSettings;

  /// No description provided for @shortcutToggleAgent.
  ///
  /// In en, this message translates to:
  /// **'Toggle Agent panel'**
  String get shortcutToggleAgent;

  /// No description provided for @shortcutInlineGenerate.
  ///
  /// In en, this message translates to:
  /// **'Inline AI task'**
  String get shortcutInlineGenerate;

  /// No description provided for @shortcutTerminalCopy.
  ///
  /// In en, this message translates to:
  /// **'Terminal copy'**
  String get shortcutTerminalCopy;

  /// No description provided for @shortcutTerminalPaste.
  ///
  /// In en, this message translates to:
  /// **'Terminal paste'**
  String get shortcutTerminalPaste;

  /// No description provided for @shortcutTerminalSearch.
  ///
  /// In en, this message translates to:
  /// **'Terminal search'**
  String get shortcutTerminalSearch;

  /// No description provided for @shortcutCommandHistory.
  ///
  /// In en, this message translates to:
  /// **'Command history'**
  String get shortcutCommandHistory;

  /// No description provided for @shortcutPreviousPane.
  ///
  /// In en, this message translates to:
  /// **'Previous pane'**
  String get shortcutPreviousPane;

  /// No description provided for @shortcutNextPane.
  ///
  /// In en, this message translates to:
  /// **'Next pane'**
  String get shortcutNextPane;

  /// No description provided for @shortcutPreviousTab.
  ///
  /// In en, this message translates to:
  /// **'Previous tab'**
  String get shortcutPreviousTab;

  /// No description provided for @shortcutNextTab.
  ///
  /// In en, this message translates to:
  /// **'Next tab'**
  String get shortcutNextTab;

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
  /// **'Quit Sshairy?'**
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

  /// No description provided for @backgroundGalleryFull.
  ///
  /// In en, this message translates to:
  /// **'Saved backgrounds are full. Remove one to add another.'**
  String get backgroundGalleryFull;

  /// No description provided for @backgroundImageItem.
  ///
  /// In en, this message translates to:
  /// **'Image {number}'**
  String backgroundImageItem(int number);

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

  /// No description provided for @terminalMultilineInput.
  ///
  /// In en, this message translates to:
  /// **'Multiline input'**
  String get terminalMultilineInput;

  /// No description provided for @terminalMultilineSend.
  ///
  /// In en, this message translates to:
  /// **'Send to terminal'**
  String get terminalMultilineSend;

  /// No description provided for @terminalMultilinePlaceholder.
  ///
  /// In en, this message translates to:
  /// **'Enter commands…'**
  String get terminalMultilinePlaceholder;

  /// No description provided for @localShellsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No local shells found'**
  String get localShellsEmpty;

  /// No description provided for @aiAgentTitle.
  ///
  /// In en, this message translates to:
  /// **'Airy'**
  String get aiAgentTitle;

  /// No description provided for @aiAgentRail.
  ///
  /// In en, this message translates to:
  /// **'Airy Agent'**
  String get aiAgentRail;

  /// No description provided for @aiAgentClear.
  ///
  /// In en, this message translates to:
  /// **'Clear conversation'**
  String get aiAgentClear;

  /// No description provided for @aiAgentConfigure.
  ///
  /// In en, this message translates to:
  /// **'Configure a model and enable AI in Settings to begin.'**
  String get aiAgentConfigure;

  /// No description provided for @aiAgentConfigurationFailed.
  ///
  /// In en, this message translates to:
  /// **'AI configuration could not be read. Review it in Settings.'**
  String get aiAgentConfigurationFailed;

  /// No description provided for @aiAgentChooseHost.
  ///
  /// In en, this message translates to:
  /// **'Choose a server'**
  String get aiAgentChooseHost;

  /// No description provided for @aiAgentGoal.
  ///
  /// In en, this message translates to:
  /// **'Describe what you want to check or do…'**
  String get aiAgentGoal;

  /// No description provided for @aiAgentSend.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get aiAgentSend;

  /// No description provided for @aiAgentEmpty.
  ///
  /// In en, this message translates to:
  /// **'Only the text you send and explicitly authorized data are shared with the selected model.'**
  String get aiAgentEmpty;

  /// No description provided for @aiAgentIdle.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get aiAgentIdle;

  /// No description provided for @aiAgentPreparing.
  ///
  /// In en, this message translates to:
  /// **'Preparing'**
  String get aiAgentPreparing;

  /// No description provided for @aiAgentStreaming.
  ///
  /// In en, this message translates to:
  /// **'Receiving response'**
  String get aiAgentStreaming;

  /// No description provided for @aiAgentAwaitingApproval.
  ///
  /// In en, this message translates to:
  /// **'Waiting for command approval'**
  String get aiAgentAwaitingApproval;

  /// No description provided for @aiAgentExecuting.
  ///
  /// In en, this message translates to:
  /// **'Running'**
  String get aiAgentExecuting;

  /// No description provided for @aiAgentCompleted.
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get aiAgentCompleted;

  /// No description provided for @aiAgentStopping.
  ///
  /// In en, this message translates to:
  /// **'Stopping'**
  String get aiAgentStopping;

  /// No description provided for @aiAgentCancelled.
  ///
  /// In en, this message translates to:
  /// **'Stopped'**
  String get aiAgentCancelled;

  /// No description provided for @aiAgentFailed.
  ///
  /// In en, this message translates to:
  /// **'The request could not be completed.'**
  String get aiAgentFailed;

  /// No description provided for @aiAgentOutcomeUnknown.
  ///
  /// In en, this message translates to:
  /// **'Remote outcome is unknown'**
  String get aiAgentOutcomeUnknown;

  /// No description provided for @aiAgentDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'Fixed diagnostics'**
  String get aiAgentDiagnostics;

  /// No description provided for @aiAgentToolHosts.
  ///
  /// In en, this message translates to:
  /// **'List hosts'**
  String get aiAgentToolHosts;

  /// No description provided for @aiAgentToolHostsHint.
  ///
  /// In en, this message translates to:
  /// **'View saved hosts by name and ID.'**
  String get aiAgentToolHostsHint;

  /// No description provided for @aiAgentToolTerminals.
  ///
  /// In en, this message translates to:
  /// **'List terminal windows'**
  String get aiAgentToolTerminals;

  /// No description provided for @aiAgentToolTerminalsHint.
  ///
  /// In en, this message translates to:
  /// **'List connected tabs and splits without reading commands or output.'**
  String get aiAgentToolTerminalsHint;

  /// No description provided for @aiAgentToolTerminalHistory.
  ///
  /// In en, this message translates to:
  /// **'Read window context'**
  String get aiAgentToolTerminalHistory;

  /// No description provided for @aiAgentToolTerminalHistoryHint.
  ///
  /// In en, this message translates to:
  /// **'Read one terminal\'s known directory, recent commands and paired results.'**
  String get aiAgentToolTerminalHistoryHint;

  /// No description provided for @aiAgentTerminalApproveHint.
  ///
  /// In en, this message translates to:
  /// **'Let Airy use this terminal\'s known directory, prompt status and recent command results for this turn. Window numbers are the tab and pane positions when you sent the message. No commands will run.'**
  String get aiAgentTerminalApproveHint;

  /// No description provided for @aiAgentToolTerminalScreen.
  ///
  /// In en, this message translates to:
  /// **'Read terminal screen'**
  String get aiAgentToolTerminalScreen;

  /// No description provided for @aiAgentToolTerminalScreenHint.
  ///
  /// In en, this message translates to:
  /// **'Read the visible text of one terminal, up to 200 lines, without scrollback.'**
  String get aiAgentToolTerminalScreenHint;

  /// No description provided for @aiAgentTerminalScreenApproveHint.
  ///
  /// In en, this message translates to:
  /// **'Let Airy read only the visible text of this terminal, up to 200 lines. Every read asks again. No commands will run.'**
  String get aiAgentTerminalScreenApproveHint;

  /// No description provided for @aiAgentToolFilesList.
  ///
  /// In en, this message translates to:
  /// **'List directory'**
  String get aiAgentToolFilesList;

  /// No description provided for @aiAgentToolFilesStat.
  ///
  /// In en, this message translates to:
  /// **'File info'**
  String get aiAgentToolFilesStat;

  /// No description provided for @aiAgentToolFilesRead.
  ///
  /// In en, this message translates to:
  /// **'Read file'**
  String get aiAgentToolFilesRead;

  /// No description provided for @aiAgentToolFilesWrite.
  ///
  /// In en, this message translates to:
  /// **'Write file'**
  String get aiAgentToolFilesWrite;

  /// No description provided for @aiAgentToolFilesMkdir.
  ///
  /// In en, this message translates to:
  /// **'Create directory'**
  String get aiAgentToolFilesMkdir;

  /// No description provided for @aiAgentToolFilesRename.
  ///
  /// In en, this message translates to:
  /// **'Rename path'**
  String get aiAgentToolFilesRename;

  /// No description provided for @aiAgentToolFilesDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete path'**
  String get aiAgentToolFilesDelete;

  /// No description provided for @aiAgentToolFilesHint.
  ///
  /// In en, this message translates to:
  /// **'Read or change remote files and directories.'**
  String get aiAgentToolFilesHint;

  /// No description provided for @aiAgentToolTransferList.
  ///
  /// In en, this message translates to:
  /// **'List transfers'**
  String get aiAgentToolTransferList;

  /// No description provided for @aiAgentToolTransferEnqueue.
  ///
  /// In en, this message translates to:
  /// **'Start transfer'**
  String get aiAgentToolTransferEnqueue;

  /// No description provided for @aiAgentToolTransferCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel transfer'**
  String get aiAgentToolTransferCancel;

  /// No description provided for @aiAgentToolTransferHint.
  ///
  /// In en, this message translates to:
  /// **'View or act on file transfers.'**
  String get aiAgentToolTransferHint;

  /// No description provided for @aiAgentToolSessionOpen.
  ///
  /// In en, this message translates to:
  /// **'Open session'**
  String get aiAgentToolSessionOpen;

  /// No description provided for @aiAgentToolSessionClose.
  ///
  /// In en, this message translates to:
  /// **'Close session'**
  String get aiAgentToolSessionClose;

  /// No description provided for @aiAgentToolSessionReconnect.
  ///
  /// In en, this message translates to:
  /// **'Reconnect session'**
  String get aiAgentToolSessionReconnect;

  /// No description provided for @aiAgentToolSessionHint.
  ///
  /// In en, this message translates to:
  /// **'Open, close or reconnect terminal sessions.'**
  String get aiAgentToolSessionHint;

  /// No description provided for @aiAgentToolWorkspaceFocus.
  ///
  /// In en, this message translates to:
  /// **'Switch window'**
  String get aiAgentToolWorkspaceFocus;

  /// No description provided for @aiAgentToolWorkspaceSplit.
  ///
  /// In en, this message translates to:
  /// **'Split pane'**
  String get aiAgentToolWorkspaceSplit;

  /// No description provided for @aiAgentToolWorkspaceRename.
  ///
  /// In en, this message translates to:
  /// **'Rename tab'**
  String get aiAgentToolWorkspaceRename;

  /// No description provided for @aiAgentToolWorkspaceCloseTabs.
  ///
  /// In en, this message translates to:
  /// **'Close tabs'**
  String get aiAgentToolWorkspaceCloseTabs;

  /// No description provided for @aiAgentToolWorkspaceHint.
  ///
  /// In en, this message translates to:
  /// **'Switch windows or change the layout.'**
  String get aiAgentToolWorkspaceHint;

  /// No description provided for @aiAgentToolSettingsGet.
  ///
  /// In en, this message translates to:
  /// **'Read settings'**
  String get aiAgentToolSettingsGet;

  /// No description provided for @aiAgentToolSettingsPatch.
  ///
  /// In en, this message translates to:
  /// **'Change settings'**
  String get aiAgentToolSettingsPatch;

  /// No description provided for @aiAgentToolSettingsHint.
  ///
  /// In en, this message translates to:
  /// **'Read or change this app\'s settings.'**
  String get aiAgentToolSettingsHint;

  /// No description provided for @aiAgentToolHostCreate.
  ///
  /// In en, this message translates to:
  /// **'Add host'**
  String get aiAgentToolHostCreate;

  /// No description provided for @aiAgentToolHostUpdate.
  ///
  /// In en, this message translates to:
  /// **'Update host'**
  String get aiAgentToolHostUpdate;

  /// No description provided for @aiAgentToolHostMove.
  ///
  /// In en, this message translates to:
  /// **'Move host'**
  String get aiAgentToolHostMove;

  /// No description provided for @aiAgentToolHostDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete host'**
  String get aiAgentToolHostDelete;

  /// No description provided for @aiAgentToolHostHint.
  ///
  /// In en, this message translates to:
  /// **'Add, update or delete saved hosts.'**
  String get aiAgentToolHostHint;

  /// No description provided for @aiAgentToolForwardList.
  ///
  /// In en, this message translates to:
  /// **'List forwards'**
  String get aiAgentToolForwardList;

  /// No description provided for @aiAgentToolForwardSave.
  ///
  /// In en, this message translates to:
  /// **'Save forward'**
  String get aiAgentToolForwardSave;

  /// No description provided for @aiAgentToolForwardDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete forward'**
  String get aiAgentToolForwardDelete;

  /// No description provided for @aiAgentToolForwardStart.
  ///
  /// In en, this message translates to:
  /// **'Start forward'**
  String get aiAgentToolForwardStart;

  /// No description provided for @aiAgentToolForwardStop.
  ///
  /// In en, this message translates to:
  /// **'Stop forward'**
  String get aiAgentToolForwardStop;

  /// No description provided for @aiAgentToolForwardHint.
  ///
  /// In en, this message translates to:
  /// **'View or act on port forwarding rules.'**
  String get aiAgentToolForwardHint;

  /// No description provided for @aiAgentToolJobStart.
  ///
  /// In en, this message translates to:
  /// **'Start background job'**
  String get aiAgentToolJobStart;

  /// No description provided for @aiAgentToolJobRead.
  ///
  /// In en, this message translates to:
  /// **'Read job output'**
  String get aiAgentToolJobRead;

  /// No description provided for @aiAgentToolJobStatus.
  ///
  /// In en, this message translates to:
  /// **'Job status'**
  String get aiAgentToolJobStatus;

  /// No description provided for @aiAgentToolJobStop.
  ///
  /// In en, this message translates to:
  /// **'Stop job'**
  String get aiAgentToolJobStop;

  /// No description provided for @aiAgentToolJobHint.
  ///
  /// In en, this message translates to:
  /// **'Run or inspect background jobs.'**
  String get aiAgentToolJobHint;

  /// No description provided for @aiAgentToolDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'Collect diagnostics'**
  String get aiAgentToolDiagnostics;

  /// No description provided for @aiAgentToolDiagnosticsHint.
  ///
  /// In en, this message translates to:
  /// **'Collect fixed system or disk diagnostics.'**
  String get aiAgentToolDiagnosticsHint;

  /// No description provided for @aiAgentToolExecute.
  ///
  /// In en, this message translates to:
  /// **'Execute command'**
  String get aiAgentToolExecute;

  /// No description provided for @aiAgentToolExecuteHint.
  ///
  /// In en, this message translates to:
  /// **'Run an authorized command through a separate SSH channel.'**
  String get aiAgentToolExecuteHint;

  /// No description provided for @aiAgentToolOutput.
  ///
  /// In en, this message translates to:
  /// **'Read output'**
  String get aiAgentToolOutput;

  /// No description provided for @aiAgentToolOutputHint.
  ///
  /// In en, this message translates to:
  /// **'Read command output that has been approved for sharing.'**
  String get aiAgentToolOutputHint;

  /// No description provided for @aiAgentDiagnosticScope.
  ///
  /// In en, this message translates to:
  /// **'Fixed Linux diagnostics may send OS, kernel, load, memory, disk mounts and capacity to the selected model. Process arguments and environment variables are excluded.'**
  String get aiAgentDiagnosticScope;

  /// No description provided for @aiAgentExitCode.
  ///
  /// In en, this message translates to:
  /// **'Exit code: {code}'**
  String aiAgentExitCode(int code);

  /// No description provided for @aiAgentExecutionTimeout.
  ///
  /// In en, this message translates to:
  /// **'Execution timeout: {seconds} s'**
  String aiAgentExecutionTimeout(int seconds);

  /// No description provided for @aiAgentTruncated.
  ///
  /// In en, this message translates to:
  /// **'Output was truncated.'**
  String get aiAgentTruncated;

  /// No description provided for @aiAgentShowOutput.
  ///
  /// In en, this message translates to:
  /// **'Show local output'**
  String get aiAgentShowOutput;

  /// No description provided for @aiAgentHideOutput.
  ///
  /// In en, this message translates to:
  /// **'Hide output'**
  String get aiAgentHideOutput;

  /// No description provided for @aiAgentShellPermission.
  ///
  /// In en, this message translates to:
  /// **'This command runs with the SSH account\'s permissions and may change files or access the network. Approval also lets Airy use its bounded output. Stopping closes this client\'s channel; remote processes may continue.'**
  String get aiAgentShellPermission;

  /// No description provided for @aiAgentReject.
  ///
  /// In en, this message translates to:
  /// **'Reject'**
  String get aiAgentReject;

  /// No description provided for @aiAgentApprove.
  ///
  /// In en, this message translates to:
  /// **'Approve once'**
  String get aiAgentApprove;

  /// No description provided for @aiAgentNewTask.
  ///
  /// In en, this message translates to:
  /// **'New conversation'**
  String get aiAgentNewTask;

  /// No description provided for @aiAgentWelcome.
  ///
  /// In en, this message translates to:
  /// **'What would you like to work on?'**
  String get aiAgentWelcome;

  /// No description provided for @aiAgentWelcomeHint.
  ///
  /// In en, this message translates to:
  /// **'Uses the current terminal context by default; asks before reading another window.'**
  String get aiAgentWelcomeHint;

  /// No description provided for @aiAgentSetupTitle.
  ///
  /// In en, this message translates to:
  /// **'Your SSH assistant'**
  String get aiAgentSetupTitle;

  /// No description provided for @aiAgentConfigureAction.
  ///
  /// In en, this message translates to:
  /// **'Configure AI'**
  String get aiAgentConfigureAction;

  /// No description provided for @aiAgentExampleExplain.
  ///
  /// In en, this message translates to:
  /// **'Explain a command'**
  String get aiAgentExampleExplain;

  /// No description provided for @aiAgentExampleExplainGoal.
  ///
  /// In en, this message translates to:
  /// **'Explain how to read a shell command and spot its side effects.'**
  String get aiAgentExampleExplainGoal;

  /// No description provided for @aiAgentExampleDiagnose.
  ///
  /// In en, this message translates to:
  /// **'Check server health'**
  String get aiAgentExampleDiagnose;

  /// No description provided for @aiAgentExampleDiagnoseGoal.
  ///
  /// In en, this message translates to:
  /// **'Check this server\'s load, memory and disk space. Explain any missing evidence before suggesting a change.'**
  String get aiAgentExampleDiagnoseGoal;

  /// No description provided for @aiAgentNoHost.
  ///
  /// In en, this message translates to:
  /// **'No server'**
  String get aiAgentNoHost;

  /// No description provided for @aiAgentScopeDetails.
  ///
  /// In en, this message translates to:
  /// **'Data and command permissions'**
  String get aiAgentScopeDetails;

  /// No description provided for @aiAgentScopeSummary.
  ///
  /// In en, this message translates to:
  /// **'Fixed diagnostics allowed · commands ask first'**
  String get aiAgentScopeSummary;

  /// No description provided for @aiAgentTextOnly.
  ///
  /// In en, this message translates to:
  /// **'Text only'**
  String get aiAgentTextOnly;

  /// No description provided for @aiAgentSendShortcut.
  ///
  /// In en, this message translates to:
  /// **'Send · Enter'**
  String get aiAgentSendShortcut;

  /// No description provided for @aiAgentApproveTitle.
  ///
  /// In en, this message translates to:
  /// **'Approve command'**
  String get aiAgentApproveTitle;

  /// No description provided for @aiAgentExecutionFailed.
  ///
  /// In en, this message translates to:
  /// **'Finished with errors'**
  String get aiAgentExecutionFailed;

  /// No description provided for @aiAgentErrorConfiguration.
  ///
  /// In en, this message translates to:
  /// **'Review the model configuration and API key in Settings.'**
  String get aiAgentErrorConfiguration;

  /// No description provided for @aiAgentErrorModelConfig.
  ///
  /// In en, this message translates to:
  /// **'Review the endpoint and model name in Settings.'**
  String get aiAgentErrorModelConfig;

  /// No description provided for @aiAgentErrorToolDefinition.
  ///
  /// In en, this message translates to:
  /// **'This tool is unavailable because its definition is invalid. This turn has stopped.'**
  String get aiAgentErrorToolDefinition;

  /// No description provided for @aiAgentErrorNetwork.
  ///
  /// In en, this message translates to:
  /// **'Could not reach the model. Check the connection and try a new task.'**
  String get aiAgentErrorNetwork;

  /// No description provided for @aiAgentErrorHttp.
  ///
  /// In en, this message translates to:
  /// **'The model service rejected this request. Check its credentials, quota and settings.'**
  String get aiAgentErrorHttp;

  /// No description provided for @aiAgentErrorTimeout.
  ///
  /// In en, this message translates to:
  /// **'The request reached its time limit. Review the task before trying again.'**
  String get aiAgentErrorTimeout;

  /// No description provided for @aiAgentErrorLimit.
  ///
  /// In en, this message translates to:
  /// **'This task reached its context, output or step limit. Start a smaller task.'**
  String get aiAgentErrorLimit;

  /// No description provided for @aiAgentErrorScope.
  ///
  /// In en, this message translates to:
  /// **'The model configuration or server connection changed. Start a new task to authorize the current target.'**
  String get aiAgentErrorScope;

  /// No description provided for @aiAgentErrorJournal.
  ///
  /// In en, this message translates to:
  /// **'The operation record could not be saved. Review the execution status before trying another command.'**
  String get aiAgentErrorJournal;

  /// No description provided for @aiAgentErrorProtocol.
  ///
  /// In en, this message translates to:
  /// **'The model returned an incomplete or unsupported response. No partial tool request was executed.'**
  String get aiAgentErrorProtocol;

  /// No description provided for @aiAgentErrorUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This server does not support the current command adapter.'**
  String get aiAgentErrorUnsupported;

  /// No description provided for @aiAgentErrorFileDenied.
  ///
  /// In en, this message translates to:
  /// **'The file tool refused this path or content (sensitive location, credential-like text or policy limit).'**
  String get aiAgentErrorFileDenied;

  /// No description provided for @aiAgentErrorFileSensitive.
  ///
  /// In en, this message translates to:
  /// **'The file contains credential-like or key material and was not read. Ask the user to inspect it, or narrow the request to content that excludes it.'**
  String get aiAgentErrorFileSensitive;

  /// No description provided for @aiAgentErrorFileUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This file operation is unsupported: binary or non-UTF-8, larger than 256 KiB, or the server lacks private staging and atomic replace.'**
  String get aiAgentErrorFileUnsupported;

  /// No description provided for @aiAgentErrorFileConflict.
  ///
  /// In en, this message translates to:
  /// **'The file changed after it was read. Read it again before writing.'**
  String get aiAgentErrorFileConflict;

  /// No description provided for @aiAgentErrorFileExists.
  ///
  /// In en, this message translates to:
  /// **'The target already exists. Read it first and provide its current sha256 when overwriting.'**
  String get aiAgentErrorFileExists;

  /// No description provided for @aiAgentErrorFileNotFound.
  ///
  /// In en, this message translates to:
  /// **'The file or directory does not exist.'**
  String get aiAgentErrorFileNotFound;

  /// No description provided for @aiAgentErrorFilePermission.
  ///
  /// In en, this message translates to:
  /// **'The SSH account cannot perform this file operation.'**
  String get aiAgentErrorFilePermission;

  /// No description provided for @aiAgentErrorFileInvalid.
  ///
  /// In en, this message translates to:
  /// **'The file tool arguments were invalid; check hostId, the absolute path and paging values.'**
  String get aiAgentErrorFileInvalid;

  /// No description provided for @aiAgentErrorFileScope.
  ///
  /// In en, this message translates to:
  /// **'This host is not authorized for the current task. Confirm the host before retrying.'**
  String get aiAgentErrorFileScope;

  /// No description provided for @aiReasoningEffort.
  ///
  /// In en, this message translates to:
  /// **'Reasoning effort'**
  String get aiReasoningEffort;

  /// No description provided for @aiReasoningDefault.
  ///
  /// In en, this message translates to:
  /// **'Model default'**
  String get aiReasoningDefault;

  /// No description provided for @aiReasoningOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get aiReasoningOff;

  /// No description provided for @aiReasoningLow.
  ///
  /// In en, this message translates to:
  /// **'Low'**
  String get aiReasoningLow;

  /// No description provided for @aiReasoningMedium.
  ///
  /// In en, this message translates to:
  /// **'Medium'**
  String get aiReasoningMedium;

  /// No description provided for @aiReasoningHigh.
  ///
  /// In en, this message translates to:
  /// **'High'**
  String get aiReasoningHigh;

  /// No description provided for @aiReasoningActive.
  ///
  /// In en, this message translates to:
  /// **'Thinking…'**
  String get aiReasoningActive;

  /// No description provided for @aiReasoningSummary.
  ///
  /// In en, this message translates to:
  /// **'Thinking summary'**
  String get aiReasoningSummary;

  /// No description provided for @aiReasoningCompleted.
  ///
  /// In en, this message translates to:
  /// **'Thinking complete'**
  String get aiReasoningCompleted;

  /// No description provided for @aiReasoningUnsupported.
  ///
  /// In en, this message translates to:
  /// **'This model does not have a supported reasoning setting. Choose Model default or another model.'**
  String get aiReasoningUnsupported;

  /// No description provided for @aiConfigAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Model capabilities and limits'**
  String get aiConfigAdvanced;

  /// No description provided for @aiConfigInline.
  ///
  /// In en, this message translates to:
  /// **'Inline AI tasks'**
  String get aiConfigInline;

  /// No description provided for @aiConfigInlineHint.
  ///
  /// In en, this message translates to:
  /// **'Type a request at the prompt, then click the AI icon or press Alt+Enter. AI fills in commands step by step in this terminal and continues from each result after you press Enter.'**
  String get aiConfigInlineHint;

  /// No description provided for @aiConfigCompletion.
  ///
  /// In en, this message translates to:
  /// **'AI suggestions'**
  String get aiConfigCompletion;

  /// No description provided for @aiConfigTerminalScope.
  ///
  /// In en, this message translates to:
  /// **'Allow terminal input and known directory to be sent for these SSH hosts'**
  String get aiConfigTerminalScope;

  /// No description provided for @aiConfigTerminalNoHosts.
  ///
  /// In en, this message translates to:
  /// **'Add a host to allow SSH suggestions. Local shells can start inline AI tasks manually.'**
  String get aiConfigTerminalNoHosts;

  /// No description provided for @aiConfigPosix.
  ///
  /// In en, this message translates to:
  /// **'These SSH terminals use Linux / POSIX shells'**
  String get aiConfigPosix;

  /// No description provided for @aiConfigPosixHint.
  ///
  /// In en, this message translates to:
  /// **'Confirm the input environment yourself. Disable suggestions inside su, tmux or nested SSH; the client cannot verify the inner identity.'**
  String get aiConfigPosixHint;

  /// No description provided for @aiConfigCompletionHistory.
  ///
  /// In en, this message translates to:
  /// **'Use recent commands from the same session'**
  String get aiConfigCompletionHistory;

  /// No description provided for @aiConfigCompletionHint.
  ///
  /// In en, this message translates to:
  /// **'Pause after typing git st and gray text completes it to git status; press → to accept. Uses up to 8 relevant commands and their results from this session.'**
  String get aiConfigCompletionHint;

  /// No description provided for @aiAgentErrorHostTrust.
  ///
  /// In en, this message translates to:
  /// **'Open a normal SSH connection and review this server\'s host key before using remote tools.'**
  String get aiAgentErrorHostTrust;

  /// No description provided for @aiAgentErrorAuthentication.
  ///
  /// In en, this message translates to:
  /// **'Open a normal SSH connection to provide or update this server\'s credentials.'**
  String get aiAgentErrorAuthentication;

  /// No description provided for @aiAgentErrorHostUnavailable.
  ///
  /// In en, this message translates to:
  /// **'This server is no longer available. Select a saved server for the next task.'**
  String get aiAgentErrorHostUnavailable;

  /// No description provided for @aiAgentErrorConnection.
  ///
  /// In en, this message translates to:
  /// **'The SSH connection failed. Check the server with a normal connection before trying again.'**
  String get aiAgentErrorConnection;

  /// No description provided for @aiAgentErrorExecution.
  ///
  /// In en, this message translates to:
  /// **'The command could not be completed. Review its local output and exit status before trying again.'**
  String get aiAgentErrorExecution;

  /// No description provided for @aiAgentHostAccessTitle.
  ///
  /// In en, this message translates to:
  /// **'Allow access to another host'**
  String get aiAgentHostAccessTitle;

  /// No description provided for @aiAgentHostAccessPrompt.
  ///
  /// In en, this message translates to:
  /// **'Allow this conversation to access {host}? Commands will still follow the selected permission mode.'**
  String aiAgentHostAccessPrompt(String host);

  /// No description provided for @aiAgentHostAccessAllow.
  ///
  /// In en, this message translates to:
  /// **'Allow access'**
  String get aiAgentHostAccessAllow;

  /// No description provided for @terminalAiFix.
  ///
  /// In en, this message translates to:
  /// **'Fix the last failed command'**
  String get terminalAiFix;

  /// No description provided for @terminalAiGenerate.
  ///
  /// In en, this message translates to:
  /// **'Generate command'**
  String get terminalAiGenerate;

  /// No description provided for @terminalAiInstruction.
  ///
  /// In en, this message translates to:
  /// **'Describe what you want to do'**
  String get terminalAiInstruction;

  /// No description provided for @terminalAiAuto.
  ///
  /// In en, this message translates to:
  /// **'Run automatically'**
  String get terminalAiAuto;

  /// No description provided for @terminalAiFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not generate a command. Try again.'**
  String get terminalAiFailed;

  /// No description provided for @terminalAiFailedTimeout.
  ///
  /// In en, this message translates to:
  /// **'Generation timed out. Try again.'**
  String get terminalAiFailedTimeout;

  /// No description provided for @terminalAiFailedNetwork.
  ///
  /// In en, this message translates to:
  /// **'Could not reach the model service. Check the network or settings.'**
  String get terminalAiFailedNetwork;

  /// No description provided for @terminalAiFailedHttp.
  ///
  /// In en, this message translates to:
  /// **'The model service returned HTTP {code}.'**
  String terminalAiFailedHttp(int code);

  /// No description provided for @terminalAiFailedInvalid.
  ///
  /// In en, this message translates to:
  /// **'The model returned an invalid command. Try rephrasing.'**
  String get terminalAiFailedInvalid;

  /// No description provided for @aiAgentHistory.
  ///
  /// In en, this message translates to:
  /// **'Conversation history'**
  String get aiAgentHistory;

  /// No description provided for @aiAgentHistoryEmpty.
  ///
  /// In en, this message translates to:
  /// **'No conversations yet'**
  String get aiAgentHistoryEmpty;

  /// No description provided for @aiAgentContinueConversation.
  ///
  /// In en, this message translates to:
  /// **'Continue conversation'**
  String get aiAgentContinueConversation;

  /// No description provided for @aiAgentHistoryContinueNotice.
  ///
  /// In en, this message translates to:
  /// **'Continuing resends this conversation\'s retained, limited history to {destination}. Current server: {host}.'**
  String aiAgentHistoryContinueNotice(String destination, String host);

  /// No description provided for @aiAgentHistoryTargetChanged.
  ///
  /// In en, this message translates to:
  /// **'The model destination changed. Start a new conversation.'**
  String get aiAgentHistoryTargetChanged;

  /// No description provided for @aiAgentHistoryLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load conversation history. Try again.'**
  String get aiAgentHistoryLoadFailed;

  /// No description provided for @aiAgentHistorySaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Conversation history could not be saved. The current content is still in memory.'**
  String get aiAgentHistorySaveFailed;

  /// No description provided for @aiAgentHistoryRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get aiAgentHistoryRetry;

  /// No description provided for @aiAgentHistoryTruncated.
  ///
  /// In en, this message translates to:
  /// **'Some conversation history was trimmed to stay within storage limits.'**
  String get aiAgentHistoryTruncated;

  /// No description provided for @aiAgentHistoryOutputUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Raw tool output is not saved in history.'**
  String get aiAgentHistoryOutputUnavailable;

  /// No description provided for @aiAgentHistoryDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete conversation'**
  String get aiAgentHistoryDelete;

  /// No description provided for @aiAgentHistoryDeleteConfirm.
  ///
  /// In en, this message translates to:
  /// **'Delete this conversation and its local history?'**
  String get aiAgentHistoryDeleteConfirm;

  /// No description provided for @aiAgentHistoryBusy.
  ///
  /// In en, this message translates to:
  /// **'Stop the current task or wait for it to finish before switching conversations.'**
  String get aiAgentHistoryBusy;

  /// No description provided for @aiAgentHistoryLocalNotice.
  ///
  /// In en, this message translates to:
  /// **'Conversation text is saved locally and may contain sensitive information. Raw tool output is not saved.'**
  String get aiAgentHistoryLocalNotice;

  /// No description provided for @aiModelSearch.
  ///
  /// In en, this message translates to:
  /// **'Search models'**
  String get aiModelSearch;

  /// No description provided for @aiModelsLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load models. Retry or enter a model name.'**
  String get aiModelsLoadFailed;

  /// No description provided for @aiModelsLoadHttp.
  ///
  /// In en, this message translates to:
  /// **'The service returned HTTP {status}. Check the key and address.'**
  String aiModelsLoadHttp(String status);

  /// No description provided for @aiModelsLoadTimedOut.
  ///
  /// In en, this message translates to:
  /// **'The request timed out. Retry or enter a model name.'**
  String get aiModelsLoadTimedOut;

  /// No description provided for @aiModelCustom.
  ///
  /// In en, this message translates to:
  /// **'Use {model}'**
  String aiModelCustom(String model);

  /// No description provided for @aiModelsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No models found'**
  String get aiModelsEmpty;

  /// No description provided for @aiModelsRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh models'**
  String get aiModelsRefresh;

  /// No description provided for @aiAgentContextCompacted.
  ///
  /// In en, this message translates to:
  /// **'Earlier context was compacted to stay within the model limit.'**
  String get aiAgentContextCompacted;

  /// No description provided for @aiConfigAgentModel.
  ///
  /// In en, this message translates to:
  /// **'Default Airy model'**
  String get aiConfigAgentModel;

  /// No description provided for @aiConfigReviewModel.
  ///
  /// In en, this message translates to:
  /// **'Approval model'**
  String get aiConfigReviewModel;

  /// No description provided for @aiConfigInlineModel.
  ///
  /// In en, this message translates to:
  /// **'Inline task model'**
  String get aiConfigInlineModel;

  /// No description provided for @aiConfigPrediction.
  ///
  /// In en, this message translates to:
  /// **'Predict the next command'**
  String get aiConfigPrediction;

  /// No description provided for @aiConfigPredictionHint.
  ///
  /// In en, this message translates to:
  /// **'Back at an empty prompt, gray text suggests the next command, such as git commit after git add .; press → to accept. Needs shell integration.'**
  String get aiConfigPredictionHint;

  /// No description provided for @aiConfigCompletionModel.
  ///
  /// In en, this message translates to:
  /// **'Completion model'**
  String get aiConfigCompletionModel;

  /// No description provided for @aiConfigContextCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get aiConfigContextCustom;

  /// No description provided for @aiConfigApiKeyOptional.
  ///
  /// In en, this message translates to:
  /// **'API key (optional)'**
  String get aiConfigApiKeyOptional;

  /// No description provided for @aiConfigFeatureAdvanced.
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get aiConfigFeatureAdvanced;

  /// No description provided for @aiConfigAvailableHosts.
  ///
  /// In en, this message translates to:
  /// **'Available hosts'**
  String get aiConfigAvailableHosts;

  /// No description provided for @aiConfigFeatureNoHosts.
  ///
  /// In en, this message translates to:
  /// **'New SSH hosts will be enabled automatically.'**
  String get aiConfigFeatureNoHosts;

  /// No description provided for @aiAgentAutoTarget.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get aiAgentAutoTarget;

  /// No description provided for @aiAgentPermissionAuto.
  ///
  /// In en, this message translates to:
  /// **'Full auto'**
  String get aiAgentPermissionAuto;

  /// No description provided for @aiAgentPermissionConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get aiAgentPermissionConfirm;

  /// No description provided for @aiAgentPermissionObserve.
  ///
  /// In en, this message translates to:
  /// **'Observe'**
  String get aiAgentPermissionObserve;

  /// No description provided for @aiAgentPermissionReview.
  ///
  /// In en, this message translates to:
  /// **'Auto confirm'**
  String get aiAgentPermissionReview;

  /// No description provided for @aiAgentPermissionAutoHint.
  ///
  /// In en, this message translates to:
  /// **'Read, execute and share results automatically'**
  String get aiAgentPermissionAutoHint;

  /// No description provided for @aiAgentPermissionConfirmHint.
  ///
  /// In en, this message translates to:
  /// **'Approve reads and commands'**
  String get aiAgentPermissionConfirmHint;

  /// No description provided for @aiAgentPermissionObserveHint.
  ///
  /// In en, this message translates to:
  /// **'Read-only tools; approve reads'**
  String get aiAgentPermissionObserveHint;

  /// No description provided for @aiAgentPermissionReviewHint.
  ///
  /// In en, this message translates to:
  /// **'Model review; ask you when uncertain'**
  String get aiAgentPermissionReviewHint;

  /// No description provided for @aiAgentReviewing.
  ///
  /// In en, this message translates to:
  /// **'Approval model reviewing…'**
  String get aiAgentReviewing;

  /// No description provided for @aiAgentReadApproveTitle.
  ///
  /// In en, this message translates to:
  /// **'Approve reading information'**
  String get aiAgentReadApproveTitle;

  /// No description provided for @aiAgentReadApproveHint.
  ///
  /// In en, this message translates to:
  /// **'Run a fixed read-only diagnostic and let Airy use its bounded result.'**
  String get aiAgentReadApproveHint;

  /// No description provided for @aiAgentContentApproveHint.
  ///
  /// In en, this message translates to:
  /// **'Let Airy read this content and use its bounded result for this turn.'**
  String get aiAgentContentApproveHint;

  /// No description provided for @aiAgentActionApproveTitle.
  ///
  /// In en, this message translates to:
  /// **'Approve action'**
  String get aiAgentActionApproveTitle;

  /// No description provided for @aiAgentActionApproveHint.
  ///
  /// In en, this message translates to:
  /// **'Let Airy perform this action and use its bounded result for this turn.'**
  String get aiAgentActionApproveHint;

  /// No description provided for @aiAgentDiagnosticSystem.
  ///
  /// In en, this message translates to:
  /// **'System and memory'**
  String get aiAgentDiagnosticSystem;

  /// No description provided for @aiAgentDiagnosticStorage.
  ///
  /// In en, this message translates to:
  /// **'Storage capacity'**
  String get aiAgentDiagnosticStorage;

  /// No description provided for @aiAgentDiagnosticProcesses.
  ///
  /// In en, this message translates to:
  /// **'Process resources'**
  String get aiAgentDiagnosticProcesses;

  /// No description provided for @aiAgentDiagnosticPorts.
  ///
  /// In en, this message translates to:
  /// **'Listening ports'**
  String get aiAgentDiagnosticPorts;

  /// No description provided for @aiAgentDiagnosticServices.
  ///
  /// In en, this message translates to:
  /// **'Service states'**
  String get aiAgentDiagnosticServices;

  /// No description provided for @aiAgentContextUsage.
  ///
  /// In en, this message translates to:
  /// **'Estimated context: {percent}% · {used} / {total} tokens'**
  String aiAgentContextUsage(int percent, int used, int total);

  /// No description provided for @aiAgentRegenerate.
  ///
  /// In en, this message translates to:
  /// **'Regenerate'**
  String get aiAgentRegenerate;

  /// No description provided for @aiAgentRegenerateHint.
  ///
  /// In en, this message translates to:
  /// **'Generate another answer without running commands again'**
  String get aiAgentRegenerateHint;

  /// No description provided for @aiAgentWithdraw.
  ///
  /// In en, this message translates to:
  /// **'Withdraw last turn'**
  String get aiAgentWithdraw;

  /// No description provided for @aiAgentWithdrawHint.
  ///
  /// In en, this message translates to:
  /// **'Restore the last question as a draft. Executed operations are not undone; clear the current draft first.'**
  String get aiAgentWithdrawHint;

  /// No description provided for @aiAgentExecutionRecord.
  ///
  /// In en, this message translates to:
  /// **'Execution record'**
  String get aiAgentExecutionRecord;

  /// No description provided for @aiAgentThinkingFlow.
  ///
  /// In en, this message translates to:
  /// **'Thinking steps'**
  String get aiAgentThinkingFlow;

  /// No description provided for @aiAgentCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get aiAgentCopied;

  /// No description provided for @aiAgentCopyFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not copy. Select the text and copy manually.'**
  String get aiAgentCopyFailed;

  /// No description provided for @aiAgentToolLocalRequest.
  ///
  /// In en, this message translates to:
  /// **'Request local access'**
  String get aiAgentToolLocalRequest;

  /// No description provided for @aiAgentToolLocalList.
  ///
  /// In en, this message translates to:
  /// **'List local folder'**
  String get aiAgentToolLocalList;

  /// No description provided for @aiAgentToolLocalStat.
  ///
  /// In en, this message translates to:
  /// **'Local file info'**
  String get aiAgentToolLocalStat;

  /// No description provided for @aiAgentToolLocalRead.
  ///
  /// In en, this message translates to:
  /// **'Read local file'**
  String get aiAgentToolLocalRead;

  /// No description provided for @aiAgentToolLocalHint.
  ///
  /// In en, this message translates to:
  /// **'Use local files and folders you granted to this conversation.'**
  String get aiAgentToolLocalHint;

  /// No description provided for @aiAgentLocalFolder.
  ///
  /// In en, this message translates to:
  /// **'Folder'**
  String get aiAgentLocalFolder;

  /// No description provided for @aiAgentLocalGrantRevoke.
  ///
  /// In en, this message translates to:
  /// **'Revoke access'**
  String get aiAgentLocalGrantRevoke;

  /// No description provided for @aiAgentLocalGrantWrite.
  ///
  /// In en, this message translates to:
  /// **'{name} · writable'**
  String aiAgentLocalGrantWrite(String name);

  /// No description provided for @aiAgentLocalGrantExpired.
  ///
  /// In en, this message translates to:
  /// **'This local access has expired. Attach or grant it again.'**
  String get aiAgentLocalGrantExpired;

  /// No description provided for @aiAgentLocalAccessTitle.
  ///
  /// In en, this message translates to:
  /// **'Allow access to local files'**
  String get aiAgentLocalAccessTitle;

  /// No description provided for @aiAgentLocalAccessFolder.
  ///
  /// In en, this message translates to:
  /// **'Airy asks to read a folder in this conversation.'**
  String get aiAgentLocalAccessFolder;

  /// No description provided for @aiAgentLocalAccessFile.
  ///
  /// In en, this message translates to:
  /// **'Airy asks to read a file in this conversation.'**
  String get aiAgentLocalAccessFile;

  /// No description provided for @aiAgentLocalAccessWrite.
  ///
  /// In en, this message translates to:
  /// **'Airy asks to read and write a folder in this conversation. Files from servers may be saved into it.'**
  String get aiAgentLocalAccessWrite;

  /// No description provided for @aiAgentLocalAccessChooseFolder.
  ///
  /// In en, this message translates to:
  /// **'Choose folder'**
  String get aiAgentLocalAccessChooseFolder;

  /// No description provided for @aiAgentLocalAccessChooseFile.
  ///
  /// In en, this message translates to:
  /// **'Choose file'**
  String get aiAgentLocalAccessChooseFile;

  /// No description provided for @mcpTitle.
  ///
  /// In en, this message translates to:
  /// **'MCP / Skills'**
  String get mcpTitle;

  /// No description provided for @mcpChangeFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not save the change.'**
  String get mcpChangeFailed;

  /// No description provided for @mcpStartFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not start MCP. Check the port and system credential storage.'**
  String get mcpStartFailed;

  /// No description provided for @mcpModeModel.
  ///
  /// In en, this message translates to:
  /// **'Model review'**
  String get mcpModeModel;

  /// No description provided for @mcpModeHost.
  ///
  /// In en, this message translates to:
  /// **'Confirm hosts'**
  String get mcpModeHost;

  /// No description provided for @mcpModeAuto.
  ///
  /// In en, this message translates to:
  /// **'Automatic within scope'**
  String get mcpModeAuto;

  /// No description provided for @mcpModeModelHint.
  ///
  /// In en, this message translates to:
  /// **'You confirm each host on its first use in a session, then the review model checks every call. Calls it denies or cannot judge are not run.'**
  String get mcpModeModelHint;

  /// No description provided for @mcpModeHostHint.
  ///
  /// In en, this message translates to:
  /// **'Confirm each host once per session. Calls on approved hosts need no per-call review.'**
  String get mcpModeHostHint;

  /// No description provided for @mcpModeAutoHint.
  ///
  /// In en, this message translates to:
  /// **'Calls on the hosts you select run without host confirmation or model review.'**
  String get mcpModeAutoHint;

  /// No description provided for @mcpScopeHosts.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No hosts} =1{1 host} other{{count} hosts}}'**
  String mcpScopeHosts(int count);

  /// No description provided for @mcpAudit.
  ///
  /// In en, this message translates to:
  /// **'MCP audit'**
  String get mcpAudit;

  /// No description provided for @mcpAuditEmpty.
  ///
  /// In en, this message translates to:
  /// **'No MCP calls recorded.'**
  String get mcpAuditEmpty;

  /// No description provided for @mcpAuditCompleted.
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get mcpAuditCompleted;

  /// No description provided for @mcpAuditRunning.
  ///
  /// In en, this message translates to:
  /// **'In progress'**
  String get mcpAuditRunning;

  /// No description provided for @mcpAuditCancelled.
  ///
  /// In en, this message translates to:
  /// **'Cancelled'**
  String get mcpAuditCancelled;

  /// No description provided for @mcpAuditHostDenied.
  ///
  /// In en, this message translates to:
  /// **'Host not allowed'**
  String get mcpAuditHostDenied;

  /// No description provided for @mcpAuditReviewDenied.
  ///
  /// In en, this message translates to:
  /// **'Denied by the review model'**
  String get mcpAuditReviewDenied;

  /// No description provided for @mcpAuditReviewUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Review model unavailable'**
  String get mcpAuditReviewUnavailable;

  /// No description provided for @mcpAuditOutsideScope.
  ///
  /// In en, this message translates to:
  /// **'Host outside scope'**
  String get mcpAuditOutsideScope;

  /// No description provided for @mcpAuditScopeChanged.
  ///
  /// In en, this message translates to:
  /// **'Access changed during the call'**
  String get mcpAuditScopeChanged;

  /// No description provided for @mcpAuditNotExposed.
  ///
  /// In en, this message translates to:
  /// **'Tool not available'**
  String get mcpAuditNotExposed;

  /// No description provided for @mcpAuditInvalid.
  ///
  /// In en, this message translates to:
  /// **'Invalid arguments'**
  String get mcpAuditInvalid;

  /// No description provided for @mcpAuditFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed ({code})'**
  String mcpAuditFailed(String code);

  /// No description provided for @mcpClientConflict.
  ///
  /// In en, this message translates to:
  /// **'Existing configuration kept'**
  String get mcpClientConflict;

  /// No description provided for @mcpClientUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Client configuration unavailable'**
  String get mcpClientUnavailable;

  /// No description provided for @mcpConnectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Allow MCP connection'**
  String get mcpConnectionTitle;

  /// No description provided for @mcpConnectionPrompt.
  ///
  /// In en, this message translates to:
  /// **'Allow {client} to use the Airy tools in Sshairy?'**
  String mcpConnectionPrompt(String client);

  /// No description provided for @mcpTerminalHistoryPrompt.
  ///
  /// In en, this message translates to:
  /// **'Allow {client} to read recent commands and results from {terminal} in this MCP session?'**
  String mcpTerminalHistoryPrompt(String client, String terminal);

  /// No description provided for @mcpTerminalScreenPrompt.
  ///
  /// In en, this message translates to:
  /// **'Allow {client} to read up to {maxLines} visible lines from {terminal} now?'**
  String mcpTerminalScreenPrompt(String client, String terminal, int maxLines);

  /// No description provided for @mcpWorkspacePrompt.
  ///
  /// In en, this message translates to:
  /// **'Allow {client} to perform this action on these windows?\n{windows}'**
  String mcpWorkspacePrompt(String client, String windows);

  /// No description provided for @mcpLocalPrompt.
  ///
  /// In en, this message translates to:
  /// **'{client} is requesting local file access.'**
  String mcpLocalPrompt(String client);

  /// No description provided for @mcpHostPrompt.
  ///
  /// In en, this message translates to:
  /// **'Allow {client} to access {host} for this MCP session?'**
  String mcpHostPrompt(String client, String host);

  /// No description provided for @mcpPortSave.
  ///
  /// In en, this message translates to:
  /// **'Save port'**
  String get mcpPortSave;

  /// No description provided for @mcpScopeChanged.
  ///
  /// In en, this message translates to:
  /// **'{host} (connection changed, select again)'**
  String mcpScopeChanged(String host);

  /// No description provided for @linkTitle.
  ///
  /// In en, this message translates to:
  /// **'Device Link'**
  String get linkTitle;

  /// No description provided for @linkTab.
  ///
  /// In en, this message translates to:
  /// **'Link'**
  String get linkTab;

  /// No description provided for @linkEnabled.
  ///
  /// In en, this message translates to:
  /// **'Enable desktop link'**
  String get linkEnabled;

  /// No description provided for @linkPort.
  ///
  /// In en, this message translates to:
  /// **'Link port'**
  String get linkPort;

  /// No description provided for @linkDiscovery.
  ///
  /// In en, this message translates to:
  /// **'LAN discovery'**
  String get linkDiscovery;

  /// No description provided for @linkDeviceName.
  ///
  /// In en, this message translates to:
  /// **'Device name'**
  String get linkDeviceName;

  /// No description provided for @linkAddresses.
  ///
  /// In en, this message translates to:
  /// **'LAN addresses'**
  String get linkAddresses;

  /// No description provided for @linkRunning.
  ///
  /// In en, this message translates to:
  /// **'Listening on port {port}'**
  String linkRunning(int port);

  /// No description provided for @linkStopped.
  ///
  /// In en, this message translates to:
  /// **'Stopped'**
  String get linkStopped;

  /// No description provided for @linkStartFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not start link listener'**
  String get linkStartFailed;

  /// No description provided for @linkPairDevice.
  ///
  /// In en, this message translates to:
  /// **'Pair device'**
  String get linkPairDevice;

  /// No description provided for @linkCancelPairing.
  ///
  /// In en, this message translates to:
  /// **'Cancel pairing'**
  String get linkCancelPairing;

  /// No description provided for @linkPairingCode.
  ///
  /// In en, this message translates to:
  /// **'Pairing code'**
  String get linkPairingCode;

  /// No description provided for @linkCopyUri.
  ///
  /// In en, this message translates to:
  /// **'Copy pairing URI'**
  String get linkCopyUri;

  /// No description provided for @linkCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get linkCopied;

  /// No description provided for @linkPairedDevices.
  ///
  /// In en, this message translates to:
  /// **'Paired devices'**
  String get linkPairedDevices;

  /// No description provided for @linkNoPeers.
  ///
  /// In en, this message translates to:
  /// **'No paired devices yet.'**
  String get linkNoPeers;

  /// No description provided for @linkOnline.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get linkOnline;

  /// No description provided for @linkOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get linkOffline;

  /// No description provided for @linkPermMirror.
  ///
  /// In en, this message translates to:
  /// **'Terminal mirror'**
  String get linkPermMirror;

  /// No description provided for @linkPermProxy.
  ///
  /// In en, this message translates to:
  /// **'Proxy SSH'**
  String get linkPermProxy;

  /// No description provided for @linkPermSync.
  ///
  /// In en, this message translates to:
  /// **'Config sync'**
  String get linkPermSync;

  /// No description provided for @linkPermApproval.
  ///
  /// In en, this message translates to:
  /// **'Remote approval'**
  String get linkPermApproval;

  /// No description provided for @linkRevoke.
  ///
  /// In en, this message translates to:
  /// **'Unpair'**
  String get linkRevoke;

  /// No description provided for @linkDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Disconnect'**
  String get linkDisconnect;

  /// No description provided for @linkPushCredentials.
  ///
  /// In en, this message translates to:
  /// **'Push credentials'**
  String get linkPushCredentials;

  /// No description provided for @linkPushCredentialsTitle.
  ///
  /// In en, this message translates to:
  /// **'Push credentials to {device}'**
  String linkPushCredentialsTitle(String device);

  /// No description provided for @linkPushCredentialsSent.
  ///
  /// In en, this message translates to:
  /// **'Encrypted credentials sent to {device}'**
  String linkPushCredentialsSent(String device);

  /// No description provided for @linkPushCredentialsEmpty.
  ///
  /// In en, this message translates to:
  /// **'Select at least one host password or key.'**
  String get linkPushCredentialsEmpty;

  /// No description provided for @linkScanLan.
  ///
  /// In en, this message translates to:
  /// **'Scan LAN'**
  String get linkScanLan;

  /// No description provided for @linkScanning.
  ///
  /// In en, this message translates to:
  /// **'Scanning...'**
  String get linkScanning;

  /// No description provided for @linkDiscoveredDesktops.
  ///
  /// In en, this message translates to:
  /// **'Nearby desktops'**
  String get linkDiscoveredDesktops;

  /// No description provided for @linkSavedDesktops.
  ///
  /// In en, this message translates to:
  /// **'Saved desktops'**
  String get linkSavedDesktops;

  /// No description provided for @linkManualConnect.
  ///
  /// In en, this message translates to:
  /// **'Pair with desktop'**
  String get linkManualConnect;

  /// No description provided for @linkHostOrIp.
  ///
  /// In en, this message translates to:
  /// **'Desktop IP / Tailscale IP'**
  String get linkHostOrIp;

  /// No description provided for @linkPasteUri.
  ///
  /// In en, this message translates to:
  /// **'Paste pairing URI'**
  String get linkPasteUri;

  /// No description provided for @linkPairNow.
  ///
  /// In en, this message translates to:
  /// **'Pair'**
  String get linkPairNow;

  /// No description provided for @linkReconnect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get linkReconnect;

  /// No description provided for @linkConnectedTo.
  ///
  /// In en, this message translates to:
  /// **'Linked with {desktop}'**
  String linkConnectedTo(String desktop);

  /// No description provided for @linkSyncConfig.
  ///
  /// In en, this message translates to:
  /// **'Sync config'**
  String get linkSyncConfig;

  /// No description provided for @linkSyncDone.
  ///
  /// In en, this message translates to:
  /// **'Synced {hosts} hosts, {snippets} snippets, +{keys} keys'**
  String linkSyncDone(int hosts, int snippets, int keys);

  /// No description provided for @linkPendingApprovals.
  ///
  /// In en, this message translates to:
  /// **'Pending approvals'**
  String get linkPendingApprovals;

  /// No description provided for @linkDesktopOnlyAction.
  ///
  /// In en, this message translates to:
  /// **'Complete on desktop'**
  String get linkDesktopOnlyAction;

  /// No description provided for @linkAllow.
  ///
  /// In en, this message translates to:
  /// **'Allow'**
  String get linkAllow;

  /// No description provided for @linkDeny.
  ///
  /// In en, this message translates to:
  /// **'Deny'**
  String get linkDeny;

  /// No description provided for @linkDesktopTerminals.
  ///
  /// In en, this message translates to:
  /// **'Desktop terminals'**
  String get linkDesktopTerminals;

  /// No description provided for @linkNoDesktopTerminals.
  ///
  /// In en, this message translates to:
  /// **'No open terminals on desktop.'**
  String get linkNoDesktopTerminals;

  /// No description provided for @linkMirrorTag.
  ///
  /// In en, this message translates to:
  /// **'Mirror'**
  String get linkMirrorTag;

  /// No description provided for @linkProxyTag.
  ///
  /// In en, this message translates to:
  /// **'Via desktop'**
  String get linkProxyTag;

  /// No description provided for @linkDesktopHosts.
  ///
  /// In en, this message translates to:
  /// **'Connect via desktop'**
  String get linkDesktopHosts;

  /// No description provided for @linkNoDesktopHosts.
  ///
  /// In en, this message translates to:
  /// **'No saved hosts on desktop.'**
  String get linkNoDesktopHosts;

  /// No description provided for @linkCredentialOfferTitle.
  ///
  /// In en, this message translates to:
  /// **'Desktop sent encrypted credentials'**
  String get linkCredentialOfferTitle;

  /// No description provided for @linkCredentialOfferDetail.
  ///
  /// In en, this message translates to:
  /// **'{passwords} passwords, {keys} private keys'**
  String linkCredentialOfferDetail(int passwords, int keys);

  /// No description provided for @linkCredentialImport.
  ///
  /// In en, this message translates to:
  /// **'Save to keystore'**
  String get linkCredentialImport;

  /// No description provided for @linkCredentialImported.
  ///
  /// In en, this message translates to:
  /// **'Saved {count} credentials'**
  String linkCredentialImported(int count);

  /// No description provided for @linkPasswordSyncConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Confirm server password sync'**
  String get linkPasswordSyncConfirmTitle;

  /// No description provided for @linkPasswordSyncConfirmBody.
  ///
  /// In en, this message translates to:
  /// **'{device} requested {count} saved server passwords.'**
  String linkPasswordSyncConfirmBody(String device, int count);

  /// No description provided for @linkPasswordSyncAllow.
  ///
  /// In en, this message translates to:
  /// **'Sync passwords'**
  String get linkPasswordSyncAllow;

  /// No description provided for @linkPasswordSyncSkip.
  ///
  /// In en, this message translates to:
  /// **'Skip passwords'**
  String get linkPasswordSyncSkip;

  /// No description provided for @linkPasswordSyncWaiting.
  ///
  /// In en, this message translates to:
  /// **'Confirm password sync on desktop…'**
  String get linkPasswordSyncWaiting;

  /// No description provided for @linkPasswordSyncImported.
  ///
  /// In en, this message translates to:
  /// **'Synced {count} server passwords'**
  String linkPasswordSyncImported(int count);

  /// No description provided for @linkPasswordSyncDeclined.
  ///
  /// In en, this message translates to:
  /// **'Password sync skipped on desktop'**
  String get linkPasswordSyncDeclined;

  /// No description provided for @linkErrorAuth.
  ///
  /// In en, this message translates to:
  /// **'Authentication failed'**
  String get linkErrorAuth;

  /// No description provided for @linkErrorCode.
  ///
  /// In en, this message translates to:
  /// **'Invalid pairing code'**
  String get linkErrorCode;

  /// No description provided for @linkErrorExpired.
  ///
  /// In en, this message translates to:
  /// **'Pairing code expired'**
  String get linkErrorExpired;

  /// No description provided for @linkErrorRevoked.
  ///
  /// In en, this message translates to:
  /// **'Device unpaired on desktop'**
  String get linkErrorRevoked;

  /// No description provided for @linkErrorNetwork.
  ///
  /// In en, this message translates to:
  /// **'Cannot reach desktop'**
  String get linkErrorNetwork;

  /// No description provided for @mobileNoActiveTerminal.
  ///
  /// In en, this message translates to:
  /// **'No active terminal'**
  String get mobileNoActiveTerminal;

  /// No description provided for @mobileSessions.
  ///
  /// In en, this message translates to:
  /// **'Sessions'**
  String get mobileSessions;

  /// No description provided for @mobileTools.
  ///
  /// In en, this message translates to:
  /// **'Tools'**
  String get mobileTools;

  /// No description provided for @mobileTabAiry.
  ///
  /// In en, this message translates to:
  /// **'Airy'**
  String get mobileTabAiry;

  /// No description provided for @mobileTabMe.
  ///
  /// In en, this message translates to:
  /// **'Me'**
  String get mobileTabMe;

  /// No description provided for @mobileScanQr.
  ///
  /// In en, this message translates to:
  /// **'Scan desktop QR'**
  String get mobileScanQr;

  /// No description provided for @mobileScanQrHint.
  ///
  /// In en, this message translates to:
  /// **'Point at the pairing QR code on Sshairy desktop'**
  String get mobileScanQrHint;

  /// No description provided for @mobileHandoffToDesktop.
  ///
  /// In en, this message translates to:
  /// **'Open on desktop'**
  String get mobileHandoffToDesktop;

  /// No description provided for @mobileHandoffSent.
  ///
  /// In en, this message translates to:
  /// **'Opened on desktop'**
  String get mobileHandoffSent;

  /// No description provided for @mobilePushClipboard.
  ///
  /// In en, this message translates to:
  /// **'Send clipboard'**
  String get mobilePushClipboard;

  /// No description provided for @mobileClipboardSent.
  ///
  /// In en, this message translates to:
  /// **'Sent clipboard to desktop'**
  String get mobileClipboardSent;

  /// No description provided for @mobileDirectTag.
  ///
  /// In en, this message translates to:
  /// **'Direct'**
  String get mobileDirectTag;

  /// No description provided for @mobileKeepScreenOn.
  ///
  /// In en, this message translates to:
  /// **'Keep screen awake'**
  String get mobileKeepScreenOn;

  /// No description provided for @mobileKeepAlive.
  ///
  /// In en, this message translates to:
  /// **'Background keep-alive'**
  String get mobileKeepAlive;

  /// No description provided for @mobileKeepAliveTitle.
  ///
  /// In en, this message translates to:
  /// **'Sshairy active'**
  String get mobileKeepAliveTitle;

  /// No description provided for @mobileKeepAliveSubtitle.
  ///
  /// In en, this message translates to:
  /// **'{count} active sessions'**
  String mobileKeepAliveSubtitle(int count);

  /// No description provided for @mobileHaptics.
  ///
  /// In en, this message translates to:
  /// **'Haptic feedback'**
  String get mobileHaptics;

  /// No description provided for @mobileBiometricLock.
  ///
  /// In en, this message translates to:
  /// **'Biometric lock'**
  String get mobileBiometricLock;

  /// No description provided for @mobileUnlockPrompt.
  ///
  /// In en, this message translates to:
  /// **'Unlock Sshairy'**
  String get mobileUnlockPrompt;

  /// No description provided for @mobileUnlockAction.
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get mobileUnlockAction;

  /// No description provided for @mobileTrackpad.
  ///
  /// In en, this message translates to:
  /// **'Trackpad'**
  String get mobileTrackpad;

  /// No description provided for @mobileDraftMode.
  ///
  /// In en, this message translates to:
  /// **'Command bar'**
  String get mobileDraftMode;

  /// No description provided for @mobileDraftPlaceholder.
  ///
  /// In en, this message translates to:
  /// **'Type command or ask Airy…'**
  String get mobileDraftPlaceholder;

  /// No description provided for @mobileAskAiry.
  ///
  /// In en, this message translates to:
  /// **'Ask Airy'**
  String get mobileAskAiry;

  /// No description provided for @mobileSyncAiFromDesktop.
  ///
  /// In en, this message translates to:
  /// **'Sync AI from desktop'**
  String get mobileSyncAiFromDesktop;

  /// No description provided for @mobileAiQuickSystem.
  ///
  /// In en, this message translates to:
  /// **'CPU & Memory'**
  String get mobileAiQuickSystem;

  /// No description provided for @mobileAiQuickDisk.
  ///
  /// In en, this message translates to:
  /// **'Disk usage'**
  String get mobileAiQuickDisk;

  /// No description provided for @mobileAiQuickLogs.
  ///
  /// In en, this message translates to:
  /// **'Recent errors'**
  String get mobileAiQuickLogs;

  /// No description provided for @mobileAiQuickPorts.
  ///
  /// In en, this message translates to:
  /// **'Open ports'**
  String get mobileAiQuickPorts;

  /// No description provided for @mobileFileEditor.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get mobileFileEditor;

  /// No description provided for @mobileFileSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved'**
  String get mobileFileSaved;

  /// No description provided for @mobileFileTooLarge.
  ///
  /// In en, this message translates to:
  /// **'File is too large for inline editor'**
  String get mobileFileTooLarge;

  /// No description provided for @mobileSendPathToTerminal.
  ///
  /// In en, this message translates to:
  /// **'Send path to terminal'**
  String get mobileSendPathToTerminal;

  /// No description provided for @mobileNewFile.
  ///
  /// In en, this message translates to:
  /// **'New file'**
  String get mobileNewFile;

  /// No description provided for @mobileNewFolder.
  ///
  /// In en, this message translates to:
  /// **'New folder'**
  String get mobileNewFolder;

  /// No description provided for @mobileUploadFile.
  ///
  /// In en, this message translates to:
  /// **'Upload file'**
  String get mobileUploadFile;

  /// No description provided for @mobileThisPhone.
  ///
  /// In en, this message translates to:
  /// **'This phone'**
  String get mobileThisPhone;

  /// No description provided for @linkSharePhoneFiles.
  ///
  /// In en, this message translates to:
  /// **'Share phone files'**
  String get linkSharePhoneFiles;

  /// No description provided for @mobileGenerateKey.
  ///
  /// In en, this message translates to:
  /// **'Generate Ed25519 key'**
  String get mobileGenerateKey;

  /// No description provided for @mobilePublicKeyCopied.
  ///
  /// In en, this message translates to:
  /// **'Public key copied'**
  String get mobilePublicKeyCopied;

  /// No description provided for @mobileSecuritySection.
  ///
  /// In en, this message translates to:
  /// **'Security & background'**
  String get mobileSecuritySection;

  /// No description provided for @mobileTerminalSection.
  ///
  /// In en, this message translates to:
  /// **'Terminal & touch'**
  String get mobileTerminalSection;

  /// No description provided for @mobileQuickConnect.
  ///
  /// In en, this message translates to:
  /// **'Quick connect'**
  String get mobileQuickConnect;

  /// No description provided for @mobileAllGroups.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get mobileAllGroups;

  /// No description provided for @mobilePinned.
  ///
  /// In en, this message translates to:
  /// **'Pinned'**
  String get mobilePinned;

  /// No description provided for @mobileSyncAiIncluded.
  ///
  /// In en, this message translates to:
  /// **'+ AI config'**
  String get mobileSyncAiIncluded;
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
