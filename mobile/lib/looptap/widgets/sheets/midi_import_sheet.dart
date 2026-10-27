import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/loop_models.dart';
import '../../music/instruments.dart';
import '../../music/midi_import.dart';
import '../../music/midi_section_import.dart';
import '../../music/theory.dart';
import '../../theme/tokens.dart';

String _text(BuildContext c, String ko, String en) =>
    Localizations.localeOf(c).languageCode == 'ko' ? ko : en;

/// A chosen MIDI file: display name and bytes (null = cancelled).
typedef MidiFilePicker = Future<({String name, Uint8List bytes})?> Function();

/// The platform file picker (8 MB limit), used unless a test injects one.
// Folder of the last MIDI file opened in this app session (memory only, no
// stored setting), so picking several section files doesn't restart in
// Documents every time. Ignored if the folder no longer exists.
String? _lastMidiDirectory;

/// [last] when it still exists, else null (the platform default).
@visibleForTesting
String? midiInitialDirectory(String? last, bool Function(String) exists) =>
    last != null && last.isNotEmpty && exists(last) ? last : null;

/// Parent folder of a picked file path; null when the platform gives no path.
@visibleForTesting
String? midiParentDirectory(String path) {
  if (path.isEmpty) return null;
  final cut = path.lastIndexOf(RegExp(r'[\\/]'));
  return cut > 0 ? path.substring(0, cut) : null;
}

@visibleForTesting
String? get debugLastMidiDirectory => _lastMidiDirectory;

@visibleForTesting
set debugLastMidiDirectory(String? dir) => _lastMidiDirectory = dir;

Future<({String name, Uint8List bytes})?> openMidiFile() async {
  final file = await openFile(
    initialDirectory: midiInitialDirectory(
      _lastMidiDirectory,
      (d) => Directory(d).existsSync(),
    ),
    acceptedTypeGroups: [
      const XTypeGroup(
        label: 'MIDI',
        extensions: ['mid', 'midi'],
        uniformTypeIdentifiers: ['public.midi-audio'],
      ),
    ],
  );
  if (file == null) return null;
  if (await file.length() > 8 * 1024 * 1024) {
    throw const FormatException('MIDI exceeds 8 MB.');
  }
  final bytes = await file.readAsBytes();
  // Remember the folder once the file was actually read. A later parse error
  // still leaves a real, existing folder to start from; a cancel keeps the
  // previous one.
  _lastMidiDirectory = midiParentDirectory(file.path) ?? _lastMidiDirectory;
  return (name: file.name, bytes: bytes);
}

String _baseName(String name) => name.replaceFirst(RegExp(r'\.[^.]+$'), '');

void _openFailed(BuildContext context, Object error) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        '${_text(context, "MIDI를 열지 못했습니다", "Could not open MIDI")}: $error',
      ),
    ),
  );
}

/// Returns a new, unsaved song. The caller keeps the library/quota/save policy.
Future<Song?> pickMidiPassage(BuildContext context) async {
  try {
    final file = await openMidiFile();
    if (file == null || !context.mounted) return null;
    final midi = await compute(MidiReference.parse, file.bytes);
    if (!context.mounted) return null;
    return await showMidiPassageDialog(
      context,
      midi: midi,
      title: _baseName(file.name),
    );
  } catch (error) {
    _openFailed(context, error);
    return null;
  }
}

/// The song a MIDI passage is added to as a new section.
class MidiSectionTarget {
  const MidiSectionTarget({
    required this.sections,
    required this.currentIdx,
    required this.instruments,
    required this.keyRoot,
    required this.scale,
    required this.bpm,
  });
  final List<Section> sections;
  final int currentIdx;

  /// Every track's program (used for the articulation channel reservation).
  final Map<String, int> instruments;
  final String keyRoot, scale;
  final int bpm;
}

