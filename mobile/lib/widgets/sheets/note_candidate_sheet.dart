// 노트 후보 휠 피커 — Cupertino-style wheel로 음 선택.
part of '../sheets.dart';

// 노트 보정 시트 전용 — 단음 미리듣기 (6-3).
// 기존 백엔드 /render_audio + audioplayers 경로를 온디바이스 SoundFont 합성으로 교체.
// 200~500ms 네트워크 지연 → 즉시 응답 + 오프라인 동작.
int _previewSeq = 0;

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
