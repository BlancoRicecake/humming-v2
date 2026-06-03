// 바텀 시트 3종: 악기 선택 / 노트 후보 / 내보내기·공유.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:material_symbols_icons/symbols.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../audio/player.dart';
import '../audio/synth.dart';
import '../audio/synth_player.dart';
import '../l10n/generated/app_localizations.dart';
import '../models/models.dart';
import '../music/chord_expand.dart';
import '../services/analytics_service.dart';
import '../music/instrument_icons.dart';
import '../music/strum.dart';
import '../state/project_store.dart';
import '../theme/app_theme.dart';
import 'common.dart';

// 노트 보정 시트 전용 — 단음 미리듣기 (6-3).
// 기존 백엔드 /render_audio + audioplayers 경로를 온디바이스 SoundFont 합성으로 교체.
// 200~500ms 네트워크 지연 → 즉시 응답 + 오프라인 동작.
int _previewSeq = 0;

BoxDecoration _sheetDeco() => const BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
    );

Widget _grabber() => Center(
      child: Container(
        width: 40,
        height: 4,
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(color: const Color(0xFF3F3F46), borderRadius: BorderRadius.circular(2)),
      ),
    );

// ─── 도움말 시트 ───────────────────────────────────────────────────────
// 5-3: 음악·DSP 용어(키/AUTO/피치 어시스트/단음·코드 등)에 짧은 설명.
// 카드 헤더의 ⓘ 아이콘 탭 → 이 시트가 모달로 노출. 닫기 버튼 1개.
void showHelpSheet(BuildContext context, String title, String body) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (_) => Container(
      decoration: _sheetDeco(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _grabber(),
          Row(
            children: [
              const Icon(Symbols.info, size: 18, color: AppColors.lime),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: T.h2.copyWith(fontSize: 17))),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            body,
            style: T.body.copyWith(fontSize: 13.5, height: 1.5, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.bg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                child: Text(L10n.of(context).close, style: T.body.copyWith(fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

// ─── 녹음 결과 사용/삭제 시트 ──────────────────────────────────────────
// 녹음 종료 → 분석/정리 결과 미리보기 + 사용/삭제. 어시스트 토글 포함(보컬 제외).
// 기존 인라인 트랙 박스에서 모달 시트로 승격 — 좁은 공간에 다 안 들어가는 문제 해결.
void showPendingRecordingSheet(
  BuildContext context,
  ProjectStore store, {
  VoidCallback? onRetry,
}) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    isScrollControlled: true,
    isDismissible: false, // 사용/삭제 버튼으로만 닫힘 (실수 dismiss 방지)
    enableDrag: false,
    builder: (sheetCtx) {
      return AnimatedBuilder(
        animation: store,
        builder: (_, __) {
          final p = store.pendingRecording;
          if (p == null) {
            // commit/discard 후 자동 닫힘.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (Navigator.canPop(sheetCtx)) Navigator.pop(sheetCtx);
            });
            return const SizedBox.shrink();
          }
          return _PendingSheetBody(store: store, p: p, onRetry: onRetry);
        },
      );
    },
  );
}

class _PendingSheetBody extends StatefulWidget {
  const _PendingSheetBody({required this.store, required this.p, this.onRetry});
  final ProjectStore store;
  final PendingRecording p;
  final VoidCallback? onRetry;

  @override
  State<_PendingSheetBody> createState() => _PendingSheetBodyState();
}

class _PendingSheetBodyState extends State<_PendingSheetBody> {
  final SynthPlayer _synth = SynthPlayer();
  final AudioPlayerService _audio = AudioPlayerService();
  bool _previewPlaying = false;
  StreamSubscription? _doneSub;

  @override
  void dispose() {
    _doneSub?.cancel();
    _synth.stop();
    _audio.stop();
    super.dispose();
  }

  Future<void> _togglePreview() async {
    final p = widget.p;
    if (_previewPlaying) {
      await _synth.stop();
      await _audio.stop();
      if (mounted) setState(() => _previewPlaying = false);
      return;
    }
    final isVocal = p.role == TrackRole.vocal;
    setState(() => _previewPlaying = true);
    _doneSub?.cancel();
    if (isVocal) {
      if (p.vocalWavPath == null) {
        setState(() => _previewPlaying = false);
        return;
      }
      await _audio.playFile(p.vocalWavPath!);
      // audioplayers 완료 시점 stream 이 따로 있지만 간단히 duration 후 reset.
      Future.delayed(Duration(milliseconds: (p.vocalDuration * 1000).toInt() + 200), () {
        if (mounted) setState(() => _previewPlaying = false);
      });
    } else {
      final tr = widget.store.trackById(p.trackId);
      final program = tr?.program ?? 0;
      final isDrum = tr?.role == TrackRole.drum;
      _doneSub = _synth.onComplete.listen((_) {
        if (mounted) setState(() => _previewPlaying = false);
      });
      // 커밋 후 렌더와 동일하게 변환된 노트로 미리듣기(베이스 저음역 배치 등).
      final notes = widget.store.pendingRenderNotes(p);
      await _synth.play([SynthTrack(notes: notes, program: program, isDrum: isDrum)]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final p = widget.p;
    final store = widget.store;
    final mq = MediaQuery.of(context);
    final isVocal = p.role == TrackRole.vocal;
    final analyzing = store.busy && p.analysis == null && p.vocalWavPath == null;
    final notesCount = p.notes.length;
    final dur = p.analysis?.durationSec ?? p.vocalDuration;
    final canPreview = !analyzing && (isVocal ? p.vocalWavPath != null : p.notes.isNotEmpty);
    return Container(
      decoration: _sheetDeco(),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + mq.viewPadding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _grabber(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: Text(l.pendingRecTitle, style: T.h2.copyWith(fontSize: 18))),
              if (widget.onRetry != null)
                _RetryIconBtn(
                  onTap: analyzing
                      ? null
                      : () async {
                          await _synth.stop();
                          await _audio.stop();
                          store.discardPendingRecording();
                          widget.onRetry!();
                        },
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            analyzing
                ? l.pendingAnalyzing
                : (isVocal
                    ? l.pendingVocalUseQ(dur.toStringAsFixed(1))
                    : l.pendingNotesUseQ(dur.toStringAsFixed(1), notesCount)),
            style: T.body.copyWith(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          Container(
            height: 110,
            decoration: BoxDecoration(
              color: AppColors.bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: analyzing
                ? const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.2, color: AppColors.lime),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.all(8),
                    child: CustomPaint(
                      painter: isVocal
                          ? _PendingWavePainter(peaks: p.vocalPeaks)
                          : _PendingNotesPainter(notes: widget.store.pendingRenderNotes(p)),
                      size: Size.infinite,
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          _previewButton(canPreview),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: _pendingSheetBtn(
                l.delete,
                outlined: true,
                onTap: () async {
                  await _synth.stop();
                  await _audio.stop();
                  store.discardPendingRecording();
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _pendingSheetBtn(
                l.use,
                outlined: false,
                onTap: analyzing
                    ? null
                    : () async {
                        await _synth.stop();
                        await _audio.stop();
                        store.commitPendingRecording();
                      },
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _previewButton(bool enabled) {
    final color = enabled
        ? (_previewPlaying ? AppColors.lime : AppColors.textPrimary)
        : AppColors.textTertiary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? _togglePreview : null,
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _previewPlaying ? AppColors.lime : AppColors.border),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(_previewPlaying ? Symbols.stop : Symbols.play_arrow, size: 18, color: color),
            const SizedBox(width: 6),
            Text(_previewPlaying ? L10n.of(context).pendingStop : L10n.of(context).pendingPreview,
                style: T.body.copyWith(fontSize: 14, fontWeight: FontWeight.w600, color: color)),
          ],
        ),
      ),
    );
  }
}

Widget _pendingSheetBtn(String label, {required bool outlined, VoidCallback? onTap}) {
  final disabled = onTap == null;
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Container(
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: outlined ? Colors.transparent : (disabled ? AppColors.border : AppColors.lime),
        border: outlined ? Border.all(color: AppColors.border) : null,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label,
          style: T.body.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: outlined ? AppColors.textPrimary : AppColors.bg)),
    ),
  );
}

class _PendingWavePainter extends CustomPainter {
  _PendingWavePainter({required this.peaks});
  final List<double> peaks;
  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty) return;
    final w = size.width, h = size.height;
    final pad = 8.0;
    final innerH = h - pad * 2;
    final mid = h / 2;
    final paint = Paint()..color = AppColors.lime..strokeWidth = 1.4..strokeCap = StrokeCap.round;
    final n = peaks.length;
    for (int i = 0; i < n; i++) {
      final x = (i / (n - 1)) * w;
      final a = peaks[i].clamp(0.0, 1.0) * innerH / 2;
      canvas.drawLine(Offset(x, mid - a), Offset(x, mid + a), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PendingWavePainter old) => old.peaks != peaks;
}

class _PendingNotesPainter extends CustomPainter {
  _PendingNotesPainter({required this.notes});
  final List<Note> notes;
  @override
  void paint(Canvas canvas, Size size) {
    if (notes.isEmpty) return;
    final w = size.width, h = size.height;
    final minT = notes.map((n) => n.start).reduce(math.min);
    final maxT = notes.map((n) => n.end).reduce(math.max);
    final span = math.max(maxT - minT, 0.05);
    final pitched = notes.where((n) => n.kind == 'pitched').toList();
    int minP = 60, maxP = 72;
    if (pitched.isNotEmpty) {
      minP = pitched.map((n) => n.pitch).reduce((a, b) => a < b ? a : b) - 1;
      maxP = pitched.map((n) => n.pitch).reduce((a, b) => a > b ? a : b) + 1;
    }
    final range = (maxP - minP).clamp(1, 127);
    final paint = Paint()..color = AppColors.lime;
    final bh = (h / range).clamp(4.0, 10.0);
    for (final n in notes) {
      final x = ((n.start - minT) / span) * w;
      final bw = math.max(((n.end - n.start) / span) * w, 3.0);
      if (n.kind == 'percussive') {
        canvas.drawRect(Rect.fromLTWH(x, h / 2 - 2, bw.clamp(3.0, 12.0), 4), paint);
        continue;
      }
      final tt = 1 - (n.pitch - minP) / range;
      final y = (tt * (h - bh)).clamp(0.0, h - bh);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, y, bw, bh), const Radius.circular(2)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PendingNotesPainter old) => old.notes != notes;
}

// ─── 트랙 추가 (FAB → 카테고리별 악기 시트) ───────────────────────────
// #27: 우측 하단 FAB 탭으로 열림. CHORDS / BASS / DRUM / VOCAL 4개 카테고리,
// 각 카테고리는 2 컬럼 악기 그리드. 카드 탭 → store.addTrack(role, program)
// + setActiveTrack → 사이드바/카드/녹음 pill 이 새 트랙으로 갱신.
//
// 표시용 카탈로그: 시안 docs/mockups/track-expansion.html Frame 5 와 1:1.
// `_AddTrackItem.program` 은 표시용 GM program — 드럼/보컬은 가상 program
// (kDrumKitProgram / kVocalProgram) 으로 아이콘만 결정되고, addTrack 시엔
// 0 (드럼) / 0 (보컬) 으로 전달해 기존 합성/매핑 로직과 호환.
class _AddTrackItem {
  final String name;
  final String sub;
  final int program;     // 표시용(아이콘/저장)
  final int? saveProgram; // store.addTrack 에 전달할 program (null = program 그대로)
  const _AddTrackItem(this.name, this.sub, this.program, {this.saveProgram});
}

// 트랙 추가 카탈로그 — instrumentPalette 의 패밀리당 "대표 1개"(첫 프리셋)만 노출.
// 세부 프리셋(P02, AG03 …)은 트랙 생성 후 악기 선택 시트(showInstrumentPicker)에서 고른다.
// i18n: name 은 런타임에 L10n 으로 해석 (시스템 언어 토글 즉시 반영).
Map<TrackRole, List<_AddTrackItem>> _buildAddTrackCatalog(L10n l) => {
  TrackRole.keys: [
    _AddTrackItem(l.addTrackPiano, 'Piano 1', 0),
    _AddTrackItem(l.addTrackAcousticGuitar, 'Nylon Guitar', 24),
    _AddTrackItem(l.addTrackElectricGuitar, 'Overdrive Guitar', 29),
    _AddTrackItem(l.addTrackSynth, 'Poly Synth', 90),
    _AddTrackItem(l.addTrackOrgan, 'Organ 1', 16),
    _AddTrackItem(l.addTrackStrings, 'Strings CLP', 48),
  ],
  TrackRole.bass: [
    _AddTrackItem(l.addTrackBassGuitar, 'Fingered Bass', 33),
    _AddTrackItem(l.addTrackSynthBass, 'Synth Bass 2', 39),
  ],
  TrackRole.drum: [
    // 드럼 키트 — 기본 Standard(0). 아이콘만 드럼킷, 저장 program 은 0.
    _AddTrackItem(l.addTrackDrumKit, 'Standard', kDrumKitProgram, saveProgram: 0),
  ],
  TrackRole.vocal: [
    _AddTrackItem(l.addTrackVocal, l.addTrackVocalSub, kVocalProgram, saveProgram: 0),
  ],
};

const Map<TrackRole, String> _categoryLabel = {
  TrackRole.keys: 'CHORDS',
  TrackRole.bass: 'BASS',
  TrackRole.drum: 'DRUM',
  TrackRole.vocal: 'VOCAL',
};

void showAddTrackSheet(BuildContext context, ProjectStore store) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetCtx) {
      final mq = MediaQuery.of(sheetCtx);
      return Container(
        decoration: _sheetDeco(),
        padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + mq.viewPadding.bottom),
        constraints: BoxConstraints(maxHeight: mq.size.height * 0.78),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _grabber(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(L10n.of(sheetCtx).addTrackTitle, style: T.h2.copyWith(fontSize: 17)),
                GestureDetector(
                  onTap: () => Navigator.pop(sheetCtx),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                    child: Text(L10n.of(sheetCtx).close,
                        style: T.body.copyWith(color: AppColors.textSecondary, fontSize: 14)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final role in TrackRole.values) ...[
                      _addTrackCategory(sheetCtx, store, role),
                      const SizedBox(height: 14),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

Widget _addTrackCategory(BuildContext context, ProjectStore store, TrackRole role) {
  final catalog = _buildAddTrackCatalog(L10n.of(context));
  final items = catalog[role] ?? const <_AddTrackItem>[];
  if (items.isEmpty) return const SizedBox.shrink();
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 8),
        child: Text(
          _categoryLabel[role] ?? role.label.toUpperCase(),
          style: T.label.copyWith(fontSize: 10, letterSpacing: 0.8, color: AppColors.textSecondary),
        ),
      ),
      // 2 컬럼 그리드 — LayoutBuilder 로 sheet 너비 기준 카드폭 계산.
      LayoutBuilder(builder: (ctx, c) {
        const gap = 8.0;
        final cardW = (c.maxWidth - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final it in items)
              SizedBox(
                width: cardW,
                child: _addTrackCard(context, store, role, it),
              ),
          ],
        );
      }),
    ],
  );
}

// ─── 앵커 키 확인 시트 ───────────────────────────────────────────────────
// 기준 트랙에서 검출한 키 + 상대조 + top3 후보를 보여주고 1탭 확정 → 프로젝트 키 잠금.
const _kPcNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

({String tonic, String scale})? _relativeKey(String tonic, String scale) {
  final pc = _kPcNames.indexOf(tonic);
  if (pc < 0) return null;
  if (scale == 'major') return (tonic: _kPcNames[(pc - 3 + 12) % 12], scale: 'minor');
  if (scale == 'minor') return (tonic: _kPcNames[(pc + 3) % 12], scale: 'major');
  return null;
}

String _scaleLabel(L10n l, String s) =>
    s == 'major' ? l.scaleMajor : (s == 'minor' ? l.scaleMinor : s);

/// 전환 시점에 호출 — 키 앵커 후보가 있으면 확인 시트를 띄워 프로젝트 키 잠금.
/// 첫 트랙이 드럼이라 키가 없으면 조용히 건너뜀(키는 첫 멜로딕에서 잠김).
Future<void> maybeConfirmAnchorKey(BuildContext context, ProjectStore store) async {
  final prop = store.anchorKeyProposal();
  if (prop == null) return;
  final chosen = await showModalBottomSheet<({String tonic, String scale})>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => _AnchorKeySheet(
        tonic: prop.tonic, scale: prop.scale, candidates: prop.candidates),
  );
  if (chosen != null && context.mounted) {
    store.confirmAnchorKey(chosen.tonic, chosen.scale);
  }
}

