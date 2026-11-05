// LoopTap audio — thin layer over the existing SynthEngine (flutter_midi_pro + SF2).
// README says: swap the prototype's WebAudio for the platform stack but keep the
// data model + timing math. We map LoopTap voices onto GM instruments:
//   melody -> ch0 acoustic grand (prog 0)
//   bass   -> ch1 fingered bass  (prog 33)   (matches export.jsx MIDI ch1=33)
//   drums  -> ch9 GM kit; kick=36 snare=38 hihat=42 (matches export.jsx DRUM_NOTE)
//   click  -> ch9 wood block (accent=76 / normal=77)
import 'dart:async';
import 'dart:io' show File, FileSystemEntityType;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;

import '../../audio/synth.dart';
import '../music/pan.dart';
import '../music/percussion.dart';

/// GM drum note numbers per kind. Main kit (kick/snare/hihat) + the beat-fill
/// launchpad percussion (everything else) — both route to a GM bank-128 kit.
/// MIRROR: keep in sync with `_drumNote` (midi_export.dart) and `kDrumSpecs`
/// (drum_surface.dart). See [drum_mirror_test].
const Map<String, int> kDrumNote = {
  'kick': 36,
  'snare': 38,
  'hihat': 42,
  'shaker': 82,
  'tambourine': 54,
  'clap': 39,
  'cowbell': 56,
  'maracas': 70,
  'claves': 75,
  'rimshot': 37,
  'woodhi': 76,
  'woodlo': 77,
  'ride': 51,
  'crash': 57,
  'triangle': 81,
};

class LoopAudio {
  LoopAudio._();
  static final LoopAudio instance = LoopAudio._();

  final SynthEngine _engine = SynthEngine();
  bool _ready = false;

  // Current GM program per pitched channel — set per-song via [setPrograms].
  // ch0 melody, ch1 bass, ch2 melody-fill (see kTracks in theory.dart).
  final Map<int, int> _programs = {0: 0, 1: 33, 2: 48};

  /// The default (base drums + beat-fill) percussion channel.
  static const int drumChannel = SynthEngine.drumChannel;

  /// The metronome channel (never panned).
  static const int clickChannel = SynthEngine.clickChannel;

  // Per-channel drum kit (channel -> GM bank-128 program / hip-hop / catalog
  // slot). ch9 is the base drums+beat-fill kit; added drum tracks each have
  // their own channel + kit. Re-asserted in prewarm so the metronome/count-in
  // can't leave any of them wrong.
  final Map<int, int> _drumKits = {drumChannel: 0};

  /// Choose the drum kit for a specific channel (base drums use [drumChannel];
  /// added drum tracks use their allocated channel).
  Future<void> setDrumKitOn(int channel, int program) async {
    _drumKits[channel] = program;
    if (!_ready) return;
    try {
      await _engine.ensureDrumKitOn(channel, program);
    } catch (_) {
      /* graceful */
    }
  }

  /// Base drum channel convenience.
  Future<void> setDrumKit(int program) => setDrumKitOn(drumChannel, program);

  // mixer-001: per-channel pan (p in [-1, 1]) sent to the synth as CC10.
  // Re-asserted in prewarm; the engines re-send it themselves when a channel
  // moves to another soundfont.
  final Map<int, double> _pans = {};

  /// Current pan of [channel] (0 = centre).
  double panOf(int channel) => _pans[channel] ?? 0;

  /// Pan [channel] to [p] (-1 left … 1 right). The metronome channel stays
  /// centred.
  Future<void> setPan(int channel, double p) async {
    if (channel == clickChannel) return;
    final v = clampPan(p);
    final changed = (_pans[channel] ?? 0) != v;
    _pans[channel] = v;
    if (!_ready || !changed) return;
    try {
      await _engine.controlChange(channel, 10, panToCc(v));
    } catch (_) {
      /* graceful */
    }
  }

