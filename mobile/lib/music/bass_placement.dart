// 베이스 저음역 자동 배치 — 흥얼거린 베이스 라인을 적절한 저음역으로 옥타브 이동.
//
// 사람이 베이스를 흥얼거리면 대부분 자기 목소리 음역(멜로디와 같은 중음역)에서
// 녹음된다. 그대로 베이스 악기로 재생하면 멜로디와 주파수가 겹쳐(마스킹/머디) 베이스
// 답지 않게 들린다. 이 패스는 라인 전체를 **동일한 옥타브 수만큼** 통째로 내려(윤곽
// 보존) 저음역에 앉히고, 멜로디(keys) 최저음 아래로 일정 간격을 확보한다.
// 참고: "로우 인터벌 리미트 / 주파수 마스킹 / 옥타브 분리".
//
// 옥타브 이동(×12)은 pitch class 를 보존하므로 백엔드 in-key 보정·사용자 후보 편집과
// 충돌하지 않는다. 비파괴적: 결과는 clone 이며 원본 노트는 건드리지 않는다.
// 호출처: project_store.dart — `_recomputeBassPlacement`(시프트 계산) + `renderNotes`
// 게터(적용).
import 'dart:math' as math;
import '../models/models.dart';

// ── 튜닝 상수 (실기기 청취로 조정) ─────────────────────────────────────────
const int kBassCenter = 40; // E2 — 라인 무게중심 타겟
const int kBassFloor = 28; // E1 — 베이스 기타 최저음(이 아래로는 안 내림)
const int kBassCeil = 55; // G3 — 일반 베이스라인 실용 천장
const int kMinSeparation = 12; // 멜로디 최저음과의 최소 간격(반음) — 로우 인터벌 리미트

const int _kMaxOctaveShift = 4; // 후보 오프셋 범위 ±4 옥타브
const double _kCeilFloorPenalty = 2.0; // 레지스터 창 밖 노트 1개당 패널티
const double _kSeparationPenalty = 1000.0; // 멜로디와 겹침 — 강한 패널티

double _midiToHz(int m) => 440.0 * math.pow(2, (m - 69) / 12.0);

/// pitched 노트 pitch 의 중앙값(정수). pitched 노트가 없으면 null.
int? _pitchedMedian(List<Note> notes) {
  final pitches = [
    for (final n in notes)
      if (n.kind == 'pitched') n.pitch,
  ]..sort();
  if (pitches.isEmpty) return null;
  return pitches[pitches.length ~/ 2];
}

/// 라인 전체를 저음역에 앉히는 최적 옥타브 오프셋(정수, ×12반음)을 찾는다.
///
/// - pitched 노트가 없으면 0.
/// - 기준음 = pitched pitch 중앙값. 후보 k ∈ [-4, 4] 를 평가:
///   레지스터 적합도(중심 거리 + 창 밖 패널티) + 멜로디 분리 제약.
/// - 멜로디(keys) 최저음이 주어지면 `shiftedMax ≤ melodyLowPitch − kMinSeparation`
///   을 만족하도록 강하게 유도(불가하면 best-effort). 동점이면 |k| 작은 쪽.
int bestBassOctaveShift(List<Note> notes, {int? melodyLowPitch}) {
  final median = _pitchedMedian(notes);
  if (median == null) return 0;

  final pitched = [
    for (final n in notes)
      if (n.kind == 'pitched') n.pitch,
  ];

  int bestK = 0;
  double bestCost = double.infinity;
  for (int k = -_kMaxOctaveShift; k <= _kMaxOctaveShift; k++) {
    final shift = 12 * k;
    final shiftedMedian = median + shift;
    // 라인 전체가 베이스 최저음 아래로 내려가면 무의미 — 후보 제외.
    final shiftedMin = pitched.reduce(math.min) + shift;
    if (shiftedMin < kBassFloor - 12) continue;

    double cost = (shiftedMedian - kBassCenter).abs().toDouble();

    // 레지스터 창 [kBassFloor, kBassCeil] 밖 노트 소프트 패널티.
    for (final p in pitched) {
      final sp = p + shift;
      if (sp < kBassFloor || sp > kBassCeil) cost += _kCeilFloorPenalty;
    }

    // 멜로디 분리 제약 — 시프트된 최고음이 멜로디 최저음에 너무 가까우면 패널티.
    if (melodyLowPitch != null) {
      final shiftedMax = pitched.reduce(math.max) + shift;
      final ceiling = melodyLowPitch - kMinSeparation;
      if (shiftedMax > ceiling) {
        // 초과한 반음 수에 비례 — 분리를 최대화하는 방향으로 유도.
        cost += _kSeparationPenalty + (shiftedMax - ceiling);
      }
    }

    // 동점이면 |k| 작은 쪽(과도한 이동 방지).
    cost += k.abs() * 0.01;

    if (cost < bestCost) {
      bestCost = cost;
      bestK = k;
    }
  }
  return bestK;
}

/// 모든 pitched 노트를 `shift` 옥타브만큼 이동(×12반음). percussive 는 그대로.
/// `shift == 0` 이면 원본 그대로 반환(불필요한 clone 회피).
List<Note> applyOctaveShift(List<Note> notes, int shift) {
  if (shift == 0) return notes;
  final delta = 12 * shift;
  final out = <Note>[];
  for (final n in notes) {
    if (n.kind != 'pitched') {
      out.add(n);
      continue;
    }
    final p = (n.pitch + delta).clamp(0, 127);
    final cn = Note.fromJson(n.toJson())
      ..pitch = p
      ..pitchHz = _midiToHz(p)
      ..chunkId = n.chunkId; // toJson 은 chunkId 미포함 — 명시 복원.
    out.add(cn);
  }
  return out;
}
