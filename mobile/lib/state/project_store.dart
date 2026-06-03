// 앱 전역 상태 (provider/ChangeNotifier).
// Project = N개 트랙(카테고리 = TrackRole: Keys/Bass/Drum/Vocal). 한 카테고리당
// 여러 트랙을 가질 수 있음(예: Chords 안에 Piano + Guitar). 각 트랙은 고유 id 로
// 식별되며 독립적으로 녹음/분석/편집.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../api/engine_api.dart';
import '../models/models.dart';
import '../music/chords.dart';
import '../music/chord_expand.dart';
import '../music/strum.dart';
import '../music/bass_placement.dart';
import '../services/analytics_service.dart';
import '../services/auth_service.dart';
import '../services/cloud_api.dart';
import '../services/iap_service.dart';
import '../services/observability_service.dart';
import 'local_storage.dart';

double _midiToHz(int m) => 440.0 * math.pow(2, (m - 69) / 12.0);

/// 드럼 일관 볼륨 — 모든 드럼 노트 렌더 시 이 velocity 로 통일(강약 제거).
const int kDrumFlatVelocity = 100;

/// 트랙 onset 들의 그리드 phase(포켓) 추정 — `start % cellSec` 의 원형평균.
/// 일관된 러시/레이백을 흡수해 그리드를 연주자에 맞춘다(그루브 보존). O(n).
double estimateGridPhase(List<Note> notes, double cellSec) {
  if (notes.isEmpty || cellSec <= 0) return 0.0;
  double s = 0, c = 0;
  for (final n in notes) {
    final th = 2 * math.pi * ((n.start % cellSec) / cellSec);
    s += math.sin(th);
    c += math.cos(th);
  }
  var ph = cellSec * math.atan2(s, c) / (2 * math.pi);
  if (ph < 0) ph += cellSec;
  return ph;
}

/// 한 트랙의 상태. `id` 는 ProjectStore 가 발급하는 고유 식별자(세션 단위).
class TrackData {
  TrackData(this.id, this.role, {int? program})
      : program = program ??
            (instrumentsForRole(role).isNotEmpty
                ? instrumentsForRole(role).first.program
                : 0),
        options = AnalyzeOptions() {
    // 드럼 트랙은 백엔드 onset 기반 드럼 분석을 요청 (단일 진실원).
    options.asDrums = role == TrackRole.drum;
    // 박자 보정 기본 on(보컬 제외). 사용자가 시트에서 끄기/그리드/세기 조절 가능.
    if (role != TrackRole.vocal) {
      quantizeEnabled = true;
    }
  }

  final int id;
  final TrackRole role;
  int program; // 선택된 GM 악기
  bool chordMode = false;
  // 베이스 저음역 자동 배치(role==bass 에서만 의미). 흥얼거린 베이스 라인을 윤곽 보존한
  // 채 저음역으로 통째 옥타브 이동 + 멜로디 분리. bassOctaveShift 는 파생 캐시값으로
  // _recomputeBassPlacement 가 채운다(저장 안 함 — 로드 후 재계산).
  bool bassPlacement = true;
  int bassOctaveShift = 0;
  bool enabled = true; // 믹스 재생 포함 여부(사이드바 토글)
  bool looping = false; // 트랙 루프 — 가장 긴 non-loop 트랙 끝까지 컨텐츠 반복
  // 박자 보정(quantize) — 노트 start 를 그리드(BPM 기반)에 끌어당김.
  // 비-파괴적: store.effectiveRenderNotesFor() 에서 렌더 시 적용. 원본 timing 보존.
  bool quantizeEnabled = false;
  int quantizeGrid = 4;           // 4/8/16/32 분음 — 기본 1/4(quarter)
  double quantizeStrength = 1.0;  // 0..1 — 기본 100%(완전 스냅)
  String? wavPath; // 마지막 녹음 원본 WAV (호환용 — 청크별 wav 는 Chunk.vocalWavPath)
  AnalyzeResponse? analysis; // 최근 분석 결과(가장 최근 청크 메타)
  List<Note> notes = []; // 전 청크의 모든 노트(원본 시간 보존)
  List<Chunk> chunks = []; // 청크 메타(이동/트림). 노트들은 chunkId 로 참조됨.
  AnalyzeOptions options; // autoKey / pitchAssistant / key

  // 호환용 — 신규 코드는 chunks 의 vocalWavPath 사용.
  String? vocalWavPath;
  List<double> vocalPeaks = const [];
  double vocalDuration = 0;

  bool get isVocal => role == TrackRole.vocal;
  bool get hasRecording =>
      chunks.isNotEmpty || wavPath != null || vocalWavPath != null;

  Chunk? chunkById(int id) {
    for (final c in chunks) {
      if (c.id == id) return c;
    }
    return null;
  }

  bool get isChordInstrument {
    for (final i in instrumentsForRole(role)) {
      if (i.program == program) return i.chordCapable;
    }
    return false;
  }

  bool get chordActive =>
      chordMode && isChordInstrument && (analysis?.detectedKey?.tonic != null);

  /// 재생/내보내기에 쓸 노트.
  /// - 베이스(배치 on): 저음역 옥타브 이동(bassOctaveShift, 사전 계산값) 적용.
  /// - 그 외: 코드 모드면 트라이어드 확장.
  List<Note> get renderNotes => (role == TrackRole.bass && bassPlacement)
      ? applyOctaveShift(notes, bassOctaveShift)
      : expandChords(notes, analysis?.detectedKey, chordActive);

  /// 청크의 timelineStart/inPoint/outPoint 를 적용한 "효과 시간" 기준 노트.
  /// 청크의 가시 윈도우 [inPoint, outPoint) 와 노트 [start, end) 의 교집합만 재생되도록 클립.
  /// 노트가 트림 경계를 가로지르면 잘려나간 부분은 무음 — 남은 구간만 발음.
  /// 청크 메타가 비어있으면(레거시) renderNotes 그대로 반환.
  List<Note> get effectiveRenderNotes {
    if (chunks.isEmpty) return renderNotes;
    final byId = {for (final c in chunks) c.id: c};
    final out = <Note>[];
    for (final n in renderNotes) {
      final c = byId[n.chunkId];
      if (c == null) {
        out.add(n);
        continue;
      }
      // 청크 가시 윈도우와 노트의 교집합.
      final clipStart = n.start < c.inPoint ? c.inPoint : n.start;
      final clipEnd = n.end > c.outPoint ? c.outPoint : n.end;
      if (clipEnd - clipStart <= 0.001) continue; // 교집합 없음
      final shift = c.timelineStart - c.inPoint;
      final newStart = clipStart + shift;
      final newEnd = clipEnd + shift;
      // 클립이 원본과 동일하면(start/end 모두 안쪽 + shift 0) clone 생략 가능.
      if (shift == 0 && clipStart == n.start && clipEnd == n.end) {
        out.add(n);
      } else {
        final clone = Note.fromJson(n.toJson())
          ..start = newStart
          ..end = newEnd
          ..chunkId = n.chunkId;
        clone.duration = newEnd - newStart;
        out.add(clone);
      }
    }
    return out;
  }

  /// 직렬화 — 프로젝트 저장/복원용(현재 호출처 없음, #21~ 에서 사용 예정).
  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role.name,
        'program': program,
        'chord_mode': chordMode,
        'bass_placement': bassPlacement,
        'enabled': enabled,
        'wav_path': wavPath,
        'vocal_wav_path': vocalWavPath,
        'vocal_peaks': vocalPeaks,
        'vocal_duration': vocalDuration,
        'notes': notes.map((n) => n.toJson()..['chunk_id'] = n.chunkId).toList(),
        'options': options.toJson(),
      };

  static TrackData fromJson(Map<String, dynamic> j) {
    final role = TrackRole.values.firstWhere(
      (r) => r.name == (j['role'] as String?),
      orElse: () => TrackRole.keys,
    );
    final t = TrackData(_i(j['id']), role, program: _i(j['program']))
      ..chordMode = (j['chord_mode'] ?? false) as bool
      ..bassPlacement = (j['bass_placement'] ?? true) as bool
      ..enabled = (j['enabled'] ?? true) as bool
      ..wavPath = j['wav_path'] as String?
      ..vocalWavPath = j['vocal_wav_path'] as String?
      ..vocalPeaks = ((j['vocal_peaks'] ?? []) as List).map((e) => (e as num).toDouble()).toList()
      ..vocalDuration = (j['vocal_duration'] as num?)?.toDouble() ?? 0
      ..notes = ((j['notes'] ?? []) as List).map((e) {
        final m = e as Map<String, dynamic>;
        final n = Note.fromJson(m);
        n.chunkId = (m['chunk_id'] as num?)?.toInt() ?? 0;
        return n;
      }).toList();
    final opt = (j['options'] ?? {}) as Map<String, dynamic>;
    t.options = AnalyzeOptions(
      autoKey: (opt['auto_key'] ?? true) as bool,
      pitchAssistant: (opt['pitch_assistant'] ?? true) as bool,
      keyTonic: opt['key_tonic'] as String?,
      scale: opt['scale'] as String?,
      asDrums: role == TrackRole.drum,
    );
    return t;
  }
}

int _i(dynamic v, [int def = 0]) => (v as num?)?.toInt() ?? def;

/// 녹음 종료 직후 분석 결과의 임시 보관소. 사용자가 트랙 안 다이얼로그에서
/// "사용"을 누르기 전까지는 트랙에 commit 되지 않는다 (시안 Frame 1 SYNTH).
///
/// - 멜로딕(keys/bass/drum): notes/analysis 가 채워짐, vocalWav* 는 null.
/// - 보컬: vocalWavPath/peaks/duration 이 채워짐, notes 는 항상 빈 리스트.
class PendingRecording {
  PendingRecording({
    required this.trackId,
    required this.role,
    required this.wavPath,
    this.notes = const [],
    this.analysis,
    this.vocalWavPath,
    this.vocalPeaks = const [],
    this.vocalDuration = 0,
    this.pitchAssist = true,
  });
  final int trackId;
  final TrackRole role;
  final String wavPath; // 마이크 원본 WAV (analyze 입력)
  List<Note> notes;
  AnalyzeResponse? analysis;
  // 보컬 전용 — 정리된 WAV / 표시용 파형.
  String? vocalWavPath;
  List<double> vocalPeaks;
  double vocalDuration;
  bool pitchAssist; // 다이얼로그 어시스트 토글의 현재 값
  bool reassisting = false; // /assist 재호출 중 (다이얼로그 mini 로딩용)
}

/// 결제/구독 상태 — 시안 ⑥/⑦/⑧/⑨/⑩ 분기.
enum SubscriptionStatus {
  anonymous,  // 로그인 X — 결제 정보 없음
  trial,      // 무료 체험 중
  active,     // 유효한 결제 구독
  cancelled,  // 해지 예약 — 만료 전까지는 active 와 동일 권한
  expired,    // 만료 — 클라우드 read-only / export gated
}

extension SubscriptionStatusX on SubscriptionStatus {
  bool get hasProAccess =>
      this == SubscriptionStatus.trial ||
      this == SubscriptionStatus.active ||
      this == SubscriptionStatus.cancelled;
  String get label {
    switch (this) {
      case SubscriptionStatus.anonymous: return 'Anonymous';
      case SubscriptionStatus.trial: return 'Trial';
      case SubscriptionStatus.active: return 'Active';
      case SubscriptionStatus.cancelled: return 'Cancelled';
      case SubscriptionStatus.expired: return 'Expired';
    }
  }
}

/// 클라우드 작업물 메타. UI 표시·옵션 시트용 — 실제 백엔드 페이로드는 후속 작업.
enum CloudProjectStatus { localOnly, cloudOnly, syncedClean, syncedDirty, conflict }

class CloudProjectMeta {
  CloudProjectMeta({
    required this.id,
    required this.title,
    required this.uploadedAt,
    required this.lastModifiedAt,
    required this.sizeBytes,
    required this.onThisDevice,
    this.serverMeta,
  });
  final String id;
  final String title;
  final DateTime uploadedAt;
  final DateTime lastModifiedAt;
  final int sizeBytes;
  /// 이 기기에도 같은 프로젝트가 있는지(다운로드 받았거나 업로드한 기기).
  final bool onThisDevice;
  /// 백엔드 응답의 `meta` JSON 통째 — `getProject(id)` 또는 `?include=meta` 시 채워짐.
  /// 다운로드 시 `vocal_files` 안의 public_url 을 읽어 R2 GET.
  final Map<String, dynamic>? serverMeta;

  CloudProjectMeta copyWith({
    String? title,
    DateTime? uploadedAt,
    DateTime? lastModifiedAt,
    int? sizeBytes,
    bool? onThisDevice,
    Map<String, dynamic>? serverMeta,
  }) =>
      CloudProjectMeta(
        id: id,
        title: title ?? this.title,
        uploadedAt: uploadedAt ?? this.uploadedAt,
        lastModifiedAt: lastModifiedAt ?? this.lastModifiedAt,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        onThisDevice: onThisDevice ?? this.onThisDevice,
        serverMeta: serverMeta ?? this.serverMeta,
      );

  /// 썸네일 색상 인덱스(0..3) — id 해시 기반.
  int get thumbIndex {
    var h = 0;
    for (final code in id.codeUnits) {
      h = (h * 31 + code) & 0x7fffffff;
    }
    return h % 4;
  }
}

