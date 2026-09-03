// LoopTap — Export panel (right drawer, README §8). MIDI, WAV, Stems and Share
// are all wired: MIDI via buildMidi; WAV/Stems render the song's MIDI through
// the bundled SF2 (see wav_export.dart). Gated behind Pro by the caller.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../models/loop_models.dart';
import '../../music/midi_export.dart';
import '../../music/theory.dart';
import '../../../services/clarity_service.dart';
import '../../music/wav_export.dart';
import '../../state/loop_store.dart';
import '../../theme/atoms.dart';
import '../../theme/tokens.dart';
import 'paywall_sheet.dart';

Future<void> showExportDrawer(
  BuildContext context, {
  required String title,
  String songId = 'loop',
  required List<Section> sections,
  required int bpm,
  double swing = 0,
  Map<String, double> vol = const {},
  int melodyProgram = 0,
  int bassProgram = 33,
  int melodyDecProgram = 48,
  int drumProgram = 0,
  List<TrackRef> extras = const [],
  Map<String, int> instruments = const {},
  String? songVocalPath,
}) async {
  // Defence in depth: callers gate on proActive before opening, but re-check
  // here so no code path reaches the export UI without a current Pro verdict.
  if (!context.read<LoopStore>().proActive) {
    await showPaywallSheet(context, trigger: PaywallTrigger.export);
    if (!context.mounted || !context.read<LoopStore>().proActive) return;
  }
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'export',
    barrierColor: Colors.black.withValues(alpha: 0.6),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (_, __, ___) => Align(
      alignment: Alignment.centerRight,
      child: _ExportDrawer(
        title: title,
        songId: songId,
        sections: sections,
        bpm: bpm,
        swing: swing,
        vol: vol,
        melodyProgram: melodyProgram,
        bassProgram: bassProgram,
        melodyDecProgram: melodyDecProgram,
        drumProgram: drumProgram,
        extras: extras,
        instruments: instruments,
        songVocalPath: songVocalPath,
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
    required this.songId,
    required this.sections,
    required this.bpm,
    required this.swing,
    required this.vol,
    required this.melodyProgram,
    required this.bassProgram,
    required this.melodyDecProgram,
    required this.drumProgram,
    required this.extras,
    required this.instruments,
    this.songVocalPath,
  });
  final String title;
  // file-name fallback when the title sanitises to nothing (C11)
  final String songId;
  final List<Section> sections;
  final int bpm;
  final double swing;
  final Map<String, double> vol;
  final int melodyProgram;
  final int bassProgram;
  final int melodyDecProgram;
  final int drumProgram;
  final List<TrackRef> extras;
  final Map<String, int> instruments;
  final String? songVocalPath;

  @override
  State<_ExportDrawer> createState() => _ExportDrawerState();
}

class _ExportDrawerState extends State<_ExportDrawer> {
  String? _status;
  bool _statusOk = true;
  String? _busy; // 'wav' | 'stems' while rendering (shows a spinner, blocks taps)
  // null = whole song; otherwise the index of the single section (loop) to export.
  int? _selectedSection;

  // The sections that the current export targets: the whole song, or just the
  // one selected loop. The render functions already flatten any list (with each
  // section's repeats), so a single-element list exports only that loop.
  List<Section> get _scopeSections => _selectedSection == null
      ? widget.sections
      : [widget.sections[_selectedSection!]];

  // The export title: the song title, plus the section name when a single loop
  // is selected so files don't collide and are easy to tell apart.
  String get _scopeTitle => _selectedSection == null
      ? widget.title
      : '${widget.title} - ${widget.sections[_selectedSection!].name}';

  void _note(String m, {bool ok = true}) {
    setState(() {
      _status = m;
      _statusOk = ok;
    });
    Future.delayed(const Duration(milliseconds: 2400), () {
      if (mounted) setState(() => _status = null);
    });
  }

  // iPad presents the share sheet as a popover anchored to a rect; share_plus
  // throws without one there. Anchor it to this drawer panel.
  Rect? _shareOrigin() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Future<void> _share(List<XFile> files, String text) async {
    try {
      await SharePlus.instance.share(
        ShareParams(files: files, text: text, sharePositionOrigin: _shareOrigin()),
      );
    } catch (e) {
      debugPrint('[export] share failed: $e');
    }
  }