class _AnchorKeySheet extends StatelessWidget {
  const _AnchorKeySheet({required this.tonic, required this.scale, required this.candidates});
  final String tonic, scale;
  final List<KeyCandidate> candidates;

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final tagDetected = l.anchorKeyTagDetected;
    final opts = <({String tonic, String scale, String tag})>[];
    final seen = <String>{};
    void add(String t, String s, String tag) {
      if (seen.add('$t $s')) opts.add((tonic: t, scale: s, tag: tag));
    }
    add(tonic, scale, tagDetected);
    final rel = _relativeKey(tonic, scale);
    if (rel != null) add(rel.tonic, rel.scale, l.anchorKeyTagRelative);
    for (final c in candidates.take(3)) {
      add(c.tonic, c.scale, l.anchorKeyTagCandidate);
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.anchorKeyTitle, style: T.h2),
            const SizedBox(height: 4),
            Text(l.anchorKeySub, style: T.sub),
            const SizedBox(height: 16),
            ...opts.map((o) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.pop(context, (tonic: o.tonic, scale: o.scale)),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    decoration: BoxDecoration(
                      color: AppColors.bg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: o.tag == tagDetected ? AppColors.lime : AppColors.border),
                    ),
                    child: Row(children: [
                      Text('${o.tonic} ${_scaleLabel(l, o.scale)}',
                          style: T.label.copyWith(fontSize: 16)),
                      const Spacer(),
                      Text(o.tag,
                          style: T.sub.copyWith(
                              color: o.tag == tagDetected
                                  ? AppColors.lime
                                  : AppColors.textSecondary)),
                    ]),
                  ),
                )),
          ],
        ),
      ),
    );
  }
}

