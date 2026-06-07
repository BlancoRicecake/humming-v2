// LoopTap — Hum-to-MIDI modal (README §9). Records real mic audio while
// "listening"; on Convert it passes the recorded file to [onConvert] (which
// sends it to the humming→MIDI engine and inserts the result), then shows a
// check. Falls back gracefully if recording/engine fails.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../theme/atoms.dart';
import '../../theme/tokens.dart';
import 'lt_modal.dart';

Future<void> showHumModal(
  BuildContext context, {
  required String trackLabel,
  required Color accent,
  required Future<void> Function(String audioPath) onConvert,
}) {
  return showLtModal(
    context,
    width: 440,
    dismissible: false,
    child: _HumModal(trackLabel: trackLabel, accent: accent, onConvert: onConvert),
  );
}

class _HumModal extends StatefulWidget {
  const _HumModal({required this.trackLabel, required this.accent, required this.onConvert});
  final String trackLabel;
  final Color accent;
  final Future<void> Function(String audioPath) onConvert;

  @override
  State<_HumModal> createState() => _HumModalState();
}

class _HumModalState extends State<_HumModal> {
  final AudioRecorder _rec = AudioRecorder();
  String _phase = 'listen'; // listen | converting | done | error
  String _errorMsg = '';
  int _ms = 0;
  final math.Random _rng = math.Random();
  List<double> _levels = List.filled(40, 0.1);
  Timer? _msTimer;
  Timer? _ampTimer;

  @override
  void initState() {
    super.initState();
    _startRecording();
    _msTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_phase == 'listen') setState(() => _ms += 100);
    });
    _ampTimer = Timer.periodic(const Duration(milliseconds: 80), (_) {
      if (_phase == 'listen') {
        setState(() => _levels = [..._levels.sublist(1), 0.2 + _rng.nextDouble() * 0.8]);
      }
    });
  }

  @override
  void dispose() {
    _msTimer?.cancel();
    _ampTimer?.cancel();
    _rec.dispose();
    super.dispose();
  }

  Future<void> _startRecording() async {
    try {
      if (!await _rec.hasPermission()) {
        setState(() {
          _phase = 'error';
          _errorMsg = 'Microphone permission needed';
        });
        return;
      }
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/looptap_hum_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _rec.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, sampleRate: 16000, numChannels: 1),
        path: path,
      );
    } catch (e) {
      setState(() {
        _phase = 'error';
        _errorMsg = 'Recording unavailable';
      });
    }
  }

  Future<void> _finish() async {
    String? path;
    try {
      path = await _rec.stop();
    } catch (_) {}
    if (path == null) {
      setState(() {
        _phase = 'error';
        _errorMsg = 'No audio captured';
      });
      return;
    }
    setState(() => _phase = 'converting');
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
    try {
      await _rec.stop();
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final time = '0:${(_ms ~/ 1000).toString().padLeft(2, '0')}';
    final subtitle = switch (_phase) {
      'listen' => "Hum your idea — we'll snap it in-key.",
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
