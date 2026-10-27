// 온디바이스 SoundFont 합성 — flutter_midi_pro 래퍼 (6-3).
// 단음 미리듣기와 향후 트랙 재생(task #5)에서 공용으로 사용.
// 백엔드 /render_audio 의존 제거 — 200~500ms 네트워크 지연을 즉시 응답으로 대체.
//
// 자산(메인 GM): assets/sounds/GeneralUser-GS.sf2 (~31MB). Android 은 이 파일을
// flutter_midi_pro(FluidSynth)로, iOS 는 MeltyEngine 이 같은 파일을 로드 — 동일 음색.
// 채널 0 을 미리듣기 전용으로 사용 — 트랙 재생용 채널과 분리.
import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter_midi_pro/flutter_midi_pro.dart';

import '../looptap/music/soundfont_catalog.dart';
import 'melty_synth_backend.dart';

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

  // GM soundfont for the flutter_midi_pro path (Android only — iOS routes through
  // MeltyEngine, which loads the SAME GeneralUser-GS, so both platforms match).
  static const String _sfAsset = 'assets/sounds/GeneralUser-GS.sf2';
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

  MidiPro _midi = MidiPro();

  // iOS routes through MeltySynth instead of flutter_midi_pro's AVAudioUnitSampler
  // (which could not reliably select instruments — everything fell back to piano).
  // Android keeps flutter_midi_pro/FluidSynth. Each public method below forwards
  // to [_melty] when [_useMelty] is set; the flutter_midi_pro code runs otherwise.
  static final bool _platformMelty =
      Platform.isIOS || Platform.isWindows || Platform.isMacOS;
  bool _useMelty = _platformMelty;

  /// Test hook: drive the flutter_midi_pro (Android) path with [midi], or
  /// restore the platform engine with null. Resets the engine's caches.
  @visibleForTesting
  void debugUseMidiPro(MidiPro? midi, {int? loadedSfId}) {
    _useMelty = midi == null ? _platformMelty : false;
    _midi = midi ?? MidiPro();
    _sfId = midi == null ? null : loadedSfId;
    _loading = null;
    _channelProgram.clear();
    _channelSf.clear();
    _sounding.clear();
    _channelPan.clear();
    _channelEpoch.clear();
    _resetting.clear();
    _roleGen.clear();
  }

  // gt-003: a channel-role reset still talking to the plugin. Every later
  // call on that channel waits for it, so no stale stopNote/CC of the old
  // role can land after the new role's set-up or notes.
  final Map<int, Future<void>> _resetting = <int, Future<void>>{};

  // gt-003: role generation per channel, bumped only by releaseChannel. An
  // awaited soundfont/kit set-up that a role switch overtook commits
  // nothing (no program, no binding, no voice).
  final Map<int, int> _roleGen = <int, int>{};
  bool _roleChanged(int channel, int gen) => (_roleGen[channel] ?? 0) != gen;

  Future<void> _afterReset(int channel) async {
    final pending = _resetting[channel];
    if (pending != null) await pending;
  }
  final MeltyEngine _melty = MeltyEngine();
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
  // Notes currently sounding per channel (playNote/noteOn without a matching
  // stop yet). Needed so a channel re-bound to a DIFFERENT soundfont can
  // release its old voices on the old sfId — flutter_midi_pro has no
  // per-channel all-notes-off, and a noteOff sent to the new sfId would leave
  // them ringing forever (audit A9).
  final Map<int, Set<int>> _sounding = <int, Set<int>>{};

  // mixer-001: last CC10 (pan) per channel, re-sent when the channel is bound
  // to a different soundfont (each sfId is its own synth instance).
  final Map<int, int> _channelPan = <int, int>{};

  // 재생 중인 (channel, pitch) → 예약된 release 타이머. stopAll 시 모두 취소.
  final Map<int, int> _channelEpoch = {};
  final Map<int, Map<int, Timer>> _activeReleases = <int, Map<int, Timer>>{};

  bool get isLoaded => _useMelty ? _melty.isLoaded : _sfId != null;

  /// SoundFont 자산을 1회 로드. 중복 호출은 동일 Future 공유.
  Future<int> ensureLoaded() {
    if (_useMelty) return _melty.ensureLoaded().then((_) => 0);
    if (_sfId != null) return Future.value(_sfId);
    return _loading ??= _midi
        .loadSoundfontAsset(assetPath: _sfAsset, bank: 0, program: 0)
        .then((id) {
          _sfId = id;
          debugPrint('[synth] loaded soundfont sfId=$id');
          return id;
        })
        .catchError((Object e, StackTrace st) {
          _loading = null;
          debugPrint('[synth] load failed: $e');
          throw e;
        });
  }

  /// iOS: rebuild MeltyEngine's PCM output pipe under the current audio session
  /// (see MeltyEngine.rebuildOutput). Call at recording start/stop boundaries so
  /// the synth output survives the AVAudioSession category flip that recording
  /// forces. No-op on Android — its output stream is independent of recording.
  Future<void> rebuildOutput({required bool forRecording}) async {
    if (_useMelty) await _melty.rebuildOutput(forRecording: forRecording);
  }

  /// Point [channel] at soundfont [sfId]; when that's a different soundfont
  /// than before, stop every note still sounding on the previous one first.
  Future<void> _bindSf(int channel, int sfId) async {
    final prev = _channelSf[channel];
    if (prev != null && prev != sfId) {
      final notes = _sounding.remove(channel);
      if (notes != null) {
        for (final pitch in notes) {
          try {
            await _midi.stopNote(channel: channel, key: pitch, sfId: prev);
          } catch (_) {
            /* already silent */
          }
        }
      }
    }
    _channelSf[channel] = sfId;
    final pan = _channelPan[channel];
    if (pan != null && prev != sfId) {
      try {
        await _midi.controlChange(
          controller: 10,
          value: pan,
          channel: channel,
          sfId: sfId,
        );
      } catch (_) {
        /* plugin not ready — re-sent on the next bind / setPan */
      }
    }
  }

  void _markSounding(int channel, int pitch) =>
      (_sounding[channel] ??= <int>{}).add(pitch);

  void _markSilent(int channel, int pitch) => _sounding[channel]?.remove(pitch);

  /// 채널에 GM program 선택 — 캐시 hit 시 no-op.
  Future<void> _ensureProgram(int sfId, int channel, int program) async {
    if (_channelProgram[channel] == program) return;
    await _midi.selectInstrument(
      sfId: sfId,
      channel: channel,
      bank: 0,
      program: program,
    );
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
        })
        .catchError((Object e, StackTrace st) {
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
        })
        .catchError((Object e, StackTrace st) {
          _loadingHipHop = null;
          debugPrint('[synth] hiphop kit load failed: $e');
          throw e;
        });
  }

  /// 멜로딕 채널을 [program] 에 맞는 soundfont/instrument 로 바인딩하고, 그 채널이
  /// 써야 할 sfId 를 돌려준다. program == [program808] 이면 808 soundfont 로,
  /// 그 외 GM program 이면 메인 soundfont 로 라우팅. program == null 이면 기존
  /// 바인딩 유지(시퀀서 per-note 호출용).
  Future<int?> _bindChannel(int channel, int? program) async {
    final gen = _roleGen[channel] ?? 0;
    final mainId = await ensureLoaded();
    if (_roleChanged(channel, gen)) return null;
    if (program == null) return _channelSf[channel] ?? mainId;
    if (program == program808) {
      final sf8 = await _ensure808();
      if (_roleChanged(channel, gen)) return null;
      if (_channelProgram[channel] != program808) {
        await _midi.selectInstrument(
          sfId: sf8,
          channel: channel,
          bank: 0,
          program: 0,
        );
        _channelProgram[channel] = program808;
      }
      await _bindSf(channel, sf8);
      return sf8;
    }
    if (isDynamicSlot(program)) {
      final bound = await _bindDynamic(channel, program);
      if (_roleChanged(channel, gen)) return null;
      if (bound != null) return bound;
      // file not downloaded / load failed → fall back to grand piano so the
      // track still makes sound rather than going silent.
      await _ensureProgram(mainId, channel, 0);
      await _bindSf(channel, mainId);
      return mainId;
    }
    await _ensureProgram(mainId, channel, program);
    await _bindSf(channel, mainId);
    return mainId;
  }

  /// Bind a channel to a downloaded catalog soundfont (slot >= 1000). Returns
  /// its sfId, or null when the file isn't present yet / fails to load.
  Future<int?> _bindDynamic(int channel, int slot) async {
    final gen = _roleGen[channel] ?? 0;
    final entry = SoundfontCatalog.instance.bySlot(slot);
    final path = SoundfontCatalog.instance.localPath(slot);
    if (entry == null || path == null) return null;
    int sfId;
    try {
      sfId =
          await (_loadingSlot[slot] ??= _midi
              .loadSoundfontFile(
                filePath: path,
                bank: entry.sfBank,
                program: entry.sfProgram,
              )
              .then((id) {
                _slotSfId[slot] = id;
                return id;
              })
              .catchError((Object e) {
                _loadingSlot[slot] = null;
                throw e;
              }));
    } catch (e) {
      debugPrint('[synth] dynamic slot $slot load failed: $e');
      return null;
    }
    if (_roleChanged(channel, gen)) return null;
    final marker = 100000 + slot; // distinct from GM (0-127) + drum (1000+prog)
    if (_channelProgram[channel] != marker) {
      await _midi.selectInstrument(
        sfId: sfId,
        channel: channel,
        bank: entry.sfBank,
        program: entry.sfProgram,
      );
      _channelProgram[channel] = marker;
    }
    await _bindSf(channel, sfId);
    return sfId;
  }

  /// MIDI control change on [channel] (e.g. CC10 pan, mixer-001). Android sends
  /// it to the soundfont the channel is bound to; iOS/desktop go to MeltyEngine.
  /// CC10 is remembered and re-sent when the channel moves to another
  /// soundfont.
  Future<void> controlChange(int channel, int controller, int value) async {
    final v = value.clamp(0, 127);
    if (_useMelty) {
      _melty.controlChange(channel, controller, v);
      return;
    }
    if (controller == 10) _channelPan[channel] = v;
    await _afterReset(channel);
    final sfId = _channelSf[channel] ?? _sfId;
    if (sfId == null) return; // re-sent on the first bind after load
    try {
      await _midi.controlChange(
        controller: controller,
        value: v,
        channel: channel,
        sfId: sfId,
      );
    } catch (e) {
      debugPrint('[synth] controlChange ch=$channel cc=$controller failed: $e');
    }
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
    if (_useMelty) {
      return _melty.playNote(
        channel: channel,
        pitch: pitch,
        velocity: velocity,
        program: program,
        release: release,
      );
    }
    final epoch = _channelEpoch[channel] ?? 0;
    await _afterReset(channel);
    final sfId = await _bindChannel(channel, program);
    if (sfId == null) return; // the channel changed role meanwhile

    // 동일 키 중첩 방지.
    _cancelRelease(channel, pitch);
    try {
      await _midi.stopNote(channel: channel, key: pitch, sfId: sfId);
    } catch (_) {
      /* 첫 재생이면 무시 */
    }

    if ((_channelEpoch[channel] ?? 0) != epoch) return;
    await _midi.playNote(
      channel: channel,
      key: pitch,
      velocity: velocity,
      sfId: sfId,
    );
    _markSounding(channel, pitch);

    final timer = Timer(release, () async {
      try {
        await _midi.stopNote(channel: channel, key: pitch, sfId: sfId);
      } catch (_) {}
      _markSilent(channel, pitch);
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

  /// [channel] 을 GM bank 128 / 지정 키트 program 으로 셋업. ch9(기본 드럼) 뿐
  /// 아니라 추가 드럼 트랙의 전용 채널에도 쓴다 — FluidSynth/AVAudioUnitSampler
  /// 모두 임의 채널에서 bank-128 킷을 재생하므로, 트랙마다 다른 킷을 동시에 울릴
  /// 수 있다. 캐시는 `_channelProgram[channel]` 의 `1000+program` 마커로 같은
  /// 킷 재선택을 회피.
  Future<void> ensureDrumKitOn(int channel, int program) async {
    if (_useMelty) return _melty.ensureDrumKitOn(channel, program);
    final gen = _roleGen[channel] ?? 0;
    await _afterReset(channel);
    if (_roleChanged(channel, gen)) return;
    final marker = 1000 + program;
    if (_channelProgram[channel] == marker) return;
    // The hip-hop kit lives in its own soundfont; GM kits are bank 128 of the
    // main soundfont. Either way bind the channel's sfId so drum noteOn/Off
    // route to the right soundfont.
    final int sfId;
    final int bank;
    final int prog;
    if (program == kitHipHop) {
      sfId = await _ensureHipHopKit();
      bank = 128;
      prog = 0;
    } else if (isDynamicSlot(program)) {
      // A downloaded catalog drum kit. _bindDynamic owns the channel's cache
      // marker + sf binding; falls back to the GM standard kit when the file
      // isn't present yet.
      if (await _bindDynamic(channel, program) != null) return;
      if (_roleChanged(channel, gen)) return;
      sfId = await ensureLoaded();
      bank = 128;
      prog = 0;
    } else {
      sfId = await ensureLoaded();
      bank = 128;
      prog = program;
    }
    if (_roleChanged(channel, gen)) return;
    try {
      await _midi.selectInstrument(
        sfId: sfId,
        channel: channel,
        bank: bank,
        program: prog,
      );
      _channelProgram[channel] = marker;
      await _bindSf(channel, sfId);
    } catch (e) {
      debugPrint('[synth] drum select failed (ch=$channel kit=$program): $e');
    }
  }

  /// 기본 드럼 채널(9) 셋업.
  Future<void> ensureDrumKit(int program) =>
      ensureDrumKitOn(drumChannel, program);

  /// 하위호환 — 기본 Standard 키트(program 0).
  Future<void> ensureDrumChannel() => ensureDrumKit(0);

  /// 메트로놈 클릭 — 드럼 채널(ch9)과 분리된 전용 채널에서 GM 우드블록(prog 115)을
  /// 멜로딕 노트로 울린다. 사용자가 고른 드럼 킷을 절대 건드리지 않는다.
  Future<void> playClick(bool accent) async {
    if (_useMelty) return _melty.playClick(accent);
    final pitch = accent ? 84 : 79;
    try {
      final sfId = await ensureLoaded();
      await _ensureProgram(sfId, clickChannel, 115); // GM Wood Block
      await _midi.playNote(
        channel: clickChannel,
        key: pitch,
        velocity: accent ? 100 : 66,
        sfId: sfId,
      );
      Timer(const Duration(milliseconds: 110), () async {
        try {
          await _midi.stopNote(channel: clickChannel, key: pitch, sfId: sfId);
        } catch (_) {
          /* 이미 정지 */
        }
      });
    } catch (_) {
      /* 로드 전 무시 — 호출자가 fire-and-forget 이라 여기서 삼킨다 */
    }
  }

  /// 노트온. release 타이머 없음 — 호출자가 noteOff 책임.
  /// [program] 이 주어지면 멜로딕 채널의 악기를 설정한다(드럼 채널 무시).
  Future<void> noteOn({
    required int channel,
    required int pitch,
    int velocity = 100,
    int? program,
  }) async {
    if (_useMelty) {
      return _melty.noteOn(
        channel: channel,
        pitch: pitch,
        velocity: velocity,
        program: program,
      );
    }
    final epoch = _channelEpoch[channel] ?? 0;
    final gen = _roleGen[channel] ?? 0;
    await _afterReset(channel);
    final mainId = await ensureLoaded();
    if (_roleChanged(channel, gen)) return;
    int sfId = mainId;
    if (channel == drumChannel) {
      // 키트 선택은 play() 프리앰블에서 1회 수행. 시퀀서 per-note noteOn 은 program 을
      // 넘기지 않으므로(null) 여기서 재선택하지 않아 선택된 키트를 유지한다.
      if (program != null) await ensureDrumKit(program);
      // 선택된 키트가 별도 soundfont(힙합 등)일 수 있으니 그 sfId 로 발음한다.
      sfId = _channelSf[drumChannel] ?? mainId;
    } else {
      // 멜로딕 채널 — 808/GM soundfont 라우팅. program==null 이면 기존 바인딩 유지.
      final bound = await _bindChannel(channel, program);
      if (bound == null) return;
      sfId = bound;
    }
    if ((_channelEpoch[channel] ?? 0) != epoch) return;
    final v = velocity.clamp(1, 127);
    final p = pitch.clamp(0, 127);
    try {
      await _midi.playNote(channel: channel, key: p, velocity: v, sfId: sfId);
      _markSounding(channel, p);
    } catch (e) {
      debugPrint('[synth] noteOn ch=$channel pitch=$p failed: $e');
    }
  }

  Future<void> noteOff({required int channel, required int pitch}) async {
    if (_useMelty) return _melty.noteOff(channel: channel, pitch: pitch);
    // 채널이 808 로 바인딩됐으면 그 sfId 로 stop 해야 음이 꺼진다.
    final sfId = _channelSf[channel] ?? _sfId;
    if (sfId == null) return;
    final p = pitch.clamp(0, 127);
    _markSilent(channel, p);
    try {
      await _midi.stopNote(channel: channel, key: p, sfId: sfId);
    } catch (_) {
      /* 이미 정지 */
    }
  }

  /// gt-003 channel-role switch: forget everything [channel] carried for its
  /// previous role (kit/program cache, soundfont binding, pan) and stop its
  /// voices, so a channel that was a drum track, an articulation voice or
  /// another track's channel is set up from scratch by its next note.
  Future<void> releaseChannel(int channel) {
    _channelEpoch[channel] = (_channelEpoch[channel] ?? 0) + 1;
    _roleGen[channel] = (_roleGen[channel] ?? 0) + 1;
    if (_useMelty) {
      _melty.releaseChannel(channel);
      return Future<void>.value();
    }
    for (final timer in _activeReleases.remove(channel)?.values ?? <Timer>[]) {
      timer.cancel();
    }
    // the old role's state is captured and cleared synchronously; only the
    // plugin calls below are asynchronous, and they are chained after any
    // earlier reset of this channel
    final sfId = _channelSf.remove(channel) ?? _sfId;
    final pitches = _sounding.remove(channel) ?? <int>{};
    _channelProgram.remove(channel);
    _channelPan.remove(channel);
    final previous = _resetting[channel];
    final done = () async {
      if (previous != null) await previous;
      await _resetOnPlugin(channel, sfId, pitches);
    }();
    _resetting[channel] = done;
    return done.whenComplete(() {
      if (identical(_resetting[channel], done)) _resetting.remove(channel);
    });
  }

  Future<void> _resetOnPlugin(int channel, int? sfId, Set<int> pitches) async {
    if (sfId == null) return;
    for (final pitch in pitches) {
      try {
        await _midi.stopNote(channel: channel, key: pitch, sfId: sfId);
      } catch (_) {
        /* already stopped */
      }
    }
    try {
      // reset all controllers (volume 100, pan centre) on the old binding
      await _midi.controlChange(
        controller: 121,
        value: 0,
        channel: channel,
        sfId: sfId,
      );
    } catch (_) {
      /* plugin not ready */
    }
  }

  /// Stop only this track, including its pending note-release timers.
  Future<void> stopChannel(int channel) async {
    _channelEpoch[channel] = (_channelEpoch[channel] ?? 0) + 1;
    if (_useMelty) return _melty.stopChannel(channel);
    for (final timer in _activeReleases.remove(channel)?.values ?? <Timer>[]) {
      timer.cancel();
    }
    final pitches = _sounding.remove(channel) ?? <int>{};
    final sfId = _channelSf[channel] ?? _sfId;
    if (sfId == null) return;
    for (final pitch in pitches) {
      try {
        await _midi.stopNote(channel: channel, key: pitch, sfId: sfId);
      } catch (_) {
        /* already stopped */
      }
    }
  }

  /// 모든 release 타이머 취소 + sfId 의 전 채널 음 정지.
  Future<void> stopAll() async {
    for (var ch = 0; ch < 16; ch++) {
      _channelEpoch[ch] = (_channelEpoch[ch] ?? 0) + 1;
    }
    if (_useMelty) return _melty.stopAll();
    for (final m in _activeReleases.values) {
      for (final t in m.values) {
        t.cancel();
      }
      m.clear();
    }
    _sounding.clear();
    for (final id in {_sfId, _sf808Id, _sfHipHopId, ..._slotSfId.values}) {
      if (id == null) continue;
      try {
        await _midi.stopAllNotes(sfId: id);
      } catch (_) {
        /* 로드 전이거나 plugin 미연결 — 무시 */
      }
    }
  }
}
