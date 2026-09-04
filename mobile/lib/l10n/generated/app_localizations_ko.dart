// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Korean (`ko`).
class L10nKo extends L10n {
  L10nKo([String locale = 'ko']) : super(locale);

  @override
  String get appName => 'HumTrack';

  @override
  String get ok => '확인';

  @override
  String get cancel => '취소';

  @override
  String get save => '저장';

  @override
  String get delete => '삭제';

  @override
  String get rename => '이름 바꾸기';

  @override
  String get later => '나중에';

  @override
  String get retry => '다시 시도';

  @override
  String get close => '닫기';

  @override
  String get done => '완료';

  @override
  String get apply => '적용';

  @override
  String get use => '사용';

  @override
  String get tabSongs => '내 작업물';

  @override
  String get tabCloud => '클라우드';

  @override
  String get navStudio => 'STUDIO';

  @override
  String get navSongs => 'SONGS';

  @override
  String get navMixer => 'MIXER';

  @override
  String get actionUpgradeToPro => 'Pro 로 업그레이드';

  @override
  String get freeCloudHeadline => '아직 클라우드가 없어요';

  @override
  String freeCloudSub(int gb) {
    return 'Pro 로 전환하면 ${gb}GB 클라우드를 받아\n모든 기기에서 작업물을 이어 만들 수 있어요.';
  }

  @override
  String valueCloudStorage(int gb) {
    return '${gb}GB 클라우드 보관';
  }

  @override
  String get valueExportUnlimited => '무제한 내보내기';

  @override
  String get valueAnalysisPriority => '우선 분석 처리';

  @override
  String get valuePersistentVocal => '영구 보관';

  @override
  String get trialStartCta => '7일 무료 체험 시작';

  @override
  String trialPriceFootnote(String price) {
    return '$price/월 (체험 후 자동 결제)';
  }

  @override
  String cloudUsageLabel(String used, String total) {
    return '$used / $total 사용 중';
  }

  @override
  String get projectActionUploadToCloud => '클라우드에 올리기';

  @override
  String get projectActionRefreshCloud => '클라우드 최신화';

  @override
  String get projectActionDownloadFromCloud => '내 기기에 받기';

  @override
  String get projectActionDeleteFromCloud => '클라우드에서만 삭제';

  @override
  String get projectActionDeleteFromCloudSub => '내 기기 작업물은 그대로 남아요';

  @override
  String get syncInProgress => '클라우드에 올리는 중...';

  @override
  String get downloadInProgress => '내 기기로 받는 중...';

  @override
  String get syncFailed => '동기화 실패 — 탭하여 재시도';

  @override
  String get settingsCloudHeader => '내 클라우드';

  @override
  String get settingsAutoSync => '자동 동기화';

  @override
  String get settingsAutoSyncDesc => '변경된 작업물을 자동으로 클라우드에 올려요';

  @override
  String get menuLanguage => '언어';

  @override
  String get languageScreenTitle => '언어';

  @override
  String get languageSystemDefault => '시스템 기본';

  @override
  String get languageSystemDefaultSub => '기기 설정 언어를 따라가요';

  @override
  String get languageNameKorean => '한국어';

  @override
  String get languageNameEnglish => 'English';

  @override
  String get songsTitle => 'Songs';

  @override
  String get songsEmptyTitle => '새 곡 작업을 시작하세요';

  @override
  String get songsEmptySub => '흥얼거리면 악기로 변환되고, 녹음부터 편집까지 한 번에';

  @override
  String get songsEmptyCta => '작업 시작';

  @override
  String get songsCardInCloud => '클라우드에 있음';

  @override
  String songsTrackCountChip(int count) {
    return '$count트랙';
  }

  @override
  String projectDurationLabel(int min, String sec) {
    return '$min분 $sec초';
  }

  @override
  String get agoJustNow => '방금 전';

  @override
  String agoMinutes(int n) {
    return '$n분 전';
  }

  @override
  String agoHours(int n) {
    return '$n시간 전';
  }

  @override
  String agoDays(int n) {
    return '$n일 전';
  }

  @override
  String get agoJustUploaded => '방금 올림';

  @override
  String agoMonthDay(int month, int day) {
    return '$month월 $day일';
  }

  @override
  String get agoJustEdited => '방금 수정';

  @override
  String agoSecondsAgo(int n) {
    return '$n초 전';
  }

  @override
  String get accountTitle => '계정';

  @override
  String get accountNotSignedIn => '로그인되지 않음';

  @override
  String accountProviderSuffix(String provider) {
    return '$provider 계정';
  }

  @override
  String get accountLinked => '계정 연동됨';

  @override
  String get accountSignInHint => '로그인하면 결제와 동기화가 가능해요';

  @override
  String get accountSignIn => '로그인';

  @override
  String get subFreePlan => '무료 플랜';

  @override
  String get subFreePlanSub => '내보내기와 무제한 곡 만들기는 Pro 에서 잠금이 풀려요';

  @override
  String get subTrial => '무료 체험 중';

  @override
  String subTrialBillsOn(String date) {
    return '$date에 자동 결제 시작';
  }

  @override
  String subTrialNDays(int days) {
    return '$days일 체험';
  }

  @override
  String get subActive => 'Humming Pro';

  @override
  String subActiveRenewsOn(String date) {
    return '$date 자동 갱신';
  }

  @override
  String get subActiveAllOn => '모든 기능 활성화됨';

  @override
  String get subCancelled => 'Pro · 해지 예약';

  @override
  String subCancelledValidUntil(String date) {
    return '$date까지 이용 가능';
  }

  @override
  String get subCancelledUntilExpiry => '만료 전까지 사용 가능';

  @override
  String get subExpired => '구독이 만료됐어요';

  @override
  String get subExpiredRestoreHint => '다시 구독하면 즉시 복원돼요';

  @override
  String get accountMenuManage => '구독 관리';

  @override
  String get accountMenuCloudRecover => '클라우드에서 가져오기';

  @override
  String get accountMenuCloudRecoverSub => '작업물은 직접 삭제하기 전까지 보관됨';

  @override
  String get accountMenuLanguage => '언어 / Language';

  @override
  String get accountMenuFaq => 'FAQ';

  @override
  String get accountMenuContact => '문의하기';

  @override
  String get accountMenuTerms => '서비스 약관';

  @override
  String get accountMenuPrivacy => '개인정보처리방침';

  @override
  String get accountMenuRefund => '환불 정책';

  @override
  String get devModeTitle => '개발자 모드';

  @override
  String get devSubscriptionLabel => '구독 상태 (디버그 빌드만 노출)';

  @override
  String get devCloudMockLabel => '클라우드 mock 데이터';

  @override
  String get accountDetailTitle => '계정 정보';

  @override
  String get labelEmail => '이메일';