/// 회원 탈퇴 실패 사유 — UI 에서 L10n 으로 해석.
class AccountDeleteError {
  const AccountDeleteError._({required this.code, this.status, this.detail, this.raw});
  final String code;       // 'noSession' | 'serverDelete' | 'raw'
  final int? status;
  final String? detail;
  final String? raw;

  factory AccountDeleteError.noSession() => const AccountDeleteError._(code: 'noSession');
  factory AccountDeleteError.serverDelete(int status, String detail) =>
      AccountDeleteError._(code: 'serverDelete', status: status, detail: detail);
  factory AccountDeleteError.raw(String raw) =>
      AccountDeleteError._(code: 'raw', raw: raw);
}

class ProjectStore extends ChangeNotifier {
  ProjectStore({EngineApi? api}) : _api = api ?? EngineApi() {
    projectId = 'p_${DateTime.now().millisecondsSinceEpoch}';
    _seedDefaultTracks();
    _attachExternalServices();
  }
  final EngineApi _api;

  /// 백엔드 dio 노출 — IapService.configureVerify(store.engineDio) 용.
  Dio get engineDio => _api.dio;

  // ─── 외부 SDK 리스너 (AuthService / IapService) ──────────────────────
  StreamSubscription? _authSub;
  StreamSubscription? _iapSub;