  /// Switch a channel's instrument (GM program). Pre-selects the new program
  /// with a silent note so the next audible note doesn't stall on the swap.
  Future<void> setProgram(int channel, int program) async {
    _programs[channel] = program;
    if (!_ready) return;
    try {
      await _engine.noteOn(
        channel: channel,
        pitch: 60,
        velocity: 1,
        program: program,
      );
      await _engine.noteOff(channel: channel, pitch: 60);
    } catch (_) {
      /* graceful */
    }
  }

  /// Set several channels' programs at once (channel -> GM program).
  Future<void> setPrograms(Map<int, int> byChannel) async {
    for (final e in byChannel.entries) {
      await setProgram(e.key, e.value);
    }
  }

  /// Load the SoundFont once (lazy — safe to call on first user gesture).
  Future<void> ensure() async {
    if (_ready) return;
    try {
      await _engine.ensureLoaded();
      _ready = true;
    } catch (_) {
      /* graceful: stays silent if the SF2 can't load */
    }
  }

  /// Pre-load + pre-select instruments so the FIRST tap doesn't stall on
  /// soundfont load / program select. Call once when the editor opens.
  Future<void> prewarm() async {
    await ensure();
    if (!_ready) return;
    try {
      // re-assert every drum channel's kit (base ch9 + any added drum tracks)
      for (final e in _drumKits.entries) {
        await _engine.ensureDrumKitOn(e.key, e.value);
      }
      // re-assert every channel's pan (set before the synth was ready)
      for (final e in _pans.entries) {
        await _engine.controlChange(e.key, 10, panToCc(e.value));
      }
      // pre-select every pitched channel's program (silent notes) so the first
      // live note on each voice is instant.
      for (final e in _programs.entries) {
        await _engine.noteOn(
          channel: e.key,
          pitch: 60,
          velocity: 1,
          program: e.value,
        );
        await _engine.noteOff(channel: e.key, pitch: 60);
      }
    } catch (_) {
      /* graceful */
    }
  }

  int _vel(double vol) => noteVelocity(null, vol);

  // Held live notes — sound lasts exactly as long as the pad is pressed, so the
  // duration the user HEARS matches the note that gets recorded (item 3).
  final Map<int, Timer> _liveTimers = {};
  final Map<int, int> _liveGeneration = {};
  final Map<int, int> _channelEpoch = {};

  // gt-003: what each pooled channel currently serves (e.g. 'drums:<id>',
  // 'pitched:<id>', 'art:<id>:muteVoice', 'free'). A change of role clears
  // every cache of the old role (see [releaseChannel]).
  final Map<int, String> _roles = {};

  /// The role [channel] was last assigned (null = never assigned).
  @visibleForTesting
  String? roleOf(int channel) => _roles[channel];

  /// Assign [role] to [channel]. When it differs from the channel's previous
  /// role — or the channel carries state from an unknown earlier use (a
  /// drum kit, program or pan) — the channel is released first and true is
  /// returned: the caller must set the new role up (kit, program, pan).
  bool assignChannelRole(int channel, String role) {
    final prev = _roles[channel];
    if (prev == role) return false;
    _roles[channel] = role;
    final stale =
        prev != null ||
        (channel != drumChannel && _drumKits.containsKey(channel)) ||
        (!_baseChannels.contains(channel) && _programs.containsKey(channel)) ||
        _pans.containsKey(channel);
    if (stale) releaseChannel(channel);
    return true;
  }

  static const Set<int> _baseChannels = {0, 1, 2};

  /// Forget [channel]'s kit, program and pan here and in the engine, and cut
  /// its voices (pending ones included). Base channels keep their default
  /// program; ch9 stays the base drum channel.
  void releaseChannel(int channel) {
    _channelEpoch[channel] = (_channelEpoch[channel] ?? 0) + 1;
    for (final key
        in _liveTimers.keys.where((k) => k ~/ 1000 == channel).toList()) {
      _liveTimers.remove(key)?.cancel();
    }
    if (channel != drumChannel) _drumKits.remove(channel);
    if (!_baseChannels.contains(channel)) _programs.remove(channel);
    _pans.remove(channel);
    debugOnRelease?.call(channel);
    _engine.releaseChannel(channel);
  }

