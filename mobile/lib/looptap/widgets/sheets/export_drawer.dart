// LoopTap — Export panel (right drawer, README §8). MIDI is fully wired; WAV /
// Stems / Share are locked in v1 (follow-up — see looptap-flutter-port memory).
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../models/loop_models.dart';
import '../../music/midi_export.dart';
import '../../music/wav_export.dart';
import '../../theme/atoms.dart';
import '../../theme/tokens.dart';

Future<void> showExportDrawer(
  BuildContext context, {
  required String title,
  required List<Section> sections,
  required int bpm,
  double swing = 0,
  Map<String, double> vol = const {},
  int melodyProgram = 0,
  int bassProgram = 33,
  int melodyDecProgram = 48,
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
        swing: swing,
        vol: vol,
        melodyProgram: melodyProgram,
        bassProgram: bassProgram,
        melodyDecProgram: melodyDecProgram,
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
    required this.swing,
    required this.vol,
    required this.melodyProgram,
    required this.bassProgram,
    required this.melodyDecProgram,
  });
  final String title;
  final List<Section> sections;
  final int bpm;
  final double swing;
  final Map<String, double> vol;
  final int melodyProgram;
  final int bassProgram;
  final int melodyDecProgram;

  @override
  State<_ExportDrawer> createState() => _ExportDrawerState();
}

class _ExportDrawerState extends State<_ExportDrawer> {
  String? _status;
  bool _statusOk = true;
  String? _busy; // 'wav' | 'stems' while rendering (shows a spinner, blocks taps)

  void _note(String m, {bool ok = true}) {
    setState(() {
      _status = m;
      _statusOk = ok;
    });
    Future.delayed(const Duration(milliseconds: 2400), () {
      if (mounted) setState(() => _status = null);
    });
  }

  Future<void> _share(List<XFile> files, String text) async {
    try {
      await SharePlus.instance.share(ShareParams(files: files, text: text));
    } catch (e) {
      debugPrint('[export] share failed: $e');
    }
  }

  Future<void> _doWav() async {
    if (_busy != null) return;
    setState(() => _busy = 'wav');
    try {
      final file = await exportWavSong(widget.sections, widget.bpm, widget.swing, widget.vol, widget.title,
          melodyProgram: widget.melodyProgram,
          bassProgram: widget.bassProgram,
          melodyDecProgram: widget.melodyDecProgram);
      await _share([XFile(file.path, mimeType: 'audio/wav')], '${widget.title}.wav');
      if (mounted) _note(L10n.of(context).ltExportSaved(file.uri.pathSegments.last));
    } catch (e, st) {
      debugPrint('[export] wav failed: $e\n$st');
      if (mounted) _note(L10n.of(context).ltExportFailed, ok: false);
    }
    if (mounted) setState(() => _busy = null);
  }

  Future<void> _doStems() async {
    if (_busy != null) return;
    setState(() => _busy = 'stems');
    try {
      final files = await exportStems(widget.sections, widget.bpm, widget.swing, widget.vol, widget.title,
          melodyProgram: widget.melodyProgram,
          bassProgram: widget.bassProgram,
          melodyDecProgram: widget.melodyDecProgram);
      if (files.isEmpty) {
        if (mounted) _note(L10n.of(context).ltExportFailed, ok: false);
      } else {
        await _share(
          [for (final f in files) XFile(f.path)],
          '${widget.title} stems',
        );
        if (mounted) _note(L10n.of(context).ltExportSaved('${files.length} stems'));
      }
    } catch (e, st) {
      debugPrint('[export] stems failed: $e\n$st');
      if (mounted) _note(L10n.of(context).ltExportFailed, ok: false);
    }
    if (mounted) setState(() => _busy = null);
  }

  Future<void> _doMidi() async {
    debugPrint('[export] _doMidi start title=${widget.title}');
    try {
      final file = await exportMidiSong(
        widget.sections,
        widget.bpm,
        widget.title,
        melodyProgram: widget.melodyProgram,
        bassProgram: widget.bassProgram,
        melodyDecProgram: widget.melodyDecProgram,
      );
      debugPrint('[export] midi written: ${file.path}');
      // 파일 저장 후 iOS 의 share sheet 로 사용자에게 노출 — Documents 폴더가
      // sandboxed 라 share 없이는 사용자가 꺼낼 수 없음.
      final params = ShareParams(
        files: [XFile(file.path, mimeType: 'audio/midi')],
        text: '${widget.title}.mid',
      );
      try {
        final r = await SharePlus.instance.share(params);
        debugPrint('[export] share result: ${r.status} ${r.raw}');
      } catch (shareErr) {
        // share 실패해도 파일은 저장됐으니 saved 메시지는 보여줌.
        debugPrint('[export] share failed: $shareErr');
      }
      if (!mounted) return;
      _note(L10n.of(context).ltExportSaved(file.uri.pathSegments.last));
    } catch (e, st) {
      debugPrint('[export] midi export failed: $e\n$st');
      if (!mounted) return;
      _note(L10n.of(context).ltExportFailed, ok: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
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
              // 헤더 고정.
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(l.ltExportTitle(widget.title),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: LTType.inter(size: 18, weight: FontWeight.w800, color: LT.t1)),
                  ),
                  IconBtn(icon: LtIcons.close, tooltip: 'Close', onTap: () => Navigator.of(context).pop()),
                ],
              ),
              const SizedBox(height: 8),
              Text(l.ltExportMeta(secCount, totalBars, widget.bpm),
                  style: LTType.mono(size: 11, color: LT.t3)),
              const SizedBox(height: 12),
              // 본문 — 화면 작을 때 (landscape 폰) 스크롤로 overflow 회피.
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Row(icon: LtIcons.piano, title: l.ltExportMidiTitle, sub: l.ltExportMidiSub, color: LT.lime, onTap: _doMidi),
                      const SizedBox(height: 12),
                      // WAV / Stems — on-device oscillator render (instrumental;
                      // each section's vocal recording is added to Stems as-is).
                      _Row(
                        icon: LtIcons.graphicEq,
                        title: l.ltExportWavTitle,
                        sub: l.ltExportWavSub,
                        busy: _busy == 'wav',
                        onTap: _doWav,
                      ),
                      const SizedBox(height: 12),
                      _Row(
                        icon: LtIcons.layers,
                        title: l.ltExportStemsTitle,
                        sub: l.ltExportStemsSub,
                        busy: _busy == 'stems',
                        onTap: _doStems,
                      ),
                      const SizedBox(height: 12),
                      // Share — saves the MIDI + opens the OS share sheet.
                      _Row(icon: LtIcons.iosShare, title: l.ltExportShareTitle, sub: l.ltExportShareSub, onTap: _doMidi),
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
                      const SizedBox(height: 16),
                      Text(
                        l.ltExportFooter,
                        style: LTType.inter(size: 11, color: LT.t3, height: 1.5),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.title, required this.sub, this.color, this.onTap, this.busy = false});
  final IconData icon;
  final String title;
  final String sub;
  final Color? color;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: Opacity(
        opacity: busy ? 0.6 : 1,
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
              busy
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: LT.lime))
                  : const Ms(LtIcons.download, size: 20, color: LT.t3),
            ],
          ),
        ),
      ),
    );
  }
}