  void _attachExternalServices() {
    // Supabase 세션 변경 → accountEmail / subscription 미러링.
    _authSub = AuthService.instance.onSession.listen((s) {
      if (s.isSignedIn) {
        accountEmail = s.email;
        accountProvider = s.provider;
        // 로그인 = anonymous → trial 자동 전환 *금지*.
        // 실제 trial 은 paywall → Apple/Google IAP Introductory Offer 통과 후
        // IapService.onPurchaseResult 가 SubscriptionStatus.trial 로 전환.
        // (#61 — fake trial 표시 제거)
        ObservabilityService.instance.setUser(id: s.userId, email: s.email);
        if (s.userId != null) AnalyticsService.instance.identify(s.userId!);
        AnalyticsService.instance.userSignedUp(
          provider: s.provider ?? 'unknown',
          email: s.email,
        );
      } else {
        accountEmail = null;
        accountProvider = null;
        subscription = SubscriptionStatus.anonymous;
        subscriptionRenewsAt = null;
        ObservabilityService.instance.clearUser();
        AnalyticsService.instance.reset();
      }
      notifyListeners();
    });
    // IAP 결제 결과 → subscription 갱신.
    _iapSub = IapService.instance.onPurchaseResult.listen((r) {
      if (!r.ok) return;
      subscription = SubscriptionStatus.active;
      final isYearly = r.productId == kProductYearly;
      subscriptionRenewsAt = r.renewsAt ??
          DateTime.now().add(Duration(days: isYearly ? 365 : 30));
      AnalyticsService.instance.subscriptionStarted(
        productId: r.productId,
        plan: isYearly ? 'yearly' : 'monthly',
      );
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _iapSub?.cancel();
    super.dispose();
  }

  /// 로컬 파일 경로 식별자 — 처음 newProject 시 발급, loadProject 시 교체.
  String projectId = '';

  // ─── 저장 상태 (EditScreen 인디케이터용) ──────────────────────────────
  // notifyListeners() 호출 시 _hasUnsavedChanges = true 로 마킹 → 자동 저장이
  // 완료되면 markSaved() 가 false 로 되돌림. 디스크 쓰기는 EditScreen 의
  // periodic timer / lifecycle hook 가 트리거 — 여기서는 플래그만 관리.
  DateTime? _lastSavedAt;
  bool _isSaving = false;
  bool _hasUnsavedChanges = false;
  // notify 재진입 가드 — markSaved 안에서 notifyListeners() 호출 시 다시 dirty
  // 로 마킹되는 것을 막는다.
  bool _suppressDirtyMark = false;

  DateTime? get lastSavedAt => _lastSavedAt;
  bool get isSaving => _isSaving;
  bool get hasUnsavedChanges => _hasUnsavedChanges;

  @override
  void notifyListeners() {
    if (!_suppressDirtyMark) _hasUnsavedChanges = true;
    super.notifyListeners();
  }

  /// EditScreen 의 _saveNow() 가 LocalStorage.saveProject() 호출 직전에 호출.
  /// dirty 를 여기서 false 로 클리어 → 디스크 쓰기 동안 발생한 변경은 자연스럽게
  /// 다시 true 가 되어 다음 주기에 저장된다.
  void markSavingStart() {
    _isSaving = true;
    _hasUnsavedChanges = false;
    _suppressDirtyMark = true;
    super.notifyListeners();
    _suppressDirtyMark = false;
  }

  /// 디스크 쓰기 성공 후 호출 — lastSavedAt 갱신.
  /// (dirty 는 markSavingStart 에서 이미 클리어됨)
  void markSavingEnd({required bool ok}) {
    _isSaving = false;
    if (ok) {
      _lastSavedAt = DateTime.now();
    } else {
      // 실패 — 다음 주기 재시도 위해 dirty 복원.
      _hasUnsavedChanges = true;
    }
    _suppressDirtyMark = true;
    super.notifyListeners();
    _suppressDirtyMark = false;
  }

  // ─── 계정 / 구독 (시안 ⑥ ⑦ ⑧ ⑨ ⑩) ─────────────────────────────────
  // 백엔드 verify 전까지는 클라이언트 상태만으로 동작 — UI 흐름 검증용.
  SubscriptionStatus subscription = SubscriptionStatus.anonymous;
  String? accountEmail;       // 로그인 후 표시
  String? accountProvider;    // 'apple' / 'google'
  DateTime? subscriptionRenewsAt;

  void mockLogin({required String provider, required String email}) {
    accountProvider = provider;
    accountEmail = email;
    // anonymous → trial 자동 전환은 #61 에서 제거됨. 실제 trial 은 IAP 결제 통과 후 활성.
    notifyListeners();
  }

  void mockLogout() {
    accountProvider = null;
    accountEmail = null;
    subscription = SubscriptionStatus.anonymous;
    subscriptionRenewsAt = null;
    notifyListeners();
  }

  /// 회원 탈퇴 — backend /account 엔드포인트로 Supabase user 삭제 + 로컬 데이터 wipe.
  /// 성공 시 null, 실패 시 사용자 표시용 에러 (UI 에서 L10n 으로 해석) 반환.
  Future<AccountDeleteError?> deleteAccount() async {
    try {
      // 1) Backend 에 user 삭제 요청 (JWT 인증).
      if (AuthService.instance.enabled && AuthService.instance.current.userId != null) {
        final accessToken = await AuthService.instance.currentAccessToken();
        if (accessToken == null) {
          return AccountDeleteError.noSession();
        }
        final dio = Dio(BaseOptions(
          baseUrl: EngineConfig.baseUrl,
          // 4xx/5xx 도 throw 안 하고 응답으로 받아 직접 처리 → 깔끔한 에러 메시지.
          validateStatus: (_) => true,
        ));
        final res = await dio.delete<dynamic>(
          '/account',
          options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
        );
        if (res.statusCode != 200 && res.statusCode != 204) {
          final detail = (res.data is Map ? res.data['detail'] : null) ?? '';
          return AccountDeleteError.serverDelete(res.statusCode ?? 0, detail.toString());
        }
      }
      // 2) 로컬 데이터 wipe.
      await LocalStorage.instance.wipeAll();
      // 3) 클라이언트 세션 정리.
      await AuthService.instance.signOut();
      // 4) 메모리 상태 리셋.
      accountProvider = null;
      accountEmail = null;
      subscription = SubscriptionStatus.anonymous;
      subscriptionRenewsAt = null;
      notifyListeners();
      return null;
    } catch (e) {
      debugPrint('[store] deleteAccount failed: $e');
      return AccountDeleteError.raw(e.toString());
    }
  }

  /// 개발자 모드 — 디버그 토글로 임의 상태 전환.
  void devSetSubscription(SubscriptionStatus s) {
    subscription = s;
    if (s == SubscriptionStatus.active || s == SubscriptionStatus.trial) {
      subscriptionRenewsAt = DateTime.now().add(const Duration(days: 30));
    } else if (s == SubscriptionStatus.cancelled) {
      subscriptionRenewsAt = DateTime.now().add(const Duration(days: 12));
    } else {
      subscriptionRenewsAt = null;
    }
    notifyListeners();
  }

  /// 모의 IAP — sandbox 미통과 환경에서 UI 흐름만 검증.
  Future<bool> mockPurchase({String plan = 'monthly'}) async {
    await Future.delayed(const Duration(milliseconds: 600));
    subscription = SubscriptionStatus.active;
    subscriptionRenewsAt = DateTime.now().add(
      Duration(days: plan == 'yearly' ? 365 : 30),
    );
    notifyListeners();
    return true;
  }

  /// 구독 해지 (만료 전까지 권한 유지).
  void mockCancel() {
    if (subscription == SubscriptionStatus.active ||
        subscription == SubscriptionStatus.trial) {
      subscription = SubscriptionStatus.cancelled;
      notifyListeners();
    }
  }

  // ─── Cloud Sync (실 백엔드 — api.hum-track.com) ────────────────────────
  // mock 메서드는 호환 wrapper 로 유지(아래 mockUploadToCloud 등) — 실 흐름은
  // uploadProject() / downloadProject() / deleteFromCloud() 로 라우팅.
  /// 클라우드 사용량 한도(기본 표시용). 실제 quota 는 백엔드 응답으로 갱신.
  static const double cloudQuotaBytes = 5 * 1024 * 1024 * 1024;
  /// 클라우드 작업물 목록 — refreshCloudData() 가 백엔드에서 채움.
  final List<CloudProjectMeta> cloudProjects = [];
  /// 사용량/quota — getUsage() 응답으로 갱신. fallback 은 cloudProjects 합.
  int _cloudUsedBytes = 0;
  int _cloudQuotaBytes = (cloudQuotaBytes).toInt();
  double get cloudUsageBytes => _cloudUsedBytes > 0
      ? _cloudUsedBytes.toDouble()
      : cloudProjects.fold<double>(0, (a, b) => a + b.sizeBytes);
  int get cloudQuotaBytesEffective => _cloudQuotaBytes;
  /// 마지막 sync 시도의 사용자 표시용 에러 (null = 정상).
  String? lastSyncError;
  /// 업로드/다운로드 진행률 — 키는 projectId, 값은 0..1.
  final Map<String, double> _syncProgress = {};
  double syncProgressFor(String projectId) => _syncProgress[projectId] ?? 0.0;
  void _setProgress(String projectId, double v) {
    _syncProgress[projectId] = v.clamp(0.0, 1.0);
    notifyListeners();
  }
  /// 자동 동기화 토글 — Documents/cloud_prefs.json 로 영속화.
  bool autoSyncEnabled = true;
  bool _cloudPrefsLoaded = false;

  /// LocalStorage 초기화 등 앱 부팅 시 1회 호출 — 자동 동기화 토글 로드.
  Future<void> loadCloudPrefs() async {
    if (_cloudPrefsLoaded) return;
    _cloudPrefsLoaded = true;
    try {
      final v = await LocalStorage.instance.readCloudPrefs();
      autoSyncEnabled = v['auto_sync'] as bool? ?? true;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setAutoSyncEnabled(bool on) async {
    if (on == autoSyncEnabled) return;
    autoSyncEnabled = on;
    notifyListeners();
    try {
      await LocalStorage.instance.writeCloudPrefs({'auto_sync': on});
    } catch (_) {}
  }

  /// 시안 ⑪/⑫ — Pro 결제 통과 직후 1회 표시할 환영 화면 플래그.
  bool pendingProWelcome = false;
  void markProWelcomeSeen() {
    if (!pendingProWelcome) return;
    pendingProWelcome = false;
    notifyListeners();
  }

  // ─── 실 백엔드 호출 ─────────────────────────────────────────────────────

  bool get _isCloudAuthenticated =>
      AuthService.instance.enabled && AuthService.instance.current.isSignedIn;

  /// 클라우드 탭 진입 시 호출 — 목록 + 사용량 동시 갱신.
  /// 인증 안 됐으면 skip (anonymous). 에러 시 stale 데이터 유지 + lastSyncError 기록.
  Future<void> refreshCloudData() async {
    if (!_isCloudAuthenticated) {
      lastSyncError = null;
      return;
    }
    try {
      final results = await Future.wait([
        CloudApi.instance.listProjects(),
        CloudApi.instance.getUsage(),
      ]);
      final list = results[0] as List<CloudProject>;
      final usage = results[1] as Usage;
      // 기존 로컬 onThisDevice 표시 보존: localStorage 의 프로젝트 id 와 일치하면 true.
      final localIds = (await LocalStorage.instance.listProjects())
          .map((m) => m.id)
          .toSet();
      cloudProjects
        ..clear()
        ..addAll(list.map((p) => CloudProjectMeta(
              id: p.projectId,
              title: p.title,
              uploadedAt: p.uploadedAt,
              lastModifiedAt: p.updatedAt,
              sizeBytes: p.sizeBytes,
              onThisDevice: localIds.contains(p.projectId),
              serverMeta: p.meta,
            )));
      _cloudUsedBytes = usage.usedBytes;
      _cloudQuotaBytes = usage.quotaBytes;
      lastSyncError = null;
      notifyListeners();
    } on UnauthorizedException catch (e) {
      lastSyncError = e.message;
      debugPrint('[cloud] refresh unauth: ${e.message}');
      notifyListeners();
    } on CloudApiException catch (e) {
      lastSyncError = e.message;
      debugPrint('[cloud] refresh failed: $e');
      notifyListeners();
    }
  }

  /// 로컬 프로젝트를 백엔드에 업로드 — 보컬 파일은 R2 PUT, 메타는 /projects upsert.
  ///
  /// 흐름:
  ///   1) ProjectMeta 조회 + 사전 quota_check
  ///   2) 각 보컬 파일 presign + R2 PUT (진행률 누적)
  ///   3) /projects upsert (expected_updated_at 으로 충돌 감지)
  ///   4) cloudProjects + usage 갱신
  ///
  /// 예외:
  ///   - UnauthorizedException — 로그인 필요
  ///   - QuotaExceededException — 용량 부족
  ///   - ConflictException — 다른 기기에서 변경됨
  ///   - NetworkException / CloudApiException — 기타
  Future<void> uploadProject(String projectId) async {
    if (!_isCloudAuthenticated) {
      throw UnauthorizedException('클라우드 업로드는 로그인이 필요해요');
    }

    // 1) 로컬 메타 + 보컬 파일 수집.
    final localList = await LocalStorage.instance.listProjects();
    final local = localList.firstWhere(
      (m) => m.id == projectId,
      orElse: () => throw CloudApiException('로컬 프로젝트 없음: $projectId'),
    );
    final vocalFiles = await _collectVocalFiles(projectId);
    final vocalBytes = vocalFiles.fold<int>(0, (a, f) {
      try {
        return a + f.lengthSync();
      } catch (_) {
        return a;
      }
    });
    final totalBytes = local.sizeBytes > 0 ? local.sizeBytes : vocalBytes;

    _setProgress(projectId, 0.0);

    // 2) 사전 quota check (선택적 — upsert 도 한 번 더 확인하지만 UX 친화).
    final qc = await CloudApi.instance.quotaCheck(totalBytes);
    if (!qc.allowed) {
      _syncProgress.remove(projectId);
      throw QuotaExceededException(used: qc.used, quota: qc.quota, deficit: qc.deficit);
    }

    // 3) 보컬 파일들 R2 PUT — 진행률은 각 파일 크기 비율로 누적.
    final uploadedFiles = <Map<String, dynamic>>[];
    int sentBytes = 0;
    for (final f in vocalFiles) {
      final bytes = await f.readAsBytes();
      final fileName = f.uri.pathSegments.last;
      final contentType = _guessContentType(fileName);
      final presign = await CloudApi.instance.presignUpload(
        projectId: projectId,
        fileName: fileName,
        contentType: contentType,
      );
      await CloudApi.instance.putToR2(
        presign: presign,
        bytes: bytes,
        onProgress: (frac) {
          final localProgress = sentBytes + (bytes.length * frac);
          _setProgress(projectId, totalBytes > 0 ? localProgress / totalBytes : 1.0);
        },
      );
      sentBytes += bytes.length;
      uploadedFiles.add({
        'file_name': fileName,
        'size_bytes': bytes.length,
        'content_type': contentType,
        'key': presign.key,
        'public_url': presign.publicUrl,
      });
    }

    // 4) 메타 + size_bytes upsert.
    final localMetaJson = await _loadLocalMetaJson(projectId);
    final upsertMeta = <String, dynamic>{
      ...?localMetaJson,
      'vocal_files': uploadedFiles,
      'app_version': 1,
    };
    final existing = cloudProjects.firstWhere(
      (c) => c.id == projectId,
      orElse: () => CloudProjectMeta(
        id: '',
        title: '',
        uploadedAt: DateTime.now(),
        lastModifiedAt: DateTime.now(),
        sizeBytes: 0,
        onThisDevice: true,
      ),
    );
    final result = await CloudApi.instance.upsertProject(
      projectId: projectId,
      title: local.title,
      meta: upsertMeta,
      sizeBytes: totalBytes,
      expectedUpdatedAt: existing.id.isEmpty ? null : existing.lastModifiedAt,
    );

    // 5) 상태 갱신.
    _cloudUsedBytes = result.usedBytes;
    _cloudQuotaBytes = result.quotaBytes;
    final now = DateTime.now();
    final idx = cloudProjects.indexWhere((c) => c.id == projectId);
    final updated = CloudProjectMeta(
      id: projectId,
      title: local.title,
      uploadedAt: idx >= 0 ? cloudProjects[idx].uploadedAt : now,
      lastModifiedAt: now,
      sizeBytes: totalBytes,
      onThisDevice: true,
      serverMeta: upsertMeta,
    );
    if (idx >= 0) {
      cloudProjects[idx] = updated;
    } else {
      cloudProjects.insert(0, updated);
    }
    _syncProgress.remove(projectId);
    lastSyncError = null;
    notifyListeners();
    debugPrint('[cloud] uploadProject ok: $projectId ($totalBytes B, vocal=$vocalBytes)');
  }

  /// 클라우드에서 프로젝트 다운로드. 백엔드의 `getProject` 응답 meta 안의
  /// `vocal_files[].public_url` 로 R2 GET. publicUrl 이 없으면 mock 으로 폴백
  /// (백엔드 presigned-GET endpoint 가 아직 없음 — 별도 task 권장).
  Future<void> downloadProject(String projectId) async {
    if (!_isCloudAuthenticated) {
      throw UnauthorizedException('클라우드 다운로드는 로그인이 필요해요');
    }
    _setProgress(projectId, 0.0);

    final p = await CloudApi.instance.getProject(projectId);
    final meta = p.meta ?? const <String, dynamic>{};
    final vocalFiles = (meta['vocal_files'] as List?) ?? const [];

    // 어떤 파일도 publicUrl 이 없으면 mock fallback — 백엔드 presigned-GET 필요.
    final hasUrls = vocalFiles.any((e) {
      if (e is! Map) return false;
      final u = e['public_url'];
      return u is String && u.isNotEmpty;
    });
    if (vocalFiles.isNotEmpty && !hasUrls) {
      debugPrint('[cloud] downloadProject: no public_url — backend presigned_get needed. fallback to mock.');
      await mockDownloadFromCloud(projectId);
      return;
    }

    // 1) 로컬 프로젝트 디렉터리 준비 + 보컬 파일 GET.
    final totalBytes = p.sizeBytes <= 0 ? 1 : p.sizeBytes;
    int gotBytes = 0;
    final localVocals = <Map<String, dynamic>>[];
    for (final entry in vocalFiles) {
      if (entry is! Map) continue;
      final url = entry['public_url'] as String?;
      final name = (entry['file_name'] ?? '') as String;
      final size = (entry['size_bytes'] as num?)?.toInt() ?? 0;
      if (url == null || url.isEmpty || name.isEmpty) continue;
      final bytes = await CloudApi.instance.getFromUrl(
        url,
        onProgress: (frac) {
          final localProgress = gotBytes + (size * frac);
          _setProgress(projectId, localProgress / totalBytes);
        },
      );
      gotBytes += size;
      final savedPath = await LocalStorage.instance.saveDownloadedVocal(
        projectId: projectId,
        fileName: name,
        bytes: bytes,
      );
      localVocals.add({'file_name': name, 'local_path': savedPath});
    }

    // 2) 로컬 meta.json 갱신.
    await LocalStorage.instance.writeDownloadedMeta(
      projectId: projectId,
      title: p.title,
      serverMeta: meta,
    );

    // 3) 카드 상태 갱신.
    final idx = cloudProjects.indexWhere((c) => c.id == projectId);
    if (idx >= 0) {
      cloudProjects[idx] = cloudProjects[idx].copyWith(onThisDevice: true, serverMeta: meta);
    }
    _syncProgress.remove(projectId);
    notifyListeners();
    debugPrint('[cloud] downloadProject ok: $projectId files=${localVocals.length}');
  }

  /// 클라우드에서만 삭제 — 로컬은 그대로 둠.
  /// UI 카피: "내 기기 작업물은 그대로 남아요" 와 일치.
  Future<void> deleteFromCloud(String projectId) async {
    if (!_isCloudAuthenticated) {
      throw UnauthorizedException('로그인이 필요해요');
    }
    await CloudApi.instance.deleteProject(projectId);
    cloudProjects.removeWhere((c) => c.id == projectId);
    // 사용량은 다음 getUsage 에서 정확히 갱신 — 우선 로컬 추정으로 줄임.
    try {
      final usage = await CloudApi.instance.getUsage();
      _cloudUsedBytes = usage.usedBytes;
      _cloudQuotaBytes = usage.quotaBytes;
    } catch (_) {/* best-effort */}
    notifyListeners();
  }

  /// 로컬 + 클라우드 둘 다 삭제. 사용자가 명시 선택 시.
  Future<void> deleteEverywhere(String projectId) async {
    try {
      await deleteFromCloud(projectId);
    } on CloudApiException catch (e) {
      debugPrint('[cloud] deleteEverywhere: cloud delete failed (계속): $e');
    }
    await LocalStorage.instance.deleteProject(projectId);
    notifyListeners();
  }

  // ── 내부 유틸 ───────────────────────────────────────────────────────────
  Future<List<File>> _collectVocalFiles(String projectId) async {
    final docs = await getApplicationDocumentsDirectory();
    final vocalsDir = Directory('${docs.path}/projects/$projectId/vocals');
    if (!vocalsDir.existsSync()) return const [];
    return vocalsDir
        .listSync()
        .whereType<File>()
        .toList();
  }

  Future<Map<String, dynamic>?> _loadLocalMetaJson(String projectId) async {
    final docs = await getApplicationDocumentsDirectory();
    final f = File('${docs.path}/projects/$projectId/meta.json');
    if (!f.existsSync()) return null;
    try {
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  String _guessContentType(String fileName) {
    final n = fileName.toLowerCase();
    if (n.endsWith('.caf')) return 'audio/x-caf';
    if (n.endsWith('.ogg')) return 'audio/ogg';
    if (n.endsWith('.opus')) return 'audio/opus';
    if (n.endsWith('.wav')) return 'audio/wav';
    if (n.endsWith('.m4a')) return 'audio/mp4';
    return 'application/octet-stream';
  }

  // ─── Mock 호환 wrapper (기존 호출처 보존) ────────────────────────────────
  /// @deprecated — uploadProject() 로 라우팅. 백엔드 호출 실패 시 mock 폴백.
  Future<void> mockUploadToCloud(String projectId, String title, {int sizeBytes = 8 * 1024 * 1024}) async {
    if (_isCloudAuthenticated) {
      try {
        await uploadProject(projectId);
        return;
      } catch (e) {
        debugPrint('[cloud] mockUploadToCloud: uploadProject 실패 → mock 폴백: $e');
        rethrow;
      }
    }
    // 익명 fallback (개발자 모드 / 비로그인 데모) — 기존 mock 동작.
    await Future.delayed(const Duration(milliseconds: 600));
    final i = cloudProjects.indexWhere((c) => c.id == projectId);
    if (i >= 0) {
      cloudProjects[i] = cloudProjects[i].copyWith(lastModifiedAt: DateTime.now(), onThisDevice: true);
    } else {
      cloudProjects.add(CloudProjectMeta(
        id: projectId,
        title: title,
        uploadedAt: DateTime.now(),
        lastModifiedAt: DateTime.now(),
        sizeBytes: sizeBytes,
        onThisDevice: true,
      ));
    }
    notifyListeners();
  }

  /// @deprecated — downloadProject() 로 라우팅. 폴백은 onThisDevice 만 토글.
  Future<void> mockDownloadFromCloud(String cloudId) async {
    if (_isCloudAuthenticated) {
      try {
        await downloadProject(cloudId);
        return;
      } catch (e) {
        debugPrint('[cloud] mockDownloadFromCloud: downloadProject 실패: $e');
        // 폴백 — 카드만 marked
      }
    }
    await Future.delayed(const Duration(milliseconds: 600));
    final i = cloudProjects.indexWhere((c) => c.id == cloudId);
    if (i >= 0) {
      cloudProjects[i] = cloudProjects[i].copyWith(onThisDevice: true);
      notifyListeners();
    }
  }

  /// @deprecated — deleteFromCloud() 로 라우팅. 익명이면 in-memory 만 제거.
  void mockDeleteFromCloud(String cloudId) {
    if (_isCloudAuthenticated) {
      // 비동기 호출이지만 UI 가 await 안 함 — fire-and-forget.
      deleteFromCloud(cloudId).catchError((e) {
        debugPrint('[cloud] mockDeleteFromCloud: 백엔드 삭제 실패: $e');
      });
      return;
    }
    cloudProjects.removeWhere((c) => c.id == cloudId);
    notifyListeners();
  }

  /// 데모/스타터 데이터 — 시안 ④ 의 4개 카드 (개발자 모드에서만 사용).
  void devSeedCloudMock() {
    cloudProjects
      ..clear()
      ..addAll([
        CloudProjectMeta(
          id: 'cm_1',
          title: '봄밤의 산책',
          uploadedAt: DateTime.now().subtract(const Duration(minutes: 2)),
          lastModifiedAt: DateTime.now().subtract(const Duration(minutes: 2)),
          sizeBytes: 11 * 1024 * 1024,
          onThisDevice: true,
        ),
        CloudProjectMeta(
          id: 'cm_2',
          title: '아이패드에서 작업한 곡',
          uploadedAt: DateTime.now().subtract(const Duration(days: 4)),
          lastModifiedAt: DateTime.now().subtract(const Duration(days: 4)),
          sizeBytes: (24.8 * 1024 * 1024).round(),
          onThisDevice: false,
        ),
        CloudProjectMeta(
          id: 'cm_3',
          title: 'EDM 데모 v3',
          uploadedAt: DateTime.now().subtract(const Duration(days: 7)),
          lastModifiedAt: DateTime.now().subtract(const Duration(days: 7)),
          sizeBytes: (42.1 * 1024 * 1024).round(),
          onThisDevice: false,
        ),
        CloudProjectMeta(
          id: 'cm_4',
          title: '새벽 4시의 발라드',
          uploadedAt: DateTime.now().subtract(const Duration(days: 12)),
          lastModifiedAt: DateTime.now().subtract(const Duration(days: 12)),
          sizeBytes: (18.2 * 1024 * 1024).round(),
          onThisDevice: true,
        ),
      ]);
    notifyListeners();
  }

  void devClearCloudMock() {
    cloudProjects.clear();
    notifyListeners();
  }

  String title = 'My Song';

  void setTitle(String v) {
    final s = v.trim();
    if (s.isEmpty || s == title) return;
    title = s;
    notifyListeners();
  }

  /// 모든 트랙(카테고리당 N개 가능). 순서는 사이드바 표시 순서.
  /// 처음에는 4개 카테고리 각 1개로 시작.
  final List<TrackData> tracks = [];
  int _trackSeq = 0; // 트랙 id 발급기
  int? activeTrackId; // 현재 편집/녹음 대상 트랙
  bool busy = false;
  String? error;
  int editEpoch = 0; // 오디오 출력에 영향 주는 편집마다 증가(재렌더 트리거)
  int _chunkSeq = 0; // 청크 ID 발급기
  // 프로젝트 단일 BPM — quantize 그리드 + 메트로놈 클릭 양쪽에서 사용.
  int bpm = 90;
  // 메트로놈 클릭 on/off — 트랜스포트/메트로놈 시트 양쪽에서 토글.
  bool metroOn = false;

  // ─── 프로젝트 앵커 (기준 트랙으로 키·그루브 잠금) ─────────────────────────
  // 그루브 앵커 = 노트 있는 첫 트랙(드럼 포함) → 전 노트 트랙이 이 phase 공유.
  // 키 앵커 = 키가 잡힌 첫 멜로딕 트랙 → projectKey 로 전 트랙 적극 보정.
  int? grooveAnchorTrackId;
  int? keyAnchorTrackId;
  String? projectKeyTonic;
  String? projectKeyScale;
  bool anchorLocked = false; // 키 잠금 완료(사용자 확인) 여부

  /// 노트가 있는 첫 트랙(그루브 앵커 후보).
  TrackData? firstTrackWithNotes() {
    for (final t in tracks) {
      if (t.notes.isNotEmpty) return t;
    }
    return null;
  }

  /// 키가 감지된 첫 멜로딕(비드럼·비보컬) 트랙(키 앵커 후보).
  TrackData? firstTrackWithKey() {
    for (final t in tracks) {
      if (t.role == TrackRole.drum || t.isVocal) continue;
      if (t.analysis?.detectedKey?.tonic != null) return t;
    }
    return null;
  }

  /// 아직 앵커가 안 잡혔고, 잠글 만한 녹음 트랙이 있으면 true(전환 시점에 체크).
  bool get needsAnchorLock => !anchorLocked && firstTrackWithNotes() != null;

  void setMetroOn(bool on) {
    if (on == metroOn) return;
    metroOn = on;
    notifyListeners();
  }

  void setBpm(int v) {
    final next = v.clamp(40, 240);
    if (next == bpm) return;
    bpm = next;
    _audioChanged();
  }

  void toggleTrackQuantize(int trackId, bool on) {
    final t = trackById(trackId);
    if (t == null) return;
    t.quantizeEnabled = on;
    _audioChanged();
  }

  void setTrackQuantize(int trackId, {int? grid, double? strength}) {
    final t = trackById(trackId);
    if (t == null) return;
    if (grid != null) t.quantizeGrid = grid;
    if (strength != null) t.quantizeStrength = strength.clamp(0.0, 1.0);
    _audioChanged();
  }

  /// quantize 적용된 트랙 노트 — t.effectiveRenderNotes 를 wrap.
  /// 각 노트의 start 를 그리드 cellSec 의 가장 가까운 라인으로 strength 만큼 당김.
  /// 토글 off 면 원본 그대로.
  List<Note> effectiveRenderNotesFor(TrackData t) {
    final isDrum = t.role == TrackRole.drum;
    // 박자 보정(start·end 를 그리드에 스냅 → 위치+길이 이동). 에디터 표시와 동일 경로.
    List<Note> quantized = quantizeNotes(t, t.effectiveRenderNotes);
    // 드럼은 강약 없이 일관된 볼륨 — 렌더 노트 velocity 를 상수로 통일(비파괴).
    if (isDrum) {
      quantized = quantized.map((n) {
        if (n.velocity == kDrumFlatVelocity) return n;
        final clone = Note.fromJson(n.toJson())..chunkId = n.chunkId;
        clone.velocity = kDrumFlatVelocity;
        return clone;
      }).toList();
    }
    // quantize 이후(코드 onset 이 그리드에 정렬된 뒤) 기타 스트럼 + 링아웃 적용.
    // 기타(25/27) 아니면 그대로 통과.
    return applyGuitarStrum(quantized, program: t.program, bpm: bpm);
  }

  /// 박자 보정 — 노트 **onset(start) 만** 그리드에 스냅하고 원본 duration 은 보존.
  /// DAW 표준 동작("Start only" quantize). 길이까지 그리드에 맞추는 옵션은 별도.
  /// strength 로 블렌드. 렌더(재생/내보내기)와 에디터 표시가 같은 결과를 보도록 단일 경로로 사용.
  ///
  /// 이전 구현은 start·end 를 독립적으로 스냅 + end 가 start 와 같은 셀로 붕괴하면
  /// 1셀 길이로 강제 늘리는 가드를 가졌는데, 거친 그리드(예: BPM 90 의 1/4 = 0.667s) +
  /// 짧은 노트(0.3s) 조합에서 모든 노트가 1셀로 강제 늘어나 인접 노트들과 겹치고
  /// 시각적으로 몰리는 결함이 있었음.
  List<Note> quantizeNotes(TrackData t, List<Note> base) {
    if (!t.quantizeEnabled || t.quantizeGrid <= 0 || base.isEmpty) return base;
    final cellSec = (60.0 / bpm) * 4 / t.quantizeGrid;
    if (cellSec <= 0) return base;
    final phase = _groovePhase(cellSec, base);
    final str = t.quantizeStrength;
    return base.map((n) {
      final sStart = ((n.start - phase) / cellSec).round() * cellSec + phase;
      final newStart = n.start + (sStart - n.start) * str;
      final origDur = n.end - n.start;
      final newEnd = newStart + origDur;
      if ((newStart - n.start).abs() < 1e-4) return n;
      final clone = Note.fromJson(n.toJson())
        ..start = newStart
        ..end = newEnd
        ..chunkId = n.chunkId;
      clone.duration = origDur;
      return clone;
    }).toList();
  }

  /// 그루브 phase — 앵커 잠금이면 그루브 앵커 트랙에서 1회 추정해 전 트랙 공유,
  /// 아니면 트랙 자체에서. 앵커 그루브 지터가 과도하면 메트로놈 정박(0)으로 폴백.
  double _groovePhase(double cellSec, List<Note> trackBase) {
    List<Note> src = trackBase;
    final anchor = grooveAnchorTrackId == null ? null : trackById(grooveAnchorTrackId!);
    if (anchor != null && anchor.notes.isNotEmpty) src = anchor.effectiveRenderNotes;
    if (src.isEmpty) return 0;
    final phase = estimateGridPhase(src, cellSec);
    final jit = src
            .map((n) {
              final r = (n.start - phase) % cellSec;
              return math.min(r.abs(), (cellSec - r).abs());
            })
            .fold<double>(0, (a, b) => a + b) /
        src.length;
    return jit > cellSec / 2 ? 0.0 : phase; // garbage-in 가드
  }


  // ─── 시작점 정렬(박자 보정 v1) ──────────────────────────────────────────
  // 새 녹음을 커밋할 때 첫 유의미 노트를 timeline 0 에 맞춤(리딩 무음/반응지연 트림).
  // 비파괴적: 노트는 보존하고 Chunk.inPoint 만 lead 로 세팅 →
  //   effectiveStart = note.start - inPoint + timelineStart = 0.
  // inPoint 앞쪽의 짧은 노이즈 노트는 effectiveRenderNotes 클립이 자동 제거.
  static const double _kMinAlignNoteSec = 0.06; // 숨소리/노이즈 제외 최소 노트 길이
  static const double _kVocalOnsetRatio = 0.15; // 최댓 peak 대비 온셋 임계(스케일 무관)

  /// 멜로딕/드럼 — duration 임계를 넘는 첫 노트의 start. 없으면 0(정렬 미적용).
  double _firstMeaningfulNoteStart(List<Note> notes, double span) {
    double best = double.infinity;
    for (final n in notes) {
      if (n.duration < _kMinAlignNoteSec) continue;
      if (n.start < best) best = n.start;
    }
    if (!best.isFinite || best <= 0) return 0.0;
    return span > 0 ? math.min(best, span) : best;
  }

  /// 보컬 — peaks 의 최댓값 대비 비율을 처음 넘는 인덱스의 시간. 없으면 0.
  /// peaks 값 범위가 백엔드(SoundLab)에 따라 달라질 수 있어 절대 임계 대신 상대 임계 사용.
  double _firstMeaningfulVocalStart(List<double> peaks, double duration) {
    if (peaks.isEmpty || duration <= 0) return 0.0;
    double maxPeak = 0.0;
    for (final p in peaks) {
      if (p > maxPeak) maxPeak = p;
    }
    if (maxPeak <= 0) return 0.0;
    final thresh = maxPeak * _kVocalOnsetRatio;
    for (int i = 0; i < peaks.length; i++) {
      if (peaks[i] > thresh) return (i / peaks.length) * duration;
    }
    return 0.0;
  }

  /// 녹음 종료 후 사용자가 "사용/삭제"를 결정할 때까지의 임시 결과(트랙 미반영).
  /// 활성 트랙의 다이얼로그(타임라인 레인 오버레이)로 표시된다.
  PendingRecording? pendingRecording;

  void _seedDefaultTracks() {
    for (final r in TrackRole.values) {
      tracks.add(TrackData(++_trackSeq, r));
    }
    activeTrackId = tracks.first.id;
  }

  // ─── 트랙 조회 ─────────────────────────────────────────────────────────
  TrackData get active =>
      tracks.firstWhere((t) => t.id == activeTrackId, orElse: () => tracks.first);

  TrackRole get activeRole => active.role;

  bool get hasAnyRecording => tracks.any((t) => t.hasRecording);

  /// 카테고리(role)에 속한 모든 트랙(순서 보존).
  Iterable<TrackData> tracksByRole(TrackRole r) => tracks.where((t) => t.role == r);

  /// 카테고리의 첫 트랙(없으면 null).
  TrackData? firstByRole(TrackRole r) {
    for (final t in tracks) {
      if (t.role == r) return t;
    }
    return null;
  }

  TrackData? trackById(int id) {
    for (final t in tracks) {
      if (t.id == id) return t;
    }
    return null;
  }

  void _audioChanged() {
    editEpoch++;
    _recomputeBassPlacement();
    notifyListeners();
  }

  /// 베이스 트랙들의 저음역 배치 옥타브 오프셋을 재계산해 캐시한다.
  /// 멜로디(keys) 최저음은 크로스-트랙 정보라 게터에서 못 보므로 여기서 한 번 계산해
  /// TrackData.bassOctaveShift 에 저장 → renderNotes 게터가 그 값만 적용(표시=소리 일치).
  /// 순수 계산만 — notifyListeners 호출 안 함(재진입 방지).
  void _recomputeBassPlacement() {
    final melodyLow = _melodyLowPitch();
    for (final t in tracks) {
      if (t.role != TrackRole.bass) continue;
      t.bassOctaveShift = (t.bassPlacement && t.notes.isNotEmpty)
          ? bestBassOctaveShift(t.notes, melodyLowPitch: melodyLow)
          : 0;
    }
  }

  /// keys 역할 트랙들의 pitched 최저음(베이스 분리 기준). 없으면 null.
  int? _melodyLowPitch() {
    int? low;
    for (final t in tracks) {
      if (t.role != TrackRole.keys) continue;
      for (final n in t.notes) {
        if (n.kind != 'pitched') continue;
        if (low == null || n.pitch < low) low = n.pitch;
      }
    }
    return low;
  }

  /// 미리듣기(pending) 재생용 노트 — 커밋 후 렌더와 동일하게 변환해 들려준다.
  /// 베이스(배치 on)면 저음역 옥타브 이동을 적용(키 보정은 이미 p.notes 에 반영됨).
  /// 그 외 역할은 p.notes 그대로(코드 모드는 커밋된 트랙 토글이라 미리듣기엔 미적용).
  List<Note> pendingRenderNotes(PendingRecording p) {
    final t = trackById(p.trackId);
    if (t != null &&
        t.role == TrackRole.bass &&
        t.bassPlacement &&
        p.notes.isNotEmpty) {
      final shift = bestBassOctaveShift(p.notes, melodyLowPitch: _melodyLowPitch());
      return applyOctaveShift(p.notes, shift);
    }
    return p.notes;
  }

  // ─── 활성 트랙 ──────────────────────────────────────────────────────────
  // 사용자가 명시적으로 사이드바 라벨을 탭해 트랙을 "선택"했는지 — 컨텍스트 액션 바
  // 매트릭스에서 "트랙 선택" 상태(재녹음/코드/뮤트/볼륨/삭제) 분기에 사용. 초기 시드
  // 로 정해진 activeTrackId 만으로는 "선택" 상태로 보지 않는다.
  bool trackSelected = false;

  void setActiveTrack(int trackId) {
    if (trackById(trackId) == null) return;
    activeTrackId = trackId;
    // 사이드바 탭으로 활성화 = 트랙 선택 상태로 간주. 노트/청크 선택은 해제.
    trackSelected = true;
    selectedNote = null;
    selectedChunk = null;
    notifyListeners();
  }

  /// 컨텍스트 액션 바 등에서 명시적으로 선택을 모두 해제(미선택 상태로).
  void clearSelection() {
    trackSelected = false;
    selectedNote = null;
    selectedChunk = null;
    notifyListeners();
  }

  /// 호환용 — 카테고리 선택 시 그 카테고리의 첫 트랙을 active 로.
  /// 멀티트랙 UI(#21~)가 들어오면 setActiveTrack(id) 로 대체될 예정.
  void setActiveRole(TrackRole r) {
    final t = firstByRole(r);
    if (t == null) return;
    activeTrackId = t.id;
    notifyListeners();
  }

  // ─── 트랙 추가/삭제 ───────────────────────────────────────────────────
  /// 새 트랙 추가 → 추가된 TrackData 반환. UI 는 아직 호출 안 함(#27 예정).
  TrackData addTrack(TrackRole role, {int? program}) {
    final t = TrackData(++_trackSeq, role, program: program);
    // 앵커 잠금 후 추가되는 노트 트랙은 박자 보정 on(공유 그루브에 맞물림).
    if (anchorLocked && !t.isVocal) t.quantizeEnabled = true;
    tracks.add(t);
    _audioChanged();
    return t;
  }

  /// 트랙 삭제. 활성 트랙이면 활성을 같은 카테고리의 다른 트랙(없으면 첫 트랙)으로.
  void removeTrack(int trackId) {
    final i = tracks.indexWhere((t) => t.id == trackId);
    if (i < 0) return;
    final removed = tracks.removeAt(i);
    if (activeTrackId == trackId) {
      final fallback = firstByRole(removed.role) ?? (tracks.isNotEmpty ? tracks.first : null);
      activeTrackId = fallback?.id;
    }
    // 앵커 유실 승계 — 가공된(이미 앵커 키/그루브로 보정된) 다음 트랙이 기준을 이어받음.
    // projectKey 는 유지(승계 트랙이 그 키로 보정돼 있어 자기일관).
    if (grooveAnchorTrackId == trackId) grooveAnchorTrackId = firstTrackWithNotes()?.id;
    if (keyAnchorTrackId == trackId) keyAnchorTrackId = firstTrackWithKey()?.id;
    if (firstTrackWithNotes() == null) {
      // 녹음 트랙이 모두 사라지면 앵커 완전 리셋.
      anchorLocked = false;
      projectKeyTonic = projectKeyScale = null;
      grooveAnchorTrackId = keyAnchorTrackId = null;
    }
    _audioChanged();
  }

  // ─── 드럼 재라벨링 (백엔드 호출 없음) ────────────────────────────────────
  // 백엔드는 모든 입력을 멜로딕으로 분석(auto-percussive fallback 제거됨).
  // 사용자가 드럼 슬롯에 녹음하면 = 명시적 드럼 의도 → 노트를 GM 드럼 채널(9)에서
  // 의미 있는 키트 매핑(36 Kick / 38 Snare / 42 HiHat)으로 변환한다.
  //
  // 매핑 우선순위:
  //   1) 백엔드 스펙트럼 분류(note.drum, drums.py) — 음색으로 Kick/Snare/HiHat 판별.
  //   2) 백엔드 값이 없는 노트만 pitch 폴백:
  //        - 트랙 평균보다 5 반음 이상 낮음 → Kick(36)
  //        - 트랙 평균보다 5 반음 이상 높음 → HiHat(42)
  //        - 그 외 → Snare(38)
  //
  // `pitchOriginal` 은 백엔드에서 받은 원래 멜로디 pitch — 보존되어 있어
  // `restoreFromDrums()` 로 되돌릴 때 손실 없이 복원된다. `note.drum` 도
  // 보존되므로 재호출 시 동일 결과(idempotent).
  void _relabelAsDrums(List<Note> notes) {
    if (notes.isEmpty) return;
    // 이미 percussive 로 재라벨된 노트는 pitch 가 36/38/42 의 좁은 범위라
    // pitch 폴백이 무너짐 → idempotent 가드 (백엔드 분류는 note.drum 에 보존됨).
    if (notes.every((n) => n.kind == 'percussive')) return;
    // pitch 폴백용 평균(원본 pitch 기준). 백엔드 분류가 있으면 사용 안 함.
    final orig = notes.map((n) => n.pitchOriginal != 0 ? n.pitchOriginal : n.pitch).toList();
    final avg = orig.reduce((a, b) => a + b) / orig.length;
    for (int i = 0; i < notes.length; i++) {
      final n = notes[i];
      if (n.pitchOriginal == 0) n.pitchOriginal = n.pitch;
      final int drumPitch;
      if (n.drum != null) {
        drumPitch = n.drum!; // 백엔드 스펙트럼 분류 우선
      } else {
        final diff = orig[i] - avg; // 폴백: pitch ±5 반음
        drumPitch = diff <= -5 ? 36 : (diff >= 5 ? 42 : 38);
      }
      n.pitch = drumPitch;
      n.kind = 'percussive';
    }
  }

  /// 활성 트랙의 노트를 드럼으로 재라벨(수동 트리거). 일반적으로
  /// `recordAnalyzed` 가 자동으로 처리하지만, 이미 멜로딕으로 분석된 트랙을
  /// 드럼으로 강제 전환하고 싶을 때 호출.
  void convertActiveToDrums() {
    _relabelAsDrums(active.notes);
    _audioChanged();
  }

  /// 드럼 재라벨을 되돌려 멜로딕 pitch 복원(`pitchOriginal` → `pitch`).
  /// 드럼 슬롯의 노트라도 멜로딕으로 다시 듣고 싶을 때.
  void restoreActiveFromDrums() {
    for (final n in active.notes) {
      if (n.kind == 'percussive' && n.pitchOriginal != 0) {
        n.pitch = n.pitchOriginal;
        n.kind = 'pitched';
      }
    }
    _audioChanged();
  }

  /// 카테고리 토글(호환) — 그 카테고리의 모든 트랙을 일괄 토글.
  /// 멀티트랙 UI 가 들어오면 개별 트랙 토글(toggleTrackEnabled)로 대체될 예정.
  void toggleEnabled(TrackRole r) {
    final list = tracksByRole(r).toList();
    if (list.isEmpty) return;
    // 하나라도 enabled 면 모두 disabled, 전부 disabled 면 모두 enabled.
    final anyOn = list.any((t) => t.enabled);
    for (final t in list) {
      t.enabled = !anyOn;
    }
    _audioChanged();
  }

  void toggleTrackEnabled(int trackId) {
    final t = trackById(trackId);
    if (t == null) return;
    t.enabled = !t.enabled;
    _audioChanged();
  }

  void toggleTrackLooping(int trackId) {
    final t = trackById(trackId);
    if (t == null) return;
    t.looping = !t.looping;
    _audioChanged();
  }

  /// non-loop 트랙들의 가장 늦은 컨텐츠 끝 — looping 트랙이 여기까지 반복.
  double get projectEnd => _projectEnd;
  double get _projectEnd {
    double m = 0;
    for (final t in tracks) {
      if (t.looping) continue;
      for (final c in t.chunks) {
        if (c.timelineEnd > m) m = c.timelineEnd;
      }
    }
    return m;
  }

  /// notes 를 [period] 주기로 targetEnd 까지 반복해서 펼친다.
  /// period 는 청크 timelineEnd 의 최대값(가시 영역 끝) — 노트 끝이 아니라 청크 경계.
  List<Note> _loopNotesUntil(List<Note> notes, double targetEnd, double period) {
    if (notes.isEmpty || targetEnd <= 0 || period <= 0.01) return notes;
    final out = <Note>[];
    double offset = 0;
    while (offset < targetEnd) {
      for (final n in notes) {
        if (n.start + offset >= targetEnd) continue;
        final clone = Note.fromJson(n.toJson())
          ..start = n.start + offset
          ..end = math.min(n.end + offset, targetEnd)
          ..chunkId = n.chunkId;
        clone.duration = clone.end - clone.start;
        out.add(clone);
      }
      offset += period;
    }
    return out;
  }

  void newProject() {
    projectId = 'p_${DateTime.now().millisecondsSinceEpoch}';
    title = 'My Song';
    tracks.clear();
    _trackSeq = 0;
    _chunkSeq = 0;
    selectedNote = null;
    selectedChunk = null;
    trackSelected = false;
    pendingRecording = null;
    _seedDefaultTracks();
    error = null;
    notifyListeners();
  }

  /// LocalStorage.loadProject 가 호출 — 트랙/시퀀스/메타를 한 번에 교체.
  void adoptLoaded({
    required String projectId,
    required String title,
    required int bpm,
    required List<TrackData> tracks,
    required int trackSeq,
    required int chunkSeq,
  }) {
    this.projectId = projectId;
    this.title = title;
    this.bpm = bpm;
    this.tracks
      ..clear()
      ..addAll(tracks);
    _trackSeq = trackSeq;
    _chunkSeq = chunkSeq;
    selectedNote = null;
    selectedChunk = null;
    trackSelected = false;
    pendingRecording = null;
    error = null;
    if (this.tracks.isEmpty) {
      _seedDefaultTracks();
    } else {
      activeTrackId = this.tracks.first.id;
    }
    notifyListeners();
  }

  Future<bool> health() => _api.health();

  /// 녹음 WAV → 분석 → 지정 트랙(또는 카테고리의 첫 트랙, 또는 active)에 반영.
  /// 우선순위: trackId > role(의 첫 트랙) > active.
  Future<void> recordAnalyzed(String wavPath, {TrackRole? role, int? trackId}) async {
    TrackData? t;
    if (trackId != null) t = trackById(trackId);
    t ??= role != null ? firstByRole(role) : null;
    t ??= active;
    t.wavPath = wavPath;
    busy = true;
    error = null;
    notifyListeners();

    // 보컬: 악기 변환(분석) 없이 목소리 그대로 — 가벼운 정리만.
    if (t.isVocal) {
      try {
        final v = await _api.processVocal(wavPath);
        final dir = await Directory.systemTemp.createTemp('vocal_');
        final f = File('${dir.path}/vocal.wav');
        await f.writeAsBytes(v.wav, flush: true);
        t.vocalWavPath = f.path;
        t.vocalPeaks = v.peaks;
        t.vocalDuration = v.duration;
        t.notes = []; // 보컬은 노트 없음
        t.analysis = null;
        final lead = _firstMeaningfulVocalStart(v.peaks, v.duration);
        debugPrint('[align] ${t.role.label}(vocal) lead=${lead.toStringAsFixed(2)}s');
        t.chunks
          ..clear()
          ..add(Chunk(
            id: ++_chunkSeq,
            timelineStart: 0,
            inPoint: lead,
            outPoint: v.duration,
            originalLength: v.duration,
            vocalWavPath: f.path,
            vocalPeaks: v.peaks,
            vocalDuration: v.duration,
          ));
        debugPrint('[vocal] cleaned dur=${v.duration.toStringAsFixed(1)}s peaks=${v.peaks.length}');
      } catch (e) {
        error = '보컬 처리 실패: $e';
        debugPrint('[vocal] FAILED: $e');
      } finally {
        busy = false;
        _audioChanged();
      }
      return;
    }

    try {
      _inheritAnchorIfLocked(t); // 앵커 잠금 후면 프로젝트 키 + 적극 보정 상속
      final sz = await File(wavPath).length();
      final sw = Stopwatch()..start();
      final res = await _api.analyze(wavPath, t.options);
      sw.stop();
      AnalyticsService.instance.analyzeCompleted(
        role: t.role.name,
        durationMs: sw.elapsedMilliseconds,
        noteCount: res.notes.length,
      );
      t.analysis = res;
      t.notes = res.notes;
      final cid = ++_chunkSeq; // 이번 녹음 = 하나의 청크
      for (final n in t.notes) {
        n.chunkId = cid;
      }
      final span = res.durationSec > 0
          ? res.durationSec
          : (res.notes.isEmpty ? 0.0 : res.notes.map((n) => n.end).reduce(math.max));
      final lead = _firstMeaningfulNoteStart(t.notes, span);
      debugPrint('[align] ${t.role.label} lead=${lead.toStringAsFixed(2)}s');
      t.chunks
        ..clear()
        ..add(Chunk(
          id: cid,
          timelineStart: 0,
          inPoint: lead,
          outPoint: span,
          originalLength: span,
        ));
      // 드럼 트랙: 백엔드는 항상 멜로딕으로 분석(auto-percussive 제거됨).
      // 사용자가 드럼 슬롯에 녹음 = 명시적 드럼 의도 → pitch 기반 휴리스틱으로
      // GM 드럼 노트(36/38/42) + kind='percussive' 재라벨.
      if (t.role == TrackRole.drum) {
        _relabelAsDrums(t.notes);
      }
      final pitched = res.notes.where((n) => n.kind == 'pitched').length;
      debugPrint('[analyze] ${t.role.label} wav=${(sz / 1024).toStringAsFixed(0)}KB '
          'dur=${res.durationSec.toStringAsFixed(1)}s notes=${res.notes.length}(pitched=$pitched) '
          'key=${res.detectedKey?.tonic}${res.detectedKey?.scale} assisted=${res.assistAppliedCount}');
    } catch (e) {
      error = '분석 실패: $e';
      debugPrint('[analyze] FAILED: $e');
    } finally {
      busy = false;
      _audioChanged();
    }
  }

  // ─── Pending Recording (사용/삭제 다이얼로그 흐름, task #26) ────────────
  // 녹음 종료 → analyzeForPending 으로 분석만 수행하고 트랙엔 commit 하지 않음.
  // 사용자가 트랙 안 다이얼로그에서 "사용"을 누르면 commitPendingRecording 으로
  // 실제 트랙에 반영. "삭제"면 discardPendingRecording 으로 폐기.

  /// 녹음 종료 후 호출. /analyze (or processVocal) 결과를 pending 으로 저장.
  /// 트랙에는 commit 하지 않음 — 다이얼로그 사용자 승인 대기.
  Future<void> analyzeForPending(String wavPath, int trackId) async {
    final t = trackById(trackId);
    if (t == null) return;
    // 이전 pending 이 있으면 폐기(다른 트랙 녹음으로 진입한 경우 등).
    if (pendingRecording != null && pendingRecording!.trackId != trackId) {
      _deletePendingWav(pendingRecording!);
    }
    pendingRecording = PendingRecording(
      trackId: trackId,
      role: t.role,
      wavPath: wavPath,
      pitchAssist: t.options.pitchAssistant,
    );
    busy = true;
    error = null;
    notifyListeners();

    if (t.isVocal) {
      try {
        final v = await _api.processVocal(wavPath);
        final dir = await Directory.systemTemp.createTemp('vocal_');
        final f = File('${dir.path}/vocal.wav');
        await f.writeAsBytes(v.wav, flush: true);
        pendingRecording!
          ..vocalWavPath = f.path
          ..vocalPeaks = v.peaks
          ..vocalDuration = v.duration;
      } catch (e) {
        error = '보컬 처리 실패: $e';
        debugPrint('[vocal-pending] FAILED: $e');
        pendingRecording = null;
      } finally {
        busy = false;
        notifyListeners();
      }
      return;
    }

    try {
      _inheritAnchorIfLocked(t); // 앵커 잠금 후면 프로젝트 키 + 적극 보정 상속
      // pending 의 어시스트 옵션으로 분석(트랙 옵션과 일시 분리).
      final opt = AnalyzeOptions(
        autoKey: t.options.autoKey,
        pitchAssistant: pendingRecording!.pitchAssist,
        keyTonic: t.options.keyTonic,
        scale: t.options.scale,
        asDrums: t.role == TrackRole.drum,
        assistAggressive: t.options.assistAggressive,
      );
      final sw = Stopwatch()..start();
      final res = await _api.analyze(wavPath, opt);
      sw.stop();
      AnalyticsService.instance.analyzeCompleted(
        role: t.role.name,
        durationMs: sw.elapsedMilliseconds,
        noteCount: res.notes.length,
      );
      pendingRecording!
        ..analysis = res
        ..notes = res.notes;
      // 드럼은 preview 와 commit 결과가 동일하도록 분석 직후 GM 드럼 매핑(36/38/42) 적용.
      if (t.role == TrackRole.drum) {
        _relabelAsDrums(pendingRecording!.notes);
      }
      final pitched = res.notes.where((n) => n.kind == 'pitched').length;
      debugPrint('[analyze-pending] ${t.role.label} dur=${res.durationSec.toStringAsFixed(1)}s '
          'notes=${res.notes.length}(pitched=$pitched) assisted=${res.assistAppliedCount}');
    } catch (e) {
      error = '분석 실패: $e';
      debugPrint('[analyze-pending] FAILED: $e');
      pendingRecording = null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// 다이얼로그의 어시스트 토글 변경 → 같은 notes 로 /assist 재계산.
  /// 트랙에는 commit 하지 않음 — pending 만 갱신.
  Future<void> togglePendingAssist(bool on) async {
    final p = pendingRecording;
    if (p == null) return;
    p.pitchAssist = on;
    if (p.notes.isEmpty) {
      notifyListeners();
      return;
    }
    final t = trackById(p.trackId);
    if (t == null) return;
    p.reassisting = true;
    notifyListeners();
    try {
      final opt = AnalyzeOptions(
        autoKey: t.options.autoKey,
        pitchAssistant: on,
        keyTonic: t.options.keyTonic,
        scale: t.options.scale,
      );
      final r = await _api.assist(p.notes, opt);
      p.notes = r.notes;
      final prev = p.analysis;
      p.analysis = AnalyzeResponse(
        notes: r.notes,
        detectedKey: r.detectedKey,
        keyCandidates: r.keyCandidates,
        assistAppliedCount: r.assistAppliedCount,
        durationSec: prev?.durationSec ?? 0,
        peaks: prev?.peaks ?? const [],
      );
    } catch (e) {
      error = '보정 실패: $e';
      debugPrint('[assist-pending] FAILED: $e');
    } finally {
      p.reassisting = false;
      notifyListeners();
    }
  }

  /// 사용자가 "사용" 탭 → pending 을 트랙에 실제 반영. 다이얼로그 닫힘.
  void commitPendingRecording() {
    final p = pendingRecording;
    if (p == null) return;
    final t = trackById(p.trackId);
    if (t == null) {
      pendingRecording = null;
      notifyListeners();
      return;
    }
    t.wavPath = p.wavPath;
    if (t.isVocal) {
      t.vocalWavPath = p.vocalWavPath;
      t.vocalPeaks = p.vocalPeaks;
      t.vocalDuration = p.vocalDuration;
      t.notes = [];
      t.analysis = null;
      final lead = _firstMeaningfulVocalStart(p.vocalPeaks, p.vocalDuration);
      debugPrint('[align] ${t.role.label}(vocal) lead=${lead.toStringAsFixed(2)}s');
      t.chunks
        ..clear()
        ..add(Chunk(
          id: ++_chunkSeq,
          timelineStart: 0,
          inPoint: lead,
          outPoint: p.vocalDuration,
          originalLength: p.vocalDuration,
          vocalWavPath: p.vocalWavPath,
          vocalPeaks: p.vocalPeaks,
          vocalDuration: p.vocalDuration,
        ));
    } else {
      t.analysis = p.analysis;
      t.notes = p.notes;
      final cid = ++_chunkSeq;
      for (final n in t.notes) {
        n.chunkId = cid;
      }
      final span = p.analysis?.durationSec ?? 0.0;
      final endSpan = span > 0
          ? span
          : (t.notes.isEmpty ? 0.0 : t.notes.map((n) => n.end).reduce(math.max));
      // 정렬: timing 은 드럼 재라벨과 무관하므로 노트 그대로에서 lead 계산.
      final lead = _firstMeaningfulNoteStart(t.notes, endSpan);
      debugPrint('[align] ${t.role.label} lead=${lead.toStringAsFixed(2)}s');
      t.chunks
        ..clear()
        ..add(Chunk(
          id: cid,
          timelineStart: 0,
          inPoint: lead,
          outPoint: endSpan,
          originalLength: endSpan,
        ));
      if (t.role == TrackRole.drum) {
        _relabelAsDrums(t.notes);
      }
      // 어시스트 토글이 다이얼로그에서 바뀌었으면 트랙 옵션에도 동기화.
      t.options.pitchAssistant = p.pitchAssist;
    }
    pendingRecording = null;
    _audioChanged();
  }

  /// 사용자가 "삭제" 탭 → pending 폐기 + WAV 파일 정리. 트랙은 변동 없음.
  void discardPendingRecording() {
    final p = pendingRecording;
    if (p == null) return;
    _deletePendingWav(p);
    pendingRecording = null;
    notifyListeners();
  }

  void _deletePendingWav(PendingRecording p) {
    try {
      final f = File(p.wavPath);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
    if (p.vocalWavPath != null) {
      try {
        final f = File(p.vocalWavPath!);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }

  /// 키/어시스턴트 변경 → /assist 로 빠르게 재계산 (무음).
  Future<void> reassist(TrackData t) async {
    if (t.notes.isEmpty) return;
    busy = true;
    notifyListeners();
    try {
      final old = t.notes;
      final r = await _api.assist(t.notes, t.options);
      t.notes = r.notes;
      // /assist 는 같은 개수·순서로 반환 → chunkId 를 인덱스로 보존.
      for (int i = 0; i < t.notes.length && i < old.length; i++) {
        t.notes[i].chunkId = old[i].chunkId;
      }
      final prev = t.analysis;
      t.analysis = AnalyzeResponse(
        notes: r.notes,
        detectedKey: r.detectedKey,
        keyCandidates: r.keyCandidates,
        assistAppliedCount: r.assistAppliedCount,
        durationSec: prev?.durationSec ?? 0,
        peaks: prev?.peaks ?? const [],
      );
    } catch (e) {
      error = '보정 실패: $e';
    } finally {
      busy = false;
      _audioChanged();
    }
  }

  // 메인 키: keys/bass/vocal 중 한 트랙을 기준으로 정하면 전체 트랙이 그 키로.
  TrackRole? mainKeyRole;

  Future<void> setMainKeyFromRole(TrackRole r) async {
    if (r == TrackRole.drum) return;
    // 카테고리 안에 여러 트랙이 있을 수 있음 — 분석된 detectedKey 가 있는 첫 트랙을 기준.
    TrackData? src;
    for (final t in tracksByRole(r)) {
      if (t.analysis?.detectedKey?.tonic != null) {
        src = t;
        break;
      }
    }
    final dk = src?.analysis?.detectedKey;
    if (dk?.tonic == null || dk?.scale == null) {
      error = '${r.label} 트랙의 키가 아직 감지되지 않았습니다';
      notifyListeners();
      return;
    }
    mainKeyRole = r;
    for (final t in tracks) {
      // 드럼 제외. 기준 트랙(r)은 이미 이 키로 분석된 '근거'이므로 재보정하지
      // 않는다 — 수동키(conf=1.0)로 강제하면 보정 상한이 올라가 기준 트랙에
      // 원래보다 센 교정이 한 번 더 들어가는 모순이 생김.
      if (t.role == TrackRole.drum || t.role == r) continue;
      t.options.autoKey = false;
      t.options.keyTonic = dk!.tonic;
      t.options.scale = dk.scale;
      if (t.notes.isNotEmpty) await reassist(t);
    }
    _audioChanged();
  }

  // ─── 프로젝트 앵커 잠금 ──────────────────────────────────────────────────

  /// 그루브 잠금 — 노트 있는 첫 트랙을 그루브 앵커로 지정만 한다.
  /// 기준 트랙·기존 트랙은 건드리지 않음(소급 강제 금지). 잠금 이후 (재)녹음되는
  /// 트랙이 _inheritAnchorIfLocked 에서 quantize on + 공유 그루브를 상속한다.
  void lockGroove() {
    final a = firstTrackWithNotes();
    if (a == null) return;
    grooveAnchorTrackId = a.id;
    _audioChanged();
  }

  /// 키 앵커 후보(검출 키 + 상대조 + top3 후보) — 확인 시트용. 없으면 null.
  ({String tonic, String scale, List<KeyCandidate> candidates})? anchorKeyProposal() {
    final src = firstTrackWithKey();
    final dk = src?.analysis?.detectedKey;
    if (dk?.tonic == null || dk?.scale == null) return null;
    return (tonic: dk!.tonic!, scale: dk.scale!, candidates: src!.analysis!.keyCandidates);
  }

  /// 사용자가 확정한 키로 프로젝트 키 잠금. 기준 트랙·기존 트랙은 **소급 보정하지
  /// 않는다**(녹음한 그대로 = 키의 근거). 잠금 이후 (재)녹음되는 트랙만 이 키를
  /// 상속해 적극 보정된다(_inheritAnchorIfLocked).
  void confirmAnchorKey(String tonic, String scale) {
    projectKeyTonic = tonic;
    projectKeyScale = scale;
    keyAnchorTrackId = firstTrackWithKey()?.id;
    anchorLocked = true;
    _audioChanged();
  }

  /// 앵커 잠금 후, (재)녹음 직전 멜로딕 트랙이 프로젝트 키 + 적극 보정 + 박자 보정을
  /// 상속하게. 기준 트랙 자신은 잠금 전 녹음이라 영향 없음(이후 재녹음 시에만 적용).
  void _inheritAnchorIfLocked(TrackData t) {
    if (!anchorLocked) return;
    if (t.role == TrackRole.drum || t.isVocal) return;
    if (projectKeyTonic != null) {
      t.options.autoKey = false;
      t.options.keyTonic = projectKeyTonic;
      t.options.scale = projectKeyScale;
      t.options.assistAggressive = true;
    }
    t.quantizeEnabled = true; // 공유 그루브에 맞물림(전진 적용)
  }

  void setAutoKey(bool auto, {String? tonic, String? scale}) {
    mainKeyRole = null;
    active.options.autoKey = auto;
    active.options.keyTonic = auto ? null : tonic;
    active.options.scale = auto ? null : scale;
    reassist(active);
  }

  void togglePitchAssistant(bool on) {
    active.options.pitchAssistant = on;
    notifyListeners(); // 노트 없어 reassist 가 early-return 하는 트랙(드럼/보컬/빈)도 토글 시각 반영.
    reassist(active);
  }

  void setInstrument(int program) {
    active.program = program;
    _audioChanged();
  }

  void setChordMode(bool on) {
    active.chordMode = on;
    _audioChanged();
  }

  /// 베이스 저음역 자동 배치 토글. off 면 _recomputeBassPlacement 가 shift=0 으로
  /// 되돌려 원래 흥얼 음역으로 즉시 복귀.
  void setBassPlacement(bool on) {
    active.bassPlacement = on;
    _audioChanged();
  }

  /// 노트 후보 선택(사용자 보정) — 즉시 시각 반영, 소리는 Play 시.
  /// pitchOriginal 로 되돌리면 source 도 'raw' 로 되돌려 색/상태가 원본으로 복귀.
  /// 코드 멤버도 개별 편집 가능 — voice leading / inversion / suspension 등을
  /// 자유롭게. 코드를 다른 코드로 통째 바꾸려면 Chord 버튼 → 코드 변환 시트.
  void applyCandidate(int noteIndex, int pitch) {
    final t = active;
    if (noteIndex < 0 || noteIndex >= t.notes.length) return;
    final n = t.notes[noteIndex];
    n.pitch = pitch;
    n.source = (pitch == n.pitchOriginal) ? 'raw' : 'user';
    n.pitchHz = _midiToHz(pitch);
    _audioChanged();
  }

  // ─── 단일 노트 → 코드 확장 (per-note chord) ───────────────────────────
  // 선택된 단음을 ChordType 으로 확장 → 같은 시간대 여러 노트(새 chunkId 묶음).
  // 이미 코드 묶음이면 루트(최저음)만 남기는 unchord 동작.

  /// 단음 노트(index)를 코드로 확장. 원본 노트는 결과 노트들로 교체.
  /// **원본 청크 멤버십(chunkId) 유지** — 같은 청크 안의 다른 노트와 함께 머무름.
  /// 결과 노트들은 같은 (start, end) 를 가지므로 _chordSiblings 로 묶음 인식.
  void applyChord(int noteIndex, ChordType type) {
    final t = active;
    if (noteIndex < 0 || noteIndex >= t.notes.length) return;
    final n = t.notes[noteIndex];
    if (n.kind != 'pitched') return;
    final dk = t.analysis?.detectedKey;
    // 원본 노트의 chunkId 그대로 사용 → 청크 분리 X.
    final chord = expandToChord(n, type, n.chunkId, tonic: dk?.tonic, scale: dk?.scale);
    t.notes.removeAt(noteIndex);
    t.notes.addAll(chord);
    _resort();
    // 루트(최저음)를 선택 — Unchord/추가 편집의 기준점.
    chord.sort((a, b) => a.pitch.compareTo(b.pitch));
    final root = chord.first;
    selectedNote = t.notes.indexOf(root);
    selectedChunk = null;
    _audioChanged();
  }

  /// 선택된 노트가 속한 코드 묶음(같은 chunkId + 같은 start/end) → 최저음만 남김.
  void unchordSelected() {
    final t = active;
    final i = selectedNote;
    if (i == null || i < 0 || i >= t.notes.length) return;
    final sibs = _chordSiblings(t.notes[i]);
    if (sibs.length < 2) return;
    sibs.sort((a, b) => a.pitch.compareTo(b.pitch));
    final root = sibs.first;
    t.notes.removeWhere((n) => sibs.contains(n) && !identical(n, root));
    selectedNote = t.notes.indexOf(root);
    _audioChanged();
  }

  /// 선택된 노트가 속한 "코드 묶음"(같은 chunkId · 같은 start/end 의 노트들).
  /// 단음일 경우 자기 자신만 반환.
  List<Note> _chordSiblings(Note n) {
    return active.notes.where((m) =>
      m.chunkId == n.chunkId &&
      (m.start - n.start).abs() < 0.001 &&
      (m.end - n.end).abs() < 0.001,
    ).toList();
  }

  /// 선택된 단일 노트가 코드화 가능한지(pitched + 코드 가능 악기 + 아직 코드 아님).
  bool get canChordSelected {
    final t = active;
    if (!t.isChordInstrument) return false;
    final i = selectedNote;
    if (i == null || i < 0 || i >= t.notes.length) return false;
    final n = t.notes[i];
    if (n.kind != 'pitched') return false;
    return _chordSiblings(n).length < 2; // 이미 코드면 unchord 만
  }

  /// 선택된 노트가 코드 묶음의 일원이면 unchord 가능.
  bool get canUnchordSelected {
    final t = active;
    final i = selectedNote;
    if (i == null || i < 0 || i >= t.notes.length) return false;
    return _chordSiblings(t.notes[i]).length >= 2;
  }

  // ─── 청크 단위 코드 변환 (chunk-scoped chord toggle) ─────────────────────
  // 청크가 선택된 상태에서 그 청크의 모든 멜로딕 단음을 한 번에 코드화/비코드화.
  // 이미 chord 묶음 멤버는 스킵(이중 적용 방지) — mixed 청크도 안전하게 처리.

  /// 청크 안의 모든 멜로딕 단음을 ChordType 으로 확장.
  /// 이미 코드 묶음 멤버인 노트는 건너뜀.
  void applyChordToChunk(int chunkId, ChordType type) {
    final t = active;
    final dk = t.analysis?.detectedKey;
    // 스냅샷 — 순회 중 t.notes 변경하므로 미리 대상 식별.
    final targets = <Note>[];
    for (final n in t.notes) {
      if (n.chunkId != chunkId) continue;
      if (n.kind != 'pitched') continue;
      if (_chordSiblings(n).length >= 2) continue; // 이미 코드 멤버 — 스킵
      targets.add(n);
    }
    if (targets.isEmpty) return;
    for (final n in targets) {
      final chord = expandToChord(n, type, n.chunkId, tonic: dk?.tonic, scale: dk?.scale);
      t.notes.remove(n);
      t.notes.addAll(chord);
    }
    _resort();
    _audioChanged();
  }

  /// 청크 안의 모든 코드 묶음 → 각 묶음마다 최저음(root)만 남김.
  void unchordChunk(int chunkId) {
    final t = active;
    final inChunk = t.notes.where((n) => n.chunkId == chunkId).toList();
    // 묶음 식별: (start, end) 키로 그룹화 (≈ _chordSiblings 와 같은 기준).
    final seen = <Note>{};
    final toRemove = <Note>[];
    for (final n in inChunk) {
      if (seen.contains(n)) continue;
      final sibs = _chordSiblings(n);
      seen.addAll(sibs);
      if (sibs.length < 2) continue;
      sibs.sort((a, b) => a.pitch.compareTo(b.pitch));
      final root = sibs.first;
      for (final s in sibs) {
        if (!identical(s, root)) toRemove.add(s);
      }
    }
    if (toRemove.isEmpty) return;
    t.notes.removeWhere((n) => toRemove.contains(n));
    _audioChanged();
  }

  /// 선택된 청크에 코드 변환 가능 노트(아직 코드 아닌 멜로딕)가 있는지.
  bool get canChordChunkSelected {
    final t = active;
    final id = selectedChunk;
    if (id == null) return false;
    if (!t.isChordInstrument) return false;
    if (t.chordActive) return false;
    for (final n in t.notes) {
      if (n.chunkId != id) continue;
      if (n.kind != 'pitched') continue;
      if (_chordSiblings(n).length >= 2) continue;
      return true;
    }
    return false;
  }

  /// 선택된 청크에 코드 묶음이 1개 이상 있는지.
  bool get canUnchordChunkSelected {
    final t = active;
    final id = selectedChunk;
    if (id == null) return false;
    if (t.chordActive) return false;
    for (final n in t.notes) {
      if (n.chunkId != id) continue;
      if (_chordSiblings(n).length >= 2) return true;
    }
    return false;
  }

  // ─── 선택 & 편집 (노트 또는 청크에 Split/Copy/Loop/Delete/Volume) ────────
  // 노트를 탭하면 selectedNote(그 노트만), 청크 영역을 탭하면 selectedChunk(그 청크
  // 전체)에 하단 버튼이 작용한다. 둘은 상호배타.
  int? selectedNote;
  int? selectedChunk;

  void selectNote(int? i) {
    selectedNote = i;
    selectedChunk = null;
    if (i != null) trackSelected = false;
    notifyListeners();
  }

  void selectChunk(int? id) {
    selectedChunk = id;
    selectedNote = null;
    if (id != null) trackSelected = false;
    notifyListeners();
  }

  bool get hasSelection => selectedNote != null || selectedChunk != null;

  Note _clone(Note n) => Note.fromJson(n.toJson())..chunkId = n.chunkId;

  Note? _selOr() {
    final t = active, i = selectedNote;
    if (i == null || i < 0 || i >= t.notes.length) return null;
    return t.notes[i];
  }

  List<Note> _chunkNotes(int id) => active.notes.where((n) => n.chunkId == id).toList();
  void _resort() => active.notes.sort((a, b) => a.start.compareTo(b.start));

  // ── 통합 라우터 (하단 툴바가 호출) ──
  /// 선택 대상을 atSec 에서 분할. 분할 가능했으면 true, 아니면 false.
  bool splitSelectedAny([double? atSec]) =>
      selectedChunk != null ? _splitChunk(selectedChunk!, atSec) : _splitNote(atSec);
  void copySelectedAny() => selectedChunk != null ? _copyChunk(selectedChunk!) : _copyNote();
  void deleteSelectedAny() => selectedChunk != null ? _deleteChunk(selectedChunk!) : _deleteNote();
  void loopSelectedAny() => selectedChunk != null ? _copyChunk(selectedChunk!) : loopActive();

  /// 선택된 대상의 현재 볼륨(velocity 0~127). 트랙만 선택된 경우 active 트랙의 첫 노트.
  int? get selectedVelocity {
    if (selectedChunk != null) {
      final ns = _chunkNotes(selectedChunk!);
      return ns.isEmpty ? null : ns.first.velocity;
    }
    if (selectedNote != null) return _selOr()?.velocity;
    if (trackSelected && active.notes.isNotEmpty) return active.notes.first.velocity;
    return null;
  }

  /// 선택된 노트/청크/트랙의 볼륨 설정. 트랙만 선택된 경우 active 의 모든 노트에 적용.
  void setSelectedVolume(int velocity) {
    final v = velocity.clamp(1, 127);
    if (selectedChunk != null) {
      for (final n in _chunkNotes(selectedChunk!)) {
        n.velocity = v;
      }
    } else if (selectedNote != null) {
      _selOr()?.velocity = v;
    } else if (trackSelected) {
      for (final n in active.notes) {
        n.velocity = v;
      }
    }
    _audioChanged();
  }

  // ── 노트 단위 ──
  void _deleteNote() {
    final t = active, i = selectedNote;
    if (i == null || i < 0 || i >= t.notes.length) return;
    t.notes.removeAt(i);
    selectedNote = null;
    _audioChanged();
  }

  void _copyNote() {
    final n = _selOr();
    if (n == null) return;
    final dur = n.end - n.start;
    final dup = _clone(n)
      ..start = n.end
      ..end = n.end + dur
      ..duration = dur;
    active.notes.add(dup);
    _resort();
    selectedNote = active.notes.indexOf(dup);
    _audioChanged();
  }

  bool _splitNote([double? atSec]) {
    final t = active, i = selectedNote;
    final n = _selOr();
    if (n == null) return false;
    final cut = (atSec != null && atSec > n.start && atSec < n.end) ? atSec : (n.start + n.end) / 2;
    if (cut - n.start < 0.02 || n.end - cut < 0.02) return false;
    final right = _clone(n)
      ..start = cut
      ..duration = n.end - cut;
    n.end = cut;
    n.duration = cut - n.start;
    t.notes.insert(i! + 1, right);
    _audioChanged();
    return true;
  }

  // ── 청크 단위 ──
  void _deleteChunk(int id) {
    active.notes.removeWhere((n) => n.chunkId == id);
    active.chunks.removeWhere((c) => c.id == id);
    selectedChunk = null;
    _audioChanged();
  }

  /// 청크 전체를 바로 뒤에 복제(= 청크 Loop/Copy). 새 청크로 선택 이동.
  /// 노트의 절대 시간은 그대로 두고 새 청크 메타의 timelineStart 만 뒤로 이동.
  void _copyChunk(int id) {
    final c = active.chunkById(id);
    if (c == null) return;
    final ns = _chunkNotes(id);
    final newId = ++_chunkSeq;
    for (final n in ns) {
      active.notes.add(_clone(n)..chunkId = newId);
    }
    active.chunks.add(Chunk(
      id: newId,
      timelineStart: c.timelineEnd,
      inPoint: c.inPoint,
      outPoint: c.outPoint,
      originalLength: c.originalLength,
      vocalWavPath: c.vocalWavPath,
      vocalPeaks: c.vocalPeaks,
      vocalDuration: c.vocalDuration,
    ));
    _resort();
    selectedChunk = newId;
    _audioChanged();
  }

  /// 청크 전체를 dtSec 만큼 타임라인 위치 이동. 노트는 건드리지 않고
  /// Chunk.timelineStart 만 변경. 시작이 0 미만이면 클램프.
  void moveChunkBy(int id, double dtSec) {
    final c = active.chunkById(id);
    if (c == null || dtSec == 0) return;
    final next = math.max(0.0, c.timelineStart + dtSec);
    if (next == c.timelineStart) return;
    c.timelineStart = next;
    _audioChanged();
  }

  /// 청크 양끝 트림 — 원본 청크의 [inPoint, outPoint] 윈도우만 좁힌다.
  /// 노트는 절대 시간 그대로 보존되어 다시 늘리면 복원됨.
  /// 좌측 핸들을 움직이면(newLeftTimeline) inPoint 조정 + timelineStart 보정해서
  ///   "잘려나간 만큼 청크가 안쪽으로 들어오는" 시각 효과를 낸다.
  /// 우측 핸들(newRightTimeline)은 outPoint 만 조정.
  void resizeChunk(int id, {double? newLeftTimeline, double? newRightTimeline}) {
    final c = active.chunkById(id);
    if (c == null) return;
    const minLen = 0.12;
    if (newRightTimeline != null) {
      final desiredLen = (newRightTimeline - c.timelineStart).clamp(minLen, c.originalLength - c.inPoint);
      c.outPoint = c.inPoint + desiredLen;
      _audioChanged();
    } else if (newLeftTimeline != null) {
      final fixedRight = c.timelineEnd;
      final newLeft = math.min(newLeftTimeline, fixedRight - minLen);
      final delta = newLeft - c.timelineStart; // (+) 좌측 안쪽으로 / (-) 좌측 바깥으로
      final nextIn = (c.inPoint + delta).clamp(0.0, c.outPoint - minLen);
      c.inPoint = nextIn;
      c.timelineStart = fixedRight - (c.outPoint - c.inPoint);
      _audioChanged();
    }
  }

  /// 청크를 atSec(타임라인 절대 시간 = 플레이헤드 위치)에서 둘로 분할.
  /// 좌측은 원본 청크의 [inPoint, localCut), 우측은 새 청크 [localCut, outPoint).
  /// atSec 이 청크 구간 밖이면 false 반환(분할 불가).
  bool _splitChunk(int id, double? atSec) {
    final c = active.chunkById(id);
    if (c == null || atSec == null) return false;
    if (atSec <= c.timelineStart || atSec >= c.timelineEnd) return false;
    final localCut = atSec - c.timelineStart + c.inPoint;
    final newId = ++_chunkSeq;
    active.chunks.add(Chunk(
      id: newId,
      timelineStart: atSec,
      inPoint: localCut,
      outPoint: c.outPoint,
      originalLength: c.originalLength,
      vocalWavPath: c.vocalWavPath,
      vocalPeaks: c.vocalPeaks,
      vocalDuration: c.vocalDuration,
    ));
    c.outPoint = localCut;
    // 우측 청크의 노트들을 재할당.
    for (final n in active.notes) {
      if (n.chunkId == id && n.start >= localCut) n.chunkId = newId;
    }
    selectedChunk = newId;
    _audioChanged();
    return true;
  }

  /// 활성 트랙 전체를 한 번 더 이어붙여 루프(선택 없을 때 Loop).
  void loopActive() {
    final t = active;
    if (t.notes.isEmpty) return;
    final end = t.notes.fold<double>(0, (m, n) => n.end > m ? n.end : m);
    final copies = t.notes
        .map((n) => _clone(n)
          ..start = n.start + end
          ..end = n.end + end)
        .toList();
    t.notes.addAll(copies);
    if (t.analysis != null) {
      t.analysis = AnalyzeResponse(
        notes: t.notes,
        detectedKey: t.analysis!.detectedKey,
        keyCandidates: t.analysis!.keyCandidates,
        assistAppliedCount: t.analysis!.assistAppliedCount,
        durationSec: end * 2,
        peaks: t.analysis!.peaks,
      );
    }
    _audioChanged();
  }

  bool get hasAnyNotes => tracks.any((t) => t.notes.isNotEmpty);

  /// 활성 트랙 1개만 백엔드에 보내 WAV 렌더.
  /// **Task 6-6 (2026-05-31) 기준 살아있는 호출처 없음** — 재생은
  /// `SynthPlayer`, export 는 `exportMixWav()` 가 담당. 호환용으로만 유지.
  @Deprecated('No live callers; use exportMixWav() for WAV bounce or SynthPlayer for playback.')
  // ignore: deprecated_member_use_from_same_package
  Future<Uint8List> renderActive() =>
      _api.renderAudio(active.renderNotes, program: active.program);

  // ─── 온디바이스 재생용 트랙 페이로드 (백엔드 호출 없음, Task #5) ──────────
  // SynthPlayer 가 소비. 보컬(원본 WAV) 은 SF2 합성 불가 → 제외 — 호출자가
  // audioplayers 로 별도 레이어 재생.

  /// 활성(enabled) + 노트 있는 비-보컬 트랙들의 (notes, program, isDrum) 목록.
  /// looping=true 트랙은 컨텐츠를 _projectEnd 까지 반복 펼침.
  List<({List<Note> notes, int program, bool isDrum})> playableSynthTracks() {
    final out = <({List<Note> notes, int program, bool isDrum})>[];
    final end = _projectEnd;
    for (final t in tracks) {
      if (!t.enabled || t.notes.isEmpty || t.isVocal) continue;
      var notes = effectiveRenderNotesFor(t);
      if (t.looping && end > 0 && t.chunks.isNotEmpty) {
        final period = t.chunks.map((c) => c.timelineEnd).reduce(math.max);
        notes = _loopNotesUntil(notes, end, period);
      }
      out.add((notes: notes, program: t.program, isDrum: t.role == TrackRole.drum));
    }
    return out;
  }

  /// 녹음 중 함께 들을 반주(녹음 대상 exclude). 노트 있는 비-보컬 트랙만.
  List<({List<Note> notes, int program, bool isDrum})> accompanimentSynthTracks(TrackRole exclude) {
    final out = <({List<Note> notes, int program, bool isDrum})>[];
    for (final t in tracks) {
      if (t.role == exclude || t.notes.isEmpty || t.isVocal) continue;
      out.add((notes: effectiveRenderNotesFor(t), program: t.program, isDrum: t.role == TrackRole.drum));
    }
    return out;
  }

  /// 활성(enabled)이고 노트 있는 트랙만 하나로 믹스 렌더.
  bool get hasEnabledNotes => tracks.any((t) => t.enabled && t.notes.isNotEmpty);

  // 보컬(목소리 그대로) — 믹스에 별도 레이어로 동시재생.
  // 보컬 카테고리에 트랙이 여러 개라면 첫 번째 보컬 트랙을 사용(현재는 1개만 시드됨).
  // 멀티 보컬 지원(#21~)이 들어오면 모든 보컬 트랙을 모아 mix 하도록 확장.
  TrackData? get _vocalTrack => firstByRole(TrackRole.vocal);
  bool get hasVocalAudio {
    final v = _vocalTrack;
    return v != null && v.enabled && v.vocalWavPath != null;
  }
  String? get vocalMixPath => hasVocalAudio ? _vocalTrack!.vocalWavPath : null;

  /// 보컬 청크 재생 스케줄 — 각 enabled 보컬 트랙의 청크별 (path, timelineStart, inPoint, duration).
  /// chunk meta 의 trim/move 를 반영. looping 트랙은 _projectEnd 까지 스케줄을 반복.
  List<({String path, double timelineStart, double inPoint, double duration})> vocalChunkSchedule() {
    final out = <({String path, double timelineStart, double inPoint, double duration})>[];
    final end = _projectEnd;
    for (final t in tracks) {
      if (!t.isVocal || !t.enabled) continue;
      final base = <({String path, double timelineStart, double inPoint, double duration})>[];
      for (final c in t.chunks) {
        final path = c.vocalWavPath ?? t.vocalWavPath;
        if (path == null) continue;
        final dur = c.visibleLength;
        if (dur <= 0) continue;
        base.add((path: path, timelineStart: c.timelineStart, inPoint: c.inPoint, duration: dur));
      }
      if (!t.looping || end <= 0 || base.isEmpty) {
        out.addAll(base);
        continue;
      }
      // 청크 timelineEnd 최대값(가시 영역 끝) 단위로 반복 — 트림 후 빈 여백도 보존.
      final period = t.chunks.map((c) => c.timelineEnd).reduce(math.max);
      if (period <= 0.01) {
        out.addAll(base);
        continue;
      }
      double offset = 0;
      while (offset < end) {
        for (final e in base) {
          final newStart = e.timelineStart + offset;
          if (newStart >= end) continue;
          final clippedDur = math.min(e.duration, end - newStart);
          if (clippedDur <= 0) continue;
          out.add((path: e.path, timelineStart: newStart, inPoint: e.inPoint, duration: clippedDur));
        }
        offset += period;
      }
    }
    return out;
  }
  bool get hasPlayableMix => hasEnabledNotes || hasVocalAudio;

  /// 녹음 중 함께 들을 보컬(녹음 대상이 보컬이 아니고 보컬 오디오가 있을 때).
  String? accompanimentVocalPath(TrackRole exclude) {
    if (exclude == TrackRole.vocal) return null;
    final v = _vocalTrack;
    return v?.vocalWavPath;
  }

  /// 활성(enabled)이고 노트 있는 트랙들을 백엔드 `/render_mix` 로 합쳐 WAV bytes.
  ///
  /// **Task 6-6 (2026-05-31) 기준 WAV export 전용 경로**. 일상 재생은
  /// `playableSynthTracks()` + `SynthPlayer` 로 온디바이스 처리. 현재
  /// 살아있는 호출처는 `exportMixWav()` (→ `sheets.dart` 공유 시트) 뿐.
  Future<Uint8List> renderMix() {
    final trs = tracks
        .where((t) => t.enabled && t.notes.isNotEmpty)
        .map((t) => (notes: effectiveRenderNotesFor(t), program: t.program))
        .toList();
    return _api.renderMix(trs);
  }

  /// 녹음 중 함께 들을 반주 — 녹음 대상(exclude) 트랙은 빼고 노트 있는 트랙 믹스.
  /// 다른 트랙이 없으면 null (첫 녹음 → 반주 없음).
  ///
  /// **Task 6-6 (2026-05-31) 기준 살아있는 호출처 없음** — 인라인 녹음
  /// 모니터링은 `accompanimentSynthTracks()` + `SynthPlayer` 로 대체됨
  /// (커밋 `6de9bec`). 호환용으로만 유지.
  @Deprecated('Replaced by accompanimentSynthTracks() + SynthPlayer (task 6-4).')
  Future<Uint8List?> renderAccompaniment(TrackRole exclude) async {
    final trs = tracks
        .where((t) => t.role != exclude && t.notes.isNotEmpty)
        .map((t) => (notes: effectiveRenderNotesFor(t), program: t.program))
        .toList();
    if (trs.isEmpty) return null;
    return _api.renderMix(trs);
  }

  Future<Uint8List> exportMidiActive() =>
      _api.exportMidi(effectiveRenderNotesFor(active), program: active.program);

  /// 재생 ▶ 와 동일한 WAV 믹스를 파일로 export — `renderMix()` 재사용.
  /// (보컬 오디오는 SoundFont 합성 결과가 아니므로 현재 포함되지 않음 —
  /// 재생 시점에서도 보컬은 별도 레이어로 동시재생이라 백엔드 mix 와는 무관.)
  Future<Uint8List> exportMixWav() => renderMix();

  /// 재생 ▶ 와 동일한 enabled 트랙 전부를 멀티트랙 MIDI 로 export.
  /// 보컬은 MIDI 로 의미가 없어 제외. 드럼은 GM 채널 9, 나머지는 0,1,2 … 로 배정.
  Future<Uint8List> exportMidiMix() {
    final list = <({List<Note> notes, int program, int channel})>[];
    int melodicCh = 0;
    for (final t in tracks) {
      if (!t.enabled || t.notes.isEmpty) continue;
      if (t.isVocal) continue; // 보컬은 오디오 — MIDI 제외
      int ch;
      if (t.role == TrackRole.drum) {
        ch = 9; // GM 드럼 채널
      } else {
        ch = melodicCh;
        melodicCh++;
        if (melodicCh == 9) melodicCh = 10; // 드럼 채널 회피
      }
      list.add((notes: effectiveRenderNotesFor(t), program: t.program, channel: ch));
    }
    return _api.exportMidiMix(list);
  }
}
