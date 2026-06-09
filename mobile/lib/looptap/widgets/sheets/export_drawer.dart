// LoopTap — Export panel (right drawer, README §8). MIDI is fully wired; WAV /
// Stems / Share are locked in v1 (follow-up — see looptap-flutter-port memory).
import 'package:flutter/material.dart';

import '../../models/loop_models.dart';
import '../../music/midi_export.dart';
import '../../theme/atoms.dart';
import '../../theme/tokens.dart';

Future<void> showExportDrawer(
  BuildContext context, {
  required String title,
  required List<Section> sections,
  required int bpm,
  int melodyProgram = 0,
  int bassProgram = 33,
}) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'export',
    barrierColor: Colors.black.withValues(alpha: 0.6),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (_, __, ___) => Align(
      alignment: Alignment.centerRight,
      child: _ExportDrawer(
        title: title,
        sections: sections,
        bpm: bpm,
        melodyProgram: melodyProgram,
        bassProgram: bassProgram,
      ),
    ),
    transitionBuilder: (_, anim, __, child) => SlideTransition(
      position: Tween(begin: const Offset(1, 0), end: Offset.zero)
          .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

class _ExportDrawer extends StatefulWidget {
  const _ExportDrawer({
    required this.title,
    required this.sections,
    required this.bpm,
    required this.melodyProgram,
    required this.bassProgram,
  });
  final String title;
  final List<Section> sections;
  final int bpm;
  final int melodyProgram;
  final int bassProgram;

  @override
  State<_ExportDrawer> createState() => _ExportDrawerState();
}

class _ExportDrawerState extends State<_ExportDrawer> {
  String? _status;
  bool _statusOk = true;

  void _note(String m, {bool ok = true}) {
    setState(() {
      _status = m;
      _statusOk = ok;
    });
    Future.delayed(const Duration(milliseconds: 2400), () {
      if (mounted) setState(() => _status = null);
    });
  }

  Future<void> _doMidi() async {
    try {
      final file = await exportMidiSong(
        widget.sections,
        widget.bpm,
        widget.title,
        melodyProgram: widget.melodyProgram,
        bassProgram: widget.bassProgram,
      );
      _note('saved ${file.uri.pathSegments.last}');
    } catch (e) {
      _note('MIDI export failed', ok: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final secCount = widget.sections.length;
    final totalBars = widget.sections.fold<int>(0, (a, s) => a + s.bars * s.repeats);
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 420,
        height: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: LT.surface,
          border: Border(left: BorderSide(color: LT.border)),
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text('Export "${widget.title}"',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: LTType.inter(size: 18, weight: FontWeight.w800, color: LT.t1)),
                  ),
                  IconBtn(icon: LtIcons.close, tooltip: 'Close', onTap: () => Navigator.of(context).pop()),
                ],
              ),
              const SizedBox(height: 8),
              Text('$secCount section${secCount > 1 ? 's' : ''} · $totalBars bars · ${widget.bpm} BPM',
                  style: LTType.mono(size: 11, color: LT.t3)),
              const SizedBox(height: 12),
              _Row(icon: LtIcons.piano, title: 'MIDI file', sub: 'Whole song · piano · bass · drums (ch10)', color: LT.lime, onTap: _doMidi),
              const SizedBox(height: 12),
              const _Row(icon: LtIcons.graphicEq, title: 'Audio (WAV)', sub: 'Full song, rendered mix', lock: true),
              const SizedBox(height: 12),
              const _Row(icon: LtIcons.layers, title: 'Stems', sub: 'Separate WAV per track', lock: true),
              const SizedBox(height: 12),
              const _Row(icon: LtIcons.iosShare, title: 'Share', sub: 'Send to another app', lock: true),
              const SizedBox(height: 12),
              SizedBox(
                height: 18,
                child: Center(
                  child: _status == null
                      ? const SizedBox.shrink()
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Ms(_statusOk ? LtIcons.checkCircle : LtIcons.info, size: 14, color: _statusOk ? LT.lime : LT.danger),
                            const SizedBox(width: 5),
                            Text(_status!,
                                style: LTType.inter(
                                    size: 12, weight: FontWeight.w700, color: _statusOk ? LT.lime : LT.danger)),
                          ],
                        ),
                ),
              ),
              const Spacer(),
              Text(
                'Sections render in order (with their repeats). MIDI opens in any DAW. '
                'WAV / stems are coming soon.',
                style: LTType.inter(size: 11, color: LT.t3, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.title, required this.sub, this.color, this.onTap, this.lock = false});
  final IconData icon;
  final String title;
  final String sub;
  final Color? color;
  final VoidCallback? onTap;
  final bool lock;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: lock ? 0.5 : 1,
      child: GestureDetector(
        onTap: lock ? null : onTap,
        child: Container(
          height: 60,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: LT.surface2,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: LT.border),
          ),
          child: Row(
            children: [
              Ms(icon, size: 24, color: color ?? LT.t1),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: LTType.inter(size: 14, weight: FontWeight.w700, color: LT.t1)),
                    Text(sub, style: LTType.inter(size: 11, color: LT.t2)),
                  ],
                ),
              ),
              Ms(lock ? LtIcons.lock : LtIcons.download, size: 20, color: LT.t3),
            ],
          ),
        ),
      ),
    );
  }
}
