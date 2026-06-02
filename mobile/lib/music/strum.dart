// 기타 스트럼 + 음 마무리(링아웃) 후처리 패스.
//
// 참고: "How I make MIDI guitars sound real" — 코드의 모든 음이 동시에 나면
// 가짜처럼 들린다. 줄을 시간차로 긁고(strum), 박자에 따라 업/다운스트로크로
// 시작 순서·세기·간격을 바꾸고, 음 끝은 딱 끊지 말고 자연 감쇠로 울려 퍼지게 한다.
//
// 이 패스는 **quantize 이후**(코드 onset 이 그리드에 정렬된 뒤) 적용해야 한다.
// 코드 확장(chords.dart `expandChords` / chord_expand.dart `expandToChord`) 단계에서
// start 를 어긋내면 quantize 가 다시 snap 해 스트럼이 사라지기 때문이다.
// → project_store.dart `effectiveRenderNotesFor` 의 맨 끝에서 호출.
import '../models/models.dart';

/// 스트럼/링아웃을 적용할 기타 GM program (클래식 24 · 어쿠스틱 25 · 일렉 27).
const Set<int> _kGuitarPrograms = {24, 25, 27};

bool isGuitarProgram(int program) => _kGuitarPrograms.contains(program);

// ── 튜닝 상수 (실기기 청취로 조정) ─────────────────────────────────────────
const double _kDownSpreadSec = 0.022; // 다운스트로크 줄 간 간격 (저→고)
const double _kUpSpreadSec = 0.016; // 업스트로크 줄 간 간격 (고→저, 더 촘촘)
const double _kUpStrokeGain = 0.85; // 업스트로크 약박 — 전체 세기 ↓
const double _kFirstStringAccent = 1.06; // 먼저 긁히는 줄 살짝 강조
const double _kRingOutSec = 0.18; // 음 끝 연장 — SF2 자연 감쇠가 들리도록
const double _kReleaseStaggerSec = 0.02; // noteOff 도 스트로크 순서로 엇갈림
const double _kSpreadDurFraction = 0.5; // 총 spread 를 노트 길이의 절반 이내로 clamp
const double _kEpsilon = 0.001; // start/end 동일 판정 허용 오차(초)

/// quantize 후 패스: 기타 코드 묶음을 스트럼(시간차 발음) + 링아웃 처리한다.
///
/// - 기타 program 이 아니면 그대로 반환(피아노/신스 코드는 블록 발음 유지).
/// - `(chunkId, start≈, end≈)` 가 같은 pitched 노트 2개 이상 = 코드 묶음.
/// - percussive/단음은 그대로 통과.
/// - 박자 그리드(8분음) 기준 강박=다운(저→고), 약박=업(고→저).
List<Note> applyGuitarStrum(List<Note> notes,
    {required int program, required int bpm}) {
  if (!isGuitarProgram(program) || notes.length < 2) return notes;

  final beatSec = bpm > 0 ? 60.0 / bpm : 60.0 / 90.0;
  final unitSec = beatSec / 2.0; // 8분음 — 강/약박 판정 단위

  // (chunkId, start, end) 로 코드 묶음 식별.
  final out = <Note>[];
  final consumed = List<bool>.filled(notes.length, false);

  for (var i = 0; i < notes.length; i++) {
    if (consumed[i]) continue;
    final base = notes[i];
    if (base.kind != 'pitched') {
      out.add(base);
      consumed[i] = true;
      continue;
    }

    // 같은 묶음(동일 chunkId·start·end)의 pitched 노트 수집.
    final group = <Note>[base];
    final groupIdx = <int>[i];
    for (var j = i + 1; j < notes.length; j++) {
      if (consumed[j]) continue;
      final m = notes[j];
      if (m.kind != 'pitched') continue;
      if (m.chunkId != base.chunkId) continue;
      if ((m.start - base.start).abs() > _kEpsilon) continue;
      if ((m.end - base.end).abs() > _kEpsilon) continue;
      group.add(m);
      groupIdx.add(j);
    }

    if (group.length < 2) {
      out.add(base); // 단음 — 그대로.
      consumed[i] = true;
      continue;
    }

    for (final k in groupIdx) {
      consumed[k] = true;
    }
    out.addAll(_strumChord(group, unitSec: unitSec));
  }

  return out;
}

