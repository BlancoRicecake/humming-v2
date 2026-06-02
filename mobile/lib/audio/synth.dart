// 온디바이스 SoundFont 합성 — flutter_midi_pro 래퍼 (6-3).
// 단음 미리듣기와 향후 트랙 재생(task #5)에서 공용으로 사용.
// 백엔드 /render_audio 의존 제거 — 200~500ms 네트워크 지연을 즉시 응답으로 대체.
//
// 자산: assets/sounds/TimGM6mb.sf2 (General MIDI 음원, 5.4MB).
// 채널 0 을 미리듣기 전용으로 사용 — 트랙 재생용 채널과 분리.
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_midi_pro/flutter_midi_pro.dart';

/// 싱글톤 합성 엔진. SoundFont 1회 로딩 후 재사용.
///
/// 사용 흐름:
///   await SynthEngine().ensureLoaded();          // 최초 1회 (lazy)
///   await SynthEngine().playNote(
///     channel: 0, pitch: 60, velocity: 100, program: 0,
///   );                                            // release 후 자동 stop
///   await SynthEngine().stopAll();               // 시트 닫힐 때 등
class SynthEngine {
  SynthEngine._();
  static final SynthEngine _instance = SynthEngine._();
  factory SynthEngine() => _instance;

  static const String _sfAsset = 'assets/sounds/TimGM6mb.sf2';

  final MidiPro _midi = MidiPro();
  int? _sfId;
  Future<int>? _loading;

  // 채널별로 마지막 select 된 program 캐시 — 같은 program 재선택 비용 절약.
  final Map<int, int> _channelProgram = <int, int>{};

  // 재생 중인 (channel, pitch) → 예약된 release 타이머. stopAll 시 모두 취소.
  final Map<int, Map<int, Timer>> _activeReleases = <int, Map<int, Timer>>{};

  bool get isLoaded => _sfId != null;

  /// SoundFont 자산을 1회 로드. 중복 호출은 동일 Future 공유.
  Future<int> ensureLoaded() {
    if (_sfId != null) return Future.value(_sfId);
    return _loading ??= _midi
        .loadSoundfontAsset(assetPath: _sfAsset, bank: 0, program: 0)
        .then((id) {
      _sfId = id;
      debugPrint('[synth] loaded soundfont sfId=$id');
      return id;
    }).catchError((Object e, StackTrace st) {
      _loading = null;
      debugPrint('[synth] load failed: $e');
      throw e;
    });
  }

  /// 채널에 GM program 선택 — 캐시 hit 시 no-op.
  Future<void> _ensureProgram(int sfId, int channel, int program) async {
    if (_channelProgram[channel] == program) return;
    await _midi.selectInstrument(
        sfId: sfId, channel: channel, bank: 0, program: program);
    _channelProgram[channel] = program;
  }

  /// 단음 재생. [release] 이후 자동으로 stopNote.
  /// 같은 (channel, pitch) 가 이미 울리고 있으면 먼저 정지.
  Future<void> playNote({
    int channel = 0,
    required int pitch,
    int velocity = 100,
    int program = 0,
    Duration release = const Duration(milliseconds: 600),
  }) async {
    final sfId = await ensureLoaded();
    await _ensureProgram(sfId, channel, program);

    // 동일 키 중첩 방지.
    _cancelRelease(channel, pitch);
    try {
      await _midi.stopNote(channel: channel, key: pitch, sfId: sfId);
    } catch (_) {/* 첫 재생이면 무시 */}

    await _midi.playNote(
        channel: channel, key: pitch, velocity: velocity, sfId: sfId);

    final timer = Timer(release, () async {
      try {
        await _midi.stopNote(channel: channel, key: pitch, sfId: sfId);
      } catch (_) {}
      _activeReleases[channel]?.remove(pitch);
    });
    (_activeReleases[channel] ??= <int, Timer>{})[pitch] = timer;
  }

  void _cancelRelease(int channel, int pitch) {
    final t = _activeReleases[channel]?.remove(pitch);
    t?.cancel();
  }

  // ─── 시퀀서용 저수준 API (task #5 트랙 재생) ─────────────────────────────
  // playNote 는 release 타이머로 자동 stop 하지만, 시퀀서는 noteOff 시각을 직접
  // 스케줄링하므로 명시적 on/off 가 필요. 채널 9 는 GM 드럼(bank 128) 로 라우팅.

  static const int drumChannel = 9;

  /// 드럼 채널(9)을 GM bank 128 / 지정 키트 program 으로 셋업.
  /// 캐시는 `1000+program`(멜로딕 0..127 과 비충돌)으로 같은 키트 재선택을 회피.
  Future<void> ensureDrumKit(int program) async {
    final sfId = await ensureLoaded();
    final marker = 1000 + program;
    if (_channelProgram[drumChannel] == marker) return;
    try {
      await _midi.selectInstrument(
          sfId: sfId, channel: drumChannel, bank: 128, program: program);
      _channelProgram[drumChannel] = marker;
    } catch (e) {
      debugPrint('[synth] drum select failed (kit=$program): $e');
    }
  }

  /// 하위호환 — 기본 Standard 키트(program 0).
  Future<void> ensureDrumChannel() => ensureDrumKit(0);

  /// 노트온. release 타이머 없음 — 호출자가 noteOff 책임.
  /// [program] 이 주어지면 멜로딕 채널의 악기를 설정한다(드럼 채널 무시).
  Future<void> noteOn({
    required int channel,
    required int pitch,
    int velocity = 100,
    int? program,
  }) async {
    final sfId = await ensureLoaded();
    if (channel == drumChannel) {
      // 키트 선택은 play() 프리앰블에서 1회 수행. 시퀀서 per-note noteOn 은 program 을
      // 넘기지 않으므로(null) 여기서 재선택하지 않아 선택된 키트를 유지한다.
      if (program != null) await ensureDrumKit(program);
    } else if (program != null) {
      await _ensureProgram(sfId, channel, program);
    }
    final v = velocity.clamp(1, 127);
    final p = pitch.clamp(0, 127);
    try {
      await _midi.playNote(channel: channel, key: p, velocity: v, sfId: sfId);
    } catch (e) {
      debugPrint('[synth] noteOn ch=$channel pitch=$p failed: $e');
    }
  }

  Future<void> noteOff({required int channel, required int pitch}) async {
    final sfId = _sfId;
    if (sfId == null) return;
    try {
      await _midi.stopNote(channel: channel, key: pitch.clamp(0, 127), sfId: sfId);
    } catch (_) {/* 이미 정지 */}
  }

  /// 모든 release 타이머 취소 + sfId 의 전 채널 음 정지.
  Future<void> stopAll() async {
    for (final m in _activeReleases.values) {
      for (final t in m.values) {
        t.cancel();
      }
      m.clear();
    }
    final sfId = _sfId;
    if (sfId == null) return;
    try {
      await _midi.stopAllNotes(sfId: sfId);
    } catch (_) {/* 로드 전이거나 plugin 미연결 — 무시 */}
  }
}
