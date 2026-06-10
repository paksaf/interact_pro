import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ur.dart';

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
    Locale('ur')
  ];

  /// App name
  ///
  /// In en, this message translates to:
  /// **'Interact Pro'**
  String get appTitle;

  /// No description provided for @navRecent.
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get navRecent;

  /// No description provided for @navOcr.
  ///
  /// In en, this message translates to:
  /// **'OCR'**
  String get navOcr;

  /// No description provided for @navScan.
  ///
  /// In en, this message translates to:
  /// **'Scan'**
  String get navScan;

  /// No description provided for @navDrive.
  ///
  /// In en, this message translates to:
  /// **'Drive'**
  String get navDrive;

  /// No description provided for @homeImportPdf.
  ///
  /// In en, this message translates to:
  /// **'Import PDF'**
  String get homeImportPdf;

  /// No description provided for @homeUpgrade.
  ///
  /// In en, this message translates to:
  /// **'Upgrade'**
  String get homeUpgrade;

  /// No description provided for @homeNoDocuments.
  ///
  /// In en, this message translates to:
  /// **'No documents yet'**
  String get homeNoDocuments;

  /// No description provided for @homeNoDocumentsHint.
  ///
  /// In en, this message translates to:
  /// **'Tap \"Import PDF\" to add one.'**
  String get homeNoDocumentsHint;

  /// No description provided for @tooltipSearch.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get tooltipSearch;

  /// No description provided for @tooltipSettings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get tooltipSettings;

  /// No description provided for @tooltipIdentifyImage.
  ///
  /// In en, this message translates to:
  /// **'Identify image'**
  String get tooltipIdentifyImage;

  /// No description provided for @tooltipConverter.
  ///
  /// In en, this message translates to:
  /// **'Unit converter'**
  String get tooltipConverter;

  /// No description provided for @viewerSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search in document'**
  String get viewerSearchHint;

  /// No description provided for @tooltipUndoLastChange.
  ///
  /// In en, this message translates to:
  /// **'Undo last change'**
  String get tooltipUndoLastChange;

  /// No description provided for @tooltipAddSignature.
  ///
  /// In en, this message translates to:
  /// **'Add signature'**
  String get tooltipAddSignature;

  /// No description provided for @tooltipAddStamp.
  ///
  /// In en, this message translates to:
  /// **'Add stamp'**
  String get tooltipAddStamp;

  /// No description provided for @tooltipOpenInEditor.
  ///
  /// In en, this message translates to:
  /// **'Open in editor'**
  String get tooltipOpenInEditor;

  /// No description provided for @tooltipMore.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get tooltipMore;

  /// No description provided for @toolSelect.
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get toolSelect;

  /// No description provided for @toolHighlight.
  ///
  /// In en, this message translates to:
  /// **'Highlight'**
  String get toolHighlight;

  /// No description provided for @toolSign.
  ///
  /// In en, this message translates to:
  /// **'Sign'**
  String get toolSign;

  /// No description provided for @toolStamp.
  ///
  /// In en, this message translates to:
  /// **'Stamp'**
  String get toolStamp;

  /// No description provided for @toolEdit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get toolEdit;

  /// No description provided for @menuRunOcr.
  ///
  /// In en, this message translates to:
  /// **'Run OCR on this PDF'**
  String get menuRunOcr;

  /// No description provided for @menuMergePdfs.
  ///
  /// In en, this message translates to:
  /// **'Merge with another PDF'**
  String get menuMergePdfs;

  /// No description provided for @menuSplitPdf.
  ///
  /// In en, this message translates to:
  /// **'Split PDF (extract pages)'**
  String get menuSplitPdf;

  /// No description provided for @menuAddWatermark.
  ///
  /// In en, this message translates to:
  /// **'Add watermark to every page'**
  String get menuAddWatermark;

  /// No description provided for @menuTranslate.
  ///
  /// In en, this message translates to:
  /// **'Translate'**
  String get menuTranslate;

  /// No description provided for @menuReadAloud.
  ///
  /// In en, this message translates to:
  /// **'Read aloud'**
  String get menuReadAloud;

  /// No description provided for @menuStopReading.
  ///
  /// In en, this message translates to:
  /// **'Stop reading'**
  String get menuStopReading;

  /// No description provided for @menuPrint.
  ///
  /// In en, this message translates to:
  /// **'Print'**
  String get menuPrint;

  /// No description provided for @menuSendToNearby.
  ///
  /// In en, this message translates to:
  /// **'Send to nearby device'**
  String get menuSendToNearby;

  /// No description provided for @menuSaveToDrive.
  ///
  /// In en, this message translates to:
  /// **'Save to Drive'**
  String get menuSaveToDrive;

  /// No description provided for @menuAddHotspot.
  ///
  /// In en, this message translates to:
  /// **'Add hotspot'**
  String get menuAddHotspot;

  /// No description provided for @menuShowHotspots.
  ///
  /// In en, this message translates to:
  /// **'Show hotspots'**
  String get menuShowHotspots;

  /// No description provided for @menuShare.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get menuShare;

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsHelpAndFeedback.
  ///
  /// In en, this message translates to:
  /// **'Help & Feedback'**
  String get settingsHelpAndFeedback;

  /// No description provided for @settingsCrossDevice.
  ///
  /// In en, this message translates to:
  /// **'Cross-device'**
  String get settingsCrossDevice;

  /// No description provided for @settingsSignedDocuments.
  ///
  /// In en, this message translates to:
  /// **'Signed documents'**
  String get settingsSignedDocuments;

  /// No description provided for @settingsPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Privacy'**
  String get settingsPrivacy;

  /// No description provided for @settingsSubscription.
  ///
  /// In en, this message translates to:
  /// **'Subscription'**
  String get settingsSubscription;

  /// No description provided for @settingsAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsAbout;

  /// No description provided for @settingsLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguage;

  /// No description provided for @settingsLanguageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get settingsLanguageEnglish;

  /// No description provided for @settingsLanguageUrdu.
  ///
  /// In en, this message translates to:
  /// **'اردو (Urdu)'**
  String get settingsLanguageUrdu;

  /// No description provided for @actionCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get actionCancel;

  /// No description provided for @actionSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get actionSave;

  /// No description provided for @actionDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get actionDelete;

  /// No description provided for @actionDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get actionDone;

  /// No description provided for @actionSignOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get actionSignOut;

  /// No description provided for @actionHome.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get actionHome;

  /// No description provided for @actionSendCode.
  ///
  /// In en, this message translates to:
  /// **'Send code'**
  String get actionSendCode;

  /// No description provided for @actionSending.
  ///
  /// In en, this message translates to:
  /// **'Sending…'**
  String get actionSending;

  /// No description provided for @actionContinueWithoutAccount.
  ///
  /// In en, this message translates to:
  /// **'Continue without an account'**
  String get actionContinueWithoutAccount;

  /// No description provided for @scanModeDocument.
  ///
  /// In en, this message translates to:
  /// **'Document'**
  String get scanModeDocument;

  /// No description provided for @scanModeRead.
  ///
  /// In en, this message translates to:
  /// **'Read'**
  String get scanModeRead;

  /// No description provided for @scanModeGenerate.
  ///
  /// In en, this message translates to:
  /// **'Generate'**
  String get scanModeGenerate;

  /// No description provided for @scanModeHistory.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get scanModeHistory;

  /// No description provided for @loginAlreadySignedIn.
  ///
  /// In en, this message translates to:
  /// **'Already signed in'**
  String get loginAlreadySignedIn;

  /// No description provided for @loginSignedOutNotice.
  ///
  /// In en, this message translates to:
  /// **'Signed out — sign in with a different account'**
  String get loginSignedOutNotice;

  /// No description provided for @loginWelcome.
  ///
  /// In en, this message translates to:
  /// **'Welcome to Interact Pro'**
  String get loginWelcome;

  /// No description provided for @loginWelcomeBlurb.
  ///
  /// In en, this message translates to:
  /// **'Sign in to save your library to the cloud, sync across devices, and unlock Pro features.'**
  String get loginWelcomeBlurb;

  /// No description provided for @loginTabEmail.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get loginTabEmail;

  /// No description provided for @loginTabPhone.
  ///
  /// In en, this message translates to:
  /// **'Phone'**
  String get loginTabPhone;

  /// No description provided for @loginEmailLabel.
  ///
  /// In en, this message translates to:
  /// **'Email address'**
  String get loginEmailLabel;

  /// No description provided for @loginPhoneLabel.
  ///
  /// In en, this message translates to:
  /// **'Phone number (with country code)'**
  String get loginPhoneLabel;

  /// No description provided for @loginPhoneHint.
  ///
  /// In en, this message translates to:
  /// **'+92 300 1234567'**
  String get loginPhoneHint;

  /// No description provided for @loginErrorEmptyContact.
  ///
  /// In en, this message translates to:
  /// **'Enter an email or phone number'**
  String get loginErrorEmptyContact;

  /// No description provided for @loginTrialBlurb.
  ///
  /// In en, this message translates to:
  /// **'Free 7-day trial. Pro unlocks AI handwriting, vision LLM, cloud sync, and extra storage.'**
  String get loginTrialBlurb;
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
      <String>['en', 'ur'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ur':
      return AppLocalizationsUr();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