  /// Test hook: every [releaseChannel].
  @visibleForTesting
  void Function(int channel)? debugOnRelease;

  /// Test hook: every [playArticulation] call (channel, program, key,
  /// velocity, vol, gate seconds).
  @visibleForTesting
  void Function(
    int channel,
    int program,
    int key,
    int? velocity,
    double vol,
    double durSec,
  )?
  debugOnArticulation;

  /// gt-003: one articulation voice (palm tone GM 28 / harmonic tone GM 31)
  /// on its articulation [channel]. The program is set with the note (before
  /// it sounds) on the GM font; the track channel is never touched. Volume
  /// uses exactly the track rule ([noteVelocity] with the track's [vol]); the
  /// channel's CC7 stays at its reset value like the track channel's.
  /// While the GM font is still loading the note plays as normal on the
  /// track channel instead ([trackChannel] / [soundingMidi] /
  /// [trackProgram]); both paths respect Stop through the channel epochs.
  void playArticulation({
    required int channel,
    required int program,
    required int key,
    required int trackChannel,
    required int soundingMidi,
    int? trackProgram,
    double vol = 0.85,
    double durSec = 0.4,
    int? velocity,
  }) {
    debugOnArticulation?.call(channel, program, key, velocity, vol, durSec);
    if (velocity != null && vol <= 0) return;
    final rel = Duration(
      microseconds: (durSec * 1000000).round().clamp(1000, 3600000000),
    );
    if (!_ready) {
      // GM font not ready: the normal voice, never a queued tone voice
      final prog = trackProgram ?? _programs[trackChannel] ?? 0;
      final epoch = _channelEpoch[trackChannel] ?? 0;
      ensure().then((_) {
        if (!_ready || (_channelEpoch[trackChannel] ?? 0) != epoch) return;
        _engine.playNote(
          channel: trackChannel,
          pitch: soundingMidi,
          velocity: noteVelocity(velocity, vol),
          program: prog,
          release: rel,
        );
      });
      return;
    }
    // same key on one articulation channel: the earlier note ends at this
    // onset (G2 rule, as in the export), then the new note sounds
    _engine.noteOff(channel: channel, pitch: key);
    _engine.playNote(
      channel: channel,
      pitch: key,
      velocity: noteVelocity(velocity, vol),
      program: program,
      release: rel,
    );
  }

  /// Test hook: every [stopChannel].
  @visibleForTesting
  void Function(int channel)? debugOnStopChannel;

  /// Test hooks: channels with a remembered drum kit / program / pan, and
  /// forgetting the loaded state (so a test can drive the cold path).
  @visibleForTesting
  Set<int> get debugDrumKitChannels => _drumKits.keys.toSet();
  @visibleForTesting
  Set<int> get debugProgramChannels => _programs.keys.toSet();
  @visibleForTesting
  void debugResetReady() => _ready = false;

  void stopChannel(int channel) {
    debugOnStopChannel?.call(channel);
    _channelEpoch[channel] = (_channelEpoch[channel] ?? 0) + 1;
    for (final key
        in _liveTimers.keys.where((k) => k ~/ 1000 == channel).toList()) {
      _liveTimers.remove(key)?.cancel();
    }
    _engine.stopChannel(channel);
  }

  int _liveKey(int channel, int midi) => channel * 1000 + midi;

