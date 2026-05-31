// 앱 전역 상태 (provider/ChangeNotifier).
// Project = N개 트랙(카테고리 = TrackRole: Keys/Bass/Drum/Vocal). 한 카테고리당
// 여러 트랙을 가질 수 있음(예: Chords 안에 Piano + Guitar). 각 트랙은 고유 id 로
// 식별되며 독립적으로 녹음/분석/편집.
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../api/engine_api.dart';
import '../models/models.dart';
import '../music/chords.dart';
import '../music/chord_expand.dart';

double _midiToHz(int m) => 440.0 * math.pow(2, (m - 69) / 12.0);

/// 한 트랙의 상태. `id` 는 ProjectStore 가 발급하는 고유 식별자(세션 단위).
class TrackData {
  TrackData(this.id, this.role, {int? program})
      : program = program ??
            ((instrumentPalette[role]?.isNotEmpty ?? false)
                ? instrumentPalette[role]!.first.program
                : 0),
        options = AnalyzeOptions();

  final int id;
  final TrackRole role;
  int program; // 선택된 GM 악기
  bool chordMode = false;
  bool enabled = true; // 믹스 재생 포함 여부(사이드바 토글)
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
    for (final i in instrumentPalette[role] ?? const <Instrument>[]) {
      if (i.program == program) return i.chordCapable;
    }
    return false;
  }

  bool get chordActive =>
      chordMode && isChordInstrument && (analysis?.detectedKey?.tonic != null);

  /// 재생/내보내기에 쓸 노트 (코드 모드면 트라이어드 확장).
  List<Note> get renderNotes => expandChords(notes, analysis?.detectedKey, chordActive);

  /// 청크의 timelineStart/inPoint/outPoint 를 적용한 "효과 시간" 기준 노트.
  /// 가시 범위 밖 노트는 제외, 안쪽 노트는 (timelineStart - inPoint) 만큼 시프트.
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
      if (n.start < c.inPoint || n.start >= c.outPoint) continue;
      final shift = c.timelineStart - c.inPoint;
      if (shift == 0) {
        out.add(n);
      } else {
        final clone = Note.fromJson(n.toJson())
          ..start = n.start + shift
          ..end = n.end + shift
          ..chunkId = n.chunkId;
        clone.duration = clone.end - clone.start;
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

class ProjectStore extends ChangeNotifier {
  ProjectStore({EngineApi? api}) : _api = api ?? EngineApi() {
    _seedDefaultTracks();
  }
  final EngineApi _api;

  String title = 'My Song';

  /// 모든 트랙(카테고리당 N개 가능). 순서는 사이드바 표시 순서.
  /// 처음에는 4개 카테고리 각 1개로 시작.
  final List<TrackData> tracks = [];
  int _trackSeq = 0; // 트랙 id 발급기
  int? activeTrackId; // 현재 편집/녹음 대상 트랙
  bool busy = false;
  String? error;
  int editEpoch = 0; // 오디오 출력에 영향 주는 편집마다 증가(재렌더 트리거)
  int _chunkSeq = 0; // 청크 ID 발급기

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
    notifyListeners();
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
    _audioChanged();
  }

  // ─── 드럼 재라벨링 (백엔드 호출 없음) ────────────────────────────────────
  // 백엔드는 모든 입력을 멜로딕으로 분석(auto-percussive fallback 제거됨).
  // 사용자가 드럼 슬롯에 녹음하면 = 명시적 드럼 의도 → 노트를 GM 드럼 채널(9)에서
  // 의미 있는 키트 매핑(36 Kick / 38 Snare / 42 HiHat)으로 변환한다.
  //
  // 매핑 휴리스틱(pitch 기반):
  //   - 트랙 평균보다 5 반음 이상 낮음 → Kick(36)
  //   - 트랙 평균보다 5 반음 이상 높음 → HiHat(42)
  //   - 그 외 → Snare(38)
  // 정밀 분류(스펙트럼 기반 backend/app/drums.py)는 후속 task — 일단은
  // 오프라인·즉시 동작이 우선.
  //
  // `pitchOriginal` 은 백엔드에서 받은 원래 멜로디 pitch — 보존되어 있어
  // `restoreFromDrums()` 로 되돌릴 때 손실 없이 복원된다.
  void _relabelAsDrums(List<Note> notes) {
    if (notes.isEmpty) return;
    final avg = notes.map((n) => n.pitch).reduce((a, b) => a + b) / notes.length;
    for (final n in notes) {
      // pitchOriginal 이 비어있으면(엣지) 현재 pitch 를 저장 — 복원 위해.
      if (n.pitchOriginal == 0) n.pitchOriginal = n.pitch;
      final diff = n.pitch - avg;
      final drumPitch = diff <= -5 ? 36 : (diff >= 5 ? 42 : 38);
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

  void newProject() {
    title = 'My Song';
    tracks.clear();
    _trackSeq = 0;
    _chunkSeq = 0;
    _seedDefaultTracks();
    error = null;
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
        t.chunks
          ..clear()
          ..add(Chunk(
            id: ++_chunkSeq,
            timelineStart: 0,
            inPoint: 0,
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
      final sz = await File(wavPath).length();
      final res = await _api.analyze(wavPath, t.options);
      t.analysis = res;
      t.notes = res.notes;
      final cid = ++_chunkSeq; // 이번 녹음 = 하나의 청크
      for (final n in t.notes) {
        n.chunkId = cid;
      }
      final span = res.durationSec > 0
          ? res.durationSec
          : (res.notes.isEmpty ? 0.0 : res.notes.map((n) => n.end).reduce(math.max));
      t.chunks
        ..clear()
        ..add(Chunk(
          id: cid,
          timelineStart: 0,
          inPoint: 0,
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
      // pending 의 어시스트 옵션으로 분석(트랙 옵션과 일시 분리).
      final opt = AnalyzeOptions(
        autoKey: t.options.autoKey,
        pitchAssistant: pendingRecording!.pitchAssist,
        keyTonic: t.options.keyTonic,
        scale: t.options.scale,
      );
      final res = await _api.analyze(wavPath, opt);
      pendingRecording!
        ..analysis = res
        ..notes = res.notes;
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
      t.chunks
        ..clear()
        ..add(Chunk(
          id: ++_chunkSeq,
          timelineStart: 0,
          inPoint: 0,
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
      t.chunks
        ..clear()
        ..add(Chunk(
          id: cid,
          timelineStart: 0,
          inPoint: 0,
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

  void setAutoKey(bool auto, {String? tonic, String? scale}) {
    mainKeyRole = null;
    active.options.autoKey = auto;
    active.options.keyTonic = auto ? null : tonic;
    active.options.scale = auto ? null : scale;
    reassist(active);
  }

  void togglePitchAssistant(bool on) {
    active.options.pitchAssistant = on;
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
  void splitSelectedAny([double? atSec]) =>
      selectedChunk != null ? _splitChunk(selectedChunk!, atSec) : _splitNote(atSec);
  void copySelectedAny() => selectedChunk != null ? _copyChunk(selectedChunk!) : _copyNote();
  void deleteSelectedAny() => selectedChunk != null ? _deleteChunk(selectedChunk!) : _deleteNote();
  void loopSelectedAny() => selectedChunk != null ? _copyChunk(selectedChunk!) : loopActive();

  /// 선택된 대상의 현재 볼륨(velocity 0~127). 없으면 null.
  int? get selectedVelocity {
    if (selectedChunk != null) {
      final ns = _chunkNotes(selectedChunk!);
      return ns.isEmpty ? null : ns.first.velocity;
    }
    return _selOr()?.velocity;
  }

  /// 선택된 노트/청크의 볼륨 설정(More 버튼).
  void setSelectedVolume(int velocity) {
    final v = velocity.clamp(1, 127);
    if (selectedChunk != null) {
      for (final n in _chunkNotes(selectedChunk!)) {
        n.velocity = v;
      }
    } else {
      _selOr()?.velocity = v;
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

  void _splitNote([double? atSec]) {
    final t = active, i = selectedNote;
    final n = _selOr();
    if (n == null) return;
    final cut = (atSec != null && atSec > n.start && atSec < n.end) ? atSec : (n.start + n.end) / 2;
    if (cut - n.start < 0.02 || n.end - cut < 0.02) return;
    final right = _clone(n)
      ..start = cut
      ..duration = n.end - cut;
    n.end = cut;
    n.duration = cut - n.start;
    t.notes.insert(i! + 1, right);
    _audioChanged();
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
  void _splitChunk(int id, double? atSec) {
    final c = active.chunkById(id);
    if (c == null || atSec == null) return;
    if (atSec <= c.timelineStart || atSec >= c.timelineEnd) return;
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
  List<({List<Note> notes, int program, bool isDrum})> playableSynthTracks() {
    final out = <({List<Note> notes, int program, bool isDrum})>[];
    for (final t in tracks) {
      if (!t.enabled || t.notes.isEmpty || t.isVocal) continue;
      out.add((notes: t.effectiveRenderNotes, program: t.program, isDrum: t.role == TrackRole.drum));
    }
    return out;
  }

  /// 녹음 중 함께 들을 반주(녹음 대상 exclude). 노트 있는 비-보컬 트랙만.
  List<({List<Note> notes, int program, bool isDrum})> accompanimentSynthTracks(TrackRole exclude) {
    final out = <({List<Note> notes, int program, bool isDrum})>[];
    for (final t in tracks) {
      if (t.role == exclude || t.notes.isEmpty || t.isVocal) continue;
      out.add((notes: t.effectiveRenderNotes, program: t.program, isDrum: t.role == TrackRole.drum));
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
  /// chunk meta 의 trim/move 를 그대로 반영.
  List<({String path, double timelineStart, double inPoint, double duration})> vocalChunkSchedule() {
    final out = <({String path, double timelineStart, double inPoint, double duration})>[];
    for (final t in tracks) {
      if (!t.isVocal || !t.enabled) continue;
      for (final c in t.chunks) {
        final path = c.vocalWavPath ?? t.vocalWavPath;
        if (path == null) continue;
        final dur = c.visibleLength;
        if (dur <= 0) continue;
        out.add((path: path, timelineStart: c.timelineStart, inPoint: c.inPoint, duration: dur));
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
        .map((t) => (notes: t.effectiveRenderNotes, program: t.program))
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
        .map((t) => (notes: t.effectiveRenderNotes, program: t.program))
        .toList();
    if (trs.isEmpty) return null;
    return _api.renderMix(trs);
  }

  Future<Uint8List> exportMidiActive() =>
      _api.exportMidi(active.effectiveRenderNotes, program: active.program);

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
      list.add((notes: t.effectiveRenderNotes, program: t.program, channel: ch));
    }
    return _api.exportMidiMix(list);
  }
}
