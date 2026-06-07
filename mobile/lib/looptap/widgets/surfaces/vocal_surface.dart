// LoopTap — Vocal recorder (audio only, no MIDI). README §5.
// Big red record ring + a live/"recorded" pink waveform strip. Real mic capture
// via the `record` package; the waveform amplitudes are stored as the clip.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../theme/atoms.dart';
import '../../theme/tokens.dart';

class VocalSurface extends StatefulWidget {
  const VocalSurface({super.key, required this.clip, required this.onCommit, required this.onClear});

  final List<double>? clip;
  final ValueChanged<List<double>> onCommit;
  final VoidCallback onClear;

  @override
  State<VocalSurface> createState() => _VocalSurfaceState();
}

class _VocalSurfaceState extends State<VocalSurface> {
  final AudioRecorder _rec = AudioRecorder();
  StreamSubscription<Amplitude>? _ampSub;
  Timer? _msTimer;

  bool _recording = false;
  int _ms = 0;
  List<double> _levels = List.filled(64, 0.05);
  final List<double> _captured = [];

  @override
  void dispose() {
    _ampSub?.cancel();
    _msTimer?.cancel();
    _rec.dispose();
    super.dispose();
  }

  double _norm(double dbfs) => ((dbfs + 50) / 50).clamp(0.05, 1.0);

  Future<void> _toggle() async {
    if (_recording) {
      await _stop();
    } else {
      await _start();
    }
  }

  Future<void> _start() async {
    bool ok = false;
    try {
      ok = await _rec.hasPermission();
    } catch (_) {
      ok = false;
    }
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission needed'), duration: Duration(milliseconds: 1200)),
        );
      }
      return;
    }
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/looptap_vocal_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _rec.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 44100, numChannels: 1),
        path: path,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Recording unavailable: $e'), duration: const Duration(milliseconds: 1400)),
        );
      }
      return;
    }
    _captured.clear();
    setState(() {
      _recording = true;
      _ms = 0;
      _levels = List.filled(64, 0.05);
    });
    _msTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => setState(() => _ms += 100));
    _ampSub = _rec.onAmplitudeChanged(const Duration(milliseconds: 70)).listen((a) {
      final v = _norm(a.current);
      _captured.add(v);
      setState(() => _levels = [..._levels.sublist(1), v]);
    });
  }

  Future<void> _stop() async {
    _ampSub?.cancel();
    _msTimer?.cancel();
    try {
      await _rec.stop();
    } catch (_) {}
    setState(() => _recording = false);
    final wf = _captured.isNotEmpty
        ? List<double>.from(_captured)
        : List<double>.generate(48, (i) => 0.2 + (i % 7) / 10);
    widget.onCommit(wf);
  }

  @override
  Widget build(BuildContext context) {
    final clip = widget.clip;
    final wave = _recording ? _levels : (clip != null && clip.isNotEmpty ? clip : List.filled(64, 0.05));
    final time = '${_ms ~/ 60000}:${((_ms ~/ 1000) % 60).toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          // record button
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: _toggle,
                child: Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: LT.danger, width: 3),
                  ),
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: _recording ? 30 : 62,
                      height: _recording ? 30 : 62,
                      decoration: BoxDecoration(
                        color: LT.danger,
                        borderRadius: BorderRadius.circular(_recording ? 7 : 999),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _recording ? time : (clip != null ? 'Recorded' : 'Tap to record'),
                style: LTType.mono(size: 13, weight: FontWeight.w700, color: _recording ? LT.danger : LT.t2),
              ),
            ],
          ),
          const SizedBox(width: 24),
          // waveform
          Expanded(
            child: Container(
              height: 96,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: LT.bg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: LT.border),
              ),
              child: Row(
                children: [
                  for (final l in wave)
                    Expanded(
                      child: Container(
                        height: (l * 80).clamp(4, 80),
                        margin: const EdgeInsets.symmetric(horizontal: 0.75),
                        decoration: BoxDecoration(
                          color: (_recording || clip != null) ? LT.pink : LT.surface3,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (clip != null && !_recording) ...[
            const SizedBox(width: 24),
            IconBtn(icon: LtIcons.delete, tooltip: 'Clear', size: 40, onTap: widget.onClear),
          ],
        ],
      ),
    );
  }
}