Widget _addTrackCard(BuildContext context, ProjectStore store, TrackRole role, _AddTrackItem it) {
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () async {
      // 기준(첫) 트랙을 마치고 다음 트랙으로 넘어가는 시점 → 앵커 잠금.
      // 그루브를 먼저 잠그고, 키는 검출값+상대조를 1탭 확인받아 잠근다.
      if (store.needsAnchorLock) {
        store.lockGroove();
        await maybeConfirmAnchorKey(context, store);
      }
      final saveProg = it.saveProgram ?? it.program;
      final added = store.addTrack(role, program: saveProg);
      store.setActiveTrack(added.id);
      if (context.mounted) Navigator.pop(context);
    },
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          instrumentIcon(it.program, size: 20, color: AppColors.textPrimary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(it.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: T.body.copyWith(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(it.sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: T.sub.copyWith(fontSize: 10, color: AppColors.textTertiary)),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

// ─── 악기 선택 ─────────────────────────────────────────────────────────
void showInstrumentPicker(BuildContext context, ProjectStore store) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    isScrollControlled: true, // 악기 수가 늘어나도 시트가 스크롤되도록(오버플로우 방지)
    builder: (sheetCtx) {
      final mq = MediaQuery.of(sheetCtx);
      final t = store.active;
      final families = instrumentPalette[t.role] ?? const <InstrumentFamily>[];
      final isDrum = t.role == TrackRole.drum;
      return Container(
        decoration: _sheetDeco(),
        padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + mq.viewPadding.bottom),
        constraints: BoxConstraints(maxHeight: mq.size.height * 0.78),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _grabber(),
            Text(L10n.of(sheetCtx).instrumentPickerTitle(t.role.label.toUpperCase()), style: T.h2.copyWith(fontSize: 18)),
            const SizedBox(height: 16),
            // 헤더는 고정, 패밀리(그룹) + 프리셋 목록 + 코드 모드 행만 스크롤.
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (families.isEmpty)
                      Text(L10n.of(sheetCtx).instrumentPickerVocalOnly, style: T.sub)
                    else
                      for (final fam in families) ...[
                        Padding(
                          padding: const EdgeInsets.only(left: 2, bottom: 8),
                          child: Text(fam.label,
                              style: T.label.copyWith(
                                  fontSize: 11, letterSpacing: 0.6, color: AppColors.textSecondary)),
                        ),
                        for (final inst in fam.instruments)
                          _instrumentRow(context, store, inst, t.program, isDrum),
                        const SizedBox(height: 8),
                      ],
                    if (t.isChordInstrument) ...[
                      const SizedBox(height: 2),
                      _chordModeRow(context, store),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// 악기 선택 시트의 한 프리셋 행. [isDrum] 이면 아이콘을 드럼킷으로 고정
/// (드럼 program 0/8/16… 이 멜로딕 아이콘으로 보이는 것 방지).
Widget _instrumentRow(
    BuildContext context, ProjectStore store, Instrument inst, int selectedProgram, bool isDrum) {
  final sel = inst.program == selectedProgram;
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: GestureDetector(
      onTap: () {
        store.setInstrument(inst.program);
        Navigator.pop(context);
      },
      child: Container(
        height: 54,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: sel ? AppColors.activeLane : AppColors.bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: sel ? AppColors.lime : AppColors.border, width: sel ? 1.5 : 1),
        ),
        child: Row(children: [
          instrumentIcon(
            isDrum ? kDrumKitProgram : inst.program,
            size: 18,
            color: sel ? AppColors.lime : AppColors.textSecondary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text('${inst.code} · ${inst.label}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: T.body.copyWith(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          // 미리듣기 — 선택/닫기 없이 소리만 재생(내부 GestureDetector 가 탭을 가로챔).
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _previewInstrument(inst, isDrum),
            child: Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.surface,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.border),
              ),
              child: const Icon(Symbols.play_arrow, size: 18, color: AppColors.textPrimary),
            ),
          ),
        ]),
      ),
    ),
  );
}

// 악기 미리듣기 — 중복 호출 시 마지막 것만 유효(시퀀스 가드).
int _instPreviewSeq = 0;

/// 선택/닫기 없이 해당 프리셋 소리만 잠깐 재생.
/// 멜로딕은 짧은 분산화음(또는 베이스 단음), 드럼은 킥/하이햇/스네어 패턴.
Future<void> _previewInstrument(Instrument inst, bool isDrum) async {
  final mySeq = ++_instPreviewSeq;
  try {
    await SynthEngine().stopAll();
    if (mySeq != _instPreviewSeq) return;
    if (isDrum) {
      await SynthEngine().ensureDrumKit(inst.program);
      if (mySeq != _instPreviewSeq) return;
      const hits = [36, 42, 38, 42]; // Kick · HiHat · Snare · HiHat
      for (final h in hits) {
        if (mySeq != _instPreviewSeq) return;
        SynthEngine().noteOn(channel: SynthEngine.drumChannel, pitch: h, velocity: 112);
        final p = h;
        Future<void>.delayed(const Duration(milliseconds: 220), () {
          SynthEngine().noteOff(channel: SynthEngine.drumChannel, pitch: p);
        });
        await Future<void>.delayed(const Duration(milliseconds: 180));
      }
    } else if (inst.chordCapable) {
      const pitches = [60, 64, 67]; // C-E-G 분산화음
      for (final p in pitches) {
        if (mySeq != _instPreviewSeq) return;
        SynthEngine().playNote(
          channel: 0,
          pitch: p,
          velocity: 100,
          program: inst.program,
          release: const Duration(milliseconds: 800),
        );
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    } else {
      // 베이스 등 단음 악기 — 낮은 음 한 번.
      SynthEngine().playNote(
        channel: 0,
        pitch: 40,
        velocity: 105,
        program: inst.program,
        release: const Duration(milliseconds: 900),
      );
    }
  } catch (_) {
    // 미리듣기 실패는 UI 에 영향 없음.
  }
}

Widget _chordModeRow(BuildContext context, ProjectStore store) {
  return StatefulBuilder(builder: (context, setLocal) {
    final l = L10n.of(context);
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(children: [
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.chordModeTitle, style: T.body.copyWith(fontWeight: FontWeight.w600)),
            Text(l.chordModeSub, style: T.sub.copyWith(fontSize: 11)),
          ],
        ),
        const Spacer(),
        _segToggle(
          left: l.chordModeMono,
          right: l.chordModeChord,
          rightActive: store.active.chordMode,
          onLeft: () => setLocal(() => store.setChordMode(false)),
          onRight: () => setLocal(() => store.setChordMode(true)),
        ),
      ]),
    );
  });
}

