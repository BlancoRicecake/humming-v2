// 바텀 시트 3종: 악기 선택 / 노트 후보 / 내보내기·공유.
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../audio/synth.dart';
import '../models/models.dart';
import '../music/chord_expand.dart';
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
    backgroundColor: Colors.transparent,
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
                child: Text('닫기', style: T.body.copyWith(fontWeight: FontWeight.w600)),
              ),
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
            child: Text('원음',
                style: T.label.copyWith(fontSize: 10, color: AppColors.textSecondary)),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
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
                  child: Text('취소', style: T.body.copyWith(color: AppColors.textSecondary, fontSize: 14)),
                ),
              ),
              Column(children: [
                Text('노트 보정 · #${widget.noteIndex + 1}',
                    style: T.h2.copyWith(fontSize: 16)),
              ]),
              GestureDetector(
                onTap: () {
                  widget.store.applyCandidate(widget.noteIndex, centerPitch);
                  Navigator.pop(context);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                  child: Text('적용',
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
            Text('추천', style: T.sub.copyWith(fontSize: 11)),
            const SizedBox(width: 14),
            Text('원음 = 부른 그대로', style: T.sub.copyWith(fontSize: 11)),
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
                  Text('미리듣기',
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
void showChordPicker(BuildContext context, ProjectStore store) {
  final i = store.selectedNote;
  if (i == null) return;
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => _ChordPickerSheet(store: store, noteIndex: i),
  ).whenComplete(() => SynthEngine().stopAll());
}

class _ChordPickerSheet extends StatefulWidget {
  final ProjectStore store;
  final int noteIndex;
  const _ChordPickerSheet({required this.store, required this.noteIndex});
  @override
  State<_ChordPickerSheet> createState() => _ChordPickerSheetState();
}

class _ChordPickerSheetState extends State<_ChordPickerSheet> {
  // null = 원음(단음). 그 외 ChordType = 코드.
  ChordType? _selected;
  int _previewSeq = 0;

  Future<void> _preview(ChordType? type) async {
    final mySeq = ++_previewSeq;
    final t = widget.store.active;
    final n = t.notes[widget.noteIndex];
    final dk = t.analysis?.detectedKey;
    final pitches = type == null
        ? [n.pitch]
        : chordPitches(n.pitch, type, tonic: dk?.tonic, scale: dk?.scale);
    try {
      await SynthEngine().stopAll();
      if (mySeq != _previewSeq || !mounted) return;
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
    } catch (_) {
      // 미리듣기 실패해도 UI 영향 없음.
    }
  }

  void _onSelect(ChordType? type) {
    setState(() => _selected = type);
    _preview(type);
  }

  void _onApply() {
    final i = widget.noteIndex;
    final wasChord = widget.store.canUnchordSelected;
    if (_selected == null) {
      // 원음 선택: 현재 코드면 unchord, 단음이면 변경 없음.
      if (wasChord) widget.store.unchordSelected();
    } else {
      // 코드 선택: 현재 코드면 먼저 unchord 후 새 코드 적용 (이중 적용 방지).
      if (wasChord) widget.store.unchordSelected();
      // unchord 후 selectedNote 가 root 로 갱신됨 — 그 인덱스로 다시 chord 적용.
      final newIdx = widget.store.selectedNote ?? i;
      widget.store.applyChord(newIdx, _selected!);
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.store.active;
    final n = t.notes[widget.noteIndex];
    final dk = t.analysis?.detectedKey;
    final hasKey = dk?.tonic != null && dk?.scale != null;
    final isCurrentlyChord = widget.store.canUnchordSelected;

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
                  child: Text('취소', style: T.body.copyWith(color: AppColors.textSecondary, fontSize: 14)),
                ),
              ),
              Text('코드 변환', style: T.h2.copyWith(fontSize: 16)),
              GestureDetector(
                onTap: _onApply,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                  child: Text('적용',
                      style: T.body.copyWith(color: AppColors.lime, fontSize: 14, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            hasKey
                ? '루트: ${noteName(n.pitch)} · 키: ${dk!.label}${isCurrentlyChord ? ' · 현재 코드' : ''}'
                : '루트: ${noteName(n.pitch)} (키 미감지)${isCurrentlyChord ? ' · 현재 코드' : ''}',
            style: T.sub,
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              chip(null, '원음', '단음 (코드 해제)'),
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
    // 재생 ▶ 와 동일한 결과: enabled 트랙 전부를 믹스/멀티트랙으로 export.
    final bytes = midi ? await store.exportMidiMix() : await store.exportMixWav();
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/humming_${DateTime.now().millisecondsSinceEpoch}.${midi ? 'mid' : 'wav'}');
    await f.writeAsBytes(bytes, flush: true);
    if (context.mounted) Navigator.pop(context);
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], text: store.title));
  } catch (e) {
    if (context.mounted) comingSoon(context, '내보내기 실패: $e');
  }
}
