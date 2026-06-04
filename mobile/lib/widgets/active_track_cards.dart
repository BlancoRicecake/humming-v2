// 상단 활성 트랙 정보 카드 — INSTRUMENT (1단 풀폭) + KEY / 피치 어시스트 (2단 50/50).
// 시안: docs/mockups/track-expansion.html 의 .info-cards 영역을 Flutter 로 옮긴다.
//
// - INSTRUMENT 카드 탭 → showInstrumentPicker
// - KEY 카드 탭 → showKeyPicker
// - 피치 어시스트 우측 mini-toggle → store.togglePitchAssistant(on)
// - 각 카드의 ⓘ → showHelpSheet(title, body)
import 'package:flutter/foundation.dart' show kDebugMode;
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
    // 드럼은 음정/키가 없음 → KEY·ASSIST(피치 어시스턴트) 카드 미표시. 그루브가 핵심인
    // Quantize 카드만 악기 카드와 함께 둔다.
    final isDrum = t.role == TrackRole.drum;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          _InstrumentCard(store: store, track: t),
          const SizedBox(height: 8),
          if (!isDrum) ...[
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
          ],
          _QuantizeCard(store: store, track: t),
          if (kDebugMode) _PitchModelDebugCard(store: store, track: t),
        ],
      ),
    );
  }
}

// ─── [DEBUG] 피치 트래커 토글 (kDebugMode 전용, 출시 빌드 미노출) ──────────
// pyin↔crepe 전환 → 전체 재분석. CREPE 는 dev 백엔드에만 존재(prod 미배포).
// 디바이스에서 같은 녹음을 두 트래커로 즉시 비교하기 위한 도구.
class _PitchModelDebugCard extends StatelessWidget {
  const _PitchModelDebugCard({required this.store, required this.track});
  final ProjectStore store;
  final TrackData track;

  @override
  Widget build(BuildContext context) {
    final model = track.options.pitchModel;
    final hasWav = (track.wavPath ?? '').isNotEmpty;
    final pitched = track.analysis?.notes.where((n) => n.kind == 'pitched').length ?? 0;

    Widget seg(String value, String label) {
      final sel = model == value;
      return Expanded(
        child: GestureDetector(
          onTap: hasWav ? () => store.setPitchModel(value) : null,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: sel ? AppColors.lime : AppColors.surface2,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: T.body.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: sel ? AppColors.bg : AppColors.textSecondary,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(_cardPad),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Symbols.bug_report, size: 14, color: AppColors.textSecondary),
            const SizedBox(width: 4),
            Text('PITCH TRACKER (debug)', style: _labelStyle),
            const Spacer(),
            if (hasWav) Text('$pitched notes', style: T.sub.copyWith(fontSize: 11)),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            seg('pyin', 'pYIN'),
            const SizedBox(width: 8),
            seg('crepe', 'CREPE'),
          ]),
          const SizedBox(height: 6),
          Text(
            hasWav
                ? '녹음을 두 트래커로 재분석해 비교. CREPE 는 로컬 dev 백엔드 필요.'
                : '먼저 녹음하면 활성화됩니다.',
            style: T.sub.copyWith(fontSize: 10, color: AppColors.textTertiary),
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