Widget _segToggle({
  required String left,
  required String right,
  required bool rightActive,
  required VoidCallback onLeft,
  required VoidCallback onRight,
}) {
  Widget seg(String label, bool active, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          decoration: BoxDecoration(
            color: active ? AppColors.lime : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(label,
              style: T.body.copyWith(
                  fontSize: 12, fontWeight: FontWeight.w600, color: active ? AppColors.bg : AppColors.textSecondary)),
        ),
      );
  return Container(
    padding: const EdgeInsets.all(3),
    decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(10)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      seg(left, !rightActive, onLeft),
      const SizedBox(width: 3),
      seg(right, rightActive, onRight),
    ]),
  );
}

// ─── 키 선택 (Auto / 수동) ────────────────────────────────────────────
void showKeyPicker(BuildContext context, ProjectStore store) {
  const tonics = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
  final opt = store.active.options;

  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (sheetCtx) {
      final l = L10n.of(sheetCtx);
      Widget chip(String label, bool active, VoidCallback onTap) => GestureDetector(
            onTap: () {
              onTap();
              Navigator.pop(context);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: active ? AppColors.lime : AppColors.bg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: active ? AppColors.lime : AppColors.border),
              ),
              child: Text(label,
                  style: T.body.copyWith(
                      fontSize: 13, fontWeight: FontWeight.w600, color: active ? AppColors.bg : AppColors.textPrimary)),
            ),
          );

      Widget section(String mode, String modeLabel) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(modeLabel, style: T.label),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in tonics)
                    chip(t, !opt.autoKey && opt.keyTonic == t && opt.scale == mode,
                        () => store.setAutoKey(false, tonic: t, scale: mode)),
                ],
              ),
              const SizedBox(height: 16),
            ],
          );

      return Container(
        decoration: _sheetDeco(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _grabber(),
              Text(l.keyPickerTitle, style: T.h2.copyWith(fontSize: 18)),
              const SizedBox(height: 4),
              Text(l.keyPickerSub, style: T.sub),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: chip(l.keyPickerAuto, opt.autoKey, () => store.setAutoKey(true)),
              ),
              const SizedBox(height: 16),
              Text(l.keyPickerMainRole, style: T.label),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final r in [TrackRole.keys, TrackRole.bass, TrackRole.vocal])
                    chip(r.label, store.mainKeyRole == r, () => store.setMainKeyFromRole(r)),
                ],
              ),
              const SizedBox(height: 16),
              section('major', l.keyPickerMajor),
              section('minor', l.keyPickerMinor),
            ],
          ),
        ),
      );
    },
  );
}

