// LoopTap — Hum-to-MIDI modal (README §9). Records the user's hum IN TIME with
// the loop: a count-in, then recording starts on the downbeat while the loop
// plays back, for exactly one loop length. Because capture starts at the
// downbeat, audio t=0 ≈ loop step 0, so the engine's grid snap lands cleanly.
// On Convert it passes the recorded file to [onConvert] (which sends it to the
// humming→MIDI engine and inserts the result). Falls back gracefully on failure.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../../audio/container.dart';
import '../../theme/atoms.dart';
import '../../theme/tokens.dart';
import 'lt_modal.dart';

Future<void> showHumModal(
  BuildContext context, {
  required String trackLabel,
  required Color accent,
  required Future<void> Function(String audioPath) onConvert,
  required int bpm,
  required int bars,
  double swing = 0,
  int countInBeats = 4,
  void Function(bool accent)? onClick,
  VoidCallback? startBacking,
  VoidCallback? stopBacking,
}) {
  return showLtModal(
    context,
    width: 440,
    dismissible: false,
    child: _HumModal(
      trackLabel: trackLabel,
      accent: accent,
      onConvert: onConvert,
      bpm: bpm,
      bars: bars,
      countInBeats: countInBeats,
      onClick: onClick,
      startBacking: startBacking,
      stopBacking: stopBacking,
    ),
  );
}

class _HumModal extends StatefulWidget {
  const _HumModal({
    required this.trackLabel,
    required this.accent,
    required this.onConvert,
    required this.bpm,
    required this.bars,
    this.countInBeats = 4,
    this.onClick,
    this.startBacking,
    this.stopBacking,
  });
  final String trackLabel;
  final Color accent;
  final Future<void> Function(String audioPath) onConvert;
  final int bpm;
  final int bars;
  final int countInBeats;
  final void Function(bool accent)? onClick;
  final VoidCallback? startBacking;
  final VoidCallback? stopBacking;

  @override
  State<_HumModal> createState() => _HumModalState();
}

class _HumModalState extends State<_HumModal> {
  final AudioRecorder _rec = AudioRecorder();
  String _phase = 'countin'; // countin | listen | converting | done | error
  String _errorMsg = '';
  int _ms = 0;
  int _count = 0; // count-in beats remaining (overlay)
  bool _backingOn = false;
  // waveform driven by REAL mic amplitude — bars only move when you actually
  // make sound (silence stays flat), so it reflects the input.
  List<double> _levels = List.filled(40, 0.04);
  Timer? _msTimer;
  Timer? _autoStop;
  StreamSubscription<Amplitude>? _ampSub;

  // One loop pass length (LoopTap is 4/4 → bars * 4 beats).
  int get _loopMs => (widget.bars * 4 * 60000 / widget.bpm).round();
  int get _beatMs => (60000 / widget.bpm).round();

  @override
  void initState() {
    super.initState();
    _startCountIn();
  }

  @override
  void dispose() {
    _msTimer?.cancel();
    _autoStop?.cancel();
    _ampSub?.cancel();
    _rec.dispose();
    widget.stopBacking?.call();
    super.dispose();
  }

  // dBFS (negative) → 0..1; below ~ -48 dB reads as silence (flat bars).
  double _norm(double dbfs) => ((dbfs + 48) / 48).clamp(0.04, 1.0);