  @override
  String get labelSignInMethod => '로그인 방법';

  @override
  String get labelAccountId => '계정 ID';

  @override
  String get withdrawHint =>
      '계정을 삭제하면 계정 데이터가 영구 삭제돼요.\nApp Store / Google Play 구독은 계정 삭제로 해지되지 않으니, 계속 결제되지 않도록 스토어에서 별도로 해지해 주세요.';

  @override
  String get withdrawCta => '회원 탈퇴';

  @override
  String get withdrawConfirmTitle => '정말 탈퇴하시겠어요?';

  @override
  String get withdrawConfirmBody => '계정과 모든 데이터가 영구 삭제되고 복구할 수 없어요.';

  @override
  String get withdrawConfirmAction => '탈퇴';

  @override
  String withdrawFailed(String err) {
    return '탈퇴 실패: $err';
  }

  @override
  String get withdrawCompleted => '탈퇴가 완료됐어요';

  @override
  String get subScreenTitle => '구독 관리';

  @override
  String get subStatusActive => 'Humming Pro · 활성';

  @override
  String subStatusActiveRenewsOn(String date) {
    return '$date에 자동 갱신돼요';
  }

  @override
  String get subStatusActiveAutoOn => '자동 갱신 활성';

  @override
  String subStatusTrialBillsOn(String date) {
    return '$date에 자동 결제';
  }

  @override
  String subStatusTrialNDays(int days) {
    return '$days일 무료 체험';
  }

  @override
  String get subStatusCancelled => '해지 예약됨';

  @override
  String subStatusCancelledUntil(String date) {
    return '$date까지 Pro 사용 가능';
  }

  @override
  String get subStatusExpiredBody => '다시 구독하면 Pro 기능이 즉시 복원돼요';

  @override
  String get subStatusAnonymous => '구독 정보 없음';

  @override
  String get subStatusAnonymousBody => '먼저 로그인하고 결제를 시작해 주세요';

  @override
  String get subCurrentEntitlements => '현재 권한';

  @override
  String get subFeatureCloudSync => '무제한 곡 만들기';

  @override
  String get subFeatureExport => '무제한 내보내기 (WAV / MIDI)';

  @override
  String get subFeatureVocalBackup => '스템 내보내기';

  @override
  String get subFeaturePriority => 'MIDI 내보내기';

  @override
  String subStoreNoticeActive(String store) {
    return '결제 정보 변경, 구독 해지, 환불 요청은 $store 의 구독 설정에서 진행할 수 있어요.';
  }

  @override
  String subStoreNoticeCancelled(String store) {
    return '만료일까지 모든 기능을 그대로 쓸 수 있어요.\n해지 취소(재활성화)는 $store 의 구독 설정에서 가능합니다.';
  }

  @override
  String get subResubCta => 'Pro 다시 구독하기';

  @override
  String get subResubHint => '만든 곡은 이 기기에 그대로 있어요 — 재구독하면 다시 내보낼 수 있어요';

  @override
  String get subStartCta => '구독 시작';

  @override
  String get subCancelConfirmTitle => '정말 해지하시겠어요?';

  @override
  String get subCancelConfirmBody => '만료일까지는 모든 Pro 기능을 그대로 사용하실 수 있어요.';

  @override
  String get subCancelConfirmAction => '해지';

  @override
  String get paywallHeadlineExport => '내보내려면 Pro 가 필요해요';

  @override
  String get paywallHeadlineSync => '무제한 곡 만들기는 Pro';

  @override
  String get paywallHeadlineBackup => '스템 내보내기';

  @override
  String get paywallHeadlineDefault => 'Humming Pro';

  @override
  String get paywallSubExport => 'WAV · MIDI 파일로 저장하고 공유하세요';

  @override
  String get paywallSubSync => '무료 플랜 곡 개수 제한 없이 만들기';

  @override
  String get paywallSubBackup => '트랙별 WAV 로 분리 내보내기';

  @override
  String get paywallSubDefault => '무제한 곡 · WAV / MIDI / 스템 내보내기';

  @override
  String get looptapPaywallTriggerExport =>
      '내보내기는 Pro 전용 기능입니다 — 구독하시면 MIDI / 오디오를 저장할 수 있어요.';

  @override
  String get looptapPaywallTriggerSongQuota =>
      '무료 플랜의 곡 개수 한도에 도달했어요. Pro 로 업그레이드하면 무제한으로 만들 수 있습니다.';

  @override
  String get paywallFeatureCloudTitle => '무제한 곡';

  @override
  String get paywallFeatureCloudSub => '무료 플랜은 4곡까지';

  @override
  String get paywallFeatureBackupTitle => 'MIDI 내보내기';

  @override
  String get paywallFeatureBackupSub => '어떤 DAW 에서도 열리는 .mid';

  @override
  String get paywallFeatureExportTitle => '무제한 내보내기';

  @override
  String get paywallFeatureExportSub => 'WAV · MIDI · 스템 모두';

  @override
  String get paywallFeaturePriorityTitle => '스템 내보내기';

  @override
  String get paywallFeaturePrioritySub => '트랙별 WAV 분리';

  @override
  String get paywallPlanYearly => '연 구독';

  @override
  String paywallPlanYearlyPrice(String price) {
    return '$price / 년';
  }

  @override
  String paywallPlanYearlyHint(String monthly) {
    return '월 $monthly 환산';
  }

  @override
  String get paywallPlanMonthly => '월 구독';

  @override
  String paywallPlanMonthlyPrice(String price) {
    return '$price / 월';
  }

  @override
  String get paywallPlanMonthlyHint => '언제든 해지';

  @override
  String get paywallCtaProcessing => '결제 처리 중…';

  @override
  String paywallCtaStartTrial(int days) {
    return '$days일 무료로 시작하기';
  }

  @override
  String get paywallFooterTrial => '체험 종료 전 알림 · 언제든 해지 가능';

  @override
  String get paywallRestoreLink => '구매 복원';

  @override
  String get loginTitle => '로그인';

  @override
  String get loginSub => 'Pro 구독과 구매 복원에 사용돼요';

  @override
  String get loginFailedTitle => '로그인 실패';

  @override
  String get loginTermsPrefix => 'HumTrack ';

  @override
  String get loginTermsBetween => ' 및 ';

  @override
  String get loginTermsSuffix => '을 읽었으며 이에 동의합니다.';

  @override
  String get loginTermsLinkTerms => '서비스 약관';

  @override
  String get loginTermsLinkPrivacy => '개인정보 처리방침';

  @override
  String get appleSignInCta => 'Apple로 계속하기';

  @override
  String get googleSignInCta => 'Google로 계속하기';

  @override
  String get logoutConfirmTitle => '로그아웃 하시겠어요?';