  /// Start a held note on pad press (paired with [noteOffLive] on release).
  void noteOnLive(int channel, int midi, {int? program, double vol = 0.85}) {
    final key = _liveKey(channel, midi);
    final generation = (_liveGeneration[key] ?? 0) + 1;
    _liveGeneration[key] = generation;
    final prog = program ?? _programs[channel] ?? 0;
    final epoch = _channelEpoch[channel] ?? 0;
    void fire() {
      if ((_channelEpoch[channel] ?? 0) != epoch ||
          _liveGeneration[key] != generation) {
        return;
      }
      _engine.noteOn(
        channel: channel,
        pitch: midi,
        velocity: _vel(vol),
        program: prog,
      );
    }

    if (!_ready) {
      ensure().then((_) {
        if (_ready) fire();
      });
    } else {
      fire();
    }
    // safety auto-off in case a release event is ever missed
    _liveTimers[key]?.cancel();
    _liveTimers[key] = Timer(
      const Duration(seconds: 4),
      () => noteOffLive(channel, midi),
    );
  }

  /// Stop a held note on pad release.
  void noteOffLive(int channel, int midi) {
    final key = _liveKey(channel, midi);
    _liveGeneration[key] = (_liveGeneration[key] ?? 0) + 1;
    _liveTimers.remove(key)?.cancel();
    _engine.noteOff(channel: channel, pitch: midi);
  }

  /// Test hook: observes every [playPitch] call (live schedule checks).
  @visibleForTesting
  void Function(int channel, int midi, int? velocity, double vol)?
  debugOnPlayPitch;

  /// Test hook: the gate (seconds) of every [playPitch] call (gt-002 ring
  /// lengths in the live schedule).
  @visibleForTesting
  void Function(int channel, int midi, double durSec)? debugOnPitchGate;

  /// One-shot pitched voice (loop playback + grid preview). [durSec] sets release.
  /// Fire-and-forget on the hot path once warm.
  void playPitch(
    int channel,
    int midi, {
    int? program,
    double vol = 0.85,
    double durSec = 0.4,
    int? velocity,
  }) {
    debugOnPlayPitch?.call(channel, midi, velocity, vol);
    debugOnPitchGate?.call(channel, midi, durSec);
    if (velocity != null && vol <= 0) return;
    final prog = program ?? _programs[channel] ?? 0;
    final rel = Duration(
      microseconds: (durSec * 1000000).round().clamp(1000, 3600000000),
    );
    final epoch = _channelEpoch[channel] ?? 0;
    void fire() {
      if ((_channelEpoch[channel] ?? 0) != epoch) return;
      _engine.playNote(
        channel: channel,
        pitch: midi,
        velocity: noteVelocity(velocity, vol),
        program: prog,
        release: rel,
      );
    }

    if (!_ready) {
      ensure().then((_) {
        if (_ready) fire();
      });
      return;
    }
    fire();
  }

  /// Drum hit (tap feedback + loop playback) on [channel] — base drums use
  /// [drumChannel]; an added drum track passes its own channel so it sounds
  /// through that track's kit. Fire-and-forget on the hot path.
  void playDrum(
    String kind, {
    int channel = drumChannel,
    double vol = 1,
    int? velocity,
  }) {
    if (velocity != null && vol <= 0) return;
    final pitch = percussionMidi(kind);
    if (pitch == null) return;
    if (!_ready) {
      // cold path: warm up then hit (first tap only)
      final epoch = _channelEpoch[channel] ?? 0;
      prewarm().then((_) {
        if ((_channelEpoch[channel] ?? 0) == epoch) {
          _fireDrum(channel, pitch, vol, velocity);
        }
      });
      return;
    }
    _fireDrum(channel, pitch, vol, velocity);
  }

  void _fireDrum(int channel, int pitch, double vol, int? velocity) {
    _engine.noteOn(
      channel: channel,
      pitch: pitch,
      velocity: noteVelocity(velocity, vol),
    );
    // GM percussion samples are one-shot; schedule a tidy note-off.
    Timer(const Duration(milliseconds: 220), () {
      _engine.noteOff(channel: channel, pitch: pitch);
    });
  }