  Future<void> _doWav() async {
    if (_busy != null) return;
    setState(() => _busy = 'wav');
    try {
      final res = await exportWavSong(_scopeSections, widget.bpm, widget.swing, widget.vol, _scopeTitle,
          melodyProgram: widget.melodyProgram,
          bassProgram: widget.bassProgram,
          melodyDecProgram: widget.melodyDecProgram,
          drumProgram: widget.drumProgram,
          extras: widget.extras,
          instruments: widget.instruments,
          songVocalPath: widget.songVocalPath,
          fallbackName: widget.songId);
      final file = res.file;
      await _share([XFile(file.path, mimeType: 'audio/wav')], '$_scopeTitle.wav');
      ClarityService.instance.event('export_wav');
      if (mounted) {
        _note(res.skippedVocals > 0
            ? L10n.of(context).ltExportVocalSkipped(res.skippedVocals)
            : L10n.of(context).ltExportSaved(file.uri.pathSegments.last));
      }
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
      final files = await exportStems(_scopeSections, widget.bpm, widget.swing, widget.vol, _scopeTitle,
          melodyProgram: widget.melodyProgram,
          bassProgram: widget.bassProgram,
          melodyDecProgram: widget.melodyDecProgram,
          drumProgram: widget.drumProgram,
          extras: widget.extras,
          instruments: widget.instruments,
          songVocalPath: widget.songVocalPath,
          fallbackName: widget.songId);
      if (files.isEmpty) {
        if (mounted) _note(L10n.of(context).ltExportFailed, ok: false);
      } else {
        await _share(
          [for (final f in files) XFile(f.path)],
          '${widget.title} stems',
        );
        ClarityService.instance.event('export_stems');
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
        _scopeSections,
        widget.bpm,
        _scopeTitle,
        melodyProgram: widget.melodyProgram,
        bassProgram: widget.bassProgram,
        melodyDecProgram: widget.melodyDecProgram,
        drumProgram: widget.drumProgram,
        extras: widget.extras,
        instruments: widget.instruments,
        fallbackName: widget.songId,
      );
      debugPrint('[export] midi written: ${file.path}');
      // 파일 저장 후 iOS 의 share sheet 로 사용자에게 노출 — Documents 폴더가
      // sandboxed 라 share 없이는 사용자가 꺼낼 수 없음.
      final params = ShareParams(
        files: [XFile(file.path, mimeType: 'audio/midi')],
        text: '$_scopeTitle.mid',
        sharePositionOrigin: _shareOrigin(),
      );
      try {
        final r = await SharePlus.instance.share(params);
        debugPrint('[export] share result: ${r.status} ${r.raw}');
        ClarityService.instance.event('export_midi');
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
                      // Export scope: whole song, or a single loop (section).
                      if (secCount > 1) ...[
                        Text(l.ltExportScopeLabel,
                            style: LTType.inter(size: 11, weight: FontWeight.w700, color: LT.t2)),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _ScopeChip(
                              label: l.ltExportScopeAll,
                              selected: _selectedSection == null,
                              onTap: _busy != null ? null : () => setState(() => _selectedSection = null),
                            ),
                            for (var i = 0; i < widget.sections.length; i++)
                              _ScopeChip(
                                label: widget.sections[i].name,
                                selected: _selectedSection == i,
                                onTap: _busy != null ? null : () => setState(() => _selectedSection = i),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                      ],
                      _Row(icon: LtIcons.piano, title: l.ltExportMidiTitle, sub: l.ltExportMidiSub, color: LT.lime, onTap: _doMidi),
                      const SizedBox(height: 12),
                      // WAV / Stems — on-device SF2 render (instrumental mix;
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

// A pill chip for picking the export scope (whole song vs a single loop).
class _ScopeChip extends StatelessWidget {
  const _ScopeChip({required this.label, required this.selected, this.onTap});
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.5 : 1,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? LT.lime : LT.surface2,
            borderRadius: BorderRadius.circular(LTRadius.pill),
            border: Border.all(color: selected ? LT.lime : LT.border),
          ),
          child: Text(
            label,
            style: LTType.inter(
              size: 12,
              weight: FontWeight.w700,
              color: selected ? LT.bg : LT.t2,
            ),
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