  @override
  String get logoutConfirmBody => '이 기기의 곡은 그대로 남아있어요.';

  @override
  String get logoutCta => '로그아웃';

  @override
  String get restoreOkTitle => '복원 완료';

  @override
  String get restoreEmptyTitle => '복원할 구매가 없어요';

  @override
  String get restoreOkBody => 'Pro 기능이 다시 활성화됐어요.';

  @override
  String get restoreEmptyBody => '구독한 계정으로 로그인했는지 확인해 주세요.';

  @override
  String get projectOptionUploadProBadge => 'Pro 필요';

  @override
  String projectOptionRefreshSyncedAt(String ago) {
    return '$ago 동기됨';
  }

  @override
  String get projectOptionOpen => '열기';

  @override
  String get projectOptionRename => '이름 바꾸기';

  @override
  String get projectOptionDuplicate => '복제';

  @override
  String get projectOptionExport => '내보내기';

  @override
  String get projectOptionExportSub => 'WAV · MIDI';

  @override
  String get projectOptionDelete => '삭제';

  @override
  String get projectOptionDeleteSub => '되돌릴 수 없어요';

  @override
  String projectUploadedToast(String title) {
    return '$title — 클라우드에 올렸어요';
  }

  @override
  String projectHeaderMeta(int count, String dur, String ago) {
    return '$count개 트랙 · $dur · $ago';
  }

  @override
  String projectDeleteTitle(String title) {
    return '\"$title\" 삭제';
  }

  @override
  String get projectDeleteBody => '로컬 파일이 영구 삭제돼요. 이 작업은 되돌릴 수 없어요.';

  @override
  String get cloudFreeImageHeadline => '아직 클라우드가 없어요';

  @override
  String get cloudFreeImageSub =>
      'Pro 로 전환하면 5GB 클라우드를 받아\n모든 기기에서 작업물을 이어 만들 수 있어요.';

  @override
  String get cloudValueBackupTitle => '영구 보관';

  @override
  String get cloudValueBackupSub => '기기 변경 · 분실에도 안전';

  @override
  String get cloudValueAutoSyncTitle => '자동 이어쓰기';

  @override
  String get cloudValueAutoSyncSub => '다른 기기 로그인만 하면 그대로';

  @override
  String get cloudValueExportTitle => '무제한 내보내기';

  @override
  String get cloudValueExportSub => 'WAV · MIDI · 스템 모두';

  @override
  String cloudUpgradeFootnote(int days, String price) {
    return '$days일 무료 체험 · 이후 $price/월';
  }

  @override
  String get cloudProEmptyTitle => '클라우드가 비어있어요';

  @override
  String get cloudProEmptySub =>
      '내 작업물 탭에서 작업물의 ⋯ 메뉴를 열고\n\"클라우드에 올리기\"를 눌러 보세요.';

  @override
  String get cloudGoToLocalTab => '내 작업물 탭으로 가기';

  @override
  String get cloudGraceTitle => 'Pro 가 만료됐어요';

  @override
  String get cloudGraceBody =>
      '데이터는 그대로 보관돼 있어요. 다운로드는 언제든 가능하고, 재구독하면 동기화가 다시 켜져요.';

  @override
  String get cloudGraceEmpty => '클라우드 보관함이 비어있어요';

  @override
  String get cloudUsageInUse => '사용 중';

  @override
  String get cloudUsageStored => '보관 중';

  @override
  String get cloudUsageReadOnly => '읽기 전용';

  @override
  String cloudUsageCount(int n) {
    return '$n개 작업물 보관 중';
  }

  @override
  String cloudUsageCountStored(int n) {
    return '$n개 작업물';
  }

  @override
  String get cloudCardThisDevice => '이 기기';

  @override
  String get cloudCardDownload => '받기';

  @override
  String cloudOptionsSubtitle(String uploadedAt, String size) {
    return '☁ 클라우드 · $uploadedAt 올림 · $size';
  }

  @override
  String get cloudOptionsDownloadAgain => '내 기기에 다시 받기';

  @override
  String get cloudOptionsDownload => '내 기기에 받기';

  @override
  String settingsCloudPercentUsed(int pct) {
    return '$pct% 사용';
  }

  @override
  String settingsCloudFree(String free) {
    return '$free 여유';
  }

  @override
  String get settingsCloudUsageDetail => '사용량 자세히';

  @override
  String get settingsCloudUsageDetailLink => '사용량 자세히 →';

  @override
  String get syncProgressUpload => '클라우드에 올리는 중';

  @override
  String get syncProgressDownload => '내 기기로 받는 중';

  @override
  String get comingSoonFeature => '기능';

  @override
  String comingSoonToast(String label) {
    return '$label — 준비중입니다';
  }

  @override
  String get proWelcomeTitle => '클라우드가 활성화됐어요';

  @override
  String get proWelcomeBody => '이제 어디서나 작업물을 이어 만들 수 있어요.';

  @override
  String get proWelcomeBadgeLabel => '내 클라우드';

  @override
  String get proWelcomeStep1Prefix => '내 작업물의 ⋯ 메뉴에서 ';

  @override
  String get proWelcomeStep1Bold => '클라우드에 올리기';

  @override
  String get proWelcomeStep2 => '다른 기기에서 로그인 → 클라우드 자동 표시';

  @override
  String get proWelcomeStep3 => '양쪽 어디서든 자유롭게 작업';

  @override
  String get proWelcomeCta => '클라우드 둘러보기';

  @override
  String get recPermDenied => '마이크 권한이 필요합니다. 다시 허용해주세요.';

  @override
  String get recPermPermanentlyDenied => '설정 > 개인정보 > 마이크에서 권한을 켜주세요.';

  @override
  String get recPermRestricted => '이 기기에서는 마이크 사용이 제한되어 있어 녹음할 수 없습니다.';

  @override
  String get recPermChecking => '마이크 권한을 확인 중입니다…';

  @override
  String get recPermRequest => '권한 요청';

  @override
  String get recPermOpenSettings => '설정 열기';

  @override
  String recScreenTitle(String role) {
    return '$role 녹음';
  }

  @override
  String recRecordingTitle(String role) {
    return 'Recording · $role';
  }

  @override
  String get recHumOrSing => '흥얼거리거나 노래해주세요';

  @override
  String get recReadyHint => '준비되면 아래 버튼을 누르세요';

  @override
  String get recTapToStop => '탭하면 녹음 종료';

  @override
  String get recTapToStart => '탭하면 녹음 시작';

  @override
  String get faqTitle => 'FAQ';

  @override
  String get faq1Q => '무료로 어디까지 쓸 수 있나요?';

  @override
  String get faq1A =>
      '녹음 → 분석 → 편집까지 모든 기능을 자유롭게 써 보실 수 있어요. 무료 플랜은 4곡까지 저장되고, 무제한 곡 만들기와 WAV · MIDI · 스템 내보내기는 Pro 구독에서 잠금이 풀려요.';

