// 상단 활성 트랙 정보 카드 — INSTRUMENT (1단 풀폭) + KEY / 피치 어시스트 (2단 50/50).
// 시안: docs/mockups/track-expansion.html 의 .info-cards 영역을 Flutter 로 옮긴다.
//
// - INSTRUMENT 카드 탭 → showInstrumentPicker
// - KEY 카드 탭 → showKeyPicker
// - 피치 어시스트 우측 mini-toggle → store.togglePitchAssistant(on)
// - 각 카드의 ⓘ → showHelpSheet(title, body)
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../l10n/generated/app_localizations.dart';
import '../models/models.dart';
import '../music/instrument_icons.dart';
import '../state/project_store.dart';
import '../theme/app_theme.dart';
import 'sheets.dart';

part 'controls/mini_toggle.dart';
part 'controls/pulse_dot.dart';

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
          const SizedBox(height: 8),
          _QuantizeCard(store: store, track: t),
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

String _instrumentDisplayName(BuildContext context, TrackData t) {
  for (final i in instrumentsForRole(t.role)) {
    if (i.program == t.program) return i.label;
  }
  final l = L10n.of(context);
  return t.role == TrackRole.drum
      ? l.addTrackDrumKit
      : (t.role == TrackRole.vocal ? l.addTrackVocal : l.cardInstrumentFallback);
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
    final name = _instrumentDisplayName(context, track);
    final l = L10n.of(context);
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
                Text(l.cardInstrumentLabel, style: _labelStyle),
                _helpIcon(
                  context,
                  title: l.cardInstrumentLabel,
                  body: l.helpInstrumentBody,
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
    final l = L10n.of(context);
    final isAuto = track.options.autoKey;
    final tierLabel = dk?.keyTier == null ? '' : ' · ${dk!.keyTier}';
    final confText = dk == null
        ? l.keyAnalysisPending
        : l.keyConfidence(dk!.confidence.toStringAsFixed(2), tierLabel);
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
                  Text(l.cardKeyLabel, style: _labelStyle),
                  _helpIcon(
                    context,
                    title: l.cardKeyLabel,
                    body: l.helpKeyBody,
                  ),
                ]),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.activeLane,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    isAuto ? l.keyAuto : l.keyManual,
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
    final l = L10n.of(context);
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
                Text(l.cardAssistLabel, style: _labelStyle),
                _helpIcon(
                  context,
                  title: l.cardAssistLabel,
                  body: l.helpAssistBody,
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
                l.assistCorrected,
                style: T.body.copyWith(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Text(l.assistDesc, style: T.sub.copyWith(fontSize: 11, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

// ─── 박자 보정 카드 ─────────────────────────────────────────────────────
class _QuantizeCard extends StatelessWidget {
  const _QuantizeCard({required this.store, required this.track});
  final ProjectStore store;
  final TrackData track;

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final on = track.quantizeEnabled;
    final summary = on
        ? l.quantizeSummary(track.quantizeGrid, (track.quantizeStrength * 100).round(), store.bpm)
        : l.quantizeOff;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showQuantizeSheet(context, store),
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
                  Text(l.cardQuantizeLabel, style: _labelStyle),
                  _helpIcon(
                    context,
                    title: l.cardQuantizeLabel,
                    body: l.helpQuantizeBody,
                  ),
                ]),
                Row(children: [
                  if (on) _PulseDot(bpm: store.bpm),
                  if (on) const SizedBox(width: 8),
                  _MiniToggle(on: on, onTap: () => store.toggleTrackQuantize(track.id, !on)),
                ]),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              summary,
              style: T.body.copyWith(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: on ? AppColors.textPrimary : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// _PulseDot / _MiniToggle 는 widgets/controls/ 하위 part 파일에서 정의.
