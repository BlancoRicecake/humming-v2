// 단일 노트 / 청크 → 코드 선택 시트. 칩 미리듣기 + 적용 시 store 반영.
part of '../sheets.dart';

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
