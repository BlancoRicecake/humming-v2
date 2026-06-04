// 악기 선택 시트 — 트랙 활성 시 카테고리별 프리셋 + 미리듣기 + 코드 모드 행.
part of '../sheets.dart';

// 악기 미리듣기 — 중복 호출 시 마지막 것만 유효(시퀀스 가드).
int _instPreviewSeq = 0;

// InstrumentFamily.label (한글 캐논 ID) → 로컬라이즈된 라벨.
// 패밀리 라벨은 addTrack* ARB 키와 동일 매핑.
String _localizedFamilyLabel(L10n l, String label) {
  switch (label) {
    case '피아노':
      return l.addTrackPiano;
    case '어쿠스틱 기타':
      return l.addTrackAcousticGuitar;
    case '일렉 기타':
      return l.addTrackElectricGuitar;
    case '신스':
      return l.addTrackSynth;
    case '오르간':
      return l.addTrackOrgan;
    case '스트링':
      return l.addTrackStrings;
    case '베이스 기타':
      return l.addTrackBassGuitar;
    case '신스 베이스':
      return l.addTrackSynthBass;
    case '드럼 키트':
      return l.addTrackDrumKit;
    default:
      return label;
  }
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
                          child: Text(_localizedFamilyLabel(L10n.of(sheetCtx), fam.label),
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