  @override
  String get faq2Q => '어떤 악기로 변환되나요?';

  @override
  String get faq2A =>
      '피아노 · 신스 · 어쿠스틱 기타 · 일렉 기타 · 베이스 · 드럼 그리고 보컬 원본까지 — 카드 탭으로 즉시 전환할 수 있어요.';

  @override
  String get faq3Q => '내 목소리는 누가 들을 수 있나요?';

  @override
  String get faq3A => '모든 처리는 기기 안에서 이뤄지고, 허밍 분석에 필요한 오디오만 서버로 전송된 뒤 보관되지 않아요.';

  @override
  String get faq4Q => '구독을 해지하면 만든 곡은 어떻게 되나요?';

  @override
  String get faq4A =>
      '만든 곡은 이 기기에 그대로 남아 편집할 수 있어요. 새로운 내보내기와 무제한 곡 만들기는 일시 정지되고, 다시 구독하면 즉시 복원됩니다.';

  @override
  String get faq5Q => '환불은 가능한가요?';

  @override
  String get faq5A => '결제는 앱 마켓 정책을 따릅니다. 결제 페이지에서 직접 요청해 주세요.';

  @override
  String get contactTitle => '문의하기';

  @override
  String get contactHeadline => '무엇을 도와드릴까요?';

  @override
  String get contactSub => '대부분의 답변은 FAQ 에 있어요. 그 외엔 아래로 알려주세요.';

  @override
  String get contactEmail => '이메일';

  @override
  String get contactBug => '버그 신고';

  @override
  String get contactBugSub => '재현 단계와 함께 적어주시면 큰 도움이 돼요';

  @override
  String get contactFeature => '기능 제안';

  @override
  String get contactFeatureSub => '이런 기능이 있었으면 좋겠어요';

  @override
  String get termsTitle => '서비스 약관';

  @override
  String get privacyTitle => '개인정보처리방침';

  @override
  String get refundScreenTitle => '환불 정책';

  @override
  String legalEffectiveDate(String date) {
    return '시행일: $date';
  }

  @override
  String legalLastUpdated(String date) {
    return '최종개정: $date';
  }

  @override
  String get cloudDownloadTitle => '클라우드에서 가져오기';

  @override
  String get cloudDownloadBanner =>
      '구독이 만료된 동안엔 새 업로드 / 동기화는 잠금돼요. 이전 작업물은 그대로 두고 언제든 다운로드하거나 삭제할 수 있어요.';

  @override
  String get cloudDownloadCta => '받기';

  @override
  String get cloudDownloadActionLabel => '다운로드';

  @override
  String get cloudRenameLabel => '클라우드 이름 바꾸기';

  @override
  String get editHeaderDone => '완료';

  @override
  String get editTrackInfoLabel => '트랙 정보';

  @override
  String get editConverting => '변환 중…';

  @override
  String editRecLabelRecord(String role) {
    return '$role 녹음';
  }

  @override
  String editRecLabelReRecord(String role) {
    return '$role 다시 녹음';
  }

  @override
  String get editMicPermNeededTitle => '마이크 권한이 필요해요';

  @override
  String get editMicPermNeededBody =>
      'iPad 설정 → 개인정보 보호 → 마이크에서 HumTrack 을 허용해 주세요.';

  @override
  String get editMicPermLabel => '마이크 권한이 필요합니다';

  @override
  String get editOpenSettings => '설정 열기';

  @override
  String get editPlayNoActiveTrack => '활성 트랙이 없습니다(사이드바 탭)';

  @override
  String get editPlayRecordFirst => '먼저 녹음하세요';

  @override
  String editPlayFailed(String err) {
    return '재생 실패: $err';
  }

  @override
  String get editOriginalPlayFailed => '원본 재생 실패';

  @override
  String get editSplitNotPossible => '현재 위치에서는 분할할 수 없음';

  @override
  String editTrackDeleteTitle(String role) {
    return '$role 트랙 삭제';
  }

  @override
  String get editTrackDeleteBody => '녹음과 노트가 모두 삭제됩니다.';

  @override
  String get editChunkVolumeTitle => '청크 볼륨';

  @override
  String get editNoteVolumeTitle => '노트 볼륨';

  @override
  String get editTransportOriginal => '원본';

  @override
  String get editSaveSaving => '저장 중...';

  @override
  String get editSaveJust => '방금 저장됨';

  @override
  String editSaveAt(String time) {
    return '$time 저장됨';
  }

  @override
  String get ctxActionPitch => '음정';

  @override
  String get ctxActionChord => '코드';

  @override
  String get ctxActionUnchord => '코드 해제';

  @override
  String get ctxActionVolume => '볼륨';

  @override
  String get ctxActionDelete => '삭제';

  @override
  String get ctxActionSplit => '분할';

  @override
  String get ctxActionCopy => '복사';

  @override
  String get ctxActionRerecord => '재녹음';

  @override
  String get ctxActionLoop => '루프';

  @override
  String get ctxActionUnloop => '루프 해제';

  @override
  String get ctxActionMute => '뮤트';

  @override
  String get ctxActionUnmute => '뮤트 해제';

  @override
  String get ctxActionBassPlace => '저음 배치';

  @override
  String get ctxActionBassUnplace => '배치 해제';

  @override
  String get timelineLoop => '루프';

  @override
  String get timelineRerecord => '재녹음';

  @override
  String get timelineRecordStart => '녹음 시작';

  @override
  String get timelinePitchAssist => '피치 어시스트';

  @override
  String get timelineRecCompleteVocal => '녹음 완료 — 보컬을 사용할까요?';

  @override
  String timelineRecCompleteNotes(int n) {
    return '녹음 완료 — 노트 $n개를 사용할까요?';
  }

  @override
  String get timelineRecCompleteGeneric => '녹음 완료 — 사용할까요?';

  @override
  String get pendingRecTitle => '녹음 완료';

  @override
  String get pendingAnalyzing => '분석 중…';

  @override
  String pendingVocalUseQ(String sec) {
    return '$sec초 보컬을 사용할까요?';
  }

  @override
  String pendingNotesUseQ(String sec, int n) {
    return '$sec초 · 노트 $n개를 사용할까요?';
  }

  @override
  String get pendingPreview => '미리듣기';

  @override
  String get pendingStop => '정지';

  @override
  String get addTrackTitle => '트랙 추가';

  @override
  String get addTrackPiano => '피아노';

  @override
  String get addTrackAcousticGuitar => '어쿠스틱 기타';

  @override
  String get addTrackElectricGuitar => '일렉 기타';

  @override
  String get addTrackSynth => '신스';

  @override
  String get addTrackOrgan => '오르간';