// ─── 노트 후보 ─────────────────────────────────────────────────────────
// 4-D: iOS Cupertino-style wheel picker — 룰렛 머신처럼 휠을 굴려 음을 선택.
// 전체 피아노 음역대(MIDI 21~108)를 다루고, 추천 후보엔 별/원음엔 알약 배지.
// 가운데 항목 = 선택값, lime divider로 시각화. 멈춘 위치를 디바운스로 store 반영.
void showNoteCandidate(BuildContext context, ProjectStore store, int index) {
  final t = store.active;
  if (index < 0 || index >= t.notes.length) return;
  final n = t.notes[index];
  if (n.kind != 'pitched') return;

  // 전체 피아노 음역대 — 높은 음이 위 (피아노 관습, 휠은 위로 갈수록 high pitch).
  const midiLo = 21;
  const midiHi = 108;
  final opts = [for (int p = midiHi; p >= midiLo; p--) p];
  final candidateSet = n.candidates.toSet();
  final program = t.program;

  // 시트 열릴 때 진행 중 미리듣기가 있으면 정리.
  SynthEngine().stopAll();
  // SoundFont 자산 lazy load 워밍업 — 첫 탭 응답 지연 제거.
  unawaited(SynthEngine().ensureLoaded());

  final initialIndex = opts.indexOf(n.pitch).clamp(0, opts.length - 1);

  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (_) {
      return _NoteWheelSheet(
        opts: opts,
        candidateSet: candidateSet,
        originalPitch: n.pitchOriginal,
        initialIndex: initialIndex,
        program: program,
        noteIndex: index,
        store: store,
      );
    },
  ).whenComplete(() {
    // 시트 닫히면 진행 중 미리듣기 정지.
    SynthEngine().stopAll();
  });
}

// 휠 피커 시트 본체 — StatefulWidget으로 분리해서 controller / debounce 깔끔 관리.
class _NoteWheelSheet extends StatefulWidget {
  final List<int> opts;
  final Set<int> candidateSet;
  final int originalPitch;
  final int initialIndex;
  final int program;
  final int noteIndex;
  final ProjectStore store;

  const _NoteWheelSheet({
    required this.opts,
    required this.candidateSet,
    required this.originalPitch,
    required this.initialIndex,
    required this.program,
    required this.noteIndex,
    required this.store,
  });

  @override
  State<_NoteWheelSheet> createState() => _NoteWheelSheetState();
}

class _NoteWheelSheetState extends State<_NoteWheelSheet> {
  late FixedExtentScrollController _wheelCtrl;
  late int _currentIdx;

  @override
  void initState() {
    super.initState();
    _currentIdx = widget.initialIndex;
    _wheelCtrl = FixedExtentScrollController(initialItem: widget.initialIndex);
  }

  @override
  void dispose() {
    _wheelCtrl.dispose();
    super.dispose();
  }

  Future<void> _preview(int pitch) async {
    final mySeq = ++_previewSeq;
    try {
      await SynthEngine().stopAll();
      if (mySeq != _previewSeq || !mounted) return;
      await SynthEngine().playNote(
        channel: 0,
        pitch: pitch,
        velocity: 100,
        program: widget.program,
        release: const Duration(milliseconds: 500),
      );
    } catch (_) {
      // 미리듣기는 부가 기능 — 실패해도 UI 영향 없음.
    }
  }

  // 휠 위치는 적용 버튼을 눌렀을 때만 store 에 반영. 자동 반영은 사용자 의도와
  // 다른 변경을 일으킬 수 있어 명시적 확정을 요구.
  void _onSelectedItemChanged(int i) {
    setState(() => _currentIdx = i);
  }