  // Count the user in (accented downbeat, then plain clicks), then capture.
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
      if (!await _rec.hasPermission()) {
        _fail('Microphone permission needed');
        return;
      }
      final dir = await getTemporaryDirectory();
      // Opus + 플랫폼별 컨테이너(.caf/.ogg) — AAC .m4a 는 stop() 직후 moov atom
      // finalize 가 안 끝나 partial file 로 업로드되던 회귀 fix.
      final path =
          '${dir.path}/humtrack_hum_${DateTime.now().millisecondsSinceEpoch}${opusContainerExt()}';
      await _rec.start(
        const RecordConfig(
          encoder: AudioEncoder.opus,
          sampleRate: 16000,
          numChannels: 1,
          // see vocal_record_modal: keep the recorder off Bluetooth SCO so it
          // doesn't disconnect the synth's Oboe output stream on Android.
          androidConfig: AndroidRecordConfig(manageBluetooth: false),
        ),
        path: path,
      );
      // Start the loop backing on the downbeat, right after recording opens, so
      // audio t≈0 lines up with loop step 0 (the engine absorbs the small
      // constant latency via its grid-phase estimate).
      widget.startBacking?.call();
      _backingOn = true;
      if (!mounted) return;
      setState(() {
        _phase = 'listen';
        _ms = 0;
      });
      _msTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (_phase == 'listen' && mounted) setState(() => _ms += 100);
      });
      _ampSub = _rec.onAmplitudeChanged(const Duration(milliseconds: 70)).listen((a) {
        if (_phase == 'listen' && mounted) {
          setState(() => _levels = [..._levels.sublist(1), _norm(a.current)]);
        }
      });
      // Capture exactly one loop pass, then convert automatically.
      _autoStop = Timer(Duration(milliseconds: _loopMs), _finish);
    } catch (e) {
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
    _autoStop?.cancel();
    _msTimer?.cancel();
    _ampSub?.cancel();
    _stopBacking();
    String? path;
    try {
      path = await _rec.stop();
    } catch (_) {}
    if (path == null) {
      _fail('No audio captured');
      return;
    }
    if (mounted) setState(() => _phase = 'converting');
    try {
      await widget.onConvert(path);
    } catch (_) {/* host shows its own error toast + fallback */}
    if (!mounted) return;
    setState(() => _phase = 'done');
    Timer(const Duration(milliseconds: 650), () {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _cancel() async {
    _autoStop?.cancel();
    _msTimer?.cancel();
    _ampSub?.cancel();
    _stopBacking();
    try {
      await _rec.stop();
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final time = '0:${(_ms ~/ 1000).toString().padLeft(2, '0')}';
    final subtitle = switch (_phase) {
      'countin' => 'Get ready — hum on the beat.',
      'listen' => "Hum your idea — we'll snap it in-key, in time.",
      'converting' => 'Converting to notes…',
      'error' => _errorMsg,
      _ => 'Done! Notes added.',
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Ms(LtIcons.graphicEq, size: 18, color: widget.accent),
            const SizedBox(width: 8),
            Text('Hum to MIDI · ${widget.trackLabel}',
                style: LTType.inter(size: 16, weight: FontWeight.w800, color: LT.t1)),
          ],
        ),
        const SizedBox(height: 6),
        Text(subtitle,
            textAlign: TextAlign.center,
            style: LTType.inter(size: 12, color: _phase == 'error' ? LT.danger : LT.t2)),
        const SizedBox(height: 20),
        SizedBox(
          height: 70,
          child: Center(
            child: _phase == 'done'
                ? Ms(LtIcons.checkCircle, size: 48, color: widget.accent, fill: 1)
                : _phase == 'error'
                    ? Ms(LtIcons.info, size: 44, color: LT.danger)
                    : _phase == 'countin'
                        ? Text('$_count',
                            style: LTType.mono(size: 48, weight: FontWeight.w800, color: widget.accent))
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              for (final l in _levels)
                                Container(
                                  width: 5,
                                  height: (l * (_phase == 'listen' ? 64 : 24)).clamp(6, 64),
                                  margin: const EdgeInsets.symmetric(horizontal: 1.5),
                                  decoration: BoxDecoration(
                                    color: _phase == 'listen' ? widget.accent : LT.t3,
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
              Container(width: 8, height: 8, decoration: const BoxDecoration(color: LT.danger, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text(time, style: LTType.mono(size: 14, weight: FontWeight.w700, color: LT.danger)),
              const SizedBox(width: 14),
              GestureDetector(
                onTap: _finish,
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 26),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: widget.accent, borderRadius: BorderRadius.circular(999)),
                  child: Text('Convert', style: LTType.inter(size: 14, weight: FontWeight.w800, color: LT.bg)),
                ),
              ),
              const SizedBox(width: 14),
              _ghostBtn('Cancel', _cancel),
            ],
          )
        else if (_phase == 'countin')
          _ghostBtn('Cancel', _cancel)
        else if (_phase == 'error')
          _ghostBtn('Close', _cancel),
      ],
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
          child: Text(label, style: LTType.inter(size: 13, weight: FontWeight.w700, color: LT.t2)),
        ),
      );
}
