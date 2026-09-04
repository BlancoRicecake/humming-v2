// LoopTap — loop-aligned vocal recording modal. Same state machine as the
// hum modal (count-in → record one loop while the backing plays → done), but
// captures PCM16 WAV and post-processes the take so it starts on the downbeat
// and lasts exactly one loop. Backing/click audio is only played when the host
// supplies callbacks (the editor with a headset route):
//   parse → drop the mic-latency lead-in → trim/zero-pad to loop length →
//   re-encode → real peaks for the arrangement strip.
// The host commits the result with vocalAligned=true (gapless loop playback +
// exact placement in the WAV export).
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show Float32List, compute;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../audio/autotune_monitor.dart';
import '../../../audio/headset.dart';
import '../../../audio/synth.dart';
import '../../music/wav_codec.dart';
import '../../theme/atoms.dart';
import '../../theme/tokens.dart';
import 'lt_modal.dart';

Future<void> showVocalRecordModal(
  BuildContext context, {
  required Color accent,
  required int bpm,
  required int bars,
  required HeadsetRoute headset,
  required String keyTonic,
  required String scale,
  required int latencyMs,
  required Future<bool> Function(List<double> peaks, String path) onDone,
  int countInBeats = 4,
  void Function(bool accent)? onClick,
  VoidCallback? startBacking,
  VoidCallback? stopBacking,
}) {
  return showLtModal(
    context,
    width: 440,
    dismissible: false,
    child: _VocalRecordModal(
      accent: accent,
      bpm: bpm,
      bars: bars,
      headset: headset,
      keyTonic: keyTonic,
      scale: scale,
      latencyMs: latencyMs,
      onDone: onDone,
      countInBeats: countInBeats,
      onClick: onClick,
      startBacking: startBacking,
      stopBacking: stopBacking,
    ),
  );
}

class _VocalRecordModal extends StatefulWidget {
  const _VocalRecordModal({
    required this.accent,
    required this.bpm,
    required this.bars,
    required this.headset,
    required this.keyTonic,
    required this.scale,
    required this.latencyMs,
    required this.onDone,
    this.countInBeats = 4,
    this.onClick,
    this.startBacking,
    this.stopBacking,
  });
  final Color accent;
  final int bpm;
  final int bars;
  final HeadsetRoute headset;

  /// Song key/scale (engine literals) — drives the live autotune monitor.
  final String keyTonic;
  final String scale;
  final int latencyMs;
  final Future<bool> Function(List<double> peaks, String path) onDone;
  final int countInBeats;
  final void Function(bool accent)? onClick;
  final VoidCallback? startBacking;
  final VoidCallback? stopBacking;

  @override
  State<_VocalRecordModal> createState() => _VocalRecordModalState();
}

class _VocalRecordModalState extends State<_VocalRecordModal> {
  static const int _sr = 44100;
  static const double _minUsefulRecordSec = 0.5;
  static const double _minUsefulRecordRatio = 0.1;
  static const double _minVoiceRms = 0.002;
  static const double _minVoicePeak = 0.01;

  final AudioRecorder _rec = AudioRecorder();
  String _phase = 'countin'; // countin | listen | saving | done | error
  // Error CODE (not text): _fail runs after awaits and from an isolate result,
  // so the message is localized in build() instead. See _errorText.
  String _errorCode = '';
  int _ms = 0;
  int _count = 0;
  bool _backingOn = false;
  List<double> _levels = List.filled(40, 0.04);
  Timer? _msTimer;
  Timer? _autoStop;
  StreamSubscription<Amplitude>? _ampSub;
  StreamSubscription<RecordState>? _stateSub;
  // True once _rec.start() flipped the session to .playAndRecord (and we
  // rebuilt the synth output under it) — gates the restore on stop. Mirrors
  // hum_modal (audit A5).
  bool _recStarted = false;
  bool _permissionDenied = false; // error phase offers "Open Settings"

  int get _loopMs => (widget.bars * 4 * 60000 / widget.bpm).round();
  int get _beatMs => (60000 / widget.bpm).round();

  // Live autotune monitoring — iOS + wired headphones only (Bluetooth's
  // 150-300 ms round-trip is unusable to sing against). The take stays dry;
  // the monitor only colors what the singer hears.
  bool get _monitorAvailable =>
      autotuneMonitorSupported && widget.headset == HeadsetRoute.wired;
  bool _monitorOn = true; // user toggle (effective when available)
  bool _monitorActive = false; // native graph actually running
  bool _closed = false; // cancelled/disposed — in-flight awaits must bail