/// Pick a MIDI file and build a new section for [target] (not applied yet:
/// the editor records the undo step and commits it). [picker] is a test seam.
Future<MidiSectionResult?> pickMidiSection(
  BuildContext context, {
  required MidiSectionTarget target,
  MidiFilePicker? picker,
}) async {
  try {
    final file = await (picker ?? openMidiFile)();
    if (file == null || !context.mounted) return null;
    final midi = await compute(MidiReference.parse, file.bytes);
    if (!context.mounted) return null;
    return await showMidiSectionDialog(
      context,
      midi: midi,
      title: _baseName(file.name),
      target: target,
    );
  } catch (error) {
    _openFailed(context, error);
    return null;
  }
}

Future<MidiSectionResult?> showMidiSectionDialog(
  BuildContext context, {
  required MidiReference midi,
  required String title,
  required MidiSectionTarget target,
}) => showDialog<MidiSectionResult>(
  context: context,
  builder: (_) => _MidiPassageDialog(midi: midi, title: title, target: target),
);

Future<Song?> showMidiPassageDialog(
  BuildContext context, {
  required MidiReference midi,
  required String title,
}) => showDialog<Song>(
  context: context,
  builder: (_) => _MidiPassageDialog(midi: midi, title: title),
);

class _MidiPassageDialog extends StatefulWidget {
  const _MidiPassageDialog({
    required this.midi,
    required this.title,
    this.target,
  });
  final MidiReference midi;
  final String title;

  /// Non-null: add the passage to this song as a new section (part → track
  /// mapping) instead of creating a new song.
  final MidiSectionTarget? target;
  @override
  State<_MidiPassageDialog> createState() => _MidiPassageDialogState();
}

class _MidiPassageDialogState extends State<_MidiPassageDialog> {
  late int start = widget.midi.firstNoteBar;
  int bars = 4;
  late final selected = widget.midi.lanes.map((l) => l.id).toSet();
  String? error;

  // ── section mode ──
  late Map<String, String> mapping = _defaults();
  bool useFileProgram = true;
  late final MidiNewTrackChannels? newChannels =
      widget.target == null
          ? null
          : midiNewTrackChannels(
            widget.target!.sections,
            widget.target!.instruments,
          );

  Map<String, String> _defaults() {
    final t = widget.target;
    if (t == null) return {};
    return defaultMidiMapping(
      midiLanesIn(widget.midi, start, bars),
      t.sections,
    );
  }

  void _windowChanged() {
    error = null;
    // a different window has different parts: start from the defaults again
    if (widget.target != null && start >= 1) mapping = _defaults();
  }

  void import() {
    final t = widget.target;
    try {
      if (t != null) {
        Navigator.pop(
          context,
          sectionFromPassage(
            sections: t.sections,
            currentIdx: t.currentIdx,
            instruments: t.instruments,
            key: t.keyRoot,
            scale: t.scale,
            midi: widget.midi,
            title: widget.title,
            startBar: start,
            lengthBars: bars,
            mapping: mapping,
            useFileProgram: useFileProgram,
          ),
        );
        return;
      }
      final song = widget.midi.passage(
        title: '${widget.title} [$start–${start + bars - 1}]',
        startBar: start,
        lengthBars: bars,
        selectedLanes: selected,
      );
      Navigator.pop(context, song);
    } on FormatException catch (e) {
      setState(() => error = e.message);
    }
  }

  String _trackLabel(String id) {
    final t = widget.target!;
    final own = t.sections[t.currentIdx].tracks[id]?.label;
    if (own != null) return own;
    for (final m in sectionTrackMetas(songExtras(t.sections))) {
      if (m.id == id) return m.label;
    }
    return id;
  }

  String _program(ReferenceLane lane) =>
      lane.drums
          ? 'Drums'
          : 'GM ${lane.program + 1} ${kMelodyInstruments[lane.program].label}';

