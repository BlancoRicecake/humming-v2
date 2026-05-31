// 백엔드(SoundLab, Humming V2/backend) 스키마 미러 + 악기 팔레트.
// Note / DetectedKey / KeyCandidate / AnalyzeOptions / AnalyzeResponse 는
// backend/app/schemas.py 와 1:1 대응.
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

double _d(dynamic v, [double def = 0]) => (v as num?)?.toDouble() ?? def;
int _i(dynamic v, [int def = 0]) => (v as num?)?.toInt() ?? def;

class Note {
  Note({
    required this.start,
    required this.end,
    required this.duration,
    required this.pitch,
    required this.pitchRaw,
    required this.pitchHz,
    required this.velocity,
    required this.confidence,
    required this.voicedRatio,
    required this.kind,
    required this.pitchOriginal,
    required this.assisted,
    required this.candidates,
    required this.source,
    required this.inKey,
    required this.correctionCents,
  });

  double start, end, duration, pitchRaw, pitchHz, confidence, voicedRatio, correctionCents;
  int pitch, velocity, pitchOriginal;
  String kind; // pitched | percussive
  String source; // raw | assistant | user
  bool assisted, inKey;
  List<int> candidates;
  int chunkId = 0; // 클라이언트 전용 — 같은 녹음/구간 묶음(청크 편집용). 백엔드 미전송.

  factory Note.fromJson(Map<String, dynamic> j) => Note(
        start: _d(j['start']),
        end: _d(j['end']),
        duration: _d(j['duration']),
        pitch: _i(j['pitch']),
        pitchRaw: _d(j['pitch_raw']),
        pitchHz: _d(j['pitch_hz']),
        velocity: _i(j['velocity'], 90),
        confidence: _d(j['confidence']),
        voicedRatio: _d(j['voiced_ratio']),
        kind: (j['kind'] ?? 'pitched') as String,
        pitchOriginal: _i(j['pitch_original']),
        assisted: (j['assisted'] ?? false) as bool,
        candidates: ((j['candidates'] ?? []) as List).map((e) => _i(e)).toList(),
        source: (j['source'] ?? 'raw') as String,
        inKey: (j['in_key'] ?? true) as bool,
        correctionCents: _d(j['correction_cents']),
      );

  Map<String, dynamic> toJson() => {
        'start': start,
        'end': end,
        'duration': duration,
        'pitch': pitch,
        'pitch_raw': pitchRaw,
        'pitch_hz': pitchHz,
        'velocity': velocity,
        'confidence': confidence,
        'voiced_ratio': voicedRatio,
        'kind': kind,
        'pitch_original': pitchOriginal,
        'assisted': assisted,
        'candidates': candidates,
        'source': source,
        'in_key': inKey,
        'correction_cents': correctionCents,
      };

  Note copyWith({int? pitch, String? source}) => Note.fromJson(toJson())
    ..pitch = pitch ?? this.pitch
    ..source = source ?? this.source;
}

/// 청크 = 한 번의 녹음/편집 단위. 노트들의 묶음(`Note.chunkId`로 참조).
///
/// 노트의 `start/end`는 원본 녹음 시간을 보존(편집해도 변경하지 않음).
/// 화면/재생 시점의 효과 시간은 청크의 [timelineStart] / [inPoint] 로 계산:
///   effectiveStart = note.start - inPoint + timelineStart
/// 노트는 `[inPoint, outPoint)` 안에 있을 때만 가시·재생 대상.
///
/// 트림(handle)으로 inPoint/outPoint를 좁혀도 원본 노트는 보존 → 다시 늘리면 복원.
/// 홀드&드래그로 청크를 옮기면 [timelineStart] 만 변하고 trim 은 그대로.
class Chunk {
  Chunk({
    required this.id,
    required this.timelineStart,
    required this.inPoint,
    required this.outPoint,
    required this.originalLength,
    this.vocalWavPath,
    this.vocalPeaks = const [],
    this.vocalDuration = 0,
  });

  final int id;
  double timelineStart; // 청크 좌측이 위치하는 타임라인 절대 시간
  double inPoint;       // 원본 기준 — 좌측 트림 (>= 0)
  double outPoint;      // 원본 기준 — 우측 트림 (<= originalLength)
  double originalLength; // 원본 청크 길이(불변) — 트림 최대 범위
  // 보컬 트랙 청크 전용 — 원본 wav 파일과 메타.
  String? vocalWavPath;
  List<double> vocalPeaks;
  double vocalDuration;

  double get visibleLength => outPoint - inPoint;
  double get timelineEnd => timelineStart + visibleLength;

  Map<String, dynamic> toJson() => {
        'id': id,
        'timeline_start': timelineStart,
        'in_point': inPoint,
        'out_point': outPoint,
        'original_length': originalLength,
        'vocal_wav_path': vocalWavPath,
        'vocal_peaks': vocalPeaks,
        'vocal_duration': vocalDuration,
      };