  @override
  String get addTrackStrings => '스트링';

  @override
  String get addTrackBassGuitar => '베이스 기타';

  @override
  String get addTrackSynthBass => '신스 베이스';

  @override
  String get addTrackDrumKit => '드럼 키트';

  @override
  String get addTrackVocal => '원본 보컬';

  @override
  String get addTrackVocalSub => '원본 그대로';

  @override
  String get anchorKeyTitle => '프로젝트 키 정하기';

  @override
  String get anchorKeySub => '이 키로 모든 트랙을 자동 정리합니다. 맞는 키를 골라주세요.';

  @override
  String get anchorKeyTagDetected => '감지됨';

  @override
  String get anchorKeyTagRelative => '상대조';

  @override
  String get anchorKeyTagCandidate => '후보';

  @override
  String get scaleMajor => '장조';

  @override
  String get scaleMinor => '단조';

  @override
  String instrumentPickerTitle(String role) {
    return '악기 선택 · $role';
  }

  @override
  String get instrumentPickerVocalOnly => '원본 보컬 트랙입니다';

  @override
  String get chordModeTitle => '코드 모드';

  @override
  String get chordModeSub => '단음을 자동 화음으로';

  @override
  String get chordModeMono => '단음';

  @override
  String get chordModeChord => '코드';

  @override
  String get keyPickerTitle => '키 선택';

  @override
  String get keyPickerSub => 'Auto = 추천 키 자동 적용';

  @override
  String get keyPickerAuto => 'Auto (추천)';

  @override
  String get keyPickerMainRole => '메인 키 기준 트랙 (전체 트랙이 이 키로)';

  @override
  String get keyPickerMajor => '메이저';

  @override
  String get keyPickerMinor => '마이너';

  @override
  String get keyAuto => 'AUTO';

  @override
  String get keyManual => '수동';

  @override
  String noteWheelTitle(int idx) {
    return '노트 보정 · #$idx';
  }

  @override
  String get noteWheelRecommended => '추천';

  @override
  String get noteWheelOriginal => '원음';

  @override
  String get noteWheelOriginalHint => '원음 = 부른 그대로';

  @override
  String get chordPickerTitle => '코드 변환';

  @override
  String get chordPickerScopeChunk => '청크';