  @override
  void initState() {
    super.initState();
    _count = widget.countInBeats; // shown while the permission prompt is up
    // native monitor can stop itself (headphones unplugged mid-recording) —
    // clear the LIVE AUTOTUNE badge when it does
    onAutotuneMonitorStopped = () {
      _monitorActive = false;
      if (mounted) setState(() {});
    };
    _requestPermissionThenCountIn();
  }

  @override
  void dispose() {
    _closed = true;
    onAutotuneMonitorStopped = null;
    _msTimer?.cancel();
    _autoStop?.cancel();
    _ampSub?.cancel();
    _stateSub?.cancel();
    _rec.dispose();
    if (_backingOn) widget.stopBacking?.call();
    _stopMonitor();
    super.dispose();
  }

  /// Mic permission BEFORE the count-in — the OS prompt would otherwise pop
  /// mid-count and the take would start while the user is still answering it.
  Future<void> _requestPermissionThenCountIn() async {
    bool granted;
    try {
      granted = await _rec.hasPermission();
    } catch (_) {
      granted = false;
    }
    if (_closed || !mounted) return;
    if (!granted) {
      _permissionDenied = true;
      _fail('permission');
      return;
    }
    _startCountIn();
  }

  Future<void> _startMonitor() async {
    if (!_monitorAvailable || !_monitorOn) return;
    // recorder owns the session first; a failed monitor start (mic conflict,
    // engine error) silently degrades to plain recording.
    final started = await startAutotuneMonitor(
      key: widget.keyTonic,
      scale: widget.scale,
      strength: 1.0,
    );
    if (_closed || !mounted) {
      // cancelled while the start was in flight — don't leak the native graph
      if (started) await stopAutotuneMonitor();
      return;
    }
    _monitorActive = started;
    setState(() {});
  }

  void _stopMonitor() {
    if (_monitorActive) {
      _monitorActive = false;
      stopAutotuneMonitor();
    }
  }

  double _norm(double dbfs) => ((dbfs + 48) / 48).clamp(0.04, 1.0);

  void _startCountIn() {
    setState(() {
      _phase = 'countin';
      _count = widget.countInBeats;
    });
    widget.onClick?.call(true);
    void tick() {
      _autoStop = Timer(Duration(milliseconds: _beatMs), () {
        if (!mounted) return;
        _count -= 1;
        if (_count <= 0) {
          _beginCapture();
        } else {
          setState(() {});
          widget.onClick?.call(false);
          tick();
        }
      });
    }

    tick();
  }