  Widget _mappingRow(ReferenceLane lane, int notes) {
    final value = mapping[lane.id] ?? kMidiSkip;
    final takenByOthers = {
      for (final e in mapping.entries)
        if (e.key != lane.id) e.value,
    };
    final othersNew =
        mapping.entries
            .where((e) => e.key != lane.id && e.value == kMidiNewTrack)
            .length;
    final canNew = othersNew < newChannels!.channels.length;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(lane.name),
                Text(
                  '$notes notes · ${_program(lane)}',
                  style: const TextStyle(fontSize: 11, color: LT.t3),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          DropdownButton<String>(
            key: ValueKey('midi-map-${lane.id}'),
            value: value,
            items: [
              for (final id in midiTargetIds(lane, widget.target!.sections))
                DropdownMenuItem(
                  value: id,
                  enabled: !takenByOthers.contains(id),
                  child: Text(_trackLabel(id)),
                ),
              DropdownMenuItem(
                value: kMidiNewTrack,
                enabled: canNew || value == kMidiNewTrack,
                child: Text(_text(context, '새 트랙', 'New track')),
              ),
              DropdownMenuItem(
                value: kMidiSkip,
                child: Text(_text(context, '건너뛰기', 'Skip')),
              ),
            ],
            onChanged:
                (v) => setState(() {
                  mapping[lane.id] = v ?? kMidiSkip;
                  error = null;
                }),
          ),
        ],
      ),
    );
  }

  String? _newTrackBlocked() {
    final channels = newChannels;
    if (channels == null || channels.channels.isNotEmpty) return null;
    return switch (channels.block) {
      MidiNewTrackBlock.articulation => _text(
        context,
        '새 트랙 불가: 남은 채널을 기타 주법 소리가 쓰고 있습니다.',
        'New track unavailable: the free channel is used by a guitar articulation voice.',
      ),
      MidiNewTrackBlock.layout => _text(
        context,
        '새 트랙 불가: 섹션마다 추가 트랙 구성이 달라 채널을 정할 수 없습니다.',
        'New track unavailable: sections have different added tracks.',
      ),
      _ => _text(
        context,
        '새 트랙 불가: 독립 악기 채널을 모두 쓰고 있습니다.',
        'New track unavailable: every independent instrument channel is in use.',
      ),
    };
  }

  List<Widget> _sectionNotices(MidiReference midi) {
    final t = widget.target!;
    final out = <Widget>[];
    void notice(String text, {Key? key, Color color = LT.t2}) => out.add(
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(text, key: key, style: TextStyle(fontSize: 12, color: color)),
      ),
    );
    if (!midi.constantTempo || !midi.fourFour) {
      notice(
        _text(
          context,
          '템포가 바뀌거나 4/4가 아닌 파일은 섹션으로 넣을 수 없습니다(참고용).',
          'Files with tempo changes or non-4/4 meter cannot be added (inspection only).',
        ),
        key: const ValueKey('midi-section-rejected'),
        color: Colors.orangeAccent,
      );
    }
    if (midi.bpm.round() != t.bpm) {
      notice(
        _text(
          context,
          '곡 템포(${t.bpm})를 유지합니다. 마디 단위 위치는 같고 빠르기만 곡을 따릅니다.',
          'The song tempo (${t.bpm}) is kept. Bar positions stay the same; only the speed follows the song.',
        ),
        key: const ValueKey('midi-section-bpm'),
      );
    }
    final outside =
        start >= 1
            ? midiOutOfScale(midi, start, bars, mapping, t.keyRoot, t.scale)
            : 0;
    notice(
      outside == 0
          ? _text(
            context,
            '모든 음이 곡 키(${t.keyRoot} ${t.scale}) 안에 있습니다.',
            'Every note fits the song key (${t.keyRoot} ${t.scale}).',
          )
          : _text(
            context,
            '곡 키(${t.keyRoot} ${t.scale}) 밖 음 $outside개 — 자동으로 바꾸지 않습니다. 필요하면 그리드의 [스케일에 맞추기]를 쓰세요.',
            '$outside notes are outside the song key (${t.keyRoot} ${t.scale}) — not changed automatically. Use [Fit to scale] in the grid if needed.',
          ),
      key: const ValueKey('midi-section-scale'),
    );
    notice(
      _text(
        context,
        '기존 트랙의 악기는 바뀌지 않습니다. 파일의 악기(GM)는 참고용입니다.',
        "Existing track instruments are not changed. The file's GM instruments are for reference.",
      ),
      key: const ValueKey('midi-section-instruments'),
    );
    if (mapping.values.contains(kMidiNewTrack)) {
      out.add(
        CheckboxListTile(
          key: const ValueKey('midi-section-file-program'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(
            _text(
              context,
              '새 트랙에 파일 악기 사용',
              'Use the file instrument for new tracks',
            ),
          ),
          value: useFileProgram,
          onChanged: (v) => setState(() => useFileProgram = v ?? true),
        ),
      );
    }
    final blocked = _newTrackBlocked();
    if (blocked != null) {
      notice(blocked, key: const ValueKey('midi-section-new-blocked'));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final midi = widget.midi;
    final sectionMode = widget.target != null;
    final startTick = (start - 1) * midi.ppq * 4;
    final endTick = startTick + bars * midi.ppq * 4;
    final active = midi.lanes.where(
      (l) => l.notes.any((n) => n.tick < endTick && n.endTick > startTick),
    );
    int notesIn(ReferenceLane lane) =>
        lane.notes
            .where((n) => n.tick < endTick && n.endTick > startTick)
            .length;
    return AlertDialog(
      backgroundColor: LT.surface2,
      title: Text(
        sectionMode
            ? _text(context, 'MIDI 구간을 새 섹션으로', 'MIDI passage as new section')
            : _text(context, 'MIDI 참고 구간 가져오기', 'Import MIDI passage'),
      ),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.title),
              Text(
                '${midi.bpm.toStringAsFixed(1)} BPM · ${midi.lanes.length} parts · ${midi.noteCount} notes · ${midi.bars} bars',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      key: const ValueKey('midi-start-bar'),
                      initialValue: '$start',
                      decoration: InputDecoration(
                        labelText: _text(
                          context,
                          '시작 마디 (1부터)',
                          'Start bar (1-based)',
                        ),
                      ),
                      keyboardType: TextInputType.number,
                      onChanged:
                          (s) => setState(() {
                            start = int.tryParse(s) ?? 0;
                            _windowChanged();
                          }),
                    ),
                  ),
                  const SizedBox(width: 18),
                  DropdownButton<int>(
                    key: const ValueKey('midi-length'),
                    value: bars,
                    items: [
                      for (final n in [1, 2, 4, 8])
                        DropdownMenuItem(
                          value: n,
                          child: Text(_text(context, '$n마디', '$n bars')),
                        ),
                    ],
                    onChanged:
                        (n) => setState(() {
                          bars = n!;
                          _windowChanged();
                        }),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (sectionMode) ...[
                Text(_text(context, '파트 → 트랙', 'Part → track')),
                for (final lane in active) _mappingRow(lane, notesIn(lane)),
                ..._sectionNotices(midi),
              ] else ...[
                Text(_text(context, '가져올 파트', 'Parts to import')),
                for (final lane in active)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(lane.name),
                    subtitle: Text('${notesIn(lane)} notes'),
                    value: selected.contains(lane.id),
                    onChanged:
                        (v) => setState(() {
                          if (v == true) {
                            selected.add(lane.id);
                          } else {
                            selected.remove(lane.id);
                          }
                          error = null;
                        }),
                  ),
              ],
              if (midi.warnings.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  _text(
                    context,
                    '음정·강약·타이밍을 가져옵니다. 원본의 자동화·효과·음색은 동일하게 재현되지 않습니다.',
                    'Imports pitch, velocity and timing. Source automation, effects and timbres are not reproduced exactly.',
                  ),
                ),
                ExpansionTile(
                  title: Text(
                    _text(context, '원본과 다른 부분 확인', 'View differences'),
                  ),
                  children: [
                    for (final w in midi.warnings)
                      ListTile(dense: true, title: Text(w)),
                  ],
                ),
              ],
              if (error != null)
                Text(
                  error!,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_text(context, '취소', 'Cancel')),
        ),
        FilledButton(
          key: const ValueKey('midi-import-confirm'),
          onPressed: midi.constantTempo && midi.fourFour ? import : null,
          child: Text(
            sectionMode
                ? _text(context, '새 섹션으로 추가', 'Add as new section')
                : _text(context, '새 작업으로 가져오기', 'Import as new song'),
          ),
        ),
      ],
    );
  }
}