  @override
  String get chordPickerScopeRoot => '루트';

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
    return ' · 키: $label';
  }

  @override
  String get chordPickerNoKey => ' (키 미감지)';

  @override
  String get chordPickerCurrent => ' · 현재 코드';

  @override
  String get chordPickerMono => '원음';

  @override
  String get chordPickerMonoSub => '단음 (코드 해제)';

  @override
  String exportTitle(String title) {
    return '내보내기 · $title';
  }

  @override
  String get exportCloudSaveLabel => '클라우드 저장';

  @override
  String get exportCloudSaveTitle => '프로젝트에 저장';

  @override
  String get exportCloudSaveSub => '클라우드 동기화 · 언제든 재편집';

  @override
  String get exportMidiTitle => 'MIDI 내보내기';

  @override
  String get exportMidiSub => '.mid';

  @override
  String get exportAudioTitle => '오디오 내보내기';

  @override
  String get exportAudioSub => '.wav · 믹스 렌더';

  @override
  String get exportShareLabel => '공유';

  @override
  String get exportShareSub => '링크 · Instagram · TikTok';

  @override
  String exportFailed(String err) {
    return '내보내기 실패: $err';
  }

  @override
  String get metronomeTitle => '메트로놈';

  @override
  String get metronomeOn => '메트로놈 켜기';

  @override
  String get metronomeOff => '메트로놈 끄기';

  @override
  String get metronomeNote =>
      'BPM 은 프로젝트 전체에 적용돼요. 박자 보정 카드의 그리드도 이 BPM 을 기준으로 정렬합니다.';

  @override
  String metronomeBeatSec(String sec) {
    return '1박 = $sec초';
  }

  @override
  String get tempoVerySlow => '느린 발라드';

  @override
  String get tempoBallad => '보통 발라드';

  @override
  String get tempoMidPop => '팝/미디엄';

  @override
  String get tempoDance => '댄스/업비트';

  @override
  String get tempoFast => '빠른 곡';

  @override
  String get tempoVeryFast => '매우 빠름';

  @override
  String get quantizeTitle => '박자 보정';

  @override
  String get quantizeBpmHint => 'BPM 은 전체 프로젝트 설정이라 트랜스포트의 메트로놈 버튼에서 조정해요.';

  @override
  String get quantizeGridLabel => '박자 단위';

  @override
  String quantizeGridDetail(int n) {
    return '1박을 $n등분';
  }

  @override
  String get quantizeStrength => '강도';

  @override
  String get quantizeStrengthMin => '0%: 원본 그대로';

  @override
  String get quantizeStrengthMax => '100%: 완벽 정렬';

  @override
  String get quantizeFooter =>
      '여러 트랙의 박자가 미세하게 어긋날 때 같은 BPM/박자 단위로 맞추면 자동으로 동기화돼요.';

  @override
  String get quantizeOff => 'off';

  @override
  String quantizeSummary(int grid, int pct, int bpm) {
    return '1/$grid · $pct% · BPM $bpm';
  }

  @override
  String get cardInstrumentLabel => 'INSTRUMENT';

  @override
  String get cardInstrumentFallback => '악기';

  @override
  String get helpInstrumentBody =>
      '이 트랙을 어떤 악기 소리로 재생할지 선택해요. 분석된 음정에 SoundFont 악기 음색을 입혀 들려줘요.';

  @override
  String get cardKeyLabel => 'KEY';

  @override
  String get helpKeyBody =>
      '곡의 으뜸음(C, D…)과 모드(메이저/마이너)예요. AUTO = 분석이 자동 추정한 키. 카드를 탭하면 수동으로 바꿀 수 있어요. 신뢰도 = 추정이 얼마나 확실한지 (0~1).';

  @override
  String get keyAnalysisPending => '녹음 후 분석';

  @override
  String keyConfidence(String conf, String tier) {
    return '신뢰도 $conf$tier';
  }

  @override
  String get cardAssistLabel => '피치 어시스트';

  @override
  String get helpAssistBody =>
      '키 밖으로 살짝 빗나간 음을 가장 가까운 in-key 음으로 자동 보정해 줘요. \"보정됨\" 숫자 = 실제로 끌어당겨진 노트 개수.';

  @override
  String get assistCorrected => '보정됨';

  @override
  String get assistDesc => '키 밖 음 자동 정리';

  @override
  String get cardQuantizeLabel => '박자 보정';

  @override
  String get helpQuantizeBody =>
      '여러 트랙의 박자가 미세하게 어긋날 때 같은 BPM/박자 단위로 맞추면 자동으로 동기화돼요. 원본 timing 은 그대로 보존돼, 토글을 꺼면 원래대로 돌아옵니다.';

  @override
  String get conflictTitle => '양쪽 모두 변경됐어요';

  @override
  String conflictSub(String title) {
    return '$title · 내 작업물과 클라우드에서 모두 수정됐어요';
  }

  @override
  String get conflictLocalHeader => '📱 내 작업물 (이 기기)';

  @override
  String get conflictCloudHeader => '☁ 클라우드 (다른 곳)';

  @override
  String conflictTrackInfo(int count, String size) {
    return '$count트랙 · $size';
  }

  @override
  String get conflictKeepBoth => '둘 다 보관 (사본으로)';

  @override
  String get conflictBadgeRecommended => '추천';

  @override
  String get conflictOverwriteCloud => '이 기기 버전을 클라우드에 덮어쓰기';

  @override
  String get conflictPullFromCloud => '클라우드 버전을 이 기기에 가져오기';

  @override
  String get authErrDisabled => 'Auth 비활성 (Supabase 키 미설정)';

  @override
  String get authErrIdentityBlockedGeneric =>
      '이미 다른 방법으로 가입된 이메일이에요.\n처음 가입했던 방법으로 로그인해 주세요.';

  @override
  String authErrIdentityBlockedSpecific(String providers) {
    return '이미 $providers 로 가입된 이메일이에요.\n$providers 로 로그인해 주세요.';
  }

  @override
  String get authErrGoogleNoIdToken =>
      'Google: idToken 누락 (serverClientId/iOS client 미스매치 가능)';

  @override
  String authErrAppleCode(String code, String message) {
    return 'Apple $code: $message';
  }

  @override
  String authErrGeneric(String provider, String raw) {
    return '$provider: $raw';
  }

  @override
  String get authProviderKakao => '카카오';

  @override
  String get authProviderNaver => '네이버';

  @override
  String get accountErrNoSession => '로그인 세션이 없어요. 다시 시도해 주세요.';

  @override
  String accountErrServerDelete(int status, String detail) {
    return '서버 삭제 실패 ($status)$detail';
  }

  @override
  String get payTitle => 'HumTrack Pro';

  @override
  String payBenefits(int n) {
    return '무제한 곡 만들기 (무료 플랜은 $n곡까지) · WAV / MIDI / 스템 내보내기.';
  }

  @override
  String get payPlanYearly => '연간';

  @override
  String get payPlanMonthly => '월간';

  @override
  String payPerMonthEquiv(String price) {
    return '월 $price 꼴';
  }

  @override
  String get payBilledMonthly => '매월 결제';

  @override
  String get payPeriodYear => '년';

  @override
  String get payPeriodMonth => '월';

  @override
  String payPerPeriod(String period) {
    return ' / $period';
  }

  @override
  String payDisclosureTrial(int days, String price, String period) {
    return '신규 구독자에 한해 $days일 무료 체험 후 $period $price 결제. 해지 전까지 자동 갱신되며, 갱신 24시간 전까지 설정에서 언제든 해지할 수 있어요.';
  }

  @override
  String payDisclosureNoTrial(String price, String period) {
    return '$period $price 결제. 해지 전까지 자동 갱신되며, 갱신 24시간 전까지 설정에서 언제든 해지할 수 있어요.';
  }

  @override
  String get paySubscribe => '구독하기';

  @override
  String get payPendingButton => '승인 대기 중…';

  @override
  String get payRestore => '구매 복원';

  @override
  String get payStoreUnavailable => '스토어를 사용할 수 없어요';

  @override
  String get payStoreUnavailableDevice => '이 기기에서는 스토어를 사용할 수 없어요.';

  @override
  String get payPurchaseFailed => '구매를 완료하지 못했어요. 다시 시도해 주세요.';

  @override
  String get payPendingApproval => '승인 대기 중이에요. 스토어에서 결제가 확인되면 Pro 가 활성화돼요.';

  @override
  String get payVerifyFailed =>
      '결제가 확인됐어요 — Pro 를 활성화하는 중입니다. 반영되지 않으면 \'구매 복원\'을 눌러 주세요.';

  @override
  String get paySignInRequired => '구독하려면 로그인해 주세요.';

  @override
  String get payRestoreDone => 'Pro 가 복원됐어요. 다시 오신 걸 환영해요!';

  @override
  String get payRestoreAlready => '이미 Pro 를 이용 중이에요.';

  @override
  String get payRestoreEmpty => '이 계정에 활성 구독이 없어요. 구독한 계정으로 로그인했는지 확인해 주세요.';

  @override
  String get payRestoreError => '구매를 복원하지 못했어요. 연결을 확인하고 다시 시도해 주세요.';

  @override
  String get acctTitle => '마이 페이지';

  @override
  String get acctSignedIn => '로그인됨';

  @override
  String acctSignedInWith(String provider) {
    return '로그인됨 · $provider';
  }

  @override
  String get acctProActive => 'HumTrack Pro · 이용 중';

  @override
  String get acctProBenefits => '무제한 곡 · WAV / MIDI / 스템 내보내기';

  @override
  String acctProUntil(String date) {
    return '$date까지';
  }

  @override
  String get acctUpgrade => 'Pro 로 업그레이드';

  @override
  String get acctSignOut => '로그아웃';

  @override
  String get acctSignInTitle => 'HumTrack 에 로그인';

  @override
  String get acctSignInSub => 'Pro 구독과 구매 복원에 로그인이 필요해요.';

  @override
  String get acctSignInWithEmail => '이메일로 로그인';

  @override
  String get acctEmailHint => '이메일';

  @override
  String get acctPasswordHint => '비밀번호';

  @override
  String get acctEnterEmailPassword => '이메일과 비밀번호를 입력해 주세요.';

  @override
  String get acctSigningIn => '로그인 중…';

  @override
  String get acctSignIn => '로그인';

  @override
  String get acctDeleteNotSignedIn => '로그인되어 있지 않아요.';

  @override
  String acctDeleteRejected(int code) {
    return '탈퇴 실패 ($code)';
  }

  @override
  String get acctDeleteNetwork => '네트워크 오류예요. 연결을 확인하고 다시 시도해 주세요.';

  @override
  String get authNotConfigured => '이 빌드에는 로그인이 설정되어 있지 않아요.';

  @override
  String get authFailedGeneric => '로그인에 실패했어요. 다시 시도해 주세요.';

  @override
  String get authUnavailable => '지금은 로그인을 사용할 수 없어요.';

  @override
  String get authGoogleNoIdToken =>
      'Google 로그인에서 ID 토큰을 받지 못했어요. 다시 시도하거나 Apple 로그인을 이용해 주세요.';

  @override
  String authAppleFailed(String code, String message) {
    return 'Apple 로그인 실패 ($code). $message';
  }

  @override
  String authProviderFailed(String provider) {
    return '$provider 로그인에 실패했어요. 다시 시도해 주세요.';
  }

  @override
  String get authSessionExpired => '세션이 만료됐어요. 다시 로그인해 주세요.';

  @override
  String get ltCardMore => '더 보기';

  @override
  String get ltSettingsDeleteAccount => '회원 탈퇴';

  @override
  String get ltSettingsDeleteAccountConfirmTitle => '회원 탈퇴할까요?';

  @override
  String get ltSettingsDeleteAccountConfirmBody =>
      '계정과 모든 데이터가 영구적으로 삭제돼요. 되돌릴 수 없어요.';

  @override
  String ltSettingsDeleteAccountFailed(String err) {
    return '탈퇴 실패: $err';
  }

  @override
  String get ltSettingsDeleteAccountDone => '회원 탈퇴가 완료됐어요.';

  @override
  String ltExportTitle(String title) {
    return '\"$title\" 내보내기';
  }

  @override
  String ltExportMeta(int count, int bars, int bpm) {
    return '섹션 $count개 · $bars마디 · $bpm BPM';
  }

  @override
  String get ltExportMidiTitle => 'MIDI 파일';

  @override
  String get ltExportMidiSub => '전체 곡 · 피아노 · 베이스 · 드럼 (ch10)';

  @override
  String get ltExportWavTitle => '오디오 (WAV)';

  @override
  String get ltExportWavSub => '믹스된 전체 곡';

  @override
  String get ltExportStemsTitle => '스템';

  @override
  String get ltExportStemsSub => '트랙별 WAV 분리';

  @override
  String get ltExportShareTitle => '공유';

  @override
  String get ltExportShareSub => '다른 앱으로 보내기';

  @override
  String get ltExportScopeLabel => '내보낼 범위';

  @override
  String get ltExportScopeAll => '전체 곡';

  @override
  String ltExportSaved(String filename) {
    return '$filename 저장됨';
  }

  @override
  String ltExportVocalSkipped(int count) {
    return '이전 형식 보컬 $count개는 믹스에 포함되지 않았어요';
  }

  @override
  String get ltExportFailed => 'MIDI 내보내기 실패';

  @override
  String get ltExportFooter =>
      '섹션은 순서대로(반복 포함) 렌더링됩니다. MIDI는 모든 DAW 에서 열립니다. WAV·스템은 사운드폰트로 렌더된 오디오입니다.';

  @override
  String get ltSettingsTitle => '설정';

  @override
  String get ltSettingsMetronome => '메트로놈 클릭';

  @override
  String get ltSettingsMetronomeSub => '녹음 중 클릭음 재생';

  @override
  String get ltSettingsHaptics => '햅틱';

  @override
  String get ltSettingsHapticsSub => '패드 탭 시 진동';

  @override
  String get ltSettingsAbout => '정보';

  @override
  String get ltSettingsAboutSub => 'HumTrack · v0.4';

  @override
  String get ltSettingsLegalSection => '약관 및 정책';

  @override
  String get ltSettingsOpenSource => '오픈소스 라이선스';

  @override
  String get ltSettingsContact => '문의하기';

  @override
  String get ltSongsTagline => '탭으로 만드는 비트';

  @override
  String get ltSongsNewSong => '새 곡';

  @override
  String get ltSongsNewCard => '새 루프 만들기';

  @override
  String ltSongCardMeta(String key, String scale, int bpm, int bars) {
    return '$key $scale · $bpm BPM · $bars마디';
  }

  @override
  String get ltScalePenta => '펜타토닉';

  @override
  String get ltScaleDorian => '도리안';

  @override
  String get ltKeySheetTitle => '키 & 스케일';

  @override
  String get ltKeyRoot => '루트';

  @override
  String get ltKeyScale => '스케일';

  @override
  String get ltKeyHint => '키에 맞는 음만 패드에 나와요 — 틀린 음을 누를 일이 없어요.';

  @override
  String get ltMixerTitle => '믹서';

  @override
  String ltInstrumentSheetTitle(String track) {
    return '$track 악기';
  }

  @override
  String get ltInstrumentFavorites => '즐겨찾기';

  @override
  String get ltInstrumentCloudSounds => '클라우드 사운드';

  @override
  String get ltTransportCountIn => '카운트인';

  @override
  String get ltTransportLoopAlwaysOn => '루프 (항상 켜짐)';

  @override
  String get ltTransportClearTrack => '트랙 비우기';

  @override
  String get ltTransportSwing => '스윙';

  @override
  String get ltTransportSetBpm => 'BPM 설정';

  @override
  String get ltSectionsLabel => '곡';

  @override
  String get ltSectionPlaySong => '곡 재생';

  @override
  String get ltSectionStopSong => '곡 정지';

  @override
  String get ltArrangeAddTrack => '트랙';

  @override
  String get ltEditorBack => '뒤로';

  @override
  String get ltEditorUndo => '실행 취소';

  @override
  String get ltEditorRedo => '다시 실행';

  @override
  String get ltEditorSaved => '저장됨';

  @override
  String get ltEditorUnsaved => '저장 안 됨';

  @override
  String ltEditorSectionMenuTitle(String name) {
    return '섹션 $name';
  }

  @override
  String get ltEditorMoveLeft => '왼쪽으로 이동';

  @override
  String get ltEditorMoveRight => '오른쪽으로 이동';

  @override
  String get ltEditorTrackCleared => '트랙을 비웠어요';

  @override
  String get ltEditorLaneFull => '레인이 가득 찼어요 — 새 테이크는 맨 앞에서 겹쳐 시작해요';

  @override
  String get ltEditorSoundDownloadFailed => '사운드를 받지 못했어요 — 연결을 확인해주세요';

  @override
  String get ltEditorSoundReady => '악기 준비 완료';

  @override
  String get ltEditorAutotuneTitle => '오토튠';

  @override
  String ltEditorAutotuneSub(String key, String scale) {
    return '$key $scale 에 맞춰 음정을 잡아줘요. 원본 테이크는 그대로 남아요.';
  }

  @override
  String get ltEditorAutotuneNatural => '자연스럽게';

  @override
  String get ltEditorAutotuneNaturalSub => '살짝만 보정해서 원래 느낌을 살려요';

  @override
  String get ltEditorAutotuneStrong => '강하게';

  @override
  String get ltEditorAutotuneStrongSub => '딱 붙는 그 소리';

  @override
  String get ltEditorAutotuneFailed => '오토튠은 연결이 필요해요';

  @override
  String ltEditorAutotuneProgress(int done, int total) {
    return '테이크 $done/$total 보정 중';
  }

  @override
  String ltEditorHumAdded(int count) {
    return '허밍에서 노트 $count개를 넣었어요';
  }

  @override
  String get ltEditorHumErrTooLong => '녹음이 너무 길어요';

  @override
  String get ltEditorHumErrBusy => '서버가 혼잡해요. 잠시 후 다시 시도해주세요';

  @override
  String get ltEditorHumErrWaking => '서버를 깨우는 중이에요. 다시 시도해주세요';

  @override
  String get ltEditorHumErrGeneric => '허밍을 변환하지 못했어요';

  @override
  String get ltEditorHumErrNoNotes => '노트를 찾지 못했어요 — 조금 더 크게 불러보세요';

  @override
  String get ltEditorModePads => '패드';

  @override
  String get ltEditorModeGrid => '그리드';

  @override
  String get ltEditorPowerChord => '파워';

  @override
  String get ltEditorOctaveDown => '옥타브 내리기';

  @override
  String get ltEditorOctaveUp => '옥타브 올리기';

  @override
  String get ltEditorHumToMidi => '허밍 → MIDI';

  @override
  String get ltEditorHintGridDrums => '셀을 탭해서 켜고 끄기';

  @override
  String get ltEditorHintGridPitched => '탭 · 드래그로 길이 조절 · 자동 병합';

  @override
  String get ltEditorHintPads => '녹음 후 탭';

  @override
  String ltHumModalTitle(String track) {
    return '허밍 → MIDI · $track';
  }

  @override
  String get ltHumCountIn => '준비하세요 — 박자에 맞춰 흥얼거려요.';

  @override
  String get ltHumListen => '떠오르는 멜로디를 흥얼거려요 — 키와 박자에 맞춰 정리해드려요.';

  @override
  String get ltHumConverting => '노트로 변환 중…';

  @override
  String get ltHumDone => '완료! 노트를 넣었어요.';

  @override
  String get ltHumConvert => '변환';

  @override
  String get ltRecErrUnavailable => '녹음을 시작할 수 없어요';

  @override
  String get ltRecErrInterrupted => '녹음이 중단됐어요 — 다시 시도해주세요';

  @override
  String get ltRecErrNoAudio => '녹음된 소리가 없어요';

  @override
  String get ltRecErrFailed => '녹음에 실패했어요';

  @override
  String get ltRecErrTooShort => '녹음이 너무 짧아요';

  @override
  String get ltRecErrTooQuiet => '소리가 너무 작아요';

  @override
  String get ltRecSaveFailed => '녹음을 저장하지 못했어요';

  @override
  String get ltVocalRecTitle => '보컬 녹음';

  @override
  String get ltVocalRecCountInNoHeadset =>
      '이어폰이 없어요 — 루프가 마이크에 들어가지 않게 무음으로 녹음해요.';

  @override
  String get ltVocalRecCountIn => '준비하세요 — 루프에 맞춰 불러주세요.';

  @override
  String get ltVocalRecListenMuted => '한 루프 녹음 중 — 기기 소리는 꺼져 있어요.';

  @override
  String get ltVocalRecListen => '한 루프 녹음 중 — 같이 불러주세요.';

  @override
  String get ltVocalRecDone => '완료! 보컬을 녹음했어요.';

  @override
  String get ltVocalLiveAutotune => '실시간 오토튠';

  @override
  String get ltVocalLiveAutotuneOn => '실시간 오토튠 ON';

  @override
  String get ltVocalRecorded => '녹음됨';

  @override
  String get ltVocalTapToRecord => '탭해서 녹음';

  @override
  String get ltVocalRecOverSong => '곡 전체 녹음';

  @override
  String get ltVocalReRecOverSong => '곡 전체 다시 녹음';

  @override
  String get ltVocalClearSongTake => '곡 보컬 지우기';

  @override
  String get ltVocalEdit => '편집';

  @override
  String get ltVocalClear => '지우기';

  @override
  String get ltVocalEditorTitle => '보컬 편집기';

  @override
  String ltVocalEditorMeta(int takes, int bpm, int bars) {
    return '테이크 $takes개 · $bpm BPM · $bars마디';
  }

  @override
  String get ltVocalEditorNoTake => '편집할 테이크가 없어요';

  @override
  String ltVocalEditorTake(int n) {
    return '테이크 $n';
  }

  @override
  String ltVocalEditorFxCount(int n) {
    return 'FX $n';
  }

  @override
  String get ltVocalEditorDragHint => '드래그해서 구간 선택';

  @override
  String get ltVocalEditorDragSet => '구간 선택됨 · 자르기 탭';

  @override
  String get ltVocalEditorTrimmed => '잘림';

  @override
  String ltVocalEditorFadeInReadout(int ms) {
    return '인 ${ms}ms';
  }

  @override
  String ltVocalEditorFadeOutReadout(int ms) {
    return '아웃 ${ms}ms';
  }

  @override
  String get ltVocalEditorEditGroup => '편집';

  @override
  String get ltVocalEditorEffectsGroup => '이펙트';

  @override
  String get ltVocalEditorReset => '되돌리기';

  @override
  String get ltVocalEditorServerTag => '서버';

  @override
  String get ltVocalEditorTrim => '자르기';

  @override
  String ltVocalEditorFadeIn(int ms) {
    return '페이드 인 $ms';
  }

  @override
  String ltVocalEditorFadeOut(int ms) {
    return '페이드 아웃 $ms';
  }

  @override
  String get ltVocalEditorGainDown => '게인 −';

  @override
  String get ltVocalEditorGainUp => '게인 +';

  @override
  String get ltVocalEditorNormalize => '노멀라이즈';

  @override
  String get ltVocalEditorProcessFailed => '사운드 가공에 실패했어요';

  @override
  String get ltVocalEditorPreview => '미리듣기 (편집본)';

  @override
  String get ltVocalEditorEarlier => '앞으로 당기기';

  @override
  String get ltVocalEditorLater => '뒤로 밀기';

  @override
  String ltVocalEditorStep(int n) {
    return '스텝 $n';
  }

  @override
  String get ltVocalEditorDeleteTake => '테이크 삭제';

  @override
  String ltVocalEditorFxProcessing(String fx) {
    return '$fx 처리 중…';
  }

  @override
  String ltVocalEditorFxChainItem(int index, String fx) {
    return '$index. $fx';
  }

  @override
  String get ltFxEq => 'EQ';

  @override
  String get ltFxReverb => '리버브';

  @override
  String get ltFxComp => '컴프';

  @override
  String get ltFxDelay => '딜레이';

  @override
  String get ltFxStretch => '속도';

  @override
  String get ltFxPitch => '피치';

  @override
  String get ltFxSlower => '느리게';

  @override
  String get ltFxFaster => '빠르게';

  @override
  String get ltFxPitchUp => '피치 +2';

  @override
  String get ltFxPitchDown => '피치 −2';
}
