// 앱 전역 상태 (provider/ChangeNotifier).
// Project = 4개 트랙(Keys/Bass/Drum/Vocal). 각 트랙은 독립 녹음/분석.
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../api/engine_api.dart';
import '../models/models.dart';
import '../music/chords.dart';

double _midiToHz(int m) => 440.0 * math.pow(2, (m - 69) / 12.0);

/// 한 트랙의 상태.
class TrackData {
  TrackData(this.role)
      : program = (instrumentPalette[role]?.isNotEmpty ?? false)
            ? instrumentPalette[role]!.first.program
            : 0,
        options = AnalyzeOptions();

  final TrackRole role;
  int program; // 선택된 GM 악기
  bool chordMode = false;
  bool enabled = true; // 믹스 재생 포함 여부(사이드바 토글)
  String? wavPath; // 오리지널 WAV
  AnalyzeResponse? analysis; // 최근 분석 결과
  List<Note> notes = []; // 편집된 현재 노트
  AnalyzeOptions options; // autoKey / pitchAssistant / key

  // 보컬 전용 — 악기 변환 없이 목소리 그대로. 정리된 WAV + 표시용 파형.
  String? vocalWavPath; // 노이즈 정리된 목소리(믹스/재생 소스)
  List<double> vocalPeaks = const [];
  double vocalDuration = 0;

  bool get isVocal => role == TrackRole.vocal;
  bool get hasRecording => wavPath != null || vocalWavPath != null;

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
}

class ProjectStore extends ChangeNotifier {
  ProjectStore({EngineApi? api}) : _api = api ?? EngineApi();
  final EngineApi _api;

  String title = 'My Song';
  final Map<TrackRole, TrackData> tracks = {
    for (final r in TrackRole.values) r: TrackData(r),
  };
  TrackRole activeRole = TrackRole.keys;
  bool busy = false;
  String? error;
  int editEpoch = 0; // 오디오 출력에 영향 주는 편집마다 증가(재렌더 트리거)
  int _chunkSeq = 0; // 청크 ID 발급기

  TrackData get active => tracks[activeRole]!;
  bool get hasAnyRecording => tracks.values.any((t) => t.hasRecording);

  void _audioChanged() {
    editEpoch++;
    notifyListeners();
  }

  void setActiveRole(TrackRole r) {
    activeRole = r;
    notifyListeners();
  }

  void toggleEnabled(TrackRole r) {
    tracks[r]!.enabled = !tracks[r]!.enabled;
    _audioChanged();
  }

  void newProject() {
    title = 'My Song';
    for (final r in TrackRole.values) {
      tracks[r] = TrackData(r);
    }
    activeRole = TrackRole.keys;
    error = null;
    notifyListeners();
  }

  Future<bool> health() => _api.health();

