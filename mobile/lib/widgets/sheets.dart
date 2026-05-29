// 바텀 시트 3종: 악기 선택 / 노트 후보 / 내보내기·공유.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/models.dart';
import '../state/project_store.dart';
import '../theme/app_theme.dart';
import 'common.dart';

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

// ─── 악기 선택 ─────────────────────────────────────────────────────────
void showInstrumentPicker(BuildContext context, ProjectStore store) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) {
      final t = store.active;
      final options = instrumentPalette[t.role] ?? const <Instrument>[];
      return Container(
        decoration: _sheetDeco(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _grabber(),
            Text('악기 선택 · ${t.role.label.toUpperCase()}', style: T.h2.copyWith(fontSize: 18)),
            const SizedBox(height: 16),
            if (options.isEmpty)
              Text(t.role == TrackRole.drum ? '드럼은 자동(Kick/Snare/HiHat)으로 매핑됩니다' : '원본 보컬 트랙입니다', style: T.sub)
            else
              ...options.map((inst) {
                final sel = inst.program == t.program;
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
                        Icon(t.role.icon, size: 18, color: sel ? AppColors.lime : AppColors.textSecondary),
                        const SizedBox(width: 10),
                        Text(inst.label, style: T.body.copyWith(fontWeight: FontWeight.w600)),
                        const Spacer(),
                        if (inst.chordCapable)
                          Text('코드 가능', style: T.label.copyWith(color: AppColors.textSecondary)),
                      ]),
                    ),
                  ),
                );
              }),
            if (t.isChordInstrument) ...[
              const SizedBox(height: 6),
              _chordModeRow(context, store),
            ],
          ],
        ),
      );
    },
  );
}

Widget _chordModeRow(BuildContext context, ProjectStore store) {
  return StatefulBuilder(builder: (context, setLocal) {
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
            Text('코드 모드', style: T.body.copyWith(fontWeight: FontWeight.w600)),
            Text('단음을 자동 화음으로', style: T.sub.copyWith(fontSize: 11)),
          ],
        ),
        const Spacer(),
        _segToggle(
          left: '단음',
          right: '코드',
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
    builder: (_) {
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
              Text('키 선택', style: T.h2.copyWith(fontSize: 18)),
              const SizedBox(height: 4),
              Text('Auto = 추천 키 자동 적용', style: T.sub),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: chip('Auto (추천)', opt.autoKey, () => store.setAutoKey(true)),
              ),
              const SizedBox(height: 16),
              Text('메인 키 기준 트랙 (전체 트랙이 이 키로)', style: T.label),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final r in [TrackRole.keys, TrackRole.bass, TrackRole.vocal])
                    chip(r.label, store.mainKeyRole == r, () => store.setMainKeyFromRole(r)),
                ],
              ),
              const SizedBox(height: 16),
              section('major', '메이저'),
              section('minor', '마이너'),
            ],
          ),
        ),
      );
    },
  );
}

// ─── 노트 후보 ─────────────────────────────────────────────────────────
void showNoteCandidate(BuildContext context, ProjectStore store, int index) {
  final t = store.active;
  if (index < 0 || index >= t.notes.length) return;
  final n = t.notes[index];
  if (n.kind != 'pitched') return;
  final opts = {n.pitchOriginal, ...n.candidates}.toList()..sort();

  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => Container(
      decoration: _sheetDeco(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _grabber(),
          Text('노트 보정', style: T.h2.copyWith(fontSize: 18)),
          Text('${t.role.label.toUpperCase()} · ${n.start.toStringAsFixed(1)}s', style: T.sub),
          const SizedBox(height: 16),
          ...opts.map((p) {
            final isCurrent = p == n.pitch;
            final isOriginal = p == n.pitchOriginal;
            final tag = isOriginal ? '원본 유지' : '후보';
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: GestureDetector(
                onTap: () {
                  store.applyCandidate(index, p);
                  Navigator.pop(context);
                },
                child: Container(
                  height: 58,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: isCurrent ? AppColors.activeLane : AppColors.bg,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: isCurrent ? AppColors.lime : AppColors.border, width: isCurrent ? 1.5 : 1),
                  ),
                  child: Row(children: [
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${noteName(p)}  ·  $tag',
                            style: T.body.copyWith(fontSize: 16, fontWeight: FontWeight.w700)),
                        Text(isOriginal ? '부른 그대로' : '키 안 후보',
                            style: T.sub.copyWith(fontSize: 11, color: isCurrent ? AppColors.lime : AppColors.textSecondary)),
                      ],
                    ),
                    const Spacer(),
                    if (isCurrent) const Icon(Symbols.check_circle, color: AppColors.lime, size: 24),
                  ]),
                ),
              ),
            );
          }),
        ],
      ),
    ),
  );
}

// ─── 내보내기 / 공유 ───────────────────────────────────────────────────
void showExportShare(BuildContext context, ProjectStore store) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => Container(
      decoration: _sheetDeco(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _grabber(),
          Text('내보내기 · ${store.title}', style: T.h2.copyWith(fontSize: 18)),
          const SizedBox(height: 14),
          Disabled(
            label: '클라우드 저장',
            child: _exportRow(Symbols.cloud_done, '프로젝트에 저장', '클라우드 동기화 · 언제든 재편집', AppColors.lime),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => _exportFile(context, store, midi: true),
            child: _exportRow(Symbols.piano, 'MIDI 내보내기', '.mid', AppColors.textPrimary),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => _exportFile(context, store, midi: false),
            child: _exportRow(Symbols.graphic_eq, '오디오 내보내기', '.wav · 믹스 렌더', AppColors.textPrimary),
          ),
          const SizedBox(height: 10),
          Disabled(
            label: '공유',
            child: _exportRow(Symbols.ios_share, '공유', '링크 · Instagram · TikTok', AppColors.textPrimary),
          ),
        ],
      ),
    ),
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
    final bytes = midi ? await store.exportMidiActive() : await store.renderActive();
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/humming_${DateTime.now().millisecondsSinceEpoch}.${midi ? 'mid' : 'wav'}');
    await f.writeAsBytes(bytes, flush: true);
    if (context.mounted) Navigator.pop(context);
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], text: store.title));
  } catch (e) {
    if (context.mounted) comingSoon(context, '내보내기 실패: $e');
  }
}
