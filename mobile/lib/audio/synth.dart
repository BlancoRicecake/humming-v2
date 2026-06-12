// 온디바이스 SoundFont 합성 — flutter_midi_pro 래퍼 (6-3).
// 단음 미리듣기와 향후 트랙 재생(task #5)에서 공용으로 사용.
// 백엔드 /render_audio 의존 제거 — 200~500ms 네트워크 지연을 즉시 응답으로 대체.
//
// 자산: assets/sounds/TimGM6mb.sf2 (General MIDI 음원, 5.4MB).
// 채널 0 을 미리듣기 전용으로 사용 — 트랙 재생용 채널과 분리.
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_midi_pro/flutter_midi_pro.dart';

import '../looptap/music/soundfont_catalog.dart';

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
  static const String _sf808Asset = 'assets/sounds/808.sf2';
  static const String _sfHipHopAsset = 'assets/sounds/hiphop_kit.sf2';

  /// Sentinel "program" meaning "play the 808 sub-bass soundfont" instead of a
  /// GM program. Out of GM range (0–127) so it never collides. Mirrors
  /// kProgram808 in looptap/music/instruments.dart.
  static const int program808 = 128;

  /// Sentinel "drum kit" meaning "play the bundled CC0 hip-hop kit soundfont"
  /// instead of a GM bank-128 kit. Mirrors kProgramHipHopKit in instruments.dart.
  static const int kitHipHop = 200;

  /// Dedicated channel for the metronome wood-block — kept OFF the drum channel
  /// so the click never disturbs the user's selected drum kit (ch9).
  static const int clickChannel = 15;

  final MidiPro _midi = MidiPro();
  int? _sfId;
  Future<int>? _loading;
  // The 808 sub-bass lives in a second soundfont (no GM slot for it).
  int? _sf808Id;
  Future<int>? _loading808;
  // The CC0 hip-hop drum kit lives in a third soundfont (not a GM kit).
  int? _sfHipHopId;
  Future<int>? _loadingHipHop;
  // Runtime catalog soundfonts (slot >= 1000) loaded from downloaded files,
  // keyed by slot. Each is its own loaded soundfont id.
  final Map<int, int> _slotSfId = <int, int>{};
  final Map<int, Future<int>?> _loadingSlot = <int, Future<int>?>{};

  // 채널별로 마지막 select 된 program 캐시 — 같은 program 재선택 비용 절약.
  final Map<int, int> _channelProgram = <int, int>{};
  // 채널이 현재 어느 soundfont(sfId)에 바인딩됐는지 — 808 채널은 _sf808Id 로
  // playNote/stopNote 해야 하므로 추적한다.
  final Map<int, int> _channelSf = <int, int>{};

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

  /// 808 sub-bass soundfont 1회 로드 (lazy). 중복 호출은 동일 Future 공유.
  Future<int> _ensure808() {
    if (_sf808Id != null) return Future.value(_sf808Id);
    return _loading808 ??= _midi
        .loadSoundfontAsset(assetPath: _sf808Asset, bank: 0, program: 0)
        .then((id) {
      _sf808Id = id;
      debugPrint('[synth] loaded 808 soundfont sfId=$id');
      return id;
    }).catchError((Object e, StackTrace st) {
      _loading808 = null;
      debugPrint('[synth] 808 load failed: $e');
      throw e;
    });
  }

  /// CC0 hip-hop kit soundfont 1회 로드 (lazy). 중복 호출은 동일 Future 공유.
  Future<int> _ensureHipHopKit() {
    if (_sfHipHopId != null) return Future.value(_sfHipHopId);
    return _loadingHipHop ??= _midi
        .loadSoundfontAsset(assetPath: _sfHipHopAsset, bank: 0, program: 0)
        .then((id) {
      _sfHipHopId = id;
      debugPrint('[synth] loaded hiphop kit sfId=$id');
      return id;
    }).catchError((Object e, StackTrace st) {
      _loadingHipHop = null;
      debugPrint('[synth] hiphop kit load failed: $e');
      throw e;
    });
  }

  /// 멜로딕 채널을 [program] 에 맞는 soundfont/instrument 로 바인딩하고, 그 채널이
  /// 써야 할 sfId 를 돌려준다. program == [program808] 이면 808 soundfont 로,
  /// 그 외 GM program 이면 메인 soundfont 로 라우팅. program == null 이면 기존
  /// 바인딩 유지(시퀀서 per-note 호출용).
  Future<int> _bindChannel(int channel, int? program) async {
    final mainId = await ensureLoaded();
    if (program == null) return _channelSf[channel] ?? mainId;
    if (program == program808) {
      final sf8 = await _ensure808();
      if (_channelProgram[channel] != program808) {
        await _midi.selectInstrument(sfId: sf8, channel: channel, bank: 0, program: 0);
        _channelProgram[channel] = program808;
      }
      _channelSf[channel] = sf8;
      return sf8;
    }
    if (isDynamicSlot(program)) {
      final bound = await _bindDynamic(channel, program);
      if (bound != null) return bound;
      // file not downloaded / load failed → fall back to grand piano so the
      // track still makes sound rather than going silent.
      await _ensureProgram(mainId, channel, 0);
      _channelSf[channel] = mainId;
      return mainId;
    }
    await _ensureProgram(mainId, channel, program);
    _channelSf[channel] = mainId;
    return mainId;
  }

  /// Bind a channel to a downloaded catalog soundfont (slot >= 1000). Returns
  /// its sfId, or null when the file isn't present yet / fails to load.
  Future<int?> _bindDynamic(int channel, int slot) async {
    final entry = SoundfontCatalog.instance.bySlot(slot);
    final path = SoundfontCatalog.instance.localPath(slot);
    if (entry == null || path == null) return null;
    int sfId;
    try {
      sfId = await (_loadingSlot[slot] ??= _midi
          .loadSoundfontFile(filePath: path, bank: entry.sfBank, program: entry.sfProgram)
          .then((id) {
        _slotSfId[slot] = id;
        return id;
      }).catchError((Object e) {
        _loadingSlot[slot] = null;
        throw e;
      }));
    } catch (e) {
      debugPrint('[synth] dynamic slot $slot load failed: $e');
      return null;
    }
    final marker = 100000 + slot; // distinct from GM (0-127) + drum (1000+prog)
    if (_channelProgram[channel] != marker) {
      await _midi.selectInstrument(
          sfId: sfId, channel: channel, bank: entry.sfBank, program: entry.sfProgram);
      _channelProgram[channel] = marker;
    }
    _channelSf[channel] = sfId;
    return sfId;
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
    final sfId = await _bindChannel(channel, program);

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
    final marker = 1000 + program;
    if (_channelProgram[drumChannel] == marker) return;
    // The hip-hop kit lives in its own soundfont; GM kits are bank 128 of the
    // main soundfont. Either way bind the drum channel's sfId so drum noteOn/Off
    // route to the right soundfont.
    final int sfId;
    final int bank;
    final int prog;
    if (program == kitHipHop) {
      sfId = await _ensureHipHopKit();
      bank = 128;
      prog = 0;
    } else if (isDynamicSlot(program)) {
      // A downloaded catalog drum kit. _bindDynamic owns the drum channel's
      // cache marker + sf binding; falls back to the GM standard kit when the
      // file isn't present yet.
      if (await _bindDynamic(drumChannel, program) != null) return;
      sfId = await ensureLoaded();
      bank = 128;
      prog = 0;
    } else {
      sfId = await ensureLoaded();
      bank = 128;
      prog = program;
    }
    try {
      await _midi.selectInstrument(sfId: sfId, channel: drumChannel, bank: bank, program: prog);
      _channelProgram[drumChannel] = marker;
      _channelSf[drumChannel] = sfId;
    } catch (e) {
      debugPrint('[synth] drum select failed (kit=$program): $e');
    }
  }

  /// 하위호환 — 기본 Standard 키트(program 0).
  Future<void> ensureDrumChannel() => ensureDrumKit(0);

  /// 메트로놈 클릭 — 드럼 채널(ch9)과 분리된 전용 채널에서 GM 우드블록(prog 115)을
  /// 멜로딕 노트로 울린다. 사용자가 고른 드럼 킷을 절대 건드리지 않는다.
  Future<void> playClick(bool accent) async {
    final pitch = accent ? 84 : 79;
    try {
      final sfId = await ensureLoaded();
      await _ensureProgram(sfId, clickChannel, 115); // GM Wood Block
      await _midi.playNote(channel: clickChannel, key: pitch, velocity: accent ? 100 : 66, sfId: sfId);
      Timer(const Duration(milliseconds: 110), () async {
        try {
          await _midi.stopNote(channel: clickChannel, key: pitch, sfId: sfId);
        } catch (_) {/* 이미 정지 */}
      });
    } catch (_) {/* 로드 전 무시 — 호출자가 fire-and-forget 이라 여기서 삼킨다 */}
  }

  /// 노트온. release 타이머 없음 — 호출자가 noteOff 책임.
  /// [program] 이 주어지면 멜로딕 채널의 악기를 설정한다(드럼 채널 무시).
  Future<void> noteOn({
    required int channel,
    required int pitch,
    int velocity = 100,
    int? program,
  }) async {
    final mainId = await ensureLoaded();
    int sfId = mainId;
    if (channel == drumChannel) {
      // 키트 선택은 play() 프리앰블에서 1회 수행. 시퀀서 per-note noteOn 은 program 을
      // 넘기지 않으므로(null) 여기서 재선택하지 않아 선택된 키트를 유지한다.
      if (program != null) await ensureDrumKit(program);
      // 선택된 키트가 별도 soundfont(힙합 등)일 수 있으니 그 sfId 로 발음한다.
      sfId = _channelSf[drumChannel] ?? mainId;
    } else {
      // 멜로딕 채널 — 808/GM soundfont 라우팅. program==null 이면 기존 바인딩 유지.
      sfId = await _bindChannel(channel, program);
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
    // 채널이 808 로 바인딩됐으면 그 sfId 로 stop 해야 음이 꺼진다.
    final sfId = _channelSf[channel] ?? _sfId;
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
    for (final id in {_sfId, _sf808Id, _sfHipHopId, ..._slotSfId.values}) {
      if (id == null) continue;
      try {
        await _midi.stopAllNotes(sfId: id);
      } catch (_) {/* 로드 전이거나 plugin 미연결 — 무시 */}
    }
  }
}