  Widget _itemFor(int i) {
    final p = widget.opts[i];
    final isCenter = i == _currentIdx;
    final isOriginal = p == widget.originalPitch;
    final isCandidate = widget.candidateSet.contains(p);
    // 가운데에서 떨어진 정도에 따라 폰트/투명도 살짝 변화.
    final dist = (i - _currentIdx).abs();
    final fontSize = isCenter ? 26.0 : (dist == 1 ? 19.0 : 16.0);
    final color = isCenter
        ? AppColors.textPrimary
        : (dist == 1 ? AppColors.textSecondary : AppColors.textTertiary);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (isCandidate) ...[
          Icon(Symbols.star,
              color: isCenter ? AppColors.lime : AppColors.lime.withValues(alpha: 0.55),
              size: isCenter ? 18 : 14),
          const SizedBox(width: 8),
        ],
        Text(
          noteName(p),
          style: T.body.copyWith(
            fontSize: fontSize,
            fontWeight: isCenter ? FontWeight.w700 : FontWeight.w500,
            color: color,
          ),
        ),
        if (isOriginal) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.border),
            ),
            child: Text(L10n.of(context).noteWheelOriginal,
                style: T.label.copyWith(fontSize: 10, color: AppColors.textSecondary)),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final mq = MediaQuery.of(context);
    const wheelHeight = 240.0;
    const itemExtent = 44.0;
    final centerPitch = widget.opts[_currentIdx];

    return Container(
      decoration: _sheetDeco(),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + mq.viewPadding.bottom),
      constraints: BoxConstraints(maxHeight: mq.size.height * 0.75),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _grabber(),
          // 헤더 — 취소 / 타이틀 / 적용.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                  child: Text(l.cancel, style: T.body.copyWith(color: AppColors.textSecondary, fontSize: 14)),
                ),
              ),
              Column(children: [
                Text(l.noteWheelTitle(widget.noteIndex + 1),
                    style: T.h2.copyWith(fontSize: 16)),
              ]),
              GestureDetector(
                onTap: () {
                  widget.store.applyCandidate(widget.noteIndex, centerPitch);
                  Navigator.pop(context);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                  child: Text(l.apply,
                      style: T.body.copyWith(color: AppColors.lime, fontSize: 14, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // 범례.
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Symbols.star, color: AppColors.lime, size: 13),
            const SizedBox(width: 4),
            Text(l.noteWheelRecommended, style: T.sub.copyWith(fontSize: 11)),
            const SizedBox(width: 14),
            Text(l.noteWheelOriginalHint, style: T.sub.copyWith(fontSize: 11)),
          ]),
          const SizedBox(height: 8),
          // 휠 영역 — ListWheelScrollView + 가운데 lime divider + 위/아래 fade.
          SizedBox(
            height: wheelHeight,
            child: Stack(
              children: [
                // 위/아래 fade 마스크.
                Positioned.fill(
                  child: ShaderMask(
                    shaderCallback: (rect) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black,
                        Colors.black,
                        Colors.transparent,
                      ],
                      stops: [0.0, 0.18, 0.82, 1.0],
                    ).createShader(rect),
                    blendMode: BlendMode.dstIn,
                    child: ListWheelScrollView.useDelegate(
                      controller: _wheelCtrl,
                      itemExtent: itemExtent,
                      diameterRatio: 1.6,
                      perspective: 0.0025,
                      physics: const FixedExtentScrollPhysics(),
                      overAndUnderCenterOpacity: 0.85,
                      onSelectedItemChanged: _onSelectedItemChanged,
                      childDelegate: ListWheelChildBuilderDelegate(
                        childCount: widget.opts.length,
                        builder: (_, i) => _itemFor(i),
                      ),
                    ),
                  ),
                ),
                // 가운데 선택 인디케이터 — lime 상하 divider.
                IgnorePointer(
                  child: Center(
                    child: Container(
                      height: itemExtent,
                      decoration: const BoxDecoration(
                        border: Border(
                          top: BorderSide(color: AppColors.lime, width: 1.2),
                          bottom: BorderSide(color: AppColors.lime, width: 1.2),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // 가운데 음 미리듣기 (스피커) — 휠 회전 중엔 자동 재생 X, 탭으로만.
          Center(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _preview(centerPitch),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                decoration: BoxDecoration(
                  color: AppColors.activeLane,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: AppColors.lime, width: 1.2),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Symbols.volume_up, color: AppColors.lime, size: 22),
                  const SizedBox(width: 8),
                  Text(noteName(centerPitch),
                      style: T.body.copyWith(fontWeight: FontWeight.w700, fontSize: 15)),
                  const SizedBox(width: 6),
                  Text(l.pendingPreview,
                      style: T.sub.copyWith(fontSize: 11, color: AppColors.textSecondary)),
                ]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 단일 노트 → 코드 선택 시트 ────────────────────────────────────────
// Chord 툴바 버튼이 호출. 선택한 단음을 ChordType 으로 확장(per-note chord).
// 칩 탭 = 미리듣기 (SynthEngine 으로 코드 동시 발음), 적용 버튼 = 확정.
// "원음" 칩(null) 은 단음 미리듣기 — 적용 시 unchord(코드면 단음 복원).
// 단일 진입점. selectedChunk 가 있으면 청크 모드, 아니면 selectedNote 기준.
void showChordPicker(BuildContext context, ProjectStore store) {
  final chunkId = store.selectedChunk;
  final noteIdx = store.selectedNote;
  if (chunkId == null && noteIdx == null) return;
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (_) => _ChordPickerSheet(store: store, noteIndex: noteIdx, chunkId: chunkId),
  ).whenComplete(() => SynthEngine().stopAll());
}

class _ChordPickerSheet extends StatefulWidget {
  final ProjectStore store;
  // 둘 중 하나만 non-null. chunkId 우선.
  final int? noteIndex;
  final int? chunkId;
  const _ChordPickerSheet({required this.store, required this.noteIndex, required this.chunkId});
  @override
  State<_ChordPickerSheet> createState() => _ChordPickerSheetState();
}

class _ChordPickerSheetState extends State<_ChordPickerSheet> {
  // null = 원음(단음). 그 외 ChordType = 코드.
  ChordType? _selected;
  int _previewSeq = 0;

  bool get _isChunkMode => widget.chunkId != null;

  // 미리듣기용 대표 루트 pitch — 청크 모드면 청크 안 첫 멜로딕 단음, 노트 모드면 선택 노트.
  Note? _previewRootNote() {
    final t = widget.store.active;
    if (_isChunkMode) {
      for (final n in t.notes) {
        if (n.chunkId == widget.chunkId && n.kind == 'pitched') return n;
      }
      return null;
    }
    final i = widget.noteIndex!;
    if (i < 0 || i >= t.notes.length) return null;
    return t.notes[i];
  }

  Future<void> _preview(ChordType? type) async {
    final mySeq = ++_previewSeq;
    final t = widget.store.active;
    final n = _previewRootNote();
    if (n == null) return;
    final dk = t.analysis?.detectedKey;
    final pitches = type == null
        ? [n.pitch]
        : chordPitches(n.pitch, type, tonic: dk?.tonic, scale: dk?.scale);
    try {
      await SynthEngine().stopAll();
      if (mySeq != _previewSeq || !mounted) return;
      // 기타(25/27) 코드는 줄을 시간차로 긁듯 staggering, 그 외엔 동시 발음.
      if (isGuitarProgram(t.program) && pitches.length > 1) {
        final schedule =
            strumPreviewSchedule(pitches, 100, bpm: widget.store.bpm, atSec: n.start);
        for (final s in schedule) {
          if (s.delaySec > 0) {
            await Future<void>.delayed(
                Duration(milliseconds: (s.delaySec * 1000).round()));
            if (mySeq != _previewSeq || !mounted) return;
          }
          SynthEngine().playNote(
            channel: 0,
            pitch: s.pitch,
            velocity: s.velocity,
            program: t.program,
            release: const Duration(milliseconds: 700),
          );
        }
      } else {
        for (final p in pitches) {
          // 동시 발음 — 각 pitch 가 독립 release 타이머.
          SynthEngine().playNote(
            channel: 0,
            pitch: p,
            velocity: 100,
            program: t.program,
            release: const Duration(milliseconds: 700),
          );
        }
      }
    } catch (_) {
      // 미리듣기 실패해도 UI 영향 없음.
    }
  }

  void _onSelect(ChordType? type) {
    setState(() => _selected = type);
    _preview(type);
  }

  void _onApply() {
    final store = widget.store;
    if (_isChunkMode) {
      final id = widget.chunkId!;
      if (_selected == null) {
        if (store.canUnchordChunkSelected) store.unchordChunk(id);
      } else {
        // 이미 일부 코드 묶음이 있어도 OK — applyChordToChunk 는 chord 멤버 스킵.
        // 동일 코드로 통일하려면 먼저 unchord 후 적용.
        if (store.canUnchordChunkSelected) store.unchordChunk(id);
        store.applyChordToChunk(id, _selected!);
      }
    } else {
      final i = widget.noteIndex!;
      final wasChord = store.canUnchordSelected;
      if (_selected == null) {
        if (wasChord) store.unchordSelected();
      } else {
        if (wasChord) store.unchordSelected();
        final newIdx = store.selectedNote ?? i;
        store.applyChord(newIdx, _selected!);
      }
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final t = widget.store.active;
    final dk = t.analysis?.detectedKey;
    final hasKey = dk?.tonic != null && dk?.scale != null;
    final isCurrentlyChord = _isChunkMode
        ? widget.store.canUnchordChunkSelected
        : widget.store.canUnchordSelected;
    final rootNote = _previewRootNote();

    Widget chip(ChordType? type, String label, String sub) {
      final active = _selected == type;
      return GestureDetector(
        onTap: () => _onSelect(type),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: active ? AppColors.activeLane : AppColors.bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: active ? AppColors.lime : AppColors.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: T.body.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: active ? AppColors.lime : AppColors.textPrimary,
                  )),
              const SizedBox(height: 2),
              Text(sub, style: T.sub.copyWith(fontSize: 10, color: AppColors.textSecondary)),
            ],
          ),
        ),
      );
    }

    final types = hasKey
        ? ChordType.values
        : ChordType.values.where((t) => t != ChordType.diatonic).toList();

    return Container(
      decoration: _sheetDeco(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _grabber(),
          // 헤더 — 취소 / 타이틀 / 적용.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                  child: Text(l.cancel, style: T.body.copyWith(color: AppColors.textSecondary, fontSize: 14)),
                ),
              ),
              Text(l.chordPickerTitle, style: T.h2.copyWith(fontSize: 16)),
              GestureDetector(
                onTap: _onApply,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                  child: Text(l.apply,
                      style: T.body.copyWith(color: AppColors.lime, fontSize: 14, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            () {
              final rootLabel = rootNote != null ? noteName(rootNote.pitch) : '—';
              final scope = _isChunkMode ? l.chordPickerScopeChunk : l.chordPickerScopeRoot;
              final keyPart = hasKey ? l.chordPickerKeyPart(dk!.label) : l.chordPickerNoKey;
              final chordPart = isCurrentlyChord ? l.chordPickerCurrent : '';
              return l.chordPickerSummary(scope, rootLabel, keyPart, chordPart);
            }(),
            style: T.sub,
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              chip(null, l.chordPickerMono, l.chordPickerMonoSub),
              for (final type in types) chip(type, type.label, type.intervalsLabel),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── 내보내기 / 공유 ───────────────────────────────────────────────────
void showExportShare(BuildContext context, ProjectStore store) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (sheetCtx) {
      final l = L10n.of(sheetCtx);
      return Container(
        decoration: _sheetDeco(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _grabber(),
            Text(l.exportTitle(store.title), style: T.h2.copyWith(fontSize: 18)),
            const SizedBox(height: 14),
            Disabled(
              label: l.exportCloudSaveLabel,
              child: _exportRow(Symbols.cloud_done, l.exportCloudSaveTitle, l.exportCloudSaveSub, AppColors.lime),
            ),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => _exportFile(context, store, midi: true),
              child: _exportRow(Symbols.piano, l.exportMidiTitle, l.exportMidiSub, AppColors.textPrimary),
            ),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => _exportFile(context, store, midi: false),
              child: _exportRow(Symbols.graphic_eq, l.exportAudioTitle, l.exportAudioSub, AppColors.textPrimary),
            ),
            const SizedBox(height: 10),
            Disabled(
              label: l.exportShareLabel,
              child: _exportRow(Symbols.ios_share, l.exportShareLabel, l.exportShareSub, AppColors.textPrimary),
            ),
          ],
        ),
      );
    },
  );
}

Widget _exportRow(IconData ic, String title, String sub, Color iconColor) {
  return Container(
    height: 64,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    decoration: BoxDecoration(
      color: AppColors.bg,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AppColors.border),
    ),
    child: Row(children: [
      Icon(ic, size: 24, color: iconColor),
      const SizedBox(width: 14),
      Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: T.body.copyWith(fontSize: 15, fontWeight: FontWeight.w600)),
          Text(sub, style: T.sub.copyWith(fontSize: 11)),
        ],
      ),
      const Spacer(),
      const Icon(Symbols.chevron_right, size: 22, color: AppColors.textTertiary),
    ]),
  );
}