  static Chunk fromJson(Map<String, dynamic> j) => Chunk(
        id: (j['id'] as num).toInt(),
        timelineStart: _d(j['timeline_start']),
        inPoint: _d(j['in_point']),
        outPoint: _d(j['out_point']),
        originalLength: _d(j['original_length']),
        vocalWavPath: j['vocal_wav_path'] as String?,
        vocalPeaks: ((j['vocal_peaks'] ?? []) as List).map((e) => _d(e)).toList(),
        vocalDuration: _d(j['vocal_duration']),
      );
}

class DetectedKey {
  DetectedKey({this.tonic, this.scale, this.confidence = 0, this.keyTier, this.keyApplied = false});
  final String? tonic, scale, keyTier;
  final double confidence;
  final bool keyApplied;

  factory DetectedKey.fromJson(Map<String, dynamic> j) => DetectedKey(
        tonic: j['tonic'] as String?,
        scale: j['scale'] as String?,
        confidence: _d(j['confidence']),
        keyTier: j['key_tier'] as String?,
        keyApplied: (j['key_applied'] ?? false) as bool,
      );

  String get label => tonic == null ? '—' : '$tonic ${scale ?? ''}'.trim();
}

class KeyCandidate {
  KeyCandidate(this.tonic, this.scale, this.correlation);
  final String tonic, scale;
  final double correlation;
  factory KeyCandidate.fromJson(Map<String, dynamic> j) =>
      KeyCandidate(j['tonic'] as String, j['scale'] as String, _d(j['correlation']));
}

/// 앱이 보내는 분석/보정 옵션. 미지정 필드는 백엔드 기본값 사용.
class AnalyzeOptions {
  AnalyzeOptions({this.autoKey = true, this.pitchAssistant = true, this.keyTonic, this.scale});
  bool autoKey, pitchAssistant;
  String? keyTonic, scale;

  Map<String, dynamic> toJson() => {
        'auto_key': autoKey,
        'pitch_assistant': pitchAssistant,
        if (keyTonic != null) 'key_tonic': keyTonic,
        if (scale != null) 'scale': scale,
      };
}

class AnalyzeResponse {
  AnalyzeResponse({
    required this.notes,
    required this.detectedKey,
    required this.keyCandidates,
    required this.assistAppliedCount,
    required this.durationSec,
    required this.peaks,
  });
  final List<Note> notes;
  final DetectedKey? detectedKey;
  final List<KeyCandidate> keyCandidates;
  final int assistAppliedCount;
  final double durationSec;
  final List<double> peaks;

  factory AnalyzeResponse.fromJson(Map<String, dynamic> j) {
    final wf = (j['waveform'] ?? {}) as Map<String, dynamic>;
    return AnalyzeResponse(
      notes: ((j['notes'] ?? []) as List).map((e) => Note.fromJson(e as Map<String, dynamic>)).toList(),
      detectedKey: j['detected_key'] == null ? null : DetectedKey.fromJson(j['detected_key'] as Map<String, dynamic>),
      keyCandidates: ((j['key_candidates'] ?? []) as List).map((e) => KeyCandidate.fromJson(e as Map<String, dynamic>)).toList(),
      assistAppliedCount: _i(j['assist_applied_count']),
      durationSec: _d(wf['duration']),
      peaks: ((wf['peaks'] ?? []) as List).map((e) => _d(e)).toList(),
    );
  }
}

// ─── 트랙 역할 & 악기 팔레트 ───────────────────────────────────────────

enum TrackRole {
  keys('Chords', 'Chord mode', Symbols.piano),
  bass('Bass', 'Synth bass', Symbols.music_note),
  drum('Drum', 'Beatbox', Symbols.graphic_eq),
  vocal('Vocal', 'Original take', Symbols.mic);

  const TrackRole(this.label, this.defaultMode, this.icon);
  final String label;
  final String defaultMode;
  final IconData icon;
}

class Instrument {
  const Instrument(this.label, this.program, {this.chordCapable = false});
  final String label;
  final int program; // GM program (bank 0)
  final bool chordCapable;
}

/// 역할별 선택 가능한 악기 (instruments.ts 미러). drum/vocal 은 자동.
const Map<TrackRole, List<Instrument>> instrumentPalette = {
  TrackRole.keys: [
    Instrument('피아노', 0, chordCapable: true),
    Instrument('신스', 90, chordCapable: true),
    Instrument('어쿠스틱 기타', 25, chordCapable: true),
    Instrument('일렉 기타', 27, chordCapable: true),
    // 추후 추가 검토:
    // Instrument('일렉 피아노', 4, chordCapable: true),
    // Instrument('오르간', 16, chordCapable: true),
    // Instrument('클래식 기타', 24, chordCapable: true),
    // Instrument('스트링', 48, chordCapable: true),
  ],
  TrackRole.bass: [
    Instrument('베이스 기타', 33),
    Instrument('신스 베이스', 39),
    // 추후 추가 검토:
    // Instrument('어쿠스틱 베이스', 32),
  ],
  TrackRole.drum: [],
  TrackRole.vocal: [],
};

const Map<int, String> drumNames = {36: 'Kick', 38: 'Snare', 42: 'HiHat'};

const _pcNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

/// MIDI → 음이름 (예: 60 → C4).
String noteName(int midi) {
  final pc = ((midi % 12) + 12) % 12;
  return '${_pcNames[pc]}${(midi ~/ 12) - 1}';
}
