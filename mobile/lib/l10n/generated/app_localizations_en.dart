// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class L10nEn extends L10n {
  L10nEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'HumTrack';

  @override
  String get ok => 'OK';

  @override
  String get cancel => 'Cancel';

  @override
  String get save => 'Save';

  @override
  String get delete => 'Delete';

  @override
  String get rename => 'Rename';

  @override
  String get later => 'Later';

  @override
  String get retry => 'Retry';

  @override
  String get close => 'Close';

  @override
  String get done => 'Done';

  @override
  String get apply => 'Apply';

  @override
  String get use => 'Use';

  @override
  String get tabSongs => 'My Songs';

  @override
  String get tabCloud => 'Cloud';

  @override
  String get navStudio => 'STUDIO';

  @override
  String get navSongs => 'SONGS';

  @override
  String get navMixer => 'MIXER';

  @override
  String get actionUpgradeToPro => 'Upgrade to Pro';

  @override
  String get freeCloudHeadline => 'You don\'t have a Cloud yet';

  @override
  String freeCloudSub(int gb) {
    return 'Get ${gb}GB of Cloud with Pro\nto continue your songs on every device.';
  }

  @override
  String valueCloudStorage(int gb) {
    return '${gb}GB Cloud storage';
  }

  @override
  String get valueExportUnlimited => 'Unlimited export';

  @override
  String get valueAnalysisPriority => 'Priority analysis';

  @override
  String get valuePersistentVocal => 'Permanent backup';

  @override
  String get trialStartCta => 'Start 7-day free trial';

  @override
  String trialPriceFootnote(String price) {
    return '$price/month after trial';
  }

  @override
  String cloudUsageLabel(String used, String total) {
    return '$used of $total used';
  }

  @override
  String get projectActionUploadToCloud => 'Upload to Cloud';

  @override
  String get projectActionRefreshCloud => 'Update Cloud';

  @override
  String get projectActionDownloadFromCloud => 'Download to this device';

  @override
  String get projectActionDeleteFromCloud => 'Delete from Cloud only';

  @override
  String get projectActionDeleteFromCloudSub =>
      'Your local copy stays untouched';

  @override
  String get syncInProgress => 'Uploading to Cloud...';

  @override
  String get downloadInProgress => 'Downloading to this device...';

  @override
  String get syncFailed => 'Sync failed — tap to retry';

  @override
  String get settingsCloudHeader => 'My Cloud';

  @override
  String get settingsAutoSync => 'Auto sync';

  @override
  String get settingsAutoSyncDesc =>
      'Automatically upload changed songs to Cloud';

  @override
  String get menuLanguage => 'Language';

  @override
  String get languageScreenTitle => 'Language';

  @override
  String get languageSystemDefault => 'System default';

  @override
  String get languageSystemDefaultSub => 'Follow device setting';

  @override
  String get languageNameKorean => '한국어';

  @override
  String get languageNameEnglish => 'English';

  @override
  String get songsTitle => 'Songs';

  @override
  String get songsEmptyTitle => 'Start a new song';

  @override
  String get songsEmptySub =>
      'Hum it and we\'ll turn it into instruments — record and edit in one place';

  @override
  String get songsEmptyCta => 'Start';

  @override
  String get songsCardInCloud => 'On Cloud';

  @override
  String songsTrackCountChip(int count) {
    return '$count tracks';
  }

  @override
  String projectDurationLabel(int min, String sec) {
    return '${min}m ${sec}s';
  }

  @override
  String get agoJustNow => 'Just now';

  @override
  String agoMinutes(int n) {
    return '${n}m ago';
  }

  @override
  String agoHours(int n) {
    return '${n}h ago';
  }

  @override
  String agoDays(int n) {
    return '${n}d ago';
  }

  @override
  String get agoJustUploaded => 'Just uploaded';

  @override
  String agoMonthDay(int month, int day) {
    return '$month/$day';
  }

  @override
  String get agoJustEdited => 'Just edited';

  @override
  String agoSecondsAgo(int n) {
    return '${n}s ago';
  }

  @override
  String get accountTitle => 'Account';

  @override
  String get accountNotSignedIn => 'Not signed in';

  @override
  String accountProviderSuffix(String provider) {
    return '$provider account';
  }

  @override
  String get accountLinked => 'Account linked';

  @override
  String get accountSignInHint => 'Sign in to unlock billing and sync';

  @override
  String get accountSignIn => 'Sign in';

  @override
  String get subFreePlan => 'Free plan';

  @override
  String get subFreePlanSub => 'Export and unlimited songs unlock with Pro';

  @override
  String get subTrial => 'Free trial';

  @override
  String subTrialBillsOn(String date) {
    return 'Billing starts on $date';
  }

  @override
  String subTrialNDays(int days) {
    return '$days-day trial';
  }

  @override
  String get subActive => 'Humming Pro';

  @override
  String subActiveRenewsOn(String date) {
    return 'Renews on $date';
  }

  @override
  String get subActiveAllOn => 'All features unlocked';

  @override
  String get subCancelled => 'Pro · cancellation scheduled';

  @override
  String subCancelledValidUntil(String date) {
    return 'Active until $date';
  }

  @override
  String get subCancelledUntilExpiry => 'Active until expiry';

  @override
  String get subExpired => 'Subscription expired';

  @override
  String get subExpiredRestoreHint => 'Resubscribe to restore instantly';

  @override
  String get accountMenuManage => 'Manage subscription';

  @override
  String get accountMenuCloudRecover => 'Recover from Cloud';

  @override
  String get accountMenuCloudRecoverSub =>
      'Your songs are kept until you delete them';

  @override
  String get accountMenuLanguage => 'Language / 언어';

  @override
  String get accountMenuFaq => 'FAQ';

  @override
  String get accountMenuContact => 'Contact us';

  @override
  String get accountMenuTerms => 'Terms of Service';

  @override
  String get accountMenuPrivacy => 'Privacy Policy';

  @override
  String get accountMenuRefund => 'Refund Policy';

  @override
  String get devModeTitle => 'Developer mode';

  @override
  String get devSubscriptionLabel => 'Subscription state (debug build only)';

  @override
  String get devCloudMockLabel => 'Cloud mock data';

  @override
  String get accountDetailTitle => 'Account info';

  @override
  String get labelEmail => 'Email';

  @override
  String get labelSignInMethod => 'Sign-in method';

  @override
  String get labelAccountId => 'Account ID';

  @override
  String get withdrawHint =>
      'Deleting your account permanently removes your account data.\nIt does NOT cancel an App Store / Google Play subscription — cancel it in the store separately so you are not charged again.';

  @override
  String get withdrawCta => 'Delete account';

  @override
  String get withdrawConfirmTitle => 'Delete your account?';

  @override
  String get withdrawConfirmBody =>
      'Your account and all data will be permanently removed and cannot be recovered.';

  @override
  String get withdrawConfirmAction => 'Delete';

  @override
  String withdrawFailed(String err) {
    return 'Delete failed: $err';
  }

  @override
  String get withdrawCompleted => 'Account deleted';

  @override
  String get subScreenTitle => 'Subscription';

  @override
  String get subStatusActive => 'Humming Pro · Active';

  @override
  String subStatusActiveRenewsOn(String date) {
    return 'Renews automatically on $date';
  }

  @override
  String get subStatusActiveAutoOn => 'Auto-renew on';

  @override
  String subStatusTrialBillsOn(String date) {
    return 'Auto-charge on $date';
  }

  @override
  String subStatusTrialNDays(int days) {
    return '$days-day free trial';
  }

  @override
  String get subStatusCancelled => 'Cancellation scheduled';

  @override
  String subStatusCancelledUntil(String date) {
    return 'Pro active until $date';
  }

  @override
  String get subStatusExpiredBody =>
      'Resubscribe and Pro features come back instantly';

  @override
  String get subStatusAnonymous => 'No subscription';

  @override
  String get subStatusAnonymousBody => 'Sign in first to start billing';

  @override
  String get subCurrentEntitlements => 'Current entitlements';

  @override
  String get subFeatureCloudSync => 'Unlimited songs';

  @override
  String get subFeatureExport => 'Unlimited export (WAV / MIDI)';

  @override
  String get subFeatureVocalBackup => 'Stems export';

  @override
  String get subFeaturePriority => 'MIDI export';

  @override
  String subStoreNoticeActive(String store) {
    return 'Payment info, cancellation and refunds are managed in $store subscription settings.';
  }

  @override
  String subStoreNoticeCancelled(String store) {
    return 'All features stay on until expiry.\nReactivate from $store subscription settings.';
  }

  @override
  String get subResubCta => 'Resubscribe to Pro';

  @override
  String get subResubHint =>
      'Your songs stay on this device — resubscribe to export again';

  @override
  String get subStartCta => 'Subscribe';

  @override
  String get subCancelConfirmTitle => 'Cancel subscription?';

  @override
  String get subCancelConfirmBody => 'All Pro features stay on until expiry.';

  @override
  String get subCancelConfirmAction => 'Cancel subscription';

  @override
  String get paywallHeadlineExport => 'Pro is required to export';

  @override
  String get paywallHeadlineSync => 'Pro for unlimited songs';

  @override
  String get paywallHeadlineBackup => 'Stems export';

  @override
  String get paywallHeadlineDefault => 'Humming Pro';

  @override
  String get paywallSubExport => 'Save and share as WAV · MIDI';

  @override
  String get paywallSubSync => 'No free-plan song limit';

  @override
  String get paywallSubBackup => 'Separate WAV per track';

  @override
  String get paywallSubDefault => 'Unlimited songs · WAV / MIDI / stems export';

  @override
  String get looptapPaywallTriggerExport =>
      'Export is a Pro feature — subscribe to download MIDI / audio.';

  @override
  String get looptapPaywallTriggerSongQuota =>
      'You\'ve reached the free plan\'s song limit. Pro unlocks unlimited songs.';

  @override
  String get paywallFeatureCloudTitle => 'Unlimited songs';

  @override
  String get paywallFeatureCloudSub => 'Free plan keeps 4';

  @override
  String get paywallFeatureBackupTitle => 'MIDI export';

  @override
  String get paywallFeatureBackupSub => '.mid that opens in any DAW';

  @override
  String get paywallFeatureExportTitle => 'Unlimited export';

  @override
  String get paywallFeatureExportSub => 'WAV · MIDI · stems';

  @override
  String get paywallFeaturePriorityTitle => 'Stems export';

  @override
  String get paywallFeaturePrioritySub => 'Separate WAV per track';

  @override
  String get paywallPlanYearly => 'Yearly';

  @override
  String paywallPlanYearlyPrice(String price) {
    return '$price / year';
  }

  @override
  String paywallPlanYearlyHint(String monthly) {
    return '$monthly/mo equivalent';
  }

  @override
  String get paywallPlanMonthly => 'Monthly';

  @override
  String paywallPlanMonthlyPrice(String price) {
    return '$price / month';
  }

  @override
  String get paywallPlanMonthlyHint => 'Cancel anytime';

  @override
  String get paywallCtaProcessing => 'Processing…';

  @override
  String paywallCtaStartTrial(int days) {
    return 'Start with $days-day free trial';
  }

  @override
  String get paywallFooterTrial =>
      'We\'ll remind you before trial ends · cancel anytime';

  @override
  String get paywallRestoreLink => 'Restore purchases';

  @override
  String get loginTitle => 'Sign in';

  @override
  String get loginSub => 'Used for Pro subscription and restoring purchases';

  @override
  String get loginFailedTitle => 'Sign-in failed';

  @override
  String get loginTermsPrefix => 'I have read and agree to HumTrack ';

  @override
  String get loginTermsBetween => ' and ';

  @override
  String get loginTermsSuffix => '.';

  @override
  String get loginTermsLinkTerms => 'Terms of Service';

  @override
  String get loginTermsLinkPrivacy => 'Privacy Policy';

  @override
  String get appleSignInCta => 'Continue with Apple';

  @override
  String get googleSignInCta => 'Continue with Google';

  @override
  String get logoutConfirmTitle => 'Sign out?';

  @override
  String get logoutConfirmBody => 'Songs on this device stay where they are.';

  @override
  String get logoutCta => 'Sign out';

  @override
  String get restoreOkTitle => 'Restored';

  @override
  String get restoreEmptyTitle => 'Nothing to restore';

  @override
  String get restoreOkBody => 'Pro features are back.';

  @override
  String get restoreEmptyBody =>
      'Check that you signed in with the account that subscribed.';

  @override
  String get projectOptionUploadProBadge => 'Pro required';

  @override
  String projectOptionRefreshSyncedAt(String ago) {
    return 'Synced $ago';
  }

  @override
  String get projectOptionOpen => 'Open';

  @override
  String get projectOptionRename => 'Rename';

  @override
  String get projectOptionDuplicate => 'Duplicate';

  @override
  String get projectOptionExport => 'Export';

  @override
  String get projectOptionExportSub => 'WAV · MIDI';

  @override
  String get projectOptionDelete => 'Delete';

  @override
  String get projectOptionDeleteSub => 'Cannot be undone';

  @override
  String projectUploadedToast(String title) {
    return '$title — uploaded to Cloud';
  }

  @override
  String projectHeaderMeta(int count, String dur, String ago) {
    return '$count tracks · $dur · $ago';
  }

  @override
  String projectDeleteTitle(String title) {
    return 'Delete \"$title\"';
  }

  @override
  String get projectDeleteBody =>
      'The local file will be permanently deleted. This cannot be undone.';

  @override
  String get cloudFreeImageHeadline => 'You don\'t have a Cloud yet';

  @override
  String get cloudFreeImageSub =>
      'Get 5GB of Cloud with Pro\nto continue your songs on every device.';

  @override
  String get cloudValueBackupTitle => 'Permanent backup';

  @override
  String get cloudValueBackupSub => 'Safe through device changes and loss';

  @override
  String get cloudValueAutoSyncTitle => 'Auto continue';

  @override
  String get cloudValueAutoSyncSub => 'Just sign in on another device';

  @override
  String get cloudValueExportTitle => 'Unlimited export';

  @override
  String get cloudValueExportSub => 'WAV · MIDI · stems';

  @override
  String cloudUpgradeFootnote(int days, String price) {
    return '$days-day free trial · then $price/mo';
  }

  @override
  String get cloudProEmptyTitle => 'Cloud is empty';

  @override
  String get cloudProEmptySub =>
      'Open the ⋯ menu of a song in My Songs\nand tap \"Upload to Cloud\".';

  @override
  String get cloudGoToLocalTab => 'Go to My Songs';

  @override
  String get cloudGraceTitle => 'Pro has expired';

  @override
  String get cloudGraceBody =>
      'Your data is preserved. Download anytime — and resubscribe to turn sync back on.';

  @override
  String get cloudGraceEmpty => 'Cloud is empty';

  @override
  String get cloudUsageInUse => 'used';

  @override
  String get cloudUsageStored => 'stored';

  @override
  String get cloudUsageReadOnly => 'Read-only';

  @override
  String cloudUsageCount(int n) {
    return '$n songs stored';
  }

  @override
  String cloudUsageCountStored(int n) {
    return '$n songs';
  }

  @override
  String get cloudCardThisDevice => 'This device';

  @override
  String get cloudCardDownload => 'Download';

  @override
  String cloudOptionsSubtitle(String uploadedAt, String size) {
    return '☁ Cloud · uploaded $uploadedAt · $size';
  }

  @override
  String get cloudOptionsDownloadAgain => 'Download again';

  @override
  String get cloudOptionsDownload => 'Download to this device';

  @override
  String settingsCloudPercentUsed(int pct) {
    return '$pct% used';
  }

  @override
  String settingsCloudFree(String free) {
    return '$free free';
  }

  @override
  String get settingsCloudUsageDetail => 'Usage details';

  @override
  String get settingsCloudUsageDetailLink => 'Usage details →';

  @override
  String get syncProgressUpload => 'Uploading to Cloud';

  @override
  String get syncProgressDownload => 'Downloading';

  @override
  String get comingSoonFeature => 'Feature';

  @override
  String comingSoonToast(String label) {
    return '$label — coming soon';
  }

  @override
  String get proWelcomeTitle => 'Cloud is on';

  @override
  String get proWelcomeBody => 'Pick up your songs anywhere.';

  @override
  String get proWelcomeBadgeLabel => 'My Cloud';

  @override
  String get proWelcomeStep1Prefix => 'From My Songs ⋯ menu, tap ';

  @override
  String get proWelcomeStep1Bold => 'Upload to Cloud';

  @override
  String get proWelcomeStep2 =>
      'Sign in on another device — Cloud shows up automatically';

  @override
  String get proWelcomeStep3 => 'Work freely from either side';

  @override
  String get proWelcomeCta => 'Explore Cloud';

  @override
  String get recPermDenied =>
      'Microphone access is required. Please allow it again.';

  @override
  String get recPermPermanentlyDenied =>
      'Enable Microphone access from Settings > Privacy.';

  @override
  String get recPermRestricted =>
      'Microphone is restricted on this device, so recording is unavailable.';

  @override
  String get recPermChecking => 'Checking microphone permission…';

  @override
  String get recPermRequest => 'Request permission';

  @override
  String get recPermOpenSettings => 'Open Settings';

  @override
  String recScreenTitle(String role) {
    return '$role recording';
  }

  @override
  String recRecordingTitle(String role) {
    return 'Recording · $role';
  }

  @override
  String get recHumOrSing => 'Hum or sing';

  @override
  String get recReadyHint => 'Tap the button when ready';

  @override
  String get recTapToStop => 'Tap to stop';

  @override
  String get recTapToStart => 'Tap to start';

  @override
  String get faqTitle => 'FAQ';

  @override
  String get faq1Q => 'How much can I do for free?';

  @override
  String get faq1A =>
      'Record → analyze → edit — all available for free. The free plan keeps up to 4 songs; unlimited songs and WAV · MIDI · stems export unlock with Pro.';

  @override
  String get faq2Q => 'What instruments are available?';

  @override
  String get faq2A =>
      'Piano · Synth · Acoustic guitar · Electric guitar · Bass · Drums and your original vocal — switch instantly by tapping a card.';

  @override
  String get faq3Q => 'Who can hear my voice?';

  @override
  String get faq3A =>
      'Everything is processed on your device. Only the audio needed for humming analysis is sent to the server and it is not stored.';

  @override
  String get faq4Q => 'What happens to my songs if I cancel?';

  @override
  String get faq4A =>
      'Your songs stay on this device and remain editable. New exports and unlimited songs pause, and resubscribing restores them instantly.';

  @override
  String get faq5Q => 'Can I get a refund?';

  @override
  String get faq5A =>
      'Payments follow the app marketplace policy. Please request refunds through the store directly.';

  @override
  String get contactTitle => 'Contact us';

  @override
  String get contactHeadline => 'How can we help?';

  @override
  String get contactSub =>
      'Most answers are in the FAQ. Otherwise, reach us below.';

  @override
  String get contactEmail => 'Email';

  @override
  String get contactBug => 'Report a bug';

  @override
  String get contactBugSub => 'Repro steps help a ton';

  @override
  String get contactFeature => 'Feature request';

  @override
  String get contactFeatureSub => 'Tell us what you\'d love to see';

  @override
  String get termsTitle => 'Terms of Service';

  @override
  String get privacyTitle => 'Privacy Policy';

  @override
  String get refundScreenTitle => 'Refund Policy';

  @override
  String legalEffectiveDate(String date) {
    return 'Effective: $date';
  }

  @override
  String legalLastUpdated(String date) {
    return 'Last updated: $date';
  }

  @override
  String get cloudDownloadTitle => 'Recover from Cloud';

  @override
  String get cloudDownloadBanner =>
      'While your subscription is expired, new uploads / sync are locked. Your previous songs remain — download or delete them anytime.';

  @override
  String get cloudDownloadCta => 'Download';

  @override
  String get cloudDownloadActionLabel => 'Download';

  @override
  String get cloudRenameLabel => 'Rename on Cloud';

  @override
  String get editHeaderDone => 'Done';

  @override
  String get editTrackInfoLabel => 'TRACK INFO';

  @override
  String get editConverting => 'Converting…';

  @override
  String editRecLabelRecord(String role) {
    return 'Record $role';
  }

  @override
  String editRecLabelReRecord(String role) {
    return 'Re-record $role';
  }

  @override
  String get editMicPermNeededTitle => 'Microphone permission needed';

  @override
  String get editMicPermNeededBody =>
      'Allow HumTrack microphone access in iPad Settings → Privacy → Microphone.';

  @override
  String get editMicPermLabel => 'Microphone permission required';

  @override
  String get editOpenSettings => 'Open Settings';

  @override
  String get editPlayNoActiveTrack => 'No active track (tap sidebar)';

  @override
  String get editPlayRecordFirst => 'Record first';

  @override
  String editPlayFailed(String err) {
    return 'Playback failed: $err';
  }

  @override
  String get editOriginalPlayFailed => 'Original playback failed';

  @override
  String get editSplitNotPossible => 'Cannot split at this position';

  @override
  String editTrackDeleteTitle(String role) {
    return 'Delete $role track';
  }

  @override
  String get editTrackDeleteBody => 'All recordings and notes will be deleted.';

  @override
  String get editChunkVolumeTitle => 'Chunk volume';

  @override
  String get editNoteVolumeTitle => 'Note volume';

  @override
  String get editTransportOriginal => 'Original';

  @override
  String get editSaveSaving => 'Saving...';

  @override
  String get editSaveJust => 'Just saved';

  @override
  String editSaveAt(String time) {
    return 'Saved at $time';
  }

  @override
  String get ctxActionPitch => 'Pitch';

  @override
  String get ctxActionChord => 'Chord';

  @override
  String get ctxActionUnchord => 'Unchord';

  @override
  String get ctxActionVolume => 'Volume';

  @override
  String get ctxActionDelete => 'Delete';

  @override
  String get ctxActionSplit => 'Split';

  @override
  String get ctxActionCopy => 'Copy';

  @override
  String get ctxActionRerecord => 'Re-record';

  @override
  String get ctxActionLoop => 'Loop';

  @override
  String get ctxActionUnloop => 'Unloop';

  @override
  String get ctxActionMute => 'Mute';

  @override
  String get ctxActionUnmute => 'Unmute';

  @override
  String get ctxActionBassPlace => 'Place bass';

  @override
  String get ctxActionBassUnplace => 'Unplace bass';

  @override
  String get timelineLoop => 'LOOP';

  @override
  String get timelineRerecord => 'Re-record';

  @override
  String get timelineRecordStart => 'Record';

  @override
  String get timelinePitchAssist => 'Pitch assist';

  @override
  String get timelineRecCompleteVocal => 'Recording done — use vocal?';

  @override
  String timelineRecCompleteNotes(int n) {
    return 'Recording done — use $n notes?';
  }

  @override
  String get timelineRecCompleteGeneric => 'Recording done — use it?';

  @override
  String get pendingRecTitle => 'Recording done';

  @override
  String get pendingAnalyzing => 'Analyzing…';

  @override
  String pendingVocalUseQ(String sec) {
    return 'Use this ${sec}s vocal?';
  }

  @override
  String pendingNotesUseQ(String sec, int n) {
    return '${sec}s · use $n notes?';
  }

  @override
  String get pendingPreview => 'Preview';

  @override
  String get pendingStop => 'Stop';

  @override
  String get addTrackTitle => 'Add track';

  @override
  String get addTrackPiano => 'Piano';

  @override
  String get addTrackAcousticGuitar => 'Acoustic guitar';

  @override
  String get addTrackElectricGuitar => 'Electric guitar';

  @override
  String get addTrackSynth => 'Synth';

  @override
  String get addTrackOrgan => 'Organ';

  @override
  String get addTrackStrings => 'Strings';

  @override
  String get addTrackBassGuitar => 'Bass guitar';

  @override
  String get addTrackSynthBass => 'Synth bass';

  @override
  String get addTrackDrumKit => 'Drum kit';

  @override
  String get addTrackVocal => 'Original vocal';

  @override
  String get addTrackVocalSub => 'Original take';

  @override
  String get anchorKeyTitle => 'Set project key';

  @override
  String get anchorKeySub =>
      'All tracks will align to this key. Pick the right one.';

  @override
  String get anchorKeyTagDetected => 'Detected';

  @override
  String get anchorKeyTagRelative => 'Relative';

  @override
  String get anchorKeyTagCandidate => 'Candidate';

  @override
  String get scaleMajor => 'Major';

  @override
  String get scaleMinor => 'Minor';

  @override
  String instrumentPickerTitle(String role) {
    return 'Instrument · $role';
  }

  @override
  String get instrumentPickerVocalOnly => 'Original vocal track';

  @override
  String get chordModeTitle => 'Chord mode';

  @override
  String get chordModeSub => 'Auto-chord single notes';

  @override
  String get chordModeMono => 'Mono';

  @override
  String get chordModeChord => 'Chord';

  @override
  String get keyPickerTitle => 'Key';

  @override
  String get keyPickerSub => 'Auto = recommended key';

  @override
  String get keyPickerAuto => 'Auto (recommended)';

  @override
  String get keyPickerMainRole =>
      'Main key reference track (all tracks follow)';

  @override
  String get keyPickerMajor => 'Major';

  @override
  String get keyPickerMinor => 'Minor';

  @override
  String get keyAuto => 'AUTO';

  @override
  String get keyManual => 'Manual';

  @override
  String noteWheelTitle(int idx) {
    return 'Note · #$idx';
  }

  @override
  String get noteWheelRecommended => 'Recommended';

  @override
  String get noteWheelOriginal => 'Original';

  @override
  String get noteWheelOriginalHint => 'Original = as sung';

  @override
  String get chordPickerTitle => 'Chord';

  @override
  String get chordPickerScopeChunk => 'Chunk';

  @override
  String get chordPickerScopeRoot => 'Root';

  @override
  String chordPickerSummary(
    String scope,
    String root,
    String keyPart,
    String chordPart,
  ) {
    return '$scope: $root$keyPart$chordPart';
  }

  @override
  String chordPickerKeyPart(String label) {
    return ' · Key: $label';
  }

  @override
  String get chordPickerNoKey => ' (no key)';

  @override
  String get chordPickerCurrent => ' · current chord';

  @override
  String get chordPickerMono => 'Mono';

  @override
  String get chordPickerMonoSub => 'Single note (unchord)';

  @override
  String exportTitle(String title) {
    return 'Export · $title';
  }

  @override
  String get exportCloudSaveLabel => 'Save to Cloud';

  @override
  String get exportCloudSaveTitle => 'Save project';

  @override
  String get exportCloudSaveSub => 'Cloud sync · always editable';

  @override
  String get exportMidiTitle => 'Export MIDI';

  @override
  String get exportMidiSub => '.mid';

  @override
  String get exportAudioTitle => 'Export audio';

  @override
  String get exportAudioSub => '.wav · mix render';

  @override
  String get exportShareLabel => 'Share';

  @override
  String get exportShareSub => 'Link · Instagram · TikTok';

  @override
  String exportFailed(String err) {
    return 'Export failed: $err';
  }

  @override
  String get metronomeTitle => 'Metronome';

  @override
  String get metronomeOn => 'Start metronome';

  @override
  String get metronomeOff => 'Stop metronome';

  @override
  String get metronomeNote =>
      'BPM applies to the whole project. The Quantize grid also uses this BPM.';

  @override
  String metronomeBeatSec(String sec) {
    return '1 beat = ${sec}s';
  }

  @override
  String get tempoVerySlow => 'Slow ballad';

  @override
  String get tempoBallad => 'Ballad';

  @override
  String get tempoMidPop => 'Pop / mid';

  @override
  String get tempoDance => 'Dance / upbeat';

  @override
  String get tempoFast => 'Fast';

  @override
  String get tempoVeryFast => 'Very fast';

  @override
  String get quantizeTitle => 'Quantize';

  @override
  String get quantizeBpmHint =>
      'BPM is a project-wide setting; adjust from the metronome button in the transport.';

  @override
  String get quantizeGridLabel => 'Grid';

  @override
  String quantizeGridDetail(int n) {
    return '$n per beat';
  }

  @override
  String get quantizeStrength => 'Strength';

  @override
  String get quantizeStrengthMin => '0%: original timing';

  @override
  String get quantizeStrengthMax => '100%: perfect align';

  @override
  String get quantizeFooter =>
      'When tracks drift slightly, aligning to the same BPM/grid resyncs them automatically.';

  @override
  String get quantizeOff => 'off';

  @override
  String quantizeSummary(int grid, int pct, int bpm) {
    return '1/$grid · $pct% · BPM $bpm';
  }

  @override
  String get cardInstrumentLabel => 'INSTRUMENT';

  @override
  String get cardInstrumentFallback => 'Instrument';

  @override
  String get helpInstrumentBody =>
      'Choose how this track sounds. The detected pitches play back through a SoundFont preset.';

  @override
  String get cardKeyLabel => 'KEY';

  @override
  String get helpKeyBody =>
      'The tonic (C, D…) and mode (major/minor) of the song. AUTO = inferred from analysis. Tap to set manually. Confidence = how sure the estimate is (0–1).';

  @override
  String get keyAnalysisPending => 'Pending analysis';

  @override
  String keyConfidence(String conf, String tier) {
    return 'Confidence $conf$tier';
  }

  @override
  String get cardAssistLabel => 'Pitch assist';

  @override
  String get helpAssistBody =>
      'Slightly off-key notes are pulled to the nearest in-key pitch. \"Corrected\" = number actually moved.';

  @override
  String get assistCorrected => 'Corrected';

  @override
  String get assistDesc => 'Tidy out-of-key notes';

  @override
  String get cardQuantizeLabel => 'Quantize';

  @override
  String get helpQuantizeBody =>
      'When tracks drift slightly, aligning them to the same BPM/grid resyncs everything. The original timing is preserved — toggle off to restore it.';

  @override
  String get conflictTitle => 'Both sides changed';

  @override
  String conflictSub(String title) {
    return '$title · changed locally and in Cloud';
  }

  @override
  String get conflictLocalHeader => '📱 Local (this device)';

  @override
  String get conflictCloudHeader => '☁ Cloud (other side)';

  @override
  String conflictTrackInfo(int count, String size) {
    return '$count tracks · $size';
  }

  @override
  String get conflictKeepBoth => 'Keep both (as copies)';

  @override
  String get conflictBadgeRecommended => 'Recommended';

  @override
  String get conflictOverwriteCloud => 'Overwrite Cloud with this device';

  @override
  String get conflictPullFromCloud => 'Pull Cloud to this device';

  @override
  String get authErrDisabled => 'Auth disabled (Supabase keys not set)';

  @override
  String get authErrIdentityBlockedGeneric =>
      'This email is already signed up with a different method.\nPlease sign in with the original method.';

  @override
  String authErrIdentityBlockedSpecific(String providers) {
    return 'This email is already signed up with $providers.\nPlease sign in with $providers.';
  }

  @override
  String get authErrGoogleNoIdToken =>
      'Google: idToken missing (check serverClientId / iOS client config)';

  @override
  String authErrAppleCode(String code, String message) {
    return 'Apple $code: $message';
  }

  @override
  String authErrGeneric(String provider, String raw) {
    return '$provider: $raw';
  }

  @override
  String get authProviderKakao => 'Kakao';

  @override
  String get authProviderNaver => 'Naver';

  @override
  String get accountErrNoSession => 'No active session. Please try again.';

  @override
  String accountErrServerDelete(int status, String detail) {
    return 'Server delete failed ($status)$detail';
  }

  @override
  String get payTitle => 'HumTrack Pro';

  @override
  String payBenefits(int n) {
    return 'Unlimited songs (free plan keeps $n) · WAV / MIDI / stems export.';
  }

  @override
  String get payPlanYearly => 'Yearly';

  @override
  String get payPlanMonthly => 'Monthly';

  @override
  String payPerMonthEquiv(String price) {
    return '$price / month';
  }

  @override
  String get payBilledMonthly => 'Billed every month';

  @override
  String get payPeriodYear => 'year';

  @override
  String get payPeriodMonth => 'month';

  @override
  String payPerPeriod(String period) {
    return ' / $period';
  }

  @override
  String payDisclosureTrial(int days, String price, String period) {
    return '$days-day free trial for new subscribers, then $price per $period. Auto-renews until canceled. Cancel anytime in Settings at least 24 hours before renewal.';
  }

  @override
  String payDisclosureNoTrial(String price, String period) {
    return '$price per $period. Auto-renews until canceled. Cancel anytime in Settings at least 24 hours before renewal.';
  }

  @override
  String get paySubscribe => 'Subscribe';

  @override
  String get payPendingButton => 'Waiting for approval…';

  @override
  String get payRestore => 'Restore purchases';

  @override
  String get payStoreUnavailable => 'Store unavailable';

  @override
  String get payStoreUnavailableDevice => 'Store unavailable on this device.';

  @override
  String get payPurchaseFailed =>
      'Could not complete purchase. Please try again.';

  @override
  String get payPendingApproval =>
      'Waiting for approval. Pro will activate once the store confirms the payment.';

  @override
  String get payVerifyFailed =>
      'Payment received — activating Pro. If it doesn\'t appear, use Restore purchases.';

  @override
  String get paySignInRequired => 'Sign in to subscribe.';

  @override
  String get payRestoreDone => 'Pro restored. Welcome back!';

  @override
  String get payRestoreAlready => 'You are already Pro.';

  @override
  String get payRestoreEmpty =>
      'No active subscription found for this account. Check that you signed in with the account that subscribed.';

  @override
  String get payRestoreError =>
      'Could not restore purchases. Check your connection and try again.';

  @override
  String get acctTitle => 'My page';

  @override
  String get acctSignedIn => 'Signed in';

  @override
  String acctSignedInWith(String provider) {
    return 'Signed in · $provider';
  }

  @override
  String get acctProActive => 'HumTrack Pro · active';

  @override
  String get acctProBenefits => 'Unlimited songs · WAV / MIDI / stems export';

  @override
  String acctProUntil(String date) {
    return 'Until $date';
  }

  @override
  String get acctUpgrade => 'Upgrade to Pro';

  @override
  String get acctSignOut => 'Sign out';

  @override
  String get acctSignInTitle => 'Sign in to HumTrack';

  @override
  String get acctSignInSub =>
      'Sign in to subscribe to Pro and restore purchases.';

  @override
  String get acctSignInWithEmail => 'Sign in with email';

  @override
  String get acctEmailHint => 'Email';

  @override
  String get acctPasswordHint => 'Password';

  @override
  String get acctEnterEmailPassword => 'Enter your email and password.';

  @override
  String get acctSigningIn => 'Signing in…';

  @override
  String get acctSignIn => 'Sign in';

  @override
  String get acctDeleteNotSignedIn => 'Not signed in.';

  @override
  String acctDeleteRejected(int code) {
    return 'Delete failed ($code)';
  }

  @override
  String get acctDeleteNetwork =>
      'Network error. Check your connection and try again.';

  @override
  String get authNotConfigured => 'Sign-in is not configured in this build.';

  @override
  String get authFailedGeneric => 'Sign-in failed. Please try again.';

  @override
  String get authUnavailable => 'Sign-in is not available right now.';

  @override
  String get authGoogleNoIdToken =>
      'Google sign-in did not return an ID token. Try again, or use Apple sign-in.';

  @override
  String authAppleFailed(String code, String message) {
    return 'Apple sign-in failed ($code). $message';
  }

  @override
  String authProviderFailed(String provider) {
    return 'Could not sign in with $provider. Please try again.';
  }

  @override
  String get authSessionExpired => 'Session expired. Please sign in again.';

  @override
  String get ltCardMore => 'More';

  @override
  String get ltSettingsDeleteAccount => 'Delete account';

  @override
  String get ltSettingsDeleteAccountConfirmTitle => 'Delete account?';

  @override
  String get ltSettingsDeleteAccountConfirmBody =>
      'Your account and all data will be permanently removed. This cannot be undone.';

  @override
  String ltSettingsDeleteAccountFailed(String err) {
    return 'Delete failed: $err';
  }

  @override
  String get ltSettingsDeleteAccountDone => 'Account deleted.';

  @override
  String ltExportTitle(String title) {
    return 'Export \"$title\"';
  }

  @override
  String ltExportMeta(int count, int bars, int bpm) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count sections',
      one: '1 section',
    );
    return '$_temp0 · $bars bars · $bpm BPM';
  }

  @override
  String get ltExportMidiTitle => 'MIDI file';

  @override
  String get ltExportMidiSub => 'Whole song · piano · bass · drums (ch10)';

  @override
  String get ltExportWavTitle => 'Audio (WAV)';

  @override
  String get ltExportWavSub => 'Full song, rendered mix';

  @override
  String get ltExportStemsTitle => 'Stems';

  @override
  String get ltExportStemsSub => 'Separate WAV per track';

  @override
  String get ltExportShareTitle => 'Share';

  @override
  String get ltExportShareSub => 'Send to another app';

  @override
  String get ltExportScopeLabel => 'What to export';

  @override
  String get ltExportScopeAll => 'Whole song';

  @override
  String ltExportSaved(String filename) {
    return 'Saved $filename';
  }

  @override
  String ltExportVocalSkipped(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count older-format vocals weren\'t included in the mix',
      one: '1 older-format vocal wasn\'t included in the mix',
    );
    return '$_temp0';
  }

  @override
  String get ltExportFailed => 'MIDI export failed';

  @override
  String get ltExportFooter =>
      'Sections render in order (with their repeats). MIDI opens in any DAW. WAV & stems are audio rendered through the SoundFont.';

  @override
  String get ltSettingsTitle => 'Settings';

  @override
  String get ltSettingsMetronome => 'Metronome click';

  @override
  String get ltSettingsMetronomeSub => 'Play a click while recording';

  @override
  String get ltSettingsHaptics => 'Haptics';

  @override
  String get ltSettingsHapticsSub => 'Buzz on pad hits';

  @override
  String get ltSettingsAbout => 'About';

  @override
  String get ltSettingsAboutSub => 'HumTrack · v0.4';

  @override
  String get ltSettingsLegalSection => 'Legal & Policies';

  @override
  String get ltSettingsOpenSource => 'Open-source licenses';

  @override
  String get ltSettingsContact => 'Contact support';

  @override
  String get ltSongsTagline => 'Tap-to-make beats';

  @override
  String get ltSongsNewSong => 'New song';

  @override
  String get ltSongsNewCard => 'Start a new loop';

  @override
  String ltSongCardMeta(String key, String scale, int bpm, int bars) {
    return '$key $scale · $bpm BPM · $bars bars';
  }

  @override
  String get ltScalePenta => 'Penta';

  @override
  String get ltScaleDorian => 'Dorian';

  @override
  String get ltKeySheetTitle => 'Key & scale';

  @override
  String get ltKeyRoot => 'Root';

  @override
  String get ltKeyScale => 'Scale';

  @override
  String get ltKeyHint =>
      'Only in-key notes show on the pads — you can\'t play a wrong note.';

  @override
  String get ltMixerTitle => 'Mixer';

  @override
  String ltInstrumentSheetTitle(String track) {
    return '$track instrument';
  }

  @override
  String get ltInstrumentFavorites => 'Favorites';

  @override
  String get ltInstrumentCloudSounds => 'Cloud sounds';

  @override
  String get ltTransportCountIn => 'Count-in';

  @override
  String get ltTransportLoopAlwaysOn => 'Loop (always on)';

  @override
  String get ltTransportClearTrack => 'Clear track';

  @override
  String get ltTransportSwing => 'Swing';

  @override
  String get ltTransportSetBpm => 'Set BPM';

  @override
  String get ltSectionsLabel => 'Song';

  @override
  String get ltSectionPlaySong => 'Play song';

  @override
  String get ltSectionStopSong => 'Stop song';

  @override
  String get ltArrangeAddTrack => 'Track';

  @override
  String get ltEditorBack => 'Back';

  @override
  String get ltEditorUndo => 'Undo';

  @override
  String get ltEditorRedo => 'Redo';

  @override
  String get ltEditorSaved => 'Saved';

  @override
  String get ltEditorUnsaved => 'Unsaved';

  @override
  String ltEditorSectionMenuTitle(String name) {
    return 'Section $name';
  }

  @override
  String get ltEditorMoveLeft => 'Move left';

  @override
  String get ltEditorMoveRight => 'Move right';

  @override
  String get ltEditorTrackCleared => 'Track cleared';

  @override
  String get ltEditorLaneFull =>
      'Lane is full — the new take starts at the beginning (overlapping)';

  @override
  String get ltEditorSoundDownloadFailed =>
      'Couldn\'t download the sound — check your connection';

  @override
  String ltEditorSoundDownloadAsk(String name) {
    return 'Download the sound $name used here? Until then it plays with a basic instrument.';
  }

  @override
  String ltEditorSoundDownloadAskSized(String name, String size) {
    return 'Download the sound $name used here? It is $size; until then it plays with a basic instrument.';
  }

  @override
  String get ltEditorSoundDownloadNow => 'Download';

  @override
  String get ltEditorSoundReady => 'Instrument ready';

  @override
  String get ltEditorAutotuneTitle => 'Autotune';

  @override
  String ltEditorAutotuneSub(String key, String scale) {
    return 'Snaps your vocal to $key $scale. The original take is kept.';
  }

  @override
  String get ltEditorAutotuneNatural => 'Natural';

  @override
  String get ltEditorAutotuneNaturalSub =>
      'Gentle correction, keeps your style';

  @override
  String get ltEditorAutotuneStrong => 'Strong';

  @override
  String get ltEditorAutotuneStrongSub => 'Hard snap — the classic effect';

  @override
  String get ltEditorAutotuneFailed => 'Autotune needs a connection';

  @override
  String ltEditorAutotuneProgress(int done, int total) {
    return 'Tuning take $done of $total';
  }

  @override
  String ltEditorHumAdded(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Added $count notes from your hum',
      one: 'Added 1 note from your hum',
    );
    return '$_temp0';
  }

  @override
  String get ltEditorHumErrTooLong => 'Recording too long';

  @override
  String get ltEditorHumErrBusy => 'Server busy, try again shortly';

  @override
  String get ltEditorHumErrWaking => 'Server is waking up, try again';

  @override
  String get ltEditorHumErrGeneric => 'Couldn\'t convert your hum';

  @override
  String get ltEditorHumErrNoNotes => 'No notes detected — try humming louder';

  @override
  String get ltEditorModePads => 'Pads';

  @override
  String get ltEditorModeGrid => 'Grid';

  @override
  String get ltEditorPowerChord => 'Power';

  @override
  String get ltEditorOctaveDown => 'Octave down';

  @override
  String get ltEditorOctaveUp => 'Octave up';

  @override
  String get ltEditorHumToMidi => 'Hum to MIDI';

  @override
  String get ltEditorHintGridDrums => 'tap cells to toggle';

  @override
  String get ltEditorHintGridPitched => 'tap · drag to lengthen · auto-merge';

  @override
  String get ltEditorHintPads => 'rec, then tap';

  @override
  String get ltDrumBeatGrid => 'Beat grid';

  @override
  String ltDrumGridMeta(int bars) {
    String _temp0 = intl.Intl.pluralLogic(
      bars,
      locale: localeName,
      other: '$bars bars',
      one: '1 bar',
    );
    return '$_temp0 · 4/4';
  }

  @override
  String ltDrumGridMetaEditable(int bars) {
    String _temp0 = intl.Intl.pluralLogic(
      bars,
      locale: localeName,
      other: '$bars bars',
      one: '1 bar',
    );
    return '$_temp0 · 4/4 · tap to edit';
  }

  @override
  String get ltDrumHihat => 'HI-HAT';

  @override
  String get ltDrumSnare => 'SNARE';

  @override
  String get ltDrumKick => 'KICK';

  @override
  String get ltDrumShaker => 'SHAKER';

  @override
  String get ltDrumTambourine => 'TAMB';

  @override
  String get ltDrumClap => 'CLAP';

  @override
  String get ltDrumCowbell => 'COWBELL';

  @override
  String get ltDrumMaracas => 'MARACAS';

  @override
  String get ltDrumClaves => 'CLAVES';

  @override
  String get ltDrumRimshot => 'RIMSHOT';

  @override
  String get ltDrumWoodblockHi => 'WOODBLK+';

  @override
  String get ltDrumWoodblockLo => 'WOODBLK-';

  @override
  String get ltDrumRide => 'RIDE';

  @override
  String get ltDrumCrash => 'CRASH';

  @override
  String get ltDrumTriangle => 'TRIANGLE';

  @override
  String get ltFillPadSound => 'Pad sound';

  @override
  String ltPadsDegree(int n) {
    return 'deg $n';
  }

  @override
  String ltHumModalTitle(String track) {
    return 'Hum to MIDI · $track';
  }

  @override
  String get ltHumCountIn => 'Get ready — hum on the beat.';

  @override
  String get ltHumListen => 'Hum your idea — we\'ll snap it in-key, in time.';

  @override
  String get ltHumConverting => 'Converting to notes…';

  @override
  String get ltHumDone => 'Done! Notes added.';

  @override
  String get ltHumConvert => 'Convert';

  @override
  String get ltRecErrUnavailable => 'Recording unavailable';

  @override
  String get ltRecErrInterrupted => 'Recording was interrupted — try again';

  @override
  String get ltRecErrNoAudio => 'No audio captured';

  @override
  String get ltRecErrFailed => 'Recording failed';

  @override
  String get ltRecErrTooShort => 'Recording was too short';

  @override
  String get ltRecErrTooQuiet => 'Recording is too quiet';

  @override
  String get ltRecSaveFailed => 'Couldn\'t save the recording';

  @override
  String get ltVocalRecTitle => 'Record vocal';

  @override
  String get ltVocalRecCountInNoHeadset =>
      'No earphones — recording silently so the loop stays out of the mic.';

  @override
  String get ltVocalRecCountIn => 'Get ready — sing with the loop.';

  @override
  String get ltVocalRecListenMuted =>
      'Recording one loop — device audio is muted.';

  @override
  String get ltVocalRecListen => 'Recording one loop — sing along.';

  @override
  String get ltVocalRecDone => 'Done! Vocal recorded.';

  @override
  String get ltVocalLiveAutotune => 'Live autotune';

  @override
  String get ltVocalLiveAutotuneOn => 'LIVE AUTOTUNE';

  @override
  String get ltVocalRecorded => 'Recorded';

  @override
  String get ltVocalTapToRecord => 'Tap to record';

  @override
  String get ltVocalRecOverSong => 'Rec over song';

  @override
  String get ltVocalReRecOverSong => 'Re-rec over song';

  @override
  String get ltVocalClearSongTake => 'Clear song vocal';

  @override
  String get ltVocalEdit => 'Edit';

  @override
  String get ltVocalClear => 'Clear';

  @override
  String get ltVocalEditorTitle => 'Vocal editor';

  @override
  String ltVocalEditorMeta(int takes, int bpm, int bars) {
    String _temp0 = intl.Intl.pluralLogic(
      takes,
      locale: localeName,
      other: '$takes takes',
      one: '1 take',
    );
    String _temp1 = intl.Intl.pluralLogic(
      bars,
      locale: localeName,
      other: '$bars bars',
      one: '1 bar',
    );
    return '$_temp0 · $bpm BPM · $_temp1';
  }

  @override
  String get ltVocalEditorNoTake => 'No take to edit';

  @override
  String ltVocalEditorTake(int n) {
    return 'Take $n';
  }

  @override
  String ltVocalEditorFxCount(int n) {
    return '$n fx';
  }

  @override
  String get ltVocalEditorDragHint => 'Drag to select a region';

  @override
  String get ltVocalEditorDragSet => 'Drag set · tap Trim';

  @override
  String get ltVocalEditorTrimmed => 'trimmed';

  @override
  String ltVocalEditorFadeInReadout(int ms) {
    return 'in ${ms}ms';
  }

  @override
  String ltVocalEditorFadeOutReadout(int ms) {
    return 'out ${ms}ms';
  }

  @override
  String get ltVocalEditorEditGroup => 'Edit';

  @override
  String get ltVocalEditorEffectsGroup => 'Effects';

  @override
  String get ltVocalEditorReset => 'Reset';

  @override
  String get ltVocalEditorServerTag => 'server';

  @override
  String get ltVocalEditorTrim => 'Trim';

  @override
  String ltVocalEditorFadeIn(int ms) {
    return 'Fade in $ms';
  }

  @override
  String ltVocalEditorFadeOut(int ms) {
    return 'Fade out $ms';
  }

  @override
  String get ltVocalEditorGainDown => 'Gain −';

  @override
  String get ltVocalEditorGainUp => 'Gain +';

  @override
  String get ltVocalEditorNormalize => 'Normalize';

  @override
  String get ltVocalEditorProcessFailed => 'Sound processing failed';

  @override
  String get ltVocalEditorPreview => 'Preview (edited)';

  @override
  String get ltVocalEditorEarlier => 'Earlier';

  @override
  String get ltVocalEditorLater => 'Later';

  @override
  String ltVocalEditorStep(int n) {
    return 'step $n';
  }

  @override
  String get ltVocalEditorDeleteTake => 'Delete take';

  @override
  String ltVocalEditorFxProcessing(String fx) {
    return '$fx…';
  }

  @override
  String ltVocalEditorFxChainItem(int index, String fx) {
    return '$index. $fx';
  }

  @override
  String get ltFxEq => 'EQ';

  @override
  String get ltFxReverb => 'Reverb';

  @override
  String get ltFxComp => 'Comp';

  @override
  String get ltFxDelay => 'Delay';

  @override
  String get ltFxStretch => 'Stretch';

  @override
  String get ltFxPitch => 'Pitch';

  @override
  String get ltFxSlower => 'Slower';

  @override
  String get ltFxFaster => 'Faster';

  @override
  String get ltFxPitchUp => 'Pitch +2';

  @override
  String get ltFxPitchDown => 'Pitch −2';
}