Future<void> _exportFile(BuildContext context, ProjectStore store, {required bool midi}) async {
  try {
    // 재생 ▶ 와 동일한 결과: enabled 트랙 전부를 믹스/멀티트랙으로 export.
    final bytes = midi ? await store.exportMidiMix() : await store.exportMixWav();
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/humming_${DateTime.now().millisecondsSinceEpoch}.${midi ? 'mid' : 'wav'}');
    await f.writeAsBytes(bytes, flush: true);
    if (context.mounted) Navigator.pop(context);
    AnalyticsService.instance.songExported(format: midi ? 'midi' : 'wav');
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], text: store.title));
  } catch (e) {
    if (context.mounted) comingSoon(context, L10n.of(context).exportFailed('$e'));
  }
}

// ─── 박자 보정 시트 ─────────────────────────────────────────────────────
// BPM stepper + 메트로놈 자동 클릭(시청각 보조) + 그리드 chips + 강도 슬라이더.
// 시트 열려있는 동안 메트로놈 켜져 BPM 빠르기를 귀로 확인 가능.
// ─── 메트로놈 시트 ─────────────────────────────────────────────────────
// 트랜스포트 메트로놈 버튼 → BPM stepper + on/off 토글. 박자보정 시트와 기능 분리:
// 박자보정 = 노트 정렬(그리드/강도) / 메트로놈 = 청각 클릭 + BPM 설정(공통 store.bpm).
void showMetronomeSheet(
  BuildContext context,
  ProjectStore store, {
  required Future<void> Function(bool on) onToggle,
  required Future<void> Function() onBpmChanged,
}) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (_) => _MetroSheetBody(store: store, onToggle: onToggle, onBpmChanged: onBpmChanged),
  );
}

class _MetroSheetBody extends StatefulWidget {
  const _MetroSheetBody({required this.store, required this.onToggle, required this.onBpmChanged});
  final ProjectStore store;
  final Future<void> Function(bool on) onToggle;
  final Future<void> Function() onBpmChanged;
  @override
  State<_MetroSheetBody> createState() => _MetroSheetBodyState();
}

class _MetroSheetBodyState extends State<_MetroSheetBody> {
  DateTime? _anchor;

  String _tempoHint(L10n l, int bpm) {
    if (bpm < 70) return l.tempoVerySlow;
    if (bpm < 95) return l.tempoBallad;
    if (bpm < 115) return l.tempoMidPop;
    if (bpm < 135) return l.tempoDance;
    if (bpm < 160) return l.tempoFast;
    return l.tempoVeryFast;
  }

  void _refreshAnchor() {
    // 메트로놈 켜진 동안엔 시각 펄스를 BPM 변경 시 매번 새로 anchor → drift 없는 sync.
    _anchor = DateTime.now();
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final mq = MediaQuery.of(context);
    return AnimatedBuilder(
      animation: widget.store,
      builder: (_, __) {
        final store = widget.store;
        return Container(
          decoration: _sheetDeco(),
          padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + mq.viewPadding.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _grabber(),
              Row(children: [
                Text(l.metronomeTitle, style: T.h2.copyWith(fontSize: 18)),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Text(l.done,
                        style: T.body.copyWith(color: AppColors.lime, fontWeight: FontWeight.w700)),
                  ),
                ),
              ]),
              const SizedBox(height: 14),
              // BPM + 시각 펄스 (메트로놈 켜져 있을 때만 anchor 활성)
              Row(children: [
                _PulseLarge(bpm: store.bpm, anchor: store.metroOn ? _anchor : null),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text('${store.bpm}',
                            style: T.h1.copyWith(fontSize: 38, fontFeatures: const [FontFeature.tabularFigures()])),
                        const SizedBox(width: 4),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text('BPM', style: T.label.copyWith(color: AppColors.textSecondary)),
                        ),
                      ]),
                      Text(_tempoHint(l, store.bpm),
                          style: T.body.copyWith(fontSize: 12, color: AppColors.textSecondary)),
                      Text(l.metronomeBeatSec((60 / store.bpm).toStringAsFixed(2)),
                          style: T.label.copyWith(fontSize: 10, color: AppColors.textTertiary)),
                    ],
                  ),
                ),
              ]),
              const SizedBox(height: 14),
              Row(children: [
                _metroStep(Symbols.fast_rewind, () async {
                  store.setBpm(store.bpm - 5);
                  await widget.onBpmChanged();
                  setState(_refreshAnchor);
                }),
                const SizedBox(width: 6),
                _metroStep(Symbols.remove, () async {
                  store.setBpm(store.bpm - 1);
                  await widget.onBpmChanged();
                  setState(_refreshAnchor);
                }),
                const Spacer(),
                _metroStep(Symbols.add, () async {
                  store.setBpm(store.bpm + 1);
                  await widget.onBpmChanged();
                  setState(_refreshAnchor);
                }),
                const SizedBox(width: 6),
                _metroStep(Symbols.fast_forward, () async {
                  store.setBpm(store.bpm + 5);
                  await widget.onBpmChanged();
                  setState(_refreshAnchor);
                }),
              ]),
              const SizedBox(height: 18),
              // 메트로놈 on/off 토글 — 큰 버튼.
              GestureDetector(
                onTap: () async {
                  final next = !store.metroOn;
                  await widget.onToggle(next);
                  if (next) {
                    setState(_refreshAnchor);
                  } else {
                    setState(() => _anchor = null);
                  }
                },
                child: Container(
                  width: double.infinity,
                  height: 52,
                  decoration: BoxDecoration(
                    color: store.metroOn ? AppColors.lime : Colors.transparent,
                    border: Border.all(
                      color: store.metroOn ? AppColors.lime : AppColors.border,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  alignment: Alignment.center,
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(
                      store.metroOn ? Symbols.stop : Symbols.play_arrow,
                      size: 20,
                      color: store.metroOn ? AppColors.bg : AppColors.textPrimary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      store.metroOn ? l.metronomeOff : l.metronomeOn,
                      style: T.body.copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: store.metroOn ? AppColors.bg : AppColors.textPrimary,
                      ),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                l.metronomeNote,
                style: T.body.copyWith(fontSize: 12, color: AppColors.textSecondary, height: 1.4),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _metroStep(IconData ic, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: AppColors.bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.border),
        ),
        child: Icon(ic, size: 18, color: AppColors.textPrimary),
      ),
    );
  }
}