/// 한 코드 묶음(동일 start/end)을 스트럼 + 링아웃 처리해 새 노트 리스트로 반환.
List<Note> _strumChord(List<Note> chord, {required double unitSec}) {
  final onset = chord.first.start;
  final dur = chord.first.end - chord.first.start;

  // 박자 그리드: onset 이 강박(짝수 8분음)이면 다운, 약박(홀수)이면 업.
  final idx = unitSec > 0 ? (onset / unitSec).round() : 0;
  final isDown = idx.isEven;

  // 스트로크 방향에 따라 줄 순서 정렬: 다운=저→고, 업=고→저.
  final ordered = [...chord]
    ..sort((a, b) => isDown ? a.pitch.compareTo(b.pitch) : b.pitch.compareTo(a.pitch));

  final spreadPer = isDown ? _kDownSpreadSec : _kUpSpreadSec;
  final n = ordered.length;
  // 총 spread 가 노트 길이의 절반을 넘지 않도록 clamp(짧은 코드 보호).
  final maxSpread = dur * _kSpreadDurFraction;
  final totalSpread = spreadPer * (n - 1);
  final scale = (totalSpread > maxSpread && totalSpread > 0)
      ? maxSpread / totalSpread
      : 1.0;
  final step = spreadPer * scale;
  final relStep = _kReleaseStaggerSec * scale;
  final strokeGain = isDown ? 1.0 : _kUpStrokeGain;

  final result = <Note>[];
  for (var s = 0; s < n; s++) {
    final src = ordered[s];
    final startOff = step * s;
    final endOff = _kRingOutSec + relStep * s;

    // 먼저 긁히는 줄 강조 + 스트로크 게인. 1..127 clamp.
    final accent = s == 0 ? _kFirstStringAccent : 1.0;
    final vel = (src.velocity * strokeGain * accent).round().clamp(1, 127);

    final cn = Note.fromJson(src.toJson())
      ..start = src.start + startOff
      ..end = src.end + endOff
      ..velocity = vel
      ..chunkId = src.chunkId; // toJson 은 chunkId 미포함 — 명시 복원.
    cn.duration = cn.end - cn.start;
    result.add(cn);
  }
  return result;
}

/// 코드 미리듣기(sheets.dart) 와 공유 — 한 코드의 pitch 별 발음 지연(초) 목록.
/// `pitches` 순서 그대로의 지연값을 돌려준다(정렬은 호출측 책임이 아님 →
/// 여기서 방향에 맞춰 재정렬한 (pitch, delaySec) 쌍을 반환).
List<({int pitch, int velocity, double delaySec})> strumPreviewSchedule(
  List<int> pitches,
  int baseVelocity, {
  required int bpm,
  double atSec = 0,
}) {
  if (pitches.isEmpty) return const [];
  final beatSec = bpm > 0 ? 60.0 / bpm : 60.0 / 90.0;
  final unitSec = beatSec / 2.0;
  final idx = unitSec > 0 ? (atSec / unitSec).round() : 0;
  final isDown = idx.isEven;

  final ordered = [...pitches]
    ..sort((a, b) => isDown ? a.compareTo(b) : b.compareTo(a));
  final spreadPer = isDown ? _kDownSpreadSec : _kUpSpreadSec;
  final strokeGain = isDown ? 1.0 : _kUpStrokeGain;

  final out = <({int pitch, int velocity, double delaySec})>[];
  for (var s = 0; s < ordered.length; s++) {
    final accent = s == 0 ? _kFirstStringAccent : 1.0;
    final vel = (baseVelocity * strokeGain * accent).round().clamp(1, 127);
    out.add((pitch: ordered[s], velocity: vel, delaySec: spreadPer * s));
  }
  return out;
}