  /// Metronome click — plays on a dedicated channel (GM wood block) so it never
  /// disturbs the user's selected drum kit on ch9. Accent on bar 1.
  Future<void> click(bool accent) async {
    await ensure();
    await _engine.playClick(accent);
  }

  // ── recorded vocal playback (audioplayers, plays alongside the SF2 synth) ──
  final AudioPlayer _vocalPlayer = AudioPlayer();
  Stream<bool> get vocalPlaying => _vocalPlayer.onPlayerStateChanged.map(
    (state) => state == PlayerState.playing,
  );
  Future<Duration?> vocalPosition() async {
    try {
      return await _vocalPlayer.getCurrentPosition();
    } catch (_) {
      return null;
    }
  }

  bool _vocalConfigured = false;
  String? _preparedPath; // source already loaded — start is just seek+resume
  // Identity of the prepared file (mtime + size). The section mix WAV is
  // re-bounced IN PLACE at the same path, so a path match alone would replay
  // the stale audio the player still holds (audit C17).
  DateTime? _preparedMtime;
  int? _preparedLength;

  Future<({DateTime mtime, int length})?> _statOf(String path) async {
    try {
      final st = await File(path).stat();
      if (st.type == FileSystemEntityType.notFound) return null;
      return (mtime: st.modified, length: st.size);
    } catch (_) {
      return null;
    }
  }

  Future<void> _remember(String path) async {
    final st = await _statOf(path);
    _preparedPath = path;
    _preparedMtime = st?.mtime;
    _preparedLength = st?.length;
  }

  /// True when [path] is the prepared source AND the file on disk is still the
  /// same one we loaded (unchanged mtime + size).
  Future<bool> _preparedIsCurrent(String path) async {
    if (_preparedPath != path) return false;
    final st = await _statOf(path);
    return st != null &&
        st.mtime == _preparedMtime &&
        st.length == _preparedLength;
  }

  Future<void> _configVocal() async {
    if (_vocalConfigured) return;
    // mix with the synth (don't take exclusive focus / don't stop on its own)
    await _vocalPlayer.setReleaseMode(ReleaseMode.stop);
    await _vocalPlayer.setAudioContext(
      AudioContext(
        android: const AudioContextAndroid(
          contentType: AndroidContentType.music,
          usageType: AndroidUsageType.media,
          audioFocus: AndroidAudioFocus.none,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: const {AVAudioSessionOptions.mixWithOthers},
        ),
      ),
    );
    _vocalConfigured = true;
  }

  /// Pre-load the vocal source so [playVocal] starts without the source-load
  /// latency (call when the section becomes active / the editor opens).
  Future<void> prepareVocal(String path) {
    final epoch = _vocalEpoch;
    return _enqueueVocal(() async {
      if (epoch == _vocalEpoch) await _prepareVocal(path);
    });
  }

  Future<void> _prepareVocal(String path) async {
    await _configVocal();
    try {
      await _vocalPlayer.setSource(DeviceFileSource(path));
      await _remember(path);
    } catch (_) {
      _preparedPath = null;
    }
  }

  /// Start the recorded vocal from t=0. With [loop] (a take trimmed to exactly
  /// one loop) the player loops natively — no wrap-time seek needed; unaligned
  /// takes keep ReleaseMode.stop and the caller re-aligns on loop wrap.
  int _vocalEpoch = 0;
  Future<void> _vocalOperations = Future<void>.value();

  Future<void> _enqueueVocal(Future<void> Function() operation) =>
      _vocalOperations = _vocalOperations
          .catchError((Object _) {})
          .then((_) => operation());

  Future<void> playVocal(
    String path, {
    double vol = .85,
    bool loop = false,
    Duration position = Duration.zero,
    double balance = 0,
  }) {
    final epoch = ++_vocalEpoch;
    return _enqueueVocal(() async {
      if (epoch != _vocalEpoch) return;
      await _playVocal(
        path,
        epoch: epoch,
        vol: vol,
        loop: loop,
        position: position,
        balance: balance,
      );
    });
  }