  /// 녹음 WAV → 분석 → 활성(또는 지정) 트랙에 반영.
  Future<void> recordAnalyzed(String wavPath, {TrackRole? role}) async {
    final t = tracks[role ?? activeRole]!;
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
    final dk = tracks[r]!.analysis?.detectedKey;
    if (dk?.tonic == null || dk?.scale == null) {
      error = '${r.label} 트랙의 키가 아직 감지되지 않았습니다';
      notifyListeners();
      return;
    }
    mainKeyRole = r;
    for (final t in tracks.values) {
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
  void applyCandidate(int noteIndex, int pitch) {
    final t = active;
    if (noteIndex < 0 || noteIndex >= t.notes.length) return;
    final n = t.notes[noteIndex];
    n.pitch = pitch;
    n.source = 'user';
    n.pitchHz = _midiToHz(pitch);
    _audioChanged();
  }

  // ─── 선택 & 편집 (노트 또는 청크에 Split/Copy/Loop/Delete/Volume) ────────
  // 노트를 탭하면 selectedNote(그 노트만), 청크 영역을 탭하면 selectedChunk(그 청크
  // 전체)에 하단 버튼이 작용한다. 둘은 상호배타.
  int? selectedNote;
  int? selectedChunk;

  void selectNote(int? i) {
    selectedNote = i;
    selectedChunk = null;
    notifyListeners();
  }

  void selectChunk(int? id) {
    selectedChunk = id;
    selectedNote = null;
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
    selectedChunk = null;
    _audioChanged();
  }

  /// 청크 전체를 바로 뒤에 복제(= 청크 Loop/Copy). 새 청크로 선택 이동.
  void _copyChunk(int id) {
    final ns = _chunkNotes(id);
    if (ns.isEmpty) return;
    final start = ns.map((n) => n.start).reduce(math.min);
    final end = ns.map((n) => n.end).reduce(math.max);
    final offset = end - start;
    final newId = ++_chunkSeq;
    for (final n in ns) {
      active.notes.add(_clone(n)
        ..start = n.start + offset
        ..end = n.end + offset
        ..chunkId = newId);
    }
    _resort();
    selectedChunk = newId;
    _audioChanged();
  }

  /// 청크를 atSec(플레이헤드)에서 둘로 분할 — 그 지점 이후 노트에 새 청크 ID 부여.
  void _splitChunk(int id, double? atSec) {
    final ns = _chunkNotes(id);
    if (ns.isEmpty || atSec == null) return;
    final start = ns.map((n) => n.start).reduce(math.min);
    final end = ns.map((n) => n.end).reduce(math.max);
    if (atSec <= start || atSec >= end) return; // 청크 밖이면 무시
    final newId = ++_chunkSeq;
    for (final n in ns) {
      if (n.start >= atSec) n.chunkId = newId;
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

  bool get hasAnyNotes => tracks.values.any((t) => t.notes.isNotEmpty);

  Future<Uint8List> renderActive() =>
      _api.renderAudio(active.renderNotes, program: active.program);

  /// 활성(enabled)이고 노트 있는 트랙만 하나로 믹스 렌더.
  bool get hasEnabledNotes => tracks.values.any((t) => t.enabled && t.notes.isNotEmpty);

  // 보컬(목소리 그대로) — 믹스에 별도 레이어로 동시재생.
  TrackData get _vocalTrack => tracks[TrackRole.vocal]!;
  bool get hasVocalAudio => _vocalTrack.enabled && _vocalTrack.vocalWavPath != null;
  String? get vocalMixPath => hasVocalAudio ? _vocalTrack.vocalWavPath : null;
  bool get hasPlayableMix => hasEnabledNotes || hasVocalAudio;

  /// 녹음 중 함께 들을 보컬(녹음 대상이 보컬이 아니고 보컬 오디오가 있을 때).
  String? accompanimentVocalPath(TrackRole exclude) =>
      (exclude != TrackRole.vocal && _vocalTrack.vocalWavPath != null) ? _vocalTrack.vocalWavPath : null;

  Future<Uint8List> renderMix() {
    final trs = tracks.values
        .where((t) => t.enabled && t.notes.isNotEmpty)
        .map((t) => (notes: t.renderNotes, program: t.program))
        .toList();
    return _api.renderMix(trs);
  }

  /// 녹음 중 함께 들을 반주 — 녹음 대상(exclude) 트랙은 빼고 노트 있는 트랙 믹스.
  /// 다른 트랙이 없으면 null (첫 녹음 → 반주 없음).
  Future<Uint8List?> renderAccompaniment(TrackRole exclude) async {
    final trs = tracks.values
        .where((t) => t.role != exclude && t.notes.isNotEmpty)
        .map((t) => (notes: t.renderNotes, program: t.program))
        .toList();
    if (trs.isEmpty) return null;
    return _api.renderMix(trs);
  }

  Future<Uint8List> exportMidiActive() =>
      _api.exportMidi(active.renderNotes, program: active.program);
}
