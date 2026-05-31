// 상단 활성 트랙 정보 카드 — INSTRUMENT (1단 풀폭) + KEY / 피치 어시스트 (2단 50/50).
// 시안: docs/mockups/track-expansion.html 의 .info-cards 영역을 Flutter 로 옮긴다.
//
// - INSTRUMENT 카드 탭 → showInstrumentPicker
// - KEY 카드 탭 → showKeyPicker
// - 피치 어시스트 우측 mini-toggle → store.togglePitchAssistant(on)
// - 각 카드의 ⓘ → showHelpSheet(title, body)
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../models/models.dart';
import '../music/instrument_icons.dart';
import '../state/project_store.dart';
import '../theme/app_theme.dart';
import 'sheets.dart';

class ActiveTrackCards extends StatelessWidget {
  const ActiveTrackCards({super.key, required this.store});
  final ProjectStore store;

  @override
  Widget build(BuildContext context) {
    final t = store.active;
    final dk = t.analysis?.detectedKey;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          _InstrumentCard(store: store, track: t),
          const SizedBox(height: 8),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _KeyCard(store: store, track: t, dk: dk)),
                const SizedBox(width: 10),
                Expanded(child: _AssistCard(store: store, track: t)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 공통 토큰 ───────────────────────────────────────────────────────────
const double _cardPad = 14;
const double _cardRadius = 14;

BoxDecoration _cardDecoration() => BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(_cardRadius),
      border: Border.all(color: AppColors.border),
    );

TextStyle get _labelStyle => T.label.copyWith(
      fontSize: 9,
      letterSpacing: 0.8,
      fontWeight: FontWeight.w700,
      color: AppColors.textSecondary,
    );

Widget _helpIcon(BuildContext context, {required String title, required String body}) {
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => showHelpSheet(context, title, body),
    child: const Padding(
      padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Icon(Symbols.info, size: 13, color: AppColors.textTertiary),
    ),
  );
}

String _instrumentDisplayName(TrackData t) {
  for (final i in instrumentPalette[t.role] ?? const <Instrument>[]) {
    if (i.program == t.program) return i.label;
  }
  return t.role == TrackRole.drum ? '드럼 키트' : (t.role == TrackRole.vocal ? '원본 보컬' : '악기');
}

int _iconProgram(TrackData t) {
  switch (t.role) {
    case TrackRole.drum:
      return kDrumKitProgram;
    case TrackRole.vocal:
      return kVocalProgram;
    case TrackRole.keys:
    case TrackRole.bass:
      return t.program;
  }
}

// ─── INSTRUMENT 카드 ────────────────────────────────────────────────────
class _InstrumentCard extends StatelessWidget {
  const _InstrumentCard({required this.store, required this.track});
  final ProjectStore store;
  final TrackData track;

  @override
  Widget build(BuildContext context) {
    final program = _iconProgram(track);
    final name = _instrumentDisplayName(track);
    return GestureDetector(
      onTap: () => showInstrumentPicker(context, store),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(_cardPad),
        decoration: _cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                instrumentIcon(program, size: 11, color: AppColors.textSecondary),
                const SizedBox(width: 6),
                Text('INSTRUMENT', style: _labelStyle),
                _helpIcon(
                  context,
                  title: 'INSTRUMENT',
                  body:
                      '이 트랙을 어떤 악기 소리로 재생할지 선택해요. '
                      '분석된 음정에 SoundFont 악기 음색을 입혀 들려줘요.',
                ),
                const Spacer(),
                const Icon(Symbols.keyboard_arrow_down, size: 18, color: AppColors.textSecondary),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                instrumentIcon(program, size: 20, color: AppColors.lime),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: T.body.copyWith(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── KEY 카드 ───────────────────────────────────────────────────────────
class _KeyCard extends StatelessWidget {
  const _KeyCard({required this.store, required this.track, required this.dk});
  final ProjectStore store;
  final TrackData track;
  final DetectedKey? dk;

  @override
  Widget build(BuildContext context) {
    final isAuto = track.options.autoKey;
    final tierLabel = dk?.keyTier == null ? '' : ' · ${dk!.keyTier}';
    final confText = dk == null ? '녹음 후 분석' : '신뢰도 ${dk!.confidence.toStringAsFixed(2)}$tierLabel';
    return GestureDetector(
      onTap: () => showKeyPicker(context, store),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(_cardPad),
        decoration: _cardDecoration(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(children: [
                  Text('KEY', style: _labelStyle),
                  _helpIcon(
                    context,
                    title: 'KEY',
                    body:
                        '곡의 으뜸음(C, D…)과 모드(메이저/마이너)예요. '
                        'AUTO = 분석이 자동 추정한 키. 카드를 탭하면 수동으로 바꿀 수 있어요. '
                        '신뢰도 = 추정이 얼마나 확실한지 (0~1).',
                  ),
                ]),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.activeLane,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    isAuto ? 'AUTO' : '수동',
                    style: T.label.copyWith(
                      color: AppColors.lime,
                      fontSize: 8,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              dk?.label ?? '—',
              style: T.body.copyWith(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
            ),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: Text(
                  confText,
                  style: T.sub.copyWith(fontSize: 11, color: AppColors.textSecondary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Icon(Symbols.keyboard_arrow_down, size: 14, color: AppColors.textSecondary),
            ]),
          ],
        ),
      ),
    );
  }
}

// ─── 피치 어시스트 카드 ──────────────────────────────────────────────────
class _AssistCard extends StatelessWidget {
  const _AssistCard({required this.store, required this.track});
  final ProjectStore store;
  final TrackData track;

  @override
  Widget build(BuildContext context) {
    final on = track.options.pitchAssistant;
    final count = track.analysis?.assistAppliedCount ?? 0;
    return Container(
      padding: const EdgeInsets.all(_cardPad),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(children: [
                Text('피치 어시스트', style: _labelStyle),
                _helpIcon(
                  context,
                  title: '피치 어시스트',
                  body:
                      '키 밖으로 살짝 빗나간 음을 가장 가까운 in-key 음으로 자동 보정해 줘요. '
                      '"보정됨" 숫자 = 실제로 끌어당겨진 노트 개수.',
                ),
              ]),
              _MiniToggle(on: on, onTap: () => store.togglePitchAssistant(!on)),
            ],
          ),
          const SizedBox(height: 6),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(
              '$count',
              style: T.body.copyWith(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.lime),
            ),
            const SizedBox(width: 4),
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '보정됨',
                style: T.body.copyWith(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Text('키 밖 음 자동 정리', style: T.sub.copyWith(fontSize: 11, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

class _MiniToggle extends StatelessWidget {
  const _MiniToggle({required this.on, required this.onTap});
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 36,
        height: 20,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: on ? AppColors.lime : AppColors.border,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Align(
          alignment: on ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 16,
            height: 16,
            decoration: const BoxDecoration(color: AppColors.bg, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }
}
