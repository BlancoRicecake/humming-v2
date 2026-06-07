// 트랙 추가 시트 (FAB → 카테고리별 악기 그리드) + 앵커 키 확인 시트.
part of '../sheets.dart';

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
    await store.confirmAnchorKey(chosen.tonic, chosen.scale);
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
