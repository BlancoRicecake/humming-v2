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
    this.drum,
    this.drumName,
    this.drumCentroid = 0,
    this.drumLowRatio = 0,
    this.drumHighRatio = 0,
    this.drumZcr = 0,
    this.drumRolloff = 0,
    this.drumFlatness = 0,
    this.onsetStrength = 0,
  });

  double start, end, duration, pitchRaw, pitchHz, confidence, voicedRatio, correctionCents;
  int pitch, velocity, pitchOriginal;
  String kind; // pitched | percussive
  String source; // raw | assistant | user
  bool assisted, inKey;
  List<int> candidates;
  int chunkId = 0; // 클라이언트 전용 — 같은 녹음/구간 묶음(청크 편집용). 백엔드 미전송.
  // 클라이언트 전용(비직렬화) — 이 렌더 노트가 유래한 원본 t.notes 인덱스.
  // effectiveRenderNotes 가 리딩 트림 노트를 드롭하면 표시 인덱스가 원본과 어긋나므로,
  // 선택/편집은 항상 이 raw 인덱스를 기준으로 한다(표시 인덱스 직접 사용 금지).
  int renderSrcIndex = -1;
  // 백엔드 스펙트럼 드럼 분류(drums.py) — 모든 노트에 채워짐. 드럼 트랙에서만 사용.
  int? drum;          // GM 드럼 노트 36/38/42
  String? drumName;   // Kick | Snare | HiHat
  double drumCentroid, drumLowRatio, drumHighRatio, drumZcr; // 디버그 특징값
  double drumRolloff, drumFlatness, onsetStrength; // 디버그 — rolloff/flatness/onset 세기

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
        drum: (j['drum'] as num?)?.toInt(),
        drumName: j['drum_name'] as String?,
        drumCentroid: _d(j['drum_centroid']),
        drumLowRatio: _d(j['drum_low_ratio']),
        drumHighRatio: _d(j['drum_high_ratio']),
        drumZcr: _d(j['drum_zcr']),
        drumRolloff: _d(j['drum_rolloff']),
        drumFlatness: _d(j['drum_flatness']),
        onsetStrength: _d(j['onset_strength']),
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
        if (drum != null) 'drum': drum,
        if (drumName != null) 'drum_name': drumName,
        'drum_centroid': drumCentroid,
        'drum_low_ratio': drumLowRatio,
        'drum_high_ratio': drumHighRatio,
        'drum_zcr': drumZcr,
        'drum_rolloff': drumRolloff,
        'drum_flatness': drumFlatness,
        'onset_strength': onsetStrength,
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
  AnalyzeOptions({
    this.autoKey = true,
    this.pitchAssistant = true,
    this.keyTonic,
    this.scale,
    this.asDrums = false,
    this.assistAggressive = false,
    this.pitchModel = 'pyin',
  });
  bool autoKey, pitchAssistant;
  String? keyTonic, scale;
  bool asDrums; // 드럼 트랙 → 백엔드 onset 기반 드럼 분석 요청
  bool assistAggressive; // 잠긴 키 트랙 → 스케일 밖 음을 적극 스냅(음치 안전장치)
  String pitchModel; // 'pyin'(기본) | 'crepe'(디버그 전용, 사전학습 트래커)

  Map<String, dynamic> toJson() => {
        'auto_key': autoKey,
        'pitch_assistant': pitchAssistant,
        if (keyTonic != null) 'key_tonic': keyTonic,
        if (scale != null) 'scale': scale,
        if (asDrums) 'as_drums': asDrums,
        if (assistAggressive) 'assist_aggressive': assistAggressive,
        if (pitchModel != 'pyin') 'pitch_model': pitchModel,
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

/// 한 프리셋. `code` 는 카테고리별 업로드(=bank,program 정렬) 순 고유번호(P01, AG03, D05…).
/// 멜로딕은 전부 bank 0 → program 만으로 식별. 드럼은 bank 128(역할에서 파생).
class Instrument {
  const Instrument(this.code, this.label, this.program, {this.chordCapable = false});
  final String code;
  final String label;
  final int program; // GM program (드럼은 bank128 program)
  final bool chordCapable;
}

/// 악기 패밀리(피아노/어쿠스틱 기타/…) — 그 안에 여러 프리셋.
/// 웹 frontend/src/lib/instruments.ts 의 InstrumentRole 미러.
class InstrumentFamily {
  const InstrumentFamily(this.label, this.instruments, {this.chordCapable = false});
  final String label;
  final bool chordCapable;
  final List<Instrument> instruments;
}

/// 역할별 선택 가능한 악기 — 웹 instruments.ts 규칙을 번들 SF2(TimGM6mb.sf2)에 적용해
/// 산출한 결과를 하드코딩(번들 SF2 고정이라 런타임 파서 불필요).
/// 재현법: backend/app/render.py:list_presets() 의 phdr 파싱 + instruments.ts CATEGORIES.
/// 코드는 카테고리별 (bank,program) 정렬 순 P01.., AG01.., LG01.., SM01.., BG01.., SB01.., D01...
const Map<TrackRole, List<InstrumentFamily>> instrumentPalette = {
  TrackRole.keys: [
    InstrumentFamily('피아노', [
      Instrument('P01', 'Piano 1', 0, chordCapable: true),
      Instrument('P02', 'Piano 2', 1, chordCapable: true),
      Instrument('P03', 'Piano 3', 2, chordCapable: true),
      Instrument('P04', 'E.Piano 1', 4, chordCapable: true),
    ], chordCapable: true),
    InstrumentFamily('어쿠스틱 기타', [
      Instrument('AG01', 'Nylon Guitar', 24, chordCapable: true),
      Instrument('AG02', 'Steel Guitar', 25, chordCapable: true),
      Instrument('AG03', 'Jazz Guitar', 26, chordCapable: true),
      Instrument('AG04', 'Clean Guitar', 27, chordCapable: true),
      Instrument('AG05', 'Guitar Mutes', 28, chordCapable: true),
    ], chordCapable: true),
    InstrumentFamily('일렉 기타', [
      Instrument('LG01', 'Overdrive Guitar', 29, chordCapable: true),
      Instrument('LG02', 'Distortion Guitar', 30, chordCapable: true),
    ], chordCapable: true),
    InstrumentFamily('신스', [
      Instrument('SM01', 'Poly Synth', 90, chordCapable: true),
    ], chordCapable: true),
    // 웹 규칙 외 — 사용자 요청으로 유지.
    InstrumentFamily('오르간', [
      Instrument('O01', 'Organ 1', 16, chordCapable: true),
    ], chordCapable: true),
    InstrumentFamily('스트링', [
      Instrument('ST01', 'Strings CLP', 48, chordCapable: true),
    ], chordCapable: true),
  ],
  TrackRole.bass: [
    InstrumentFamily('베이스 기타', [
      Instrument('BG01', 'Fingered Bass', 33),
      Instrument('BG02', 'Acoustic Bass', 32), // 웹 규칙 외 — 유지
    ]),
    InstrumentFamily('신스 베이스', [
      Instrument('SB01', 'Synth Bass 2', 39),
    ]),
  ],
  TrackRole.drum: [
    // bank 128 드럼 키트(웹 규칙 prog ∈ {0,1,2,8,16,24,25,26,32,40} ∩ 실존).
    InstrumentFamily('드럼 키트', [
      Instrument('D01', 'Standard', 0),
      Instrument('D02', 'Room', 8),
      Instrument('D03', 'Power', 16),
      Instrument('D04', 'Electronic', 24),
      Instrument('D05', 'TR 808', 25),
      Instrument('D06', 'Jazz', 32),
      Instrument('D07', 'Brush', 40),
    ]),
  ],
  TrackRole.vocal: [],
};

/// 역할의 모든 프리셋을 평면화(패밀리 구분 없이).
List<Instrument> instrumentsForRole(TrackRole role) =>
    [for (final f in instrumentPalette[role] ?? const <InstrumentFamily>[]) ...f.instruments];

const Map<int, String> drumNames = {36: 'Kick', 38: 'Snare', 42: 'HiHat'};

const _pcNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

/// MIDI → 음이름 (예: 60 → C4).
String noteName(int midi) {
  final pc = ((midi % 12) + 12) % 12;
  return '${_pcNames[pc]}${(midi ~/ 12) - 1}';
}