  Future<void> _beginCapture() async {
    try {
      final dir = await getTemporaryDirectory();
      if (_closed || !mounted) return;
      final path =
          '${dir.path}/humtrack_vocal_${DateTime.now().millisecondsSinceEpoch}.wav';
      // Record at the device's CURRENT output rate (iOS) like the hum modal:
      // record_ios pins the shared session to config.sampleRate and never
      // restores it, so a fixed 44.1k would drag 48k hardware down and leave
      // the synth output crackling after. _alignJob resamples to _sr anyway.
      final deviceRate = await outputSampleRate() ?? _sr;
      if (_closed || !mounted) return;
      await _rec.start(
        RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: deviceRate,
          numChannels: 1,
          // Don't let the recorder grab Bluetooth SCO / flip the audio route:
          // on Android that disconnects flutter_midi_pro's Oboe output stream
          // and it doesn't recover, so synth sound (instrument preview, loop,
          // drums) goes dead after the first recording.
          androidConfig: const AndroidRecordConfig(manageBluetooth: false),
          // Never let the plugin pause the take on its own (phone call, Siri,
          // Android focus loss) — a silently paused take resumes with a hole
          // in it. We watch the state stream instead and fail loudly (A4).
          audioInterruption: AudioInterruptionMode.none,
        ),
        path: path,
      );
      _recStarted = true;
      if (_closed || !mounted) {
        // cancelled while start() was in flight — _cancel's stop ran before
        // the recorder existed, so stop it here and skip backing/monitor
        String? p;
        try {
          p = await _rec.stop();
        } catch (_) {}
        _deleteQuiet(p);
        await _restoreOutput();
        return;
      }
      _stateSub = _rec.onStateChanged().listen(_onRecordState);
      // _rec.start just flipped the shared AVAudioSession to .playAndRecord,
      // which corrupts the synth's already-running output pipe (RemoteIO) →
      // crackle in the backing. Rebuild it under .playAndRecord; with NO
      // headset force the built-in speaker (the rebuild's setCategory drops
      // .defaultToSpeaker), with a headset leave the route alone. iOS-only,
      // no-op elsewhere. Done BEFORE the monitor so its session tweaks win.
      await SynthEngine().rebuildOutput(forRecording: true);
      if (widget.headset == HeadsetRoute.none) await overrideOutputToSpeaker();
      if (_closed || !mounted) {
        String? p;
        try {
          p = await _rec.stop();
        } catch (_) {}
        _deleteQuiet(p);
        await _restoreOutput();
        return;
      }
      // Backing starts right after recording opens, so audio t≈0 (minus the
      // mic lead-in we trim later) lines up with loop step 0. When no headset
      // is connected the host passes no backing callback, keeping device
      // speakers silent so the instrumental loop cannot bleed into the mic.
      if (widget.startBacking != null) {
        widget.startBacking!.call();
        _backingOn = true;
      }
      await _startMonitor(); // after the recorder owns the mic; fails soft
      if (_closed || !mounted) {
        _stopBacking();
        String? p;
        try {
          p = await _rec.stop();
        } catch (_) {}
        _deleteQuiet(p);
        await _restoreOutput();
        return;
      }
      setState(() {
        _phase = 'listen';
        _ms = 0;
      });
      _msTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (_phase == 'listen' && mounted) setState(() => _ms += 100);
      });
      _ampSub = _rec
          .onAmplitudeChanged(const Duration(milliseconds: 70))
          .listen((a) {
            if (_phase == 'listen' && mounted) {
              setState(
                () => _levels = [..._levels.sublist(1), _norm(a.current)],
              );
            }
          });
      // one loop + a little tail (trimmed to the exact loop length afterwards)
      _autoStop = Timer(
        Duration(milliseconds: _loopMs + widget.latencyMs + 300),
        _finish,
      );
    } catch (_) {
      _fail('unavailable');
    }
  }

  void _stopBacking() {
    if (_backingOn) {
      widget.stopBacking?.call();
      _backingOn = false;
    }
  }

  String _errorText(L10n l) => switch (_errorCode) {
    'permission' => l.editMicPermNeededTitle,
    'unavailable' => l.ltRecErrUnavailable,
    'interrupted' => l.ltRecErrInterrupted,
    'noaudio' => l.ltRecErrNoAudio,
    'tooShort' => l.ltRecErrTooShort,
    'tooQuiet' => l.ltRecErrTooQuiet,
    'saveFailed' => l.ltRecSaveFailed,
    _ => l.ltRecErrFailed,
  };

  void _fail(String code) {
    _stopBacking();
    if (!mounted) return;
    setState(() {
      _phase = 'error';
      _errorCode = code;
    });
  }

  /// Recording left the session in .playAndRecord; restore .playback and
  /// rebuild the synth output so pad taps / playback are clean afterwards.
  /// Once per started take (guarded by [_recStarted]). Call AFTER the recorder
  /// has stopped and the monitor session was released.
  Future<void> _restoreOutput() async {
    if (!_recStarted) return;
    _recStarted = false;
    await SynthEngine().rebuildOutput(forRecording: false);
  }

  static void _deleteQuiet(String? path) {
    if (path == null || path.isEmpty) return;
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  // The recorder paused underneath us (system interruption the plugin could
  // not ignore). The take would have a hole in it — abort with a clear message
  // instead of saving a truncated vocal.
  Future<void> _onRecordState(RecordState s) async {
    if (s != RecordState.pause || _phase != 'listen') return;
    if (mounted) setState(() => _phase = 'saving'); // blocks Stop/_finish
    _autoStop?.cancel();
    _msTimer?.cancel();
    _ampSub?.cancel();
    _stopBacking();
    _stopMonitor();
    String? path;
    try {
      path = await _rec.stop();
    } catch (_) {}
    _deleteQuiet(path);
    await releaseAutotuneMonitorSession();
    await _restoreOutput();
    _fail('interrupted');
  }

  Future<void> _finish() async {
    if (_phase == 'saving' || _phase == 'done') return;
    if (mounted) setState(() => _phase = 'saving');
    _autoStop?.cancel();
    _msTimer?.cancel();
    _ampSub?.cancel();
    _stateSub?.cancel();
    _stopBacking();
    _stopMonitor();
    String? path;
    try {
      path = await _rec.stop();
    } catch (_) {}
    // recorder is fully stopped — safe to let go of the iOS audio session
    // (awaited so its deactivate lands BEFORE the output rebuild re-activates
    // .playback — the other order would leave the fresh output unit on a
    // deactivated session).
    await releaseAutotuneMonitorSession();
    await _restoreOutput();
    if (path == null) {
      _fail('noaudio');
      return;
    }
    final loopSamples = (widget.bars * 4 * _samplesPerBeat(widget.bpm)).round();
    final minUsefulSamples = math.min(
      loopSamples,
      math.max(
        (_sr * _minUsefulRecordSec).round(),
        (loopSamples * _minUsefulRecordRatio).round(),
      ),
    );
    final out = await compute(_alignJob, {
      'src': path,
      'dst': '$path.aligned.wav',
      'dropSamples': (widget.latencyMs * _sr / 1000).round(),
      'loopSamples': loopSamples,
      'minUsefulSamples': minUsefulSamples,
      'minVoiceRms': _minVoiceRms,
      'minVoicePeak': _minVoicePeak,
    });
    // The raw capture is consumed — the aligned copy is all that's needed now.
    _deleteQuiet(path);
    if (out == null) {
      _fail('failed');
      return;
    }
    if (out.error != null) {
      _fail(out.error!);
      return;
    }
    var committed = false;
    try {
      // the host COPIES the aligned take into Documents (LoopStorage.copyVocal)
      committed = await widget.onDone(out.peaks, out.path);
    } catch (_) {
      committed = false;
    }
    _deleteQuiet(out.path); // temp aligned file — copied or rejected either way
    if (!mounted) return;
    if (!committed) {
      _fail('saveFailed');
      return;
    }
    setState(() => _phase = 'done');
    Timer(const Duration(milliseconds: 650), () {
      if (mounted) Navigator.of(context).pop();
    });
  }

  static double _samplesPerBeat(int bpm) => 60 / bpm * _sr;

  static Future<({String path, List<double> peaks, String? error})?> _alignJob(
    Map<String, Object> a,
  ) async {
    try {
      // readAsBytes already yields a Uint8List — no defensive copy (A14).
      final wav = parseWav(await File(a['src'] as String).readAsBytes());
      if (wav == null || wav.samples.isEmpty) return null;
      var pcm =
          wav.sampleRate == _sr
              ? wav.samples
              : resampleLinear(wav.samples, wav.sampleRate, _sr);
      final drop = a['dropSamples'] as int;
      final loop = a['loopSamples'] as int;
      final minUseful = a['minUsefulSamples'] as int;
      final minRms = a['minVoiceRms'] as double;
      final minPeak = a['minVoicePeak'] as double;
      if (pcm.length - drop < minUseful) {
        return (
          path: '',
          peaks: const <double>[],
          error: 'tooShort',
        );
      }
      // drop the mic lead-in, then trim/zero-pad to exactly one loop
      final out = Float32List(loop);
      var sumSq = 0.0;
      var peak = 0.0;
      var measured = 0;
      for (var i = 0; i < loop; i++) {
        final j = i + drop;
        final s = j < pcm.length ? pcm[j] : 0.0;
        out[i] = s;
        if (j < pcm.length) {
          measured++;
          sumSq += s * s;
          final mag = s.abs();
          if (mag > peak) peak = mag;
        }
      }
      final rms = measured > 0 ? math.sqrt(sumSq / measured) : 0.0;
      if (peak < minPeak || rms < minRms) {
        return (
          path: '',
          peaks: const <double>[],
          error: 'tooQuiet',
        );
      }
      final dst = a['dst'] as String;
      await File(dst).writeAsBytes(encodeWavMono16(out, _sr));
      return (path: dst, peaks: peaksFromPcm(out), error: null);
    } catch (_) {
      return null;
    }
  }

  Future<void> _cancel() async {
    if (_closed) return; // back button + Cancel tap → single pop
    _closed = true;
    _autoStop?.cancel();
    _msTimer?.cancel();
    _ampSub?.cancel();
    _stateSub?.cancel();
    _stopBacking();
    _stopMonitor();
    String? path;
    try {
      path = await _rec.stop();
    } catch (_) {}
    _deleteQuiet(path); // abandoned raw take
    await releaseAutotuneMonitorSession();
    await _restoreOutput();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final time = '0:${(_ms ~/ 1000).toString().padLeft(2, '0')}';
    final subtitle = switch (_phase) {
      'countin' =>
        widget.headset == HeadsetRoute.none
            ? l.ltVocalRecCountInNoHeadset
            : l.ltVocalRecCountIn,
      'listen' =>
        widget.headset == HeadsetRoute.none
            ? l.ltVocalRecListenMuted
            : l.ltVocalRecListen,
      'saving' => l.editSaveSaving,
      'error' => _errorText(l),
      _ => l.ltVocalRecDone,
    };
    // System back must go through the same cleanup as Cancel — a raw pop
    // would leave the recorder/monitor/backing running.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Ms(LtIcons.mic, size: 18, color: widget.accent),
              const SizedBox(width: 8),
              Text(
                l.ltVocalRecTitle,
                style: LTType.inter(
                  size: 16,
                  weight: FontWeight.w800,
                  color: LT.t1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: LTType.inter(
              size: 12,
              color: _phase == 'error' ? LT.danger : LT.t2,
            ),
          ),
          if (_monitorAvailable && _phase == 'countin') ...[
            const SizedBox(height: 10),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Ms(
                  LtIcons.autoFix,
                  size: 15,
                  color: _monitorOn ? widget.accent : LT.t3,
                ),
                const SizedBox(width: 6),
                Text(
                  l.ltVocalLiveAutotune,
                  style: LTType.inter(
                    size: 12,
                    weight: FontWeight.w700,
                    color: LT.t2,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 24,
                  child: Switch(
                    value: _monitorOn,
                    activeColor: widget.accent,
                    onChanged: (v) => setState(() => _monitorOn = v),
                  ),
                ),
              ],
            ),
          ],
          if (_monitorActive && _phase == 'listen') ...[
            const SizedBox(height: 8),
            Text(
              l.ltVocalLiveAutotuneOn,
              style: LTType.mono(
                size: 10,
                weight: FontWeight.w800,
                color: widget.accent,
              ),
            ),
          ],
          const SizedBox(height: 20),
          SizedBox(
            height: 70,
            child: Center(
              child:
                  _phase == 'done'
                      ? Ms(
                        LtIcons.checkCircle,
                        size: 48,
                        color: widget.accent,
                        fill: 1,
                      )
                      : _phase == 'error'
                      ? Ms(LtIcons.info, size: 44, color: LT.danger)
                      : _phase == 'saving'
                      ? SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: widget.accent,
                        ),
                      )
                      : _phase == 'countin'
                      ? Text(
                        '$_count',
                        style: LTType.mono(
                          size: 48,
                          weight: FontWeight.w800,
                          color: widget.accent,
                        ),
                      )
                      : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (final l in _levels)
                            Container(
                              width: 5,
                              height: (l * 64).clamp(6, 64),
                              margin: const EdgeInsets.symmetric(
                                horizontal: 1.5,
                              ),
                              decoration: BoxDecoration(
                                color: widget.accent,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                        ],
                      ),
            ),
          ),
          const SizedBox(height: 22),
          if (_phase == 'listen')
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: LT.danger,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  time,
                  style: LTType.mono(
                    size: 14,
                    weight: FontWeight.w700,
                    color: LT.danger,
                  ),
                ),
                const SizedBox(width: 14),
                _ghostBtn(l.cancel, _cancel),
                const SizedBox(width: 8),
                _solidBtn(l.pendingStop, _finish),
              ],
            )
          else if (_phase == 'countin')
            _ghostBtn(l.cancel, _cancel)
          else if (_phase == 'error')
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_permissionDenied) ...[
                  _solidBtn(l.editOpenSettings, () => openAppSettings()),
                  const SizedBox(width: 8),
                ],
                _ghostBtn(l.close, _cancel),
              ],
            ),
        ],
      ),
    );
  }

  Widget _ghostBtn(String label, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: LT.border),
      ),
      child: Text(
        label,
        style: LTType.inter(size: 13, weight: FontWeight.w700, color: LT.t2),
      ),
    ),
  );

  Widget _solidBtn(String label, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: widget.accent,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: LTType.inter(size: 13, weight: FontWeight.w800, color: LT.bg),
      ),
    ),
  );
}