  /// Preview callers need to distinguish actual playback from a failed load.
  Future<bool> playVocalChecked(
    String path, {
    double vol = .85,
    bool loop = false,
    Duration position = Duration.zero,
  }) async {
    final epoch = ++_vocalEpoch;
    var success = false;
    await _enqueueVocal(() async {
      if (epoch != _vocalEpoch) return;
      success = await _playVocal(
        path,
        epoch: epoch,
        vol: vol,
        loop: loop,
        position: position,
      );
    });
    return success;
  }

  Future<bool> _playVocal(
    String path, {
    required int epoch,
    double vol = 0.85,
    bool loop = false,
    Duration position = Duration.zero,
    double balance = 0,
  }) async {
    try {
      await _configVocal().timeout(const Duration(seconds: 8));
      if (epoch != _vocalEpoch) return false;
      await _vocalPlayer.setReleaseMode(
        loop ? ReleaseMode.loop : ReleaseMode.stop,
      );
      await _vocalPlayer.setVolume(vol.clamp(0.0, 1.0));
      await _setBalance(balance);
      if (epoch != _vocalEpoch) return false;
      if (!await _preparedIsCurrent(path)) {
        await _vocalPlayer.pause();
        await _vocalPlayer
            .setSource(DeviceFileSource(path))
            .timeout(const Duration(seconds: 8));
        await _remember(path);
      }
      if (epoch != _vocalEpoch) return false;
      await _vocalPlayer.seek(position).timeout(const Duration(seconds: 8));
      if (epoch != _vocalEpoch) return false;
      await _vocalPlayer.resume().timeout(const Duration(seconds: 8));
      return epoch == _vocalEpoch;
    } catch (e) {
      debugPrint('[vocal] playback failed: $e');
      return false;
    }
  }

  /// Re-align the vocal to the loop start (called on loop wrap).
  Future<void> seekVocalToStart() => seekVocal(Duration.zero);

  Future<void> seekVocal(Duration position) {
    final epoch = _vocalEpoch;
    return _enqueueVocal(() async {
      if (epoch == _vocalEpoch) await _seekVocal(position);
    });
  }

  Future<void> _seekVocal(Duration position) async {
    try {
      await _vocalPlayer.seek(position);
      if (_vocalPlayer.state != PlayerState.playing) {
        await _vocalPlayer.resume();
      }
    } catch (_) {}
  }

  Future<void> setVocalVolume(double vol) async {
    try {
      await _vocalPlayer.setVolume(vol.clamp(0.0, 1.0));
    } catch (_) {}
  }

  /// Live pan of the song-level take (mixer-001) via the player's balance.
  /// Where the platform has no balance support playback stays centred (the
  /// export always applies the pan exactly).
  Future<void> setVocalBalance(double p) => _setBalance(p);

  Future<void> _setBalance(double p) async {
    try {
      await _vocalPlayer
          .setBalance(clampPan(p))
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      /* unsupported on this platform — stays centred */
    }
  }

  /// Stop and forget the prepared source: the next [playVocal] reloads from
  /// disk, so a mix WAV re-bounced while stopped is never replayed stale.
  /// (Call [prepareVocal] again after a stop if start latency matters.)
  Future<void> stopVocal() {
    _vocalEpoch++;
    return _enqueueVocal(_stopVocal);
  }

  Future<void> _stopVocal() async {
    _preparedPath = null;
    _preparedMtime = null;
    _preparedLength = null;
    try {
      await _vocalPlayer.stop();
    } catch (_) {}
  }

  /// Silence everything (stop / leaving the editor).
  Future<void> stopAll() {
    for (var ch = 0; ch < 16; ch++) {
      _channelEpoch[ch] = (_channelEpoch[ch] ?? 0) + 1;
    }
    for (final timer in _liveTimers.values) {
      timer.cancel();
    }
    _liveTimers.clear();
    stopVocal();
    return _engine.stopAll();
  }
}
