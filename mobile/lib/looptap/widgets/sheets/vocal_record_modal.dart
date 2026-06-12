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

import 'package:flutter/foundation.dart' show Uint8List, Float32List, compute;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../../audio/autotune_monitor.dart';
import '../../../audio/headset.dart';
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
  String _errorMsg = '';
  int _ms = 0;
  int _count = 0;
  bool _backingOn = false;
  List<double> _levels = List.filled(40, 0.04);
  Timer? _msTimer;
  Timer? _autoStop;
  StreamSubscription<Amplitude>? _ampSub;

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
      _fail('Microphone permission needed');
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
      await _rec.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: _sr,
          numChannels: 1,
        ),
        path: path,
      );
      if (_closed || !mounted) {
        // cancelled while start() was in flight — _cancel's stop ran before
        // the recorder existed, so stop it here and skip backing/monitor
        try {
          await _rec.stop();
        } catch (_) {}
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
        try {
          await _rec.stop();
        } catch (_) {}
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
      _fail('Recording unavailable');
    }
  }

  void _stopBacking() {
    if (_backingOn) {
      widget.stopBacking?.call();
      _backingOn = false;
    }
  }

  void _fail(String msg) {
    _stopBacking();
    if (!mounted) return;
    setState(() {
      _phase = 'error';
      _errorMsg = msg;
    });
  }

  Future<void> _finish() async {
    if (_phase == 'saving' || _phase == 'done') return;
    if (mounted) setState(() => _phase = 'saving');
    _autoStop?.cancel();
    _msTimer?.cancel();
    _ampSub?.cancel();
    _stopBacking();
    _stopMonitor();
    String? path;
    try {
      path = await _rec.stop();
    } catch (_) {}
    // recorder is fully stopped — safe to let go of the iOS audio session
    unawaited(releaseAutotuneMonitorSession());
    if (path == null) {
      _fail('No audio captured');
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
    if (out == null) {
      _fail('Recording failed');
      return;
    }
    if (out.error != null) {
      _fail(out.error!);
      return;
    }
    var committed = false;
    try {
      committed = await widget.onDone(out.peaks, out.path);
    } catch (_) {
      committed = false;
    }
    if (!mounted) return;
    if (!committed) {
      _fail("Couldn't save the recording");
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
      final bytes = await File(a['src'] as String).readAsBytes();
      final wav = parseWav(Uint8List.fromList(bytes));
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
          error: 'Recording was too short',
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
          error: 'Recording is too quiet',
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
    _stopBacking();
    _stopMonitor();
    try {
      await _rec.stop();
    } catch (_) {}
    unawaited(releaseAutotuneMonitorSession());
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final time = '0:${(_ms ~/ 1000).toString().padLeft(2, '0')}';
    final subtitle = switch (_phase) {
      'countin' =>
        widget.headset == HeadsetRoute.none
            ? 'No earphones — recording silently so the loop stays out of the mic.'
            : 'Get ready — sing with the loop.',
      'listen' =>
        widget.headset == HeadsetRoute.none
            ? 'Recording one loop — device audio is muted.'
            : 'Recording one loop — sing along.',
      'saving' => 'Saving…',
      'error' => _errorMsg,
      _ => 'Done! Vocal recorded.',
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
                'Record vocal',
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
                  'Live autotune',
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
              'LIVE AUTOTUNE',
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
                _ghostBtn('Cancel', _cancel),
                const SizedBox(width: 8),
                _solidBtn('Stop', _finish),
              ],
            )
          else if (_phase == 'countin')
            _ghostBtn('Cancel', _cancel)
          else if (_phase == 'error')
            _ghostBtn('Close', _cancel),
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