void showQuantizeSheet(BuildContext context, ProjectStore store) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetCtx) => _QuantizeSheetBody(store: store),
  );
}

class _QuantizeSheetBody extends StatefulWidget {
  const _QuantizeSheetBody({required this.store});
  final ProjectStore store;
  @override
  State<_QuantizeSheetBody> createState() => _QuantizeSheetBodyState();
}

class _QuantizeSheetBodyState extends State<_QuantizeSheetBody> {
  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final mq = MediaQuery.of(context);
    return AnimatedBuilder(
      animation: widget.store,
      builder: (_, __) {
        final store = widget.store;
        final t = store.active;
        return Container(
          decoration: _sheetDeco(),
          padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + mq.viewPadding.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _grabber(),
              Row(children: [
                Text(l.quantizeTitle, style: T.h2.copyWith(fontSize: 18)),
                const Spacer(),
                Text('BPM ${store.bpm}',
                    style: T.label.copyWith(fontSize: 11, color: AppColors.textSecondary)),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Text(l.done,
                        style: T.body.copyWith(color: AppColors.lime, fontWeight: FontWeight.w700)),
                  ),
                ),
              ]),
              const SizedBox(height: 14),
              Text(
                l.quantizeBpmHint,
                style: T.body.copyWith(fontSize: 11, color: AppColors.textTertiary),
              ),
              const Divider(height: 28, color: Color(0xFF222229)),
              // 박자 단위 (그리드)
              Text(l.quantizeGridLabel,
                  style: T.label.copyWith(
                      fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
              const SizedBox(height: 8),
              Row(children: [
                for (final g in [4, 8, 16, 32]) ...[
                  _gridChip(g, t.quantizeGrid, () => store.setTrackQuantize(t.id, grid: g)),
                  if (g != 32) const SizedBox(width: 8),
                ],
              ]),
              const SizedBox(height: 6),
              Text(l.quantizeGridDetail(t.quantizeGrid ~/ 4),
                  style: T.label.copyWith(fontSize: 10, color: AppColors.textTertiary)),
              const SizedBox(height: 18),
              // 강도
              Row(children: [
                Text(l.quantizeStrength,
                    style: T.label.copyWith(
                        fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
                const Spacer(),
                Text('${(t.quantizeStrength * 100).round()}%',
                    style: T.body.copyWith(fontWeight: FontWeight.w700)),
              ]),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: AppColors.lime,
                  inactiveTrackColor: AppColors.border,
                  thumbColor: AppColors.lime,
                  overlayColor: AppColors.lime.withValues(alpha: 0.2),
                ),
                child: Slider(
                  value: t.quantizeStrength,
                  min: 0,
                  max: 1,
                  divisions: 20,
                  onChanged: (v) => store.setTrackQuantize(t.id, strength: v),
                ),
              ),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(l.quantizeStrengthMin,
                    style: T.label.copyWith(fontSize: 10, color: AppColors.textTertiary)),
                Text(l.quantizeStrengthMax,
                    style: T.label.copyWith(fontSize: 10, color: AppColors.textTertiary)),
              ]),
              const SizedBox(height: 14),
              Text(
                l.quantizeFooter,
                style: T.body.copyWith(fontSize: 12, color: AppColors.textSecondary, height: 1.4),
              ),
            ],
          ),
        );
      },
    );
  }


  Widget _gridChip(int grid, int current, VoidCallback onTap) {
    final active = grid == current;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active ? AppColors.lime : Colors.transparent,
          border: Border.all(color: active ? AppColors.lime : AppColors.border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text('1/$grid',
            style: T.body.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: active ? AppColors.bg : AppColors.textPrimary,
            )),
      ),
    );
  }
}

class _PulseLarge extends StatefulWidget {
  const _PulseLarge({required this.bpm, required this.anchor});
  final int bpm;
  final DateTime? anchor; // 메트로놈 첫 클릭 기준점 — 펄스 위상을 여기에 락.
  @override
  State<_PulseLarge> createState() => _PulseLargeState();
}

class _PulseLargeState extends State<_PulseLarge> with SingleTickerProviderStateMixin {
  late Ticker _ticker;
  double _v = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration _) {
    final anchor = widget.anchor;
    if (anchor == null) {
      if (_v != 0) setState(() => _v = 0);
      return;
    }
    final periodMs = (60000 / widget.bpm).clamp(150.0, 2000.0);
    final elapsedMs = DateTime.now().difference(anchor).inMicroseconds / 1000.0;
    if (elapsedMs < 0) {
      if (_v != 0) setState(() => _v = 0);
      return;
    }
    final phase = (elapsedMs % periodMs) / periodMs; // 0..1
    // 비트 시작 시 1.0 피크, easeIn 으로 감쇠 → 다음 비트 직전 0.
    final next = (1.0 - phase) * (1.0 - phase); // easeIn 근사 (x→x^2 decay)
    if ((next - _v).abs() > 0.005) setState(() => _v = next);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _v;
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: AppColors.lime.withValues(alpha: 0.15 + 0.6 * v),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: AppColors.lime.withValues(alpha: 0.45 * v),
            blurRadius: 20 * v,
            spreadRadius: 2 * v,
          ),
        ],
      ),
    );
  }
}

/// 녹음 완료 시트 우상단 — 결과가 맘에 안 들 때 즉시 재녹음.
class _RetryIconBtn extends StatelessWidget {
  const _RetryIconBtn({required this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled
              ? AppColors.lime.withValues(alpha: 0.14)
              : AppColors.surface,
          shape: BoxShape.circle,
          border: Border.all(
            color: enabled ? AppColors.lime.withValues(alpha: 0.5) : AppColors.border,
          ),
        ),
        child: Icon(
          Symbols.refresh,
          size: 20,
          color: enabled ? AppColors.lime : AppColors.textTertiary,
        ),
      ),
    );
  }
}
