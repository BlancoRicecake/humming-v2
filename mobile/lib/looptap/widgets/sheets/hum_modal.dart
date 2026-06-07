// LoopTap — Hum-to-MIDI modal (README §9). Animated mic level bars while
// listening; Convert / Cancel. On convert: a brief "Converting…" then a check,
// and the host drops an in-key generated phrase into the track.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/atoms.dart';
import '../../theme/tokens.dart';
import 'lt_modal.dart';

Future<void> showHumModal(
  BuildContext context, {
  required String trackLabel,
  required Color accent,
  required VoidCallback onConvert,
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
  final VoidCallback onConvert;

  @override
  State<_HumModal> createState() => _HumModalState();
}

class _HumModalState extends State<_HumModal> {
  String _phase = 'listen'; // listen | converting | done
  int _ms = 0;
  final math.Random _rng = math.Random();
  List<double> _levels = List.filled(40, 0.1);
  Timer? _msTimer;
  Timer? _ampTimer;

  @override
  void initState() {
    super.initState();
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
    super.dispose();
  }

  void _finish() {
    setState(() => _phase = 'converting');
    Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      widget.onConvert();
      setState(() => _phase = 'done');
      Timer(const Duration(milliseconds: 650), () {
        if (mounted) Navigator.of(context).pop();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final time = '0:${(_ms ~/ 1000).toString().padLeft(2, '0')}';
    final subtitle = _phase == 'listen'
        ? "Hum your idea — we'll snap it in-key."
        : _phase == 'converting'
            ? 'Converting to notes…'
            : 'Done! Notes added.';
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
        Text(subtitle, style: LTType.inter(size: 12, color: LT.t2)),
        const SizedBox(height: 20),
        SizedBox(
          height: 70,
          child: Center(
            child: _phase == 'done'
                ? Ms(LtIcons.checkCircle, size: 48, color: widget.accent, fill: 1)
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
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
              Text('● $time', style: LTType.mono(size: 14, weight: FontWeight.w700, color: LT.danger)),
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
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: LT.border),
                  ),
                  child: Text('Cancel', style: LTType.inter(size: 13, weight: FontWeight.w700, color: LT.t2)),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
