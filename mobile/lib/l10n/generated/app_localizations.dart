import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ko.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of L10n
/// returned by `L10n.of(context)`.
///
/// Applications need to include `L10n.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen_l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: L10n.localizationsDelegates,
///   supportedLocales: L10n.supportedLocales,
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
/// be consistent with the languages listed in the L10n.supportedLocales
/// property.
abstract class L10n {
  L10n(String locale) : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static L10n of(BuildContext context) {
    return Localizations.of<L10n>(context, L10n)!;
  }

  static const LocalizationsDelegate<L10n> delegate = _L10nDelegate();

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
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ko')
  ];

  /// 앱 이름 — 영어 표기 유지 (브랜드)
  ///
  /// In ko, this message translates to:
  /// **'HumTrack'**
  String get appName;

  /// No description provided for @ok.
  ///
  /// In ko, this message translates to:
  /// **'확인'**
  String get ok;

  /// No description provided for @cancel.
  ///
  /// In ko, this message translates to:
  /// **'취소'**
  String get cancel;

  /// No description provided for @save.
  ///
  /// In ko, this message translates to:
  /// **'저장'**
  String get save;

  /// No description provided for @delete.
  ///
  /// In ko, this message translates to:
  /// **'삭제'**
  String get delete;

  /// No description provided for @rename.
  ///
  /// In ko, this message translates to:
  /// **'이름 바꾸기'**
  String get rename;

  /// No description provided for @later.
  ///
  /// In ko, this message translates to:
  /// **'나중에'**
  String get later;

  /// No description provided for @retry.
  ///
  /// In ko, this message translates to:
  /// **'다시 시도'**
  String get retry;

  /// No description provided for @close.
  ///
  /// In ko, this message translates to:
  /// **'닫기'**
  String get close;

  /// No description provided for @done.
  ///
  /// In ko, this message translates to:
  /// **'완료'**
  String get done;

  /// No description provided for @apply.
  ///
  /// In ko, this message translates to:
  /// **'적용'**
  String get apply;

  /// No description provided for @use.
  ///
  /// In ko, this message translates to:
  /// **'사용'**
  String get use;

  /// No description provided for @tabSongs.
  ///
  /// In ko, this message translates to:
  /// **'내 작업물'**
  String get tabSongs;

  /// No description provided for @tabCloud.
  ///
  /// In ko, this message translates to:
  /// **'클라우드'**
  String get tabCloud;

  /// No description provided for @navStudio.
  ///
  /// In ko, this message translates to:
  /// **'STUDIO'**
  String get navStudio;

  /// No description provided for @navSongs.
  ///
  /// In ko, this message translates to:
  /// **'SONGS'**
  String get navSongs;

  /// No description provided for @navMixer.
  ///
  /// In ko, this message translates to:
  /// **'MIXER'**
  String get navMixer;

  /// No description provided for @actionUpgradeToPro.
  ///
  /// In ko, this message translates to:
  /// **'Pro 로 업그레이드'**
  String get actionUpgradeToPro;

  /// No description provided for @freeCloudHeadline.
  ///
  /// In ko, this message translates to:
  /// **'아직 클라우드가 없어요'**
  String get freeCloudHeadline;

  /// No description provided for @freeCloudSub.
  ///
  /// In ko, this message translates to:
  /// **'Pro 로 전환하면 {gb}GB 클라우드를 받아\n모든 기기에서 작업물을 이어 만들 수 있어요.'**
  String freeCloudSub(int gb);

  /// No description provided for @valueCloudStorage.
  ///
  /// In ko, this message translates to:
  /// **'{gb}GB 클라우드 보관'**
  String valueCloudStorage(int gb);

  /// No description provided for @valueExportUnlimited.
  ///
  /// In ko, this message translates to:
  /// **'무제한 내보내기'**
  String get valueExportUnlimited;

  /// No description provided for @valueAnalysisPriority.
  ///
  /// In ko, this message translates to:
  /// **'우선 분석 처리'**
  String get valueAnalysisPriority;

  /// No description provided for @valuePersistentVocal.
  ///
  /// In ko, this message translates to:
  /// **'영구 보관'**
  String get valuePersistentVocal;

  /// No description provided for @trialStartCta.
  ///
  /// In ko, this message translates to:
  /// **'7일 무료 체험 시작'**
  String get trialStartCta;

  /// No description provided for @trialPriceFootnote.
  ///
  /// In ko, this message translates to:
  /// **'{price}/월 (체험 후 자동 결제)'**
  String trialPriceFootnote(String price);

  /// No description provided for @cloudUsageLabel.
  ///
  /// In ko, this message translates to:
  /// **'{used} / {total} 사용 중'**
  String cloudUsageLabel(String used, String total);

  /// No description provided for @projectActionUploadToCloud.
  ///
  /// In ko, this message translates to:
  /// **'클라우드에 올리기'**
  String get projectActionUploadToCloud;

  /// No description provided for @projectActionRefreshCloud.
  ///
  /// In ko, this message translates to:
  /// **'클라우드 최신화'**
  String get projectActionRefreshCloud;

  /// No description provided for @projectActionDownloadFromCloud.
  ///
  /// In ko, this message translates to:
  /// **'내 기기에 받기'**
  String get projectActionDownloadFromCloud;

  /// No description provided for @projectActionDeleteFromCloud.
  ///
  /// In ko, this message translates to:
  /// **'클라우드에서만 삭제'**
  String get projectActionDeleteFromCloud;

  /// No description provided for @projectActionDeleteFromCloudSub.
  ///
  /// In ko, this message translates to:
  /// **'내 기기 작업물은 그대로 남아요'**
  String get projectActionDeleteFromCloudSub;

  /// No description provided for @syncInProgress.
  ///
  /// In ko, this message translates to:
  /// **'클라우드에 올리는 중...'**
  String get syncInProgress;

  /// No description provided for @downloadInProgress.
  ///
  /// In ko, this message translates to:
  /// **'내 기기로 받는 중...'**
  String get downloadInProgress;

  /// No description provided for @syncFailed.
  ///
  /// In ko, this message translates to:
  /// **'동기화 실패 — 탭하여 재시도'**
  String get syncFailed;

  /// No description provided for @settingsCloudHeader.
  ///
  /// In ko, this message translates to:
  /// **'내 클라우드'**
  String get settingsCloudHeader;

  /// No description provided for @settingsAutoSync.
  ///
  /// In ko, this message translates to:
  /// **'자동 동기화'**
  String get settingsAutoSync;

  /// No description provided for @settingsAutoSyncDesc.
  ///
  /// In ko, this message translates to:
  /// **'변경된 작업물을 자동으로 클라우드에 올려요'**
  String get settingsAutoSyncDesc;

  /// No description provided for @menuLanguage.
  ///
  /// In ko, this message translates to:
  /// **'언어'**
  String get menuLanguage;

  /// No description provided for @languageScreenTitle.
  ///
  /// In ko, this message translates to:
  /// **'언어'**
  String get languageScreenTitle;

  /// No description provided for @languageSystemDefault.
  ///
  /// In ko, this message translates to:
  /// **'시스템 기본'**
  String get languageSystemDefault;

  /// No description provided for @languageSystemDefaultSub.
  ///
  /// In ko, this message translates to:
  /// **'기기 설정 언어를 따라가요'**
  String get languageSystemDefaultSub;

  /// No description provided for @languageNameKorean.
  ///
  /// In ko, this message translates to:
  /// **'한국어'**
  String get languageNameKorean;

  /// No description provided for @languageNameEnglish.
  ///
  /// In ko, this message translates to:
  /// **'English'**
  String get languageNameEnglish;

  /// No description provided for @songsTitle.
  ///
  /// In ko, this message translates to:
  /// **'Songs'**
  String get songsTitle;

  /// No description provided for @songsEmptyTitle.
  ///
  /// In ko, this message translates to:
  /// **'새 곡 작업을 시작하세요'**
  String get songsEmptyTitle;

  /// No description provided for @songsEmptySub.
  ///
  /// In ko, this message translates to:
  /// **'흥얼거리면 악기로 변환되고, 녹음부터 편집까지 한 번에'**
  String get songsEmptySub;

  /// No description provided for @songsEmptyCta.
  ///
  /// In ko, this message translates to:
  /// **'작업 시작'**
  String get songsEmptyCta;

  /// No description provided for @songsCardInCloud.
  ///
  /// In ko, this message translates to:
  /// **'클라우드에 있음'**
  String get songsCardInCloud;

  /// No description provided for @songsTrackCountChip.
  ///
  /// In ko, this message translates to:
  /// **'{count}트랙'**
  String songsTrackCountChip(int count);

  /// No description provided for @projectDurationLabel.
  ///
  /// In ko, this message translates to:
  /// **'{min}분 {sec}초'**
  String projectDurationLabel(int min, String sec);

  /// No description provided for @agoJustNow.
  ///
  /// In ko, this message translates to:
  /// **'방금 전'**
  String get agoJustNow;

  /// No description provided for @agoMinutes.
  ///
  /// In ko, this message translates to:
  /// **'{n}분 전'**
  String agoMinutes(int n);

  /// No description provided for @agoHours.
  ///
  /// In ko, this message translates to:
  /// **'{n}시간 전'**
  String agoHours(int n);

  /// No description provided for @agoDays.
  ///
  /// In ko, this message translates to:
  /// **'{n}일 전'**
  String agoDays(int n);

  /// No description provided for @agoJustUploaded.
  ///
  /// In ko, this message translates to:
  /// **'방금 올림'**
  String get agoJustUploaded;

  /// No description provided for @agoMonthDay.
  ///
  /// In ko, this message translates to:
  /// **'{month}월 {day}일'**
  String agoMonthDay(int month, int day);

  /// No description provided for @agoJustEdited.
  ///
  /// In ko, this message translates to:
  /// **'방금 수정'**
  String get agoJustEdited;

  /// No description provided for @agoSecondsAgo.
  ///
  /// In ko, this message translates to:
  /// **'{n}초 전'**
  String agoSecondsAgo(int n);

  /// No description provided for @accountTitle.
  ///
  /// In ko, this message translates to:
  /// **'계정'**
  String get accountTitle;

  /// No description provided for @accountNotSignedIn.
  ///
  /// In ko, this message translates to:
  /// **'로그인되지 않음'**
  String get accountNotSignedIn;

  /// No description provided for @accountProviderSuffix.
  ///
  /// In ko, this message translates to:
  /// **'{provider} 계정'**
  String accountProviderSuffix(String provider);

  /// No description provided for @accountLinked.
  ///
  /// In ko, this message translates to:
  /// **'계정 연동됨'**
  String get accountLinked;

  /// No description provided for @accountSignInHint.
  ///
  /// In ko, this message translates to:
  /// **'로그인하면 결제와 동기화가 가능해요'**
  String get accountSignInHint;

  /// No description provided for @accountSignIn.
  ///
  /// In ko, this message translates to:
  /// **'로그인'**
  String get accountSignIn;

  /// No description provided for @subFreePlan.
  ///
  /// In ko, this message translates to:
  /// **'무료 플랜'**
  String get subFreePlan;

  /// No description provided for @subFreePlanSub.
  ///
  /// In ko, this message translates to:
  /// **'내보내기와 클라우드 동기화는 Pro 에서 잠금이 풀려요'**
  String get subFreePlanSub;

  /// No description provided for @subTrial.
  ///
  /// In ko, this message translates to:
  /// **'무료 체험 중'**
  String get subTrial;

  /// No description provided for @subTrialBillsOn.
  ///
  /// In ko, this message translates to:
  /// **'{date}에 자동 결제 시작'**
  String subTrialBillsOn(String date);

  /// No description provided for @subTrialNDays.
  ///
  /// In ko, this message translates to:
  /// **'{days}일 체험'**
  String subTrialNDays(int days);

  /// No description provided for @subActive.
  ///
  /// In ko, this message translates to:
  /// **'Humming Pro'**
  String get subActive;

  /// No description provided for @subActiveRenewsOn.
  ///
  /// In ko, this message translates to:
  /// **'{date} 자동 갱신'**
  String subActiveRenewsOn(String date);

  /// No description provided for @subActiveAllOn.
  ///
  /// In ko, this message translates to:
  /// **'모든 기능 활성화됨'**
  String get subActiveAllOn;

  /// No description provided for @subCancelled.
  ///
  /// In ko, this message translates to:
  /// **'Pro · 해지 예약'**
  String get subCancelled;

  /// No description provided for @subCancelledValidUntil.
  ///
  /// In ko, this message translates to:
  /// **'{date}까지 이용 가능'**
  String subCancelledValidUntil(String date);

  /// No description provided for @subCancelledUntilExpiry.
  ///
  /// In ko, this message translates to:
  /// **'만료 전까지 사용 가능'**
  String get subCancelledUntilExpiry;

  /// No description provided for @subExpired.
  ///
  /// In ko, this message translates to:
  /// **'구독이 만료됐어요'**
  String get subExpired;

  /// No description provided for @subExpiredRestoreHint.
  ///
  /// In ko, this message translates to:
  /// **'다시 구독하면 즉시 복원돼요'**
  String get subExpiredRestoreHint;

  /// No description provided for @accountMenuManage.
  ///
  /// In ko, this message translates to:
  /// **'구독 관리'**
  String get accountMenuManage;

  /// No description provided for @accountMenuCloudRecover.
  ///
  /// In ko, this message translates to:
  /// **'클라우드에서 가져오기'**
  String get accountMenuCloudRecover;

  /// No description provided for @accountMenuCloudRecoverSub.
  ///
  /// In ko, this message translates to:
  /// **'작업물은 직접 삭제하기 전까지 보관됨'**
  String get accountMenuCloudRecoverSub;

  /// No description provided for @accountMenuLanguage.
  ///
  /// In ko, this message translates to:
  /// **'언어 / Language'**
  String get accountMenuLanguage;

  /// No description provided for @accountMenuFaq.
  ///
  /// In ko, this message translates to:
  /// **'FAQ'**
  String get accountMenuFaq;

  /// No description provided for @accountMenuContact.
  ///
  /// In ko, this message translates to:
  /// **'문의하기'**
  String get accountMenuContact;

  /// No description provided for @accountMenuTerms.
  ///
  /// In ko, this message translates to:
  /// **'서비스 약관'**
  String get accountMenuTerms;

  /// No description provided for @accountMenuPrivacy.
  ///
  /// In ko, this message translates to:
  /// **'개인정보처리방침'**
  String get accountMenuPrivacy;

  /// No description provided for @accountMenuRefund.
  ///
  /// In ko, this message translates to:
  /// **'환불 정책'**
  String get accountMenuRefund;

  /// No description provided for @devModeTitle.
  ///
  /// In ko, this message translates to:
  /// **'개발자 모드'**
  String get devModeTitle;

  /// No description provided for @devSubscriptionLabel.
  ///
  /// In ko, this message translates to:
  /// **'구독 상태 (디버그 빌드만 노출)'**
  String get devSubscriptionLabel;

  /// No description provided for @devCloudMockLabel.
  ///
  /// In ko, this message translates to:
  /// **'클라우드 mock 데이터'**
  String get devCloudMockLabel;

  /// No description provided for @accountDetailTitle.
  ///
  /// In ko, this message translates to:
  /// **'계정 정보'**
  String get accountDetailTitle;

  /// No description provided for @labelEmail.
  ///
  /// In ko, this message translates to:
  /// **'이메일'**
  String get labelEmail;

  /// No description provided for @labelSignInMethod.
  ///
  /// In ko, this message translates to:
  /// **'로그인 방법'**
  String get labelSignInMethod;

  /// No description provided for @labelAccountId.
  ///
  /// In ko, this message translates to:
  /// **'계정 ID'**
  String get labelAccountId;

  /// No description provided for @withdrawHint.
  ///
  /// In ko, this message translates to:
  /// **'회원 탈퇴 시 모든 로컬 프로젝트와 클라우드 데이터가 삭제됩니다.\n구독 중인 경우 App Store / Google Play 에서 별도로 해지해 주세요.'**
  String get withdrawHint;

  /// No description provided for @withdrawCta.
  ///
  /// In ko, this message translates to:
  /// **'회원 탈퇴'**
  String get withdrawCta;

  /// No description provided for @withdrawConfirmTitle.
  ///
  /// In ko, this message translates to:
  /// **'정말 탈퇴하시겠어요?'**
  String get withdrawConfirmTitle;

  /// No description provided for @withdrawConfirmBody.
  ///
  /// In ko, this message translates to:
  /// **'계정과 모든 데이터가 영구 삭제되고 복구할 수 없어요.'**
  String get withdrawConfirmBody;

  /// No description provided for @withdrawConfirmAction.
  ///
  /// In ko, this message translates to:
  /// **'탈퇴'**
  String get withdrawConfirmAction;

  /// No description provided for @withdrawFailed.
  ///
  /// In ko, this message translates to:
  /// **'탈퇴 실패: {err}'**
  String withdrawFailed(String err);

  /// No description provided for @withdrawCompleted.
  ///
  /// In ko, this message translates to:
  /// **'탈퇴가 완료됐어요'**
  String get withdrawCompleted;

  /// No description provided for @subScreenTitle.
  ///
  /// In ko, this message translates to:
  /// **'구독 관리'**
  String get subScreenTitle;

  /// No description provided for @subStatusActive.
  ///
  /// In ko, this message translates to:
  /// **'Humming Pro · 활성'**
  String get subStatusActive;

  /// No description provided for @subStatusActiveRenewsOn.
  ///
  /// In ko, this message translates to:
  /// **'{date}에 자동 갱신돼요'**
  String subStatusActiveRenewsOn(String date);

  /// No description provided for @subStatusActiveAutoOn.
  ///
  /// In ko, this message translates to:
  /// **'자동 갱신 활성'**
  String get subStatusActiveAutoOn;

  /// No description provided for @subStatusTrialBillsOn.
  ///
  /// In ko, this message translates to:
  /// **'{date}에 자동 결제'**
  String subStatusTrialBillsOn(String date);

  /// No description provided for @subStatusTrialNDays.
  ///
  /// In ko, this message translates to:
  /// **'{days}일 무료 체험'**
  String subStatusTrialNDays(int days);

  /// No description provided for @subStatusCancelled.
  ///
  /// In ko, this message translates to:
  /// **'해지 예약됨'**
  String get subStatusCancelled;

  /// No description provided for @subStatusCancelledUntil.
  ///
  /// In ko, this message translates to:
  /// **'{date}까지 Pro 사용 가능'**
  String subStatusCancelledUntil(String date);

  /// No description provided for @subStatusExpiredBody.
  ///
  /// In ko, this message translates to:
  /// **'다시 구독하면 클라우드 작업물이 즉시 복원돼요'**
  String get subStatusExpiredBody;

  /// No description provided for @subStatusAnonymous.
  ///
  /// In ko, this message translates to:
  /// **'구독 정보 없음'**
  String get subStatusAnonymous;

  /// No description provided for @subStatusAnonymousBody.
  ///
  /// In ko, this message translates to:
  /// **'먼저 로그인하고 결제를 시작해 주세요'**
  String get subStatusAnonymousBody;

  /// No description provided for @subCurrentEntitlements.
  ///
  /// In ko, this message translates to:
  /// **'현재 권한'**
  String get subCurrentEntitlements;

  /// No description provided for @subFeatureCloudSync.
  ///
  /// In ko, this message translates to:
  /// **'클라우드 동기화'**
  String get subFeatureCloudSync;

  /// No description provided for @subFeatureExport.
  ///
  /// In ko, this message translates to:
  /// **'무제한 내보내기 (WAV / MIDI)'**
  String get subFeatureExport;

  /// No description provided for @subFeatureVocalBackup.
  ///
  /// In ko, this message translates to:
  /// **'보컬 영구 보관'**
  String get subFeatureVocalBackup;

  /// No description provided for @subFeaturePriority.
  ///
  /// In ko, this message translates to:
  /// **'우선 처리 (빠른 분석)'**
  String get subFeaturePriority;

  /// No description provided for @subStoreNoticeActive.
  ///
  /// In ko, this message translates to:
  /// **'결제 정보 변경, 구독 해지, 환불 요청은 {store} 의 구독 설정에서 진행할 수 있어요.'**
  String subStoreNoticeActive(String store);

  /// No description provided for @subStoreNoticeCancelled.
  ///
  /// In ko, this message translates to:
  /// **'만료일까지 모든 기능을 그대로 쓸 수 있어요.\n해지 취소(재활성화)는 {store} 의 구독 설정에서 가능합니다.'**
  String subStoreNoticeCancelled(String store);

  /// No description provided for @subResubCta.
  ///
  /// In ko, this message translates to:
  /// **'Pro 다시 구독하기'**
  String get subResubCta;

  /// No description provided for @subResubHint.
  ///
  /// In ko, this message translates to:
  /// **'이전 작업물은 그대로 보관돼 있어요 — 재구독하면 다시 동기화돼요'**
  String get subResubHint;

  /// No description provided for @subStartCta.
  ///
  /// In ko, this message translates to:
  /// **'구독 시작'**
  String get subStartCta;

  /// No description provided for @subCancelConfirmTitle.
  ///
  /// In ko, this message translates to:
  /// **'정말 해지하시겠어요?'**
  String get subCancelConfirmTitle;

  /// No description provided for @subCancelConfirmBody.
  ///
  /// In ko, this message translates to:
  /// **'만료일까지는 모든 Pro 기능을 그대로 사용하실 수 있어요.'**
  String get subCancelConfirmBody;

  /// No description provided for @subCancelConfirmAction.
  ///
  /// In ko, this message translates to:
  /// **'해지'**
  String get subCancelConfirmAction;

  /// No description provided for @paywallHeadlineExport.
  ///
  /// In ko, this message translates to:
  /// **'내보내려면 Pro 가 필요해요'**
  String get paywallHeadlineExport;

  /// No description provided for @paywallHeadlineSync.
  ///
  /// In ko, this message translates to:
  /// **'다른 기기에서 보려면 Pro'**
  String get paywallHeadlineSync;

  /// No description provided for @paywallHeadlineBackup.
  ///
  /// In ko, this message translates to:
  /// **'보컬 영구 보관'**
  String get paywallHeadlineBackup;

  /// No description provided for @paywallHeadlineDefault.
  ///
  /// In ko, this message translates to:
  /// **'Humming Pro'**
  String get paywallHeadlineDefault;

  /// No description provided for @paywallSubExport.
  ///
  /// In ko, this message translates to:
  /// **'WAV · MIDI 파일로 저장하고 공유하세요'**
  String get paywallSubExport;

  /// No description provided for @paywallSubSync.
  ///
  /// In ko, this message translates to:
  /// **'클라우드 동기화로 어디서든 이어서 작업'**
  String get paywallSubSync;

  /// No description provided for @paywallSubBackup.
  ///
  /// In ko, this message translates to:
  /// **'내 목소리를 잃지 않고 평생 보관'**
  String get paywallSubBackup;

  /// No description provided for @paywallSubDefault.
  ///
  /// In ko, this message translates to:
  /// **'전체 기능 잠금 해제'**
  String get paywallSubDefault;

  /// No description provided for @looptapPaywallTriggerExport.
  ///
  /// In ko, this message translates to:
  /// **'내보내기는 Pro 전용 기능입니다 — 구독하시면 MIDI / 오디오를 저장할 수 있어요.'**
  String get looptapPaywallTriggerExport;

  /// No description provided for @looptapPaywallTriggerSongQuota.
  ///
  /// In ko, this message translates to:
  /// **'무료 플랜의 곡 개수 한도에 도달했어요. Pro 로 업그레이드하면 무제한으로 만들 수 있습니다.'**
  String get looptapPaywallTriggerSongQuota;

  /// No description provided for @paywallFeatureCloudTitle.
  ///
  /// In ko, this message translates to:
  /// **'5GB 클라우드'**
  String get paywallFeatureCloudTitle;

  /// No description provided for @paywallFeatureCloudSub.
  ///
  /// In ko, this message translates to:
  /// **'모든 기기에서 작업물 이어쓰기'**
  String get paywallFeatureCloudSub;

  /// No description provided for @paywallFeatureBackupTitle.
  ///
  /// In ko, this message translates to:
  /// **'영구 보관'**
  String get paywallFeatureBackupTitle;

  /// No description provided for @paywallFeatureBackupSub.
  ///
  /// In ko, this message translates to:
  /// **'기기 변경 · 분실에도 작업물은 그대로'**
  String get paywallFeatureBackupSub;

  /// No description provided for @paywallFeatureExportTitle.
  ///
  /// In ko, this message translates to:
  /// **'무제한 내보내기'**
  String get paywallFeatureExportTitle;

  /// No description provided for @paywallFeatureExportSub.
  ///
  /// In ko, this message translates to:
  /// **'WAV · MIDI · 스템 모두'**
  String get paywallFeatureExportSub;

  /// No description provided for @paywallFeaturePriorityTitle.
  ///
  /// In ko, this message translates to:
  /// **'우선 분석 처리'**
  String get paywallFeaturePriorityTitle;

  /// No description provided for @paywallFeaturePrioritySub.
  ///
  /// In ko, this message translates to:
  /// **'더 빠른 허밍 분석 / 렌더'**
  String get paywallFeaturePrioritySub;

  /// No description provided for @paywallPlanYearly.
  ///
  /// In ko, this message translates to:
  /// **'연 구독'**
  String get paywallPlanYearly;

  /// No description provided for @paywallPlanYearlyPrice.
  ///
  /// In ko, this message translates to:
  /// **'{price} / 년'**
  String paywallPlanYearlyPrice(String price);

  /// No description provided for @paywallPlanYearlyHint.
  ///
  /// In ko, this message translates to:
  /// **'월 {monthly} 환산'**
  String paywallPlanYearlyHint(String monthly);

  /// No description provided for @paywallPlanMonthly.
  ///
  /// In ko, this message translates to:
  /// **'월 구독'**
  String get paywallPlanMonthly;

  /// No description provided for @paywallPlanMonthlyPrice.
  ///
  /// In ko, this message translates to:
  /// **'{price} / 월'**
  String paywallPlanMonthlyPrice(String price);

  /// No description provided for @paywallPlanMonthlyHint.
  ///
  /// In ko, this message translates to:
  /// **'언제든 해지'**
  String get paywallPlanMonthlyHint;

  /// No description provided for @paywallCtaProcessing.
  ///
  /// In ko, this message translates to:
  /// **'결제 처리 중…'**
  String get paywallCtaProcessing;

  /// No description provided for @paywallCtaStartTrial.
  ///
  /// In ko, this message translates to:
  /// **'{days}일 무료로 시작하기'**
  String paywallCtaStartTrial(int days);

  /// No description provided for @paywallFooterTrial.
  ///
  /// In ko, this message translates to:
  /// **'체험 종료 전 알림 · 언제든 해지 가능'**
  String get paywallFooterTrial;

  /// No description provided for @paywallRestoreLink.
  ///
  /// In ko, this message translates to:
  /// **'구매 복원'**
  String get paywallRestoreLink;

  /// No description provided for @loginTitle.
  ///
  /// In ko, this message translates to:
  /// **'로그인'**
  String get loginTitle;

  /// No description provided for @loginSub.
  ///
  /// In ko, this message translates to:
  /// **'구독 결제와 클라우드 동기화에 사용돼요'**
  String get loginSub;

  /// No description provided for @loginFailedTitle.
  ///
  /// In ko, this message translates to:
  /// **'로그인 실패'**
  String get loginFailedTitle;

  /// No description provided for @loginTermsPrefix.
  ///
  /// In ko, this message translates to:
  /// **'HumTrack '**
  String get loginTermsPrefix;

  /// No description provided for @loginTermsBetween.
  ///
  /// In ko, this message translates to:
  /// **' 및 '**
  String get loginTermsBetween;

  /// No description provided for @loginTermsSuffix.
  ///
  /// In ko, this message translates to:
  /// **'을 읽었으며 이에 동의합니다.'**
  String get loginTermsSuffix;

  /// No description provided for @loginTermsLinkTerms.
  ///
  /// In ko, this message translates to:
  /// **'서비스 약관'**
  String get loginTermsLinkTerms;

  /// No description provided for @loginTermsLinkPrivacy.
  ///
  /// In ko, this message translates to:
  /// **'개인정보 처리방침'**
  String get loginTermsLinkPrivacy;

  /// No description provided for @appleSignInCta.
  ///
  /// In ko, this message translates to:
  /// **'Apple로 계속하기'**
  String get appleSignInCta;

  /// No description provided for @googleSignInCta.
  ///
  /// In ko, this message translates to:
  /// **'Google로 계속하기'**
  String get googleSignInCta;

  /// No description provided for @logoutConfirmTitle.
  ///
  /// In ko, this message translates to:
  /// **'로그아웃 하시겠어요?'**
  String get logoutConfirmTitle;

  /// No description provided for @logoutConfirmBody.
  ///
  /// In ko, this message translates to:
  /// **'이 기기의 로컬 프로젝트는 그대로 남아있어요. 다시 로그인하면 클라우드 작업물도 복원됩니다.'**
  String get logoutConfirmBody;

  /// No description provided for @logoutCta.
  ///
  /// In ko, this message translates to:
  /// **'로그아웃'**
  String get logoutCta;

  /// No description provided for @restoreOkTitle.
  ///
  /// In ko, this message translates to:
  /// **'복원 완료'**
  String get restoreOkTitle;

  /// No description provided for @restoreEmptyTitle.
  ///
  /// In ko, this message translates to:
  /// **'복원할 구매가 없어요'**
  String get restoreEmptyTitle;

  /// No description provided for @restoreOkBody.
  ///
  /// In ko, this message translates to:
  /// **'Pro 기능이 다시 활성화됐어요.'**
  String get restoreOkBody;

  /// No description provided for @restoreEmptyBody.
  ///
  /// In ko, this message translates to:
  /// **'다른 계정으로 로그인했는지 확인해 주세요.'**
  String get restoreEmptyBody;

  /// No description provided for @projectOptionUploadProBadge.
  ///
  /// In ko, this message translates to:
  /// **'Pro 필요'**
  String get projectOptionUploadProBadge;

  /// No description provided for @projectOptionRefreshSyncedAt.
  ///
  /// In ko, this message translates to:
  /// **'{ago} 동기됨'**
  String projectOptionRefreshSyncedAt(String ago);

  /// No description provided for @projectOptionOpen.
  ///
  /// In ko, this message translates to:
  /// **'열기'**
  String get projectOptionOpen;

  /// No description provided for @projectOptionRename.
  ///
  /// In ko, this message translates to:
  /// **'이름 바꾸기'**
  String get projectOptionRename;

  /// No description provided for @projectOptionDuplicate.
  ///
  /// In ko, this message translates to:
  /// **'복제'**
  String get projectOptionDuplicate;

  /// No description provided for @projectOptionExport.
  ///
  /// In ko, this message translates to:
  /// **'내보내기'**
  String get projectOptionExport;

  /// No description provided for @projectOptionExportSub.
  ///
  /// In ko, this message translates to:
  /// **'WAV · MIDI'**
  String get projectOptionExportSub;

  /// No description provided for @projectOptionDelete.
  ///
  /// In ko, this message translates to:
  /// **'삭제'**
  String get projectOptionDelete;

  /// No description provided for @projectOptionDeleteSub.
  ///
  /// In ko, this message translates to:
  /// **'되돌릴 수 없어요'**
  String get projectOptionDeleteSub;

  /// No description provided for @projectUploadedToast.
  ///
  /// In ko, this message translates to:
  /// **'{title} — 클라우드에 올렸어요'**
  String projectUploadedToast(String title);

  /// No description provided for @projectHeaderMeta.
  ///
  /// In ko, this message translates to:
  /// **'{count}개 트랙 · {dur} · {ago}'**
  String projectHeaderMeta(int count, String dur, String ago);

  /// No description provided for @projectDeleteTitle.
  ///
  /// In ko, this message translates to:
  /// **'\"{title}\" 삭제'**
  String projectDeleteTitle(String title);

  /// No description provided for @projectDeleteBody.
  ///
  /// In ko, this message translates to:
  /// **'로컬 파일이 영구 삭제돼요. 이 작업은 되돌릴 수 없어요.'**
  String get projectDeleteBody;

  /// No description provided for @cloudFreeImageHeadline.
  ///
  /// In ko, this message translates to:
  /// **'아직 클라우드가 없어요'**
  String get cloudFreeImageHeadline;

  /// No description provided for @cloudFreeImageSub.
  ///
  /// In ko, this message translates to:
  /// **'Pro 로 전환하면 5GB 클라우드를 받아\n모든 기기에서 작업물을 이어 만들 수 있어요.'**
  String get cloudFreeImageSub;

  /// No description provided for @cloudValueBackupTitle.
  ///
  /// In ko, this message translates to:
  /// **'영구 보관'**
  String get cloudValueBackupTitle;

  /// No description provided for @cloudValueBackupSub.
  ///
  /// In ko, this message translates to:
  /// **'기기 변경 · 분실에도 안전'**
  String get cloudValueBackupSub;

  /// No description provided for @cloudValueAutoSyncTitle.
  ///
  /// In ko, this message translates to:
  /// **'자동 이어쓰기'**
  String get cloudValueAutoSyncTitle;

  /// No description provided for @cloudValueAutoSyncSub.
  ///
  /// In ko, this message translates to:
  /// **'다른 기기 로그인만 하면 그대로'**
  String get cloudValueAutoSyncSub;

  /// No description provided for @cloudValueExportTitle.
  ///
  /// In ko, this message translates to:
  /// **'무제한 내보내기'**
  String get cloudValueExportTitle;

  /// No description provided for @cloudValueExportSub.
  ///
  /// In ko, this message translates to:
  /// **'WAV · MIDI · 스템 모두'**
  String get cloudValueExportSub;

  /// No description provided for @cloudUpgradeFootnote.
  ///
  /// In ko, this message translates to:
  /// **'{days}일 무료 체험 · 이후 {price}/월'**
  String cloudUpgradeFootnote(int days, String price);

  /// No description provided for @cloudProEmptyTitle.
  ///
  /// In ko, this message translates to:
  /// **'클라우드가 비어있어요'**
  String get cloudProEmptyTitle;

  /// No description provided for @cloudProEmptySub.
  ///
  /// In ko, this message translates to:
  /// **'내 작업물 탭에서 작업물의 ⋯ 메뉴를 열고\n\"클라우드에 올리기\"를 눌러 보세요.'**
  String get cloudProEmptySub;

  /// No description provided for @cloudGoToLocalTab.
  ///
  /// In ko, this message translates to:
  /// **'내 작업물 탭으로 가기'**
  String get cloudGoToLocalTab;

  /// No description provided for @cloudGraceTitle.
  ///
  /// In ko, this message translates to:
  /// **'Pro 가 만료됐어요'**
  String get cloudGraceTitle;

  /// No description provided for @cloudGraceBody.
  ///
  /// In ko, this message translates to:
  /// **'데이터는 그대로 보관돼 있어요. 다운로드는 언제든 가능하고, 재구독하면 동기화가 다시 켜져요.'**
  String get cloudGraceBody;

  /// No description provided for @cloudGraceEmpty.
  ///
  /// In ko, this message translates to:
  /// **'클라우드 보관함이 비어있어요'**
  String get cloudGraceEmpty;

  /// No description provided for @cloudUsageInUse.
  ///
  /// In ko, this message translates to:
  /// **'사용 중'**
  String get cloudUsageInUse;

  /// No description provided for @cloudUsageStored.
  ///
  /// In ko, this message translates to:
  /// **'보관 중'**
  String get cloudUsageStored;

  /// No description provided for @cloudUsageReadOnly.
  ///
  /// In ko, this message translates to:
  /// **'읽기 전용'**
  String get cloudUsageReadOnly;

  /// No description provided for @cloudUsageCount.
  ///
  /// In ko, this message translates to:
  /// **'{n}개 작업물 보관 중'**
  String cloudUsageCount(int n);

  /// No description provided for @cloudUsageCountStored.
  ///
  /// In ko, this message translates to:
  /// **'{n}개 작업물'**
  String cloudUsageCountStored(int n);

  /// No description provided for @cloudCardThisDevice.
  ///
  /// In ko, this message translates to:
  /// **'이 기기'**
  String get cloudCardThisDevice;

  /// No description provided for @cloudCardDownload.
  ///
  /// In ko, this message translates to:
  /// **'받기'**
  String get cloudCardDownload;

  /// No description provided for @cloudOptionsSubtitle.
  ///
  /// In ko, this message translates to:
  /// **'☁ 클라우드 · {uploadedAt} 올림 · {size}'**
  String cloudOptionsSubtitle(String uploadedAt, String size);

  /// No description provided for @cloudOptionsDownloadAgain.
  ///
  /// In ko, this message translates to:
  /// **'내 기기에 다시 받기'**
  String get cloudOptionsDownloadAgain;

  /// No description provided for @cloudOptionsDownload.
  ///
  /// In ko, this message translates to:
  /// **'내 기기에 받기'**
  String get cloudOptionsDownload;

  /// No description provided for @settingsCloudPercentUsed.
  ///
  /// In ko, this message translates to:
  /// **'{pct}% 사용'**
  String settingsCloudPercentUsed(int pct);

  /// No description provided for @settingsCloudFree.
  ///
  /// In ko, this message translates to:
  /// **'{free} 여유'**
  String settingsCloudFree(String free);

  /// No description provided for @settingsCloudUsageDetail.
  ///
  /// In ko, this message translates to:
  /// **'사용량 자세히'**
  String get settingsCloudUsageDetail;

  /// No description provided for @settingsCloudUsageDetailLink.
  ///
  /// In ko, this message translates to:
  /// **'사용량 자세히 →'**
  String get settingsCloudUsageDetailLink;

  /// No description provided for @syncProgressUpload.
  ///
  /// In ko, this message translates to:
  /// **'클라우드에 올리는 중'**
  String get syncProgressUpload;

  /// No description provided for @syncProgressDownload.
  ///
  /// In ko, this message translates to:
  /// **'내 기기로 받는 중'**
  String get syncProgressDownload;

  /// No description provided for @comingSoonFeature.
  ///
  /// In ko, this message translates to:
  /// **'기능'**
  String get comingSoonFeature;

  /// No description provided for @comingSoonToast.
  ///
  /// In ko, this message translates to:
  /// **'{label} — 준비중입니다'**
  String comingSoonToast(String label);

  /// No description provided for @proWelcomeTitle.
  ///
  /// In ko, this message translates to:
  /// **'클라우드가 활성화됐어요'**
  String get proWelcomeTitle;

  /// No description provided for @proWelcomeBody.
  ///
  /// In ko, this message translates to:
  /// **'이제 어디서나 작업물을 이어 만들 수 있어요.'**
  String get proWelcomeBody;

  /// No description provided for @proWelcomeBadgeLabel.
  ///
  /// In ko, this message translates to:
  /// **'내 클라우드'**
  String get proWelcomeBadgeLabel;

  /// No description provided for @proWelcomeStep1Prefix.
  ///
  /// In ko, this message translates to:
  /// **'내 작업물의 ⋯ 메뉴에서 '**
  String get proWelcomeStep1Prefix;

  /// No description provided for @proWelcomeStep1Bold.
  ///
  /// In ko, this message translates to:
  /// **'클라우드에 올리기'**
  String get proWelcomeStep1Bold;

  /// No description provided for @proWelcomeStep2.
  ///
  /// In ko, this message translates to:
  /// **'다른 기기에서 로그인 → 클라우드 자동 표시'**
  String get proWelcomeStep2;

  /// No description provided for @proWelcomeStep3.
  ///
  /// In ko, this message translates to:
  /// **'양쪽 어디서든 자유롭게 작업'**
  String get proWelcomeStep3;

  /// No description provided for @proWelcomeCta.
  ///
  /// In ko, this message translates to:
  /// **'클라우드 둘러보기'**
  String get proWelcomeCta;

  /// No description provided for @recPermDenied.
  ///
  /// In ko, this message translates to:
  /// **'마이크 권한이 필요합니다. 다시 허용해주세요.'**
  String get recPermDenied;

  /// No description provided for @recPermPermanentlyDenied.
  ///
  /// In ko, this message translates to:
  /// **'설정 > 개인정보 > 마이크에서 권한을 켜주세요.'**
  String get recPermPermanentlyDenied;

  /// No description provided for @recPermRestricted.
  ///
  /// In ko, this message translates to:
  /// **'이 기기에서는 마이크 사용이 제한되어 있어 녹음할 수 없습니다.'**
  String get recPermRestricted;

  /// No description provided for @recPermChecking.
  ///
  /// In ko, this message translates to:
  /// **'마이크 권한을 확인 중입니다…'**
  String get recPermChecking;

  /// No description provided for @recPermRequest.
  ///
  /// In ko, this message translates to:
  /// **'권한 요청'**
  String get recPermRequest;

  /// No description provided for @recPermOpenSettings.
  ///
  /// In ko, this message translates to:
  /// **'설정 열기'**
  String get recPermOpenSettings;

  /// No description provided for @recScreenTitle.
  ///
  /// In ko, this message translates to:
  /// **'{role} 녹음'**
  String recScreenTitle(String role);

  /// No description provided for @recRecordingTitle.
  ///
  /// In ko, this message translates to:
  /// **'Recording · {role}'**
  String recRecordingTitle(String role);

  /// No description provided for @recHumOrSing.
  ///
  /// In ko, this message translates to:
  /// **'흥얼거리거나 노래해주세요'**
  String get recHumOrSing;

  /// No description provided for @recReadyHint.
  ///
  /// In ko, this message translates to:
  /// **'준비되면 아래 버튼을 누르세요'**
  String get recReadyHint;

  /// No description provided for @recTapToStop.
  ///
  /// In ko, this message translates to:
  /// **'탭하면 녹음 종료'**
  String get recTapToStop;

  /// No description provided for @recTapToStart.
  ///
  /// In ko, this message translates to:
  /// **'탭하면 녹음 시작'**
  String get recTapToStart;

  /// No description provided for @faqTitle.
  ///
  /// In ko, this message translates to:
  /// **'FAQ'**
  String get faqTitle;

  /// No description provided for @faq1Q.
  ///
  /// In ko, this message translates to:
  /// **'무료로 어디까지 쓸 수 있나요?'**
  String get faq1Q;

  /// No description provided for @faq1A.
  ///
  /// In ko, this message translates to:
  /// **'녹음 → 분석 → 편집까지 모든 기능을 자유롭게 써 보실 수 있어요. 내보내기 · 클라우드 동기화 · 보컬 영구 보관은 Pro 구독에서 잠금이 풀려요.'**
  String get faq1A;

  /// No description provided for @faq2Q.
  ///
  /// In ko, this message translates to:
  /// **'어떤 악기로 변환되나요?'**
  String get faq2Q;

  /// No description provided for @faq2A.
  ///
  /// In ko, this message translates to:
  /// **'피아노 · 신스 · 어쿠스틱 기타 · 일렉 기타 · 베이스 · 드럼 그리고 보컬 원본까지 — 카드 탭으로 즉시 전환할 수 있어요.'**
  String get faq2A;

  /// No description provided for @faq3Q.
  ///
  /// In ko, this message translates to:
  /// **'내 목소리는 누가 들을 수 있나요?'**
  String get faq3Q;

  /// No description provided for @faq3A.
  ///
  /// In ko, this message translates to:
  /// **'기본은 기기 안에서만 처리됩니다. Pro 사용자에 한해 본인 계정의 암호화된 클라우드 보관함에 보컬을 동기화해요.'**
  String get faq3A;

  /// No description provided for @faq4Q.
  ///
  /// In ko, this message translates to:
  /// **'구독을 해지하면 만든 곡은 어떻게 되나요?'**
  String get faq4Q;

  /// No description provided for @faq4A.
  ///
  /// In ko, this message translates to:
  /// **'로컬 프로젝트는 그대로 남아 편집할 수 있어요. 클라우드 동기화 · 새로운 내보내기는 일시 정지되고, 다시 구독하면 즉시 복원됩니다.'**
  String get faq4A;

  /// No description provided for @faq5Q.
  ///
  /// In ko, this message translates to:
  /// **'환불은 가능한가요?'**
  String get faq5Q;

  /// No description provided for @faq5A.
  ///
  /// In ko, this message translates to:
  /// **'결제는 App Store · Google Play 정책을 따릅니다. 결제 페이지에서 직접 요청해 주세요.'**
  String get faq5A;

  /// No description provided for @contactTitle.
  ///
  /// In ko, this message translates to:
  /// **'문의하기'**
  String get contactTitle;

  /// No description provided for @contactHeadline.
  ///
  /// In ko, this message translates to:
  /// **'무엇을 도와드릴까요?'**
  String get contactHeadline;

  /// No description provided for @contactSub.
  ///
  /// In ko, this message translates to:
  /// **'대부분의 답변은 FAQ 에 있어요. 그 외엔 아래로 알려주세요.'**
  String get contactSub;

  /// No description provided for @contactEmail.
  ///
  /// In ko, this message translates to:
  /// **'이메일'**
  String get contactEmail;

  /// No description provided for @contactBug.
  ///
  /// In ko, this message translates to:
  /// **'버그 신고'**
  String get contactBug;

  /// No description provided for @contactBugSub.
  ///
  /// In ko, this message translates to:
  /// **'재현 단계와 함께 적어주시면 큰 도움이 돼요'**
  String get contactBugSub;

  /// No description provided for @contactFeature.
  ///
  /// In ko, this message translates to:
  /// **'기능 제안'**
  String get contactFeature;

  /// No description provided for @contactFeatureSub.
  ///
  /// In ko, this message translates to:
  /// **'이런 기능이 있었으면 좋겠어요'**
  String get contactFeatureSub;

  /// No description provided for @termsTitle.
  ///
  /// In ko, this message translates to:
  /// **'서비스 약관'**
  String get termsTitle;

  /// No description provided for @privacyTitle.
  ///
  /// In ko, this message translates to:
  /// **'개인정보처리방침'**
  String get privacyTitle;

  /// No description provided for @refundScreenTitle.
  ///
  /// In ko, this message translates to:
  /// **'환불 정책'**
  String get refundScreenTitle;

  /// No description provided for @legalEffectiveDate.
  ///
  /// In ko, this message translates to:
  /// **'시행일: {date}'**
  String legalEffectiveDate(String date);

  /// No description provided for @legalLastUpdated.
  ///
  /// In ko, this message translates to:
  /// **'최종개정: {date}'**
  String legalLastUpdated(String date);

  /// No description provided for @cloudDownloadTitle.
  ///
  /// In ko, this message translates to:
  /// **'클라우드에서 가져오기'**
  String get cloudDownloadTitle;

  /// No description provided for @cloudDownloadBanner.
  ///
  /// In ko, this message translates to:
  /// **'구독이 만료된 동안엔 새 업로드 / 동기화는 잠금돼요. 이전 작업물은 그대로 두고 언제든 다운로드하거나 삭제할 수 있어요.'**
  String get cloudDownloadBanner;

  /// No description provided for @cloudDownloadCta.
  ///
  /// In ko, this message translates to:
  /// **'받기'**
  String get cloudDownloadCta;

  /// No description provided for @cloudDownloadActionLabel.
  ///
  /// In ko, this message translates to:
  /// **'다운로드'**
  String get cloudDownloadActionLabel;

  /// No description provided for @cloudRenameLabel.
  ///
  /// In ko, this message translates to:
  /// **'클라우드 이름 바꾸기'**
  String get cloudRenameLabel;

  /// No description provided for @editHeaderDone.
  ///
  /// In ko, this message translates to:
  /// **'완료'**
  String get editHeaderDone;

  /// No description provided for @editTrackInfoLabel.
  ///
  /// In ko, this message translates to:
  /// **'트랙 정보'**
  String get editTrackInfoLabel;

  /// No description provided for @editConverting.
  ///
  /// In ko, this message translates to:
  /// **'변환 중…'**
  String get editConverting;

  /// No description provided for @editRecLabelRecord.
  ///
  /// In ko, this message translates to:
  /// **'{role} 녹음'**
  String editRecLabelRecord(String role);

  /// No description provided for @editRecLabelReRecord.
  ///
  /// In ko, this message translates to:
  /// **'{role} 다시 녹음'**
  String editRecLabelReRecord(String role);

  /// No description provided for @editMicPermNeededTitle.
  ///
  /// In ko, this message translates to:
  /// **'마이크 권한이 필요해요'**
  String get editMicPermNeededTitle;

  /// No description provided for @editMicPermNeededBody.
  ///
  /// In ko, this message translates to:
  /// **'iPad 설정 → 개인정보 보호 → 마이크에서 HumTrack 을 허용해 주세요.'**
  String get editMicPermNeededBody;

  /// No description provided for @editMicPermLabel.
  ///
  /// In ko, this message translates to:
  /// **'마이크 권한이 필요합니다'**
  String get editMicPermLabel;

  /// No description provided for @editOpenSettings.
  ///
  /// In ko, this message translates to:
  /// **'설정 열기'**
  String get editOpenSettings;

  /// No description provided for @editPlayNoActiveTrack.
  ///
  /// In ko, this message translates to:
  /// **'활성 트랙이 없습니다(사이드바 탭)'**
  String get editPlayNoActiveTrack;

  /// No description provided for @editPlayRecordFirst.
  ///
  /// In ko, this message translates to:
  /// **'먼저 녹음하세요'**
  String get editPlayRecordFirst;

  /// No description provided for @editPlayFailed.
  ///
  /// In ko, this message translates to:
  /// **'재생 실패: {err}'**
  String editPlayFailed(String err);

  /// No description provided for @editOriginalPlayFailed.
  ///
  /// In ko, this message translates to:
  /// **'원본 재생 실패'**
  String get editOriginalPlayFailed;

  /// No description provided for @editSplitNotPossible.
  ///
  /// In ko, this message translates to:
  /// **'현재 위치에서는 분할할 수 없음'**
  String get editSplitNotPossible;

  /// No description provided for @editTrackDeleteTitle.
  ///
  /// In ko, this message translates to:
  /// **'{role} 트랙 삭제'**
  String editTrackDeleteTitle(String role);

  /// No description provided for @editTrackDeleteBody.
  ///
  /// In ko, this message translates to:
  /// **'녹음과 노트가 모두 삭제됩니다.'**
  String get editTrackDeleteBody;

  /// No description provided for @editChunkVolumeTitle.
  ///
  /// In ko, this message translates to:
  /// **'청크 볼륨'**
  String get editChunkVolumeTitle;

  /// No description provided for @editNoteVolumeTitle.
  ///
  /// In ko, this message translates to:
  /// **'노트 볼륨'**
  String get editNoteVolumeTitle;

  /// No description provided for @editTransportOriginal.
  ///
  /// In ko, this message translates to:
  /// **'원본'**
  String get editTransportOriginal;

  /// No description provided for @editSaveSaving.
  ///
  /// In ko, this message translates to:
  /// **'저장 중...'**
  String get editSaveSaving;

  /// No description provided for @editSaveJust.
  ///
  /// In ko, this message translates to:
  /// **'방금 저장됨'**
  String get editSaveJust;

  /// No description provided for @editSaveAt.
  ///
  /// In ko, this message translates to:
  /// **'{time} 저장됨'**
  String editSaveAt(String time);

  /// No description provided for @ctxActionPitch.
  ///
  /// In ko, this message translates to:
  /// **'음정'**
  String get ctxActionPitch;

  /// No description provided for @ctxActionChord.
  ///
  /// In ko, this message translates to:
  /// **'코드'**
  String get ctxActionChord;

  /// No description provided for @ctxActionUnchord.
  ///
  /// In ko, this message translates to:
  /// **'코드 해제'**
  String get ctxActionUnchord;

  /// No description provided for @ctxActionVolume.
  ///
  /// In ko, this message translates to:
  /// **'볼륨'**
  String get ctxActionVolume;

  /// No description provided for @ctxActionDelete.
  ///
  /// In ko, this message translates to:
  /// **'삭제'**
  String get ctxActionDelete;

  /// No description provided for @ctxActionSplit.
  ///
  /// In ko, this message translates to:
  /// **'분할'**
  String get ctxActionSplit;

  /// No description provided for @ctxActionCopy.
  ///
  /// In ko, this message translates to:
  /// **'복사'**
  String get ctxActionCopy;

  /// No description provided for @ctxActionRerecord.
  ///
  /// In ko, this message translates to:
  /// **'재녹음'**
  String get ctxActionRerecord;

  /// No description provided for @ctxActionLoop.
  ///
  /// In ko, this message translates to:
  /// **'루프'**
  String get ctxActionLoop;

  /// No description provided for @ctxActionUnloop.
  ///
  /// In ko, this message translates to:
  /// **'루프 해제'**
  String get ctxActionUnloop;

  /// No description provided for @ctxActionMute.
  ///
  /// In ko, this message translates to:
  /// **'뮤트'**
  String get ctxActionMute;

  /// No description provided for @ctxActionUnmute.
  ///
  /// In ko, this message translates to:
  /// **'뮤트 해제'**
  String get ctxActionUnmute;

  /// No description provided for @ctxActionBassPlace.
  ///
  /// In ko, this message translates to:
  /// **'저음 배치'**
  String get ctxActionBassPlace;

  /// No description provided for @ctxActionBassUnplace.
  ///
  /// In ko, this message translates to:
  /// **'배치 해제'**
  String get ctxActionBassUnplace;

  /// No description provided for @timelineLoop.
  ///
  /// In ko, this message translates to:
  /// **'루프'**
  String get timelineLoop;

  /// No description provided for @timelineRerecord.
  ///
  /// In ko, this message translates to:
  /// **'재녹음'**
  String get timelineRerecord;

  /// No description provided for @timelineRecordStart.
  ///
  /// In ko, this message translates to:
  /// **'녹음 시작'**
  String get timelineRecordStart;

  /// No description provided for @timelinePitchAssist.
  ///
  /// In ko, this message translates to:
  /// **'피치 어시스트'**
  String get timelinePitchAssist;

  /// No description provided for @timelineRecCompleteVocal.
  ///
  /// In ko, this message translates to:
  /// **'녹음 완료 — 보컬을 사용할까요?'**
  String get timelineRecCompleteVocal;

  /// No description provided for @timelineRecCompleteNotes.
  ///
  /// In ko, this message translates to:
  /// **'녹음 완료 — 노트 {n}개를 사용할까요?'**
  String timelineRecCompleteNotes(int n);

  /// No description provided for @timelineRecCompleteGeneric.
  ///
  /// In ko, this message translates to:
  /// **'녹음 완료 — 사용할까요?'**
  String get timelineRecCompleteGeneric;

  /// No description provided for @pendingRecTitle.
  ///
  /// In ko, this message translates to:
  /// **'녹음 완료'**
  String get pendingRecTitle;

  /// No description provided for @pendingAnalyzing.
  ///
  /// In ko, this message translates to:
  /// **'분석 중…'**
  String get pendingAnalyzing;

  /// No description provided for @pendingVocalUseQ.
  ///
  /// In ko, this message translates to:
  /// **'{sec}초 보컬을 사용할까요?'**
  String pendingVocalUseQ(String sec);

  /// No description provided for @pendingNotesUseQ.
  ///
  /// In ko, this message translates to:
  /// **'{sec}초 · 노트 {n}개를 사용할까요?'**
  String pendingNotesUseQ(String sec, int n);

  /// No description provided for @pendingPreview.
  ///
  /// In ko, this message translates to:
  /// **'미리듣기'**
  String get pendingPreview;

  /// No description provided for @pendingStop.
  ///
  /// In ko, this message translates to:
  /// **'정지'**
  String get pendingStop;

  /// No description provided for @addTrackTitle.
  ///
  /// In ko, this message translates to:
  /// **'트랙 추가'**
  String get addTrackTitle;

  /// No description provided for @addTrackPiano.
  ///
  /// In ko, this message translates to:
  /// **'피아노'**
  String get addTrackPiano;

  /// No description provided for @addTrackAcousticGuitar.
  ///
  /// In ko, this message translates to:
  /// **'어쿠스틱 기타'**
  String get addTrackAcousticGuitar;

  /// No description provided for @addTrackElectricGuitar.
  ///
  /// In ko, this message translates to:
  /// **'일렉 기타'**
  String get addTrackElectricGuitar;

  /// No description provided for @addTrackSynth.
  ///
  /// In ko, this message translates to:
  /// **'신스'**
  String get addTrackSynth;

  /// No description provided for @addTrackOrgan.
  ///
  /// In ko, this message translates to:
  /// **'오르간'**
  String get addTrackOrgan;

  /// No description provided for @addTrackStrings.
  ///
  /// In ko, this message translates to:
  /// **'스트링'**
  String get addTrackStrings;

  /// No description provided for @addTrackBassGuitar.
  ///
  /// In ko, this message translates to:
  /// **'베이스 기타'**
  String get addTrackBassGuitar;

  /// No description provided for @addTrackSynthBass.
  ///
  /// In ko, this message translates to:
  /// **'신스 베이스'**
  String get addTrackSynthBass;

  /// No description provided for @addTrackDrumKit.
  ///
  /// In ko, this message translates to:
  /// **'드럼 키트'**
  String get addTrackDrumKit;

  /// No description provided for @addTrackVocal.
  ///
  /// In ko, this message translates to:
  /// **'원본 보컬'**
  String get addTrackVocal;

  /// No description provided for @addTrackVocalSub.
  ///
  /// In ko, this message translates to:
  /// **'원본 그대로'**
  String get addTrackVocalSub;

  /// No description provided for @anchorKeyTitle.
  ///
  /// In ko, this message translates to:
  /// **'프로젝트 키 정하기'**
  String get anchorKeyTitle;

  /// No description provided for @anchorKeySub.
  ///
  /// In ko, this message translates to:
  /// **'이 키로 모든 트랙을 자동 정리합니다. 맞는 키를 골라주세요.'**
  String get anchorKeySub;

  /// No description provided for @anchorKeyTagDetected.
  ///
  /// In ko, this message translates to:
  /// **'감지됨'**
  String get anchorKeyTagDetected;

  /// No description provided for @anchorKeyTagRelative.
  ///
  /// In ko, this message translates to:
  /// **'상대조'**
  String get anchorKeyTagRelative;

  /// No description provided for @anchorKeyTagCandidate.
  ///
  /// In ko, this message translates to:
  /// **'후보'**
  String get anchorKeyTagCandidate;

  /// No description provided for @scaleMajor.
  ///
  /// In ko, this message translates to:
  /// **'장조'**
  String get scaleMajor;

  /// No description provided for @scaleMinor.
  ///
  /// In ko, this message translates to:
  /// **'단조'**
  String get scaleMinor;

  /// No description provided for @instrumentPickerTitle.
  ///
  /// In ko, this message translates to:
  /// **'악기 선택 · {role}'**
  String instrumentPickerTitle(String role);

  /// No description provided for @instrumentPickerVocalOnly.
  ///
  /// In ko, this message translates to:
  /// **'원본 보컬 트랙입니다'**
  String get instrumentPickerVocalOnly;

  /// No description provided for @chordModeTitle.
  ///
  /// In ko, this message translates to:
  /// **'코드 모드'**
  String get chordModeTitle;

  /// No description provided for @chordModeSub.
  ///
  /// In ko, this message translates to:
  /// **'단음을 자동 화음으로'**
  String get chordModeSub;

  /// No description provided for @chordModeMono.
  ///
  /// In ko, this message translates to:
  /// **'단음'**
  String get chordModeMono;

  /// No description provided for @chordModeChord.
  ///
  /// In ko, this message translates to:
  /// **'코드'**
  String get chordModeChord;

  /// No description provided for @keyPickerTitle.
  ///
  /// In ko, this message translates to:
  /// **'키 선택'**
  String get keyPickerTitle;

  /// No description provided for @keyPickerSub.
  ///
  /// In ko, this message translates to:
  /// **'Auto = 추천 키 자동 적용'**
  String get keyPickerSub;

  /// No description provided for @keyPickerAuto.
  ///
  /// In ko, this message translates to:
  /// **'Auto (추천)'**
  String get keyPickerAuto;

  /// No description provided for @keyPickerMainRole.
  ///
  /// In ko, this message translates to:
  /// **'메인 키 기준 트랙 (전체 트랙이 이 키로)'**
  String get keyPickerMainRole;

  /// No description provided for @keyPickerMajor.
  ///
  /// In ko, this message translates to:
  /// **'메이저'**
  String get keyPickerMajor;

  /// No description provided for @keyPickerMinor.
  ///
  /// In ko, this message translates to:
  /// **'마이너'**
  String get keyPickerMinor;

  /// No description provided for @keyAuto.
  ///
  /// In ko, this message translates to:
  /// **'AUTO'**
  String get keyAuto;

  /// No description provided for @keyManual.
  ///
  /// In ko, this message translates to:
  /// **'수동'**
  String get keyManual;

  /// No description provided for @noteWheelTitle.
  ///
  /// In ko, this message translates to:
  /// **'노트 보정 · #{idx}'**
  String noteWheelTitle(int idx);

  /// No description provided for @noteWheelRecommended.
  ///
  /// In ko, this message translates to:
  /// **'추천'**
  String get noteWheelRecommended;

  /// No description provided for @noteWheelOriginal.
  ///
  /// In ko, this message translates to:
  /// **'원음'**
  String get noteWheelOriginal;

  /// No description provided for @noteWheelOriginalHint.
  ///
  /// In ko, this message translates to:
  /// **'원음 = 부른 그대로'**
  String get noteWheelOriginalHint;

  /// No description provided for @chordPickerTitle.
  ///
  /// In ko, this message translates to:
  /// **'코드 변환'**
  String get chordPickerTitle;

  /// No description provided for @chordPickerScopeChunk.
  ///
  /// In ko, this message translates to:
  /// **'청크'**
  String get chordPickerScopeChunk;

  /// No description provided for @chordPickerScopeRoot.
  ///
  /// In ko, this message translates to:
  /// **'루트'**
  String get chordPickerScopeRoot;

  /// No description provided for @chordPickerSummary.
  ///
  /// In ko, this message translates to:
  /// **'{scope}: {root}{keyPart}{chordPart}'**
  String chordPickerSummary(String scope, String root, String keyPart, String chordPart);

  /// No description provided for @chordPickerKeyPart.
  ///
  /// In ko, this message translates to:
  /// **' · 키: {label}'**
  String chordPickerKeyPart(String label);

  /// No description provided for @chordPickerNoKey.
  ///
  /// In ko, this message translates to:
  /// **' (키 미감지)'**
  String get chordPickerNoKey;

  /// No description provided for @chordPickerCurrent.
  ///
  /// In ko, this message translates to:
  /// **' · 현재 코드'**
  String get chordPickerCurrent;

  /// No description provided for @chordPickerMono.
  ///
  /// In ko, this message translates to:
  /// **'원음'**
  String get chordPickerMono;

  /// No description provided for @chordPickerMonoSub.
  ///
  /// In ko, this message translates to:
  /// **'단음 (코드 해제)'**
  String get chordPickerMonoSub;

  /// No description provided for @exportTitle.
  ///
  /// In ko, this message translates to:
  /// **'내보내기 · {title}'**
  String exportTitle(String title);

  /// No description provided for @exportCloudSaveLabel.
  ///
  /// In ko, this message translates to:
  /// **'클라우드 저장'**
  String get exportCloudSaveLabel;

  /// No description provided for @exportCloudSaveTitle.
  ///
  /// In ko, this message translates to:
  /// **'프로젝트에 저장'**
  String get exportCloudSaveTitle;

  /// No description provided for @exportCloudSaveSub.
  ///
  /// In ko, this message translates to:
  /// **'클라우드 동기화 · 언제든 재편집'**
  String get exportCloudSaveSub;

  /// No description provided for @exportMidiTitle.
  ///
  /// In ko, this message translates to:
  /// **'MIDI 내보내기'**
  String get exportMidiTitle;

  /// No description provided for @exportMidiSub.
  ///
  /// In ko, this message translates to:
  /// **'.mid'**
  String get exportMidiSub;

  /// No description provided for @exportAudioTitle.
  ///
  /// In ko, this message translates to:
  /// **'오디오 내보내기'**
  String get exportAudioTitle;

  /// No description provided for @exportAudioSub.
  ///
  /// In ko, this message translates to:
  /// **'.wav · 믹스 렌더'**
  String get exportAudioSub;

  /// No description provided for @exportShareLabel.
  ///
  /// In ko, this message translates to:
  /// **'공유'**
  String get exportShareLabel;

  /// No description provided for @exportShareSub.
  ///
  /// In ko, this message translates to:
  /// **'링크 · Instagram · TikTok'**
  String get exportShareSub;

  /// No description provided for @exportFailed.
  ///
  /// In ko, this message translates to:
  /// **'내보내기 실패: {err}'**
  String exportFailed(String err);

  /// No description provided for @metronomeTitle.
  ///
  /// In ko, this message translates to:
  /// **'메트로놈'**
  String get metronomeTitle;

  /// No description provided for @metronomeOn.
  ///
  /// In ko, this message translates to:
  /// **'메트로놈 켜기'**
  String get metronomeOn;

  /// No description provided for @metronomeOff.
  ///
  /// In ko, this message translates to:
  /// **'메트로놈 끄기'**
  String get metronomeOff;

  /// No description provided for @metronomeNote.
  ///
  /// In ko, this message translates to:
  /// **'BPM 은 프로젝트 전체에 적용돼요. 박자 보정 카드의 그리드도 이 BPM 을 기준으로 정렬합니다.'**
  String get metronomeNote;

  /// No description provided for @metronomeBeatSec.
  ///
  /// In ko, this message translates to:
  /// **'1박 = {sec}초'**
  String metronomeBeatSec(String sec);

  /// No description provided for @tempoVerySlow.
  ///
  /// In ko, this message translates to:
  /// **'느린 발라드'**
  String get tempoVerySlow;

  /// No description provided for @tempoBallad.
  ///
  /// In ko, this message translates to:
  /// **'보통 발라드'**
  String get tempoBallad;

  /// No description provided for @tempoMidPop.
  ///
  /// In ko, this message translates to:
  /// **'팝/미디엄'**
  String get tempoMidPop;

  /// No description provided for @tempoDance.
  ///
  /// In ko, this message translates to:
  /// **'댄스/업비트'**
  String get tempoDance;

  /// No description provided for @tempoFast.
  ///
  /// In ko, this message translates to:
  /// **'빠른 곡'**
  String get tempoFast;

  /// No description provided for @tempoVeryFast.
  ///
  /// In ko, this message translates to:
  /// **'매우 빠름'**
  String get tempoVeryFast;

  /// No description provided for @quantizeTitle.
  ///
  /// In ko, this message translates to:
  /// **'박자 보정'**
  String get quantizeTitle;

  /// No description provided for @quantizeBpmHint.
  ///
  /// In ko, this message translates to:
  /// **'BPM 은 전체 프로젝트 설정이라 트랜스포트의 메트로놈 버튼에서 조정해요.'**
  String get quantizeBpmHint;

  /// No description provided for @quantizeGridLabel.
  ///
  /// In ko, this message translates to:
  /// **'박자 단위'**
  String get quantizeGridLabel;

  /// No description provided for @quantizeGridDetail.
  ///
  /// In ko, this message translates to:
  /// **'1박을 {n}등분'**
  String quantizeGridDetail(int n);

  /// No description provided for @quantizeStrength.
  ///
  /// In ko, this message translates to:
  /// **'강도'**
  String get quantizeStrength;

  /// No description provided for @quantizeStrengthMin.
  ///
  /// In ko, this message translates to:
  /// **'0%: 원본 그대로'**
  String get quantizeStrengthMin;

  /// No description provided for @quantizeStrengthMax.
  ///
  /// In ko, this message translates to:
  /// **'100%: 완벽 정렬'**
  String get quantizeStrengthMax;

  /// No description provided for @quantizeFooter.
  ///
  /// In ko, this message translates to:
  /// **'여러 트랙의 박자가 미세하게 어긋날 때 같은 BPM/박자 단위로 맞추면 자동으로 동기화돼요.'**
  String get quantizeFooter;

  /// No description provided for @quantizeOff.
  ///
  /// In ko, this message translates to:
  /// **'off'**
  String get quantizeOff;

  /// No description provided for @quantizeSummary.
  ///
  /// In ko, this message translates to:
  /// **'1/{grid} · {pct}% · BPM {bpm}'**
  String quantizeSummary(int grid, int pct, int bpm);

  /// No description provided for @cardInstrumentLabel.
  ///
  /// In ko, this message translates to:
  /// **'INSTRUMENT'**
  String get cardInstrumentLabel;

  /// No description provided for @cardInstrumentFallback.
  ///
  /// In ko, this message translates to:
  /// **'악기'**
  String get cardInstrumentFallback;

  /// No description provided for @helpInstrumentBody.
  ///
  /// In ko, this message translates to:
  /// **'이 트랙을 어떤 악기 소리로 재생할지 선택해요. 분석된 음정에 SoundFont 악기 음색을 입혀 들려줘요.'**
  String get helpInstrumentBody;

  /// No description provided for @cardKeyLabel.
  ///
  /// In ko, this message translates to:
  /// **'KEY'**
  String get cardKeyLabel;

  /// No description provided for @helpKeyBody.
  ///
  /// In ko, this message translates to:
  /// **'곡의 으뜸음(C, D…)과 모드(메이저/마이너)예요. AUTO = 분석이 자동 추정한 키. 카드를 탭하면 수동으로 바꿀 수 있어요. 신뢰도 = 추정이 얼마나 확실한지 (0~1).'**
  String get helpKeyBody;

  /// No description provided for @keyAnalysisPending.
  ///
  /// In ko, this message translates to:
  /// **'녹음 후 분석'**
  String get keyAnalysisPending;

  /// No description provided for @keyConfidence.
  ///
  /// In ko, this message translates to:
  /// **'신뢰도 {conf}{tier}'**
  String keyConfidence(String conf, String tier);

  /// No description provided for @cardAssistLabel.
  ///
  /// In ko, this message translates to:
  /// **'피치 어시스트'**
  String get cardAssistLabel;

  /// No description provided for @helpAssistBody.
  ///
  /// In ko, this message translates to:
  /// **'키 밖으로 살짝 빗나간 음을 가장 가까운 in-key 음으로 자동 보정해 줘요. \"보정됨\" 숫자 = 실제로 끌어당겨진 노트 개수.'**
  String get helpAssistBody;

  /// No description provided for @assistCorrected.
  ///
  /// In ko, this message translates to:
  /// **'보정됨'**
  String get assistCorrected;

  /// No description provided for @assistDesc.
  ///
  /// In ko, this message translates to:
  /// **'키 밖 음 자동 정리'**
  String get assistDesc;

  /// No description provided for @cardQuantizeLabel.
  ///
  /// In ko, this message translates to:
  /// **'박자 보정'**
  String get cardQuantizeLabel;

  /// No description provided for @helpQuantizeBody.
  ///
  /// In ko, this message translates to:
  /// **'여러 트랙의 박자가 미세하게 어긋날 때 같은 BPM/박자 단위로 맞추면 자동으로 동기화돼요. 원본 timing 은 그대로 보존돼, 토글을 꺼면 원래대로 돌아옵니다.'**
  String get helpQuantizeBody;

  /// No description provided for @conflictTitle.
  ///
  /// In ko, this message translates to:
  /// **'양쪽 모두 변경됐어요'**
  String get conflictTitle;

  /// No description provided for @conflictSub.
  ///
  /// In ko, this message translates to:
  /// **'{title} · 내 작업물과 클라우드에서 모두 수정됐어요'**
  String conflictSub(String title);

  /// No description provided for @conflictLocalHeader.
  ///
  /// In ko, this message translates to:
  /// **'📱 내 작업물 (이 기기)'**
  String get conflictLocalHeader;

  /// No description provided for @conflictCloudHeader.
  ///
  /// In ko, this message translates to:
  /// **'☁ 클라우드 (다른 곳)'**
  String get conflictCloudHeader;

  /// No description provided for @conflictTrackInfo.
  ///
  /// In ko, this message translates to:
  /// **'{count}트랙 · {size}'**
  String conflictTrackInfo(int count, String size);

  /// No description provided for @conflictKeepBoth.
  ///
  /// In ko, this message translates to:
  /// **'둘 다 보관 (사본으로)'**
  String get conflictKeepBoth;

  /// No description provided for @conflictBadgeRecommended.
  ///
  /// In ko, this message translates to:
  /// **'추천'**
  String get conflictBadgeRecommended;

  /// No description provided for @conflictOverwriteCloud.
  ///
  /// In ko, this message translates to:
  /// **'이 기기 버전을 클라우드에 덮어쓰기'**
  String get conflictOverwriteCloud;

  /// No description provided for @conflictPullFromCloud.
  ///
  /// In ko, this message translates to:
  /// **'클라우드 버전을 이 기기에 가져오기'**
  String get conflictPullFromCloud;

  /// No description provided for @authErrDisabled.
  ///
  /// In ko, this message translates to:
  /// **'Auth 비활성 (Supabase 키 미설정)'**
  String get authErrDisabled;

  /// No description provided for @authErrIdentityBlockedGeneric.
  ///
  /// In ko, this message translates to:
  /// **'이미 다른 방법으로 가입된 이메일이에요.\n처음 가입했던 방법으로 로그인해 주세요.'**
  String get authErrIdentityBlockedGeneric;

  /// No description provided for @authErrIdentityBlockedSpecific.
  ///
  /// In ko, this message translates to:
  /// **'이미 {providers} 로 가입된 이메일이에요.\n{providers} 로 로그인해 주세요.'**
  String authErrIdentityBlockedSpecific(String providers);

  /// No description provided for @authErrGoogleNoIdToken.
  ///
  /// In ko, this message translates to:
  /// **'Google: idToken 누락 (serverClientId/iOS client 미스매치 가능)'**
  String get authErrGoogleNoIdToken;

  /// No description provided for @authErrAppleCode.
  ///
  /// In ko, this message translates to:
  /// **'Apple {code}: {message}'**
  String authErrAppleCode(String code, String message);

  /// No description provided for @authErrGeneric.
  ///
  /// In ko, this message translates to:
  /// **'{provider}: {raw}'**
  String authErrGeneric(String provider, String raw);

  /// No description provided for @authProviderKakao.
  ///
  /// In ko, this message translates to:
  /// **'카카오'**
  String get authProviderKakao;

  /// No description provided for @authProviderNaver.
  ///
  /// In ko, this message translates to:
  /// **'네이버'**
  String get authProviderNaver;

  /// No description provided for @accountErrNoSession.
  ///
  /// In ko, this message translates to:
  /// **'로그인 세션이 없어요. 다시 시도해 주세요.'**
  String get accountErrNoSession;

  /// No description provided for @accountErrServerDelete.
  ///
  /// In ko, this message translates to:
  /// **'서버 삭제 실패 ({status}){detail}'**
  String accountErrServerDelete(int status, String detail);

  /// No description provided for @ltCardMore.
  ///
  /// In ko, this message translates to:
  /// **'더 보기'**
  String get ltCardMore;

  /// No description provided for @ltSettingsDeleteAccount.
  ///
  /// In ko, this message translates to:
  /// **'회원 탈퇴'**
  String get ltSettingsDeleteAccount;

  /// No description provided for @ltSettingsDeleteAccountConfirmTitle.
  ///
  /// In ko, this message translates to:
  /// **'회원 탈퇴할까요?'**
  String get ltSettingsDeleteAccountConfirmTitle;

  /// No description provided for @ltSettingsDeleteAccountConfirmBody.
  ///
  /// In ko, this message translates to:
  /// **'계정과 모든 데이터가 영구적으로 삭제돼요. 되돌릴 수 없어요.'**
  String get ltSettingsDeleteAccountConfirmBody;

  /// No description provided for @ltSettingsDeleteAccountFailed.
  ///
  /// In ko, this message translates to:
  /// **'탈퇴 실패: {err}'**
  String ltSettingsDeleteAccountFailed(String err);

  /// No description provided for @ltSettingsDeleteAccountDone.
  ///
  /// In ko, this message translates to:
  /// **'회원 탈퇴가 완료됐어요.'**
  String get ltSettingsDeleteAccountDone;

  /// No description provided for @ltExportTitle.
  ///
  /// In ko, this message translates to:
  /// **'\"{title}\" 내보내기'**
  String ltExportTitle(String title);

  /// No description provided for @ltExportMeta.
  ///
  /// In ko, this message translates to:
  /// **'섹션 {count}개 · {bars}마디 · {bpm} BPM'**
  String ltExportMeta(int count, int bars, int bpm);

  /// No description provided for @ltExportMidiTitle.
  ///
  /// In ko, this message translates to:
  /// **'MIDI 파일'**
  String get ltExportMidiTitle;

  /// No description provided for @ltExportMidiSub.
  ///
  /// In ko, this message translates to:
  /// **'전체 곡 · 피아노 · 베이스 · 드럼 (ch10)'**
  String get ltExportMidiSub;

  /// No description provided for @ltExportWavTitle.
  ///
  /// In ko, this message translates to:
  /// **'오디오 (WAV)'**
  String get ltExportWavTitle;

  /// No description provided for @ltExportWavSub.
  ///
  /// In ko, this message translates to:
  /// **'믹스된 전체 곡'**
  String get ltExportWavSub;

  /// No description provided for @ltExportStemsTitle.
  ///
  /// In ko, this message translates to:
  /// **'스템'**
  String get ltExportStemsTitle;

  /// No description provided for @ltExportStemsSub.
  ///
  /// In ko, this message translates to:
  /// **'트랙별 WAV 분리'**
  String get ltExportStemsSub;

  /// No description provided for @ltExportShareTitle.
  ///
  /// In ko, this message translates to:
  /// **'공유'**
  String get ltExportShareTitle;

  /// No description provided for @ltExportShareSub.
  ///
  /// In ko, this message translates to:
  /// **'다른 앱으로 보내기'**
  String get ltExportShareSub;

  /// No description provided for @ltExportSaved.
  ///
  /// In ko, this message translates to:
  /// **'{filename} 저장됨'**
  String ltExportSaved(String filename);

  /// No description provided for @ltExportVocalSkipped.
  ///
  /// In ko, this message translates to:
  /// **'이전 형식 보컬 {count}개는 믹스에 포함되지 않았어요'**
  String ltExportVocalSkipped(int count);

  /// No description provided for @ltExportFailed.
  ///
  /// In ko, this message translates to:
  /// **'MIDI 내보내기 실패'**
  String get ltExportFailed;

  /// No description provided for @ltExportFooter.
  ///
  /// In ko, this message translates to:
  /// **'섹션은 순서대로(반복 포함) 렌더링됩니다. MIDI는 모든 DAW 에서 열립니다. WAV·스템은 사운드폰트로 렌더된 오디오입니다.'**
  String get ltExportFooter;

  /// No description provided for @ltSettingsTitle.
  ///
  /// In ko, this message translates to:
  /// **'설정'**
  String get ltSettingsTitle;

  /// No description provided for @ltSettingsMetronome.
  ///
  /// In ko, this message translates to:
  /// **'메트로놈 클릭'**
  String get ltSettingsMetronome;

  /// No description provided for @ltSettingsMetronomeSub.
  ///
  /// In ko, this message translates to:
  /// **'녹음 중 클릭음 재생'**
  String get ltSettingsMetronomeSub;

  /// No description provided for @ltSettingsHaptics.
  ///
  /// In ko, this message translates to:
  /// **'햅틱'**
  String get ltSettingsHaptics;

  /// No description provided for @ltSettingsHapticsSub.
  ///
  /// In ko, this message translates to:
  /// **'패드 탭 시 진동'**
  String get ltSettingsHapticsSub;

  /// No description provided for @ltSettingsAbout.
  ///
  /// In ko, this message translates to:
  /// **'정보'**
  String get ltSettingsAbout;

  /// No description provided for @ltSettingsAboutSub.
  ///
  /// In ko, this message translates to:
  /// **'HumTrack · v0.4'**
  String get ltSettingsAboutSub;

  /// No description provided for @ltSettingsLegalSection.
  ///
  /// In ko, this message translates to:
  /// **'약관 및 정책'**
  String get ltSettingsLegalSection;

  /// No description provided for @ltSettingsOpenSource.
  ///
  /// In ko, this message translates to:
  /// **'오픈소스 라이선스'**
  String get ltSettingsOpenSource;

  /// No description provided for @ltSettingsContact.
  ///
  /// In ko, this message translates to:
  /// **'문의하기'**
  String get ltSettingsContact;
}

class _L10nDelegate extends LocalizationsDelegate<L10n> {
  const _L10nDelegate();

  @override
  Future<L10n> load(Locale locale) {
    return SynchronousFuture<L10n>(lookupL10n(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>['en', 'ko'].contains(locale.languageCode);

  @override
  bool shouldReload(_L10nDelegate old) => false;
}

L10n lookupL10n(Locale locale) {


  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en': return L10nEn();
    case 'ko': return L10nKo();
  }

  throw FlutterError(
    'L10n.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.'
  );
}
