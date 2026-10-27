// groove-001: per-track groove picker. Assigning, the sliders, extraction and
// renaming all go through [GrooveSheetHost], which records undo steps and
// keeps playback in sync; the sheet only renders the host's current state.
import 'package:flutter/material.dart';

import '../../music/groove.dart';

/// The editor side of the groove sheet.
abstract class GrooveSheetHost {
  String get trackLabel;
  List<GrooveTemplate> get songGrooves;
  double get amount;

  /// The track's song-wide groove.
  GrooveAssign? get trackGroove;

  /// Whether the active section overrides this track, and with what (null
  /// value = "no groove in this section").
  bool get hasSectionOverride;
  GrooveAssign? get sectionGroove;

  /// Default template length for extraction (16 for a 1-bar section).
  int get defaultLength;
  bool get hasTake;

  /// [section] = write the section override instead of the track groove.
  /// [coalesce] = a slider drag (one undo step per gesture).
  void assign(GrooveAssign? a, {required bool section, bool coalesce = false});
  void clearSectionOverride();
  void setAmount(double v, {bool coalesce = false});

  /// Extract and assign; returns an error message or null on success.
  String? extractFromTake(int length);
  String? extractFromTrack(int length);
  void rename(String id, String name);
}

Future<void> showGrooveSheet(BuildContext context, GrooveSheetHost host) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _GrooveSheet(host: host),
    );

class _GrooveSheet extends StatefulWidget {
  const _GrooveSheet({required this.host});
  final GrooveSheetHost host;
  @override
  State<_GrooveSheet> createState() => _GrooveSheetState();
}

class _GrooveSheetState extends State<_GrooveSheet> {
  late bool _section = widget.host.hasSectionOverride;
  late int _length = widget.host.defaultLength;
  String? _error;

  GrooveSheetHost get h => widget.host;
  bool get _ko => Localizations.localeOf(context).languageCode == 'ko';
  GrooveAssign? get _current => _section ? h.sectionGroove : h.trackGroove;

  void _pick(String? id) {
    final now = _current;
    setState(() {
      _error = null;
      h.assign(
        id == null
            ? null
            : (now == null
                ? GrooveAssign(grooveId: id)
                : now.copyWith(grooveId: id)),
        section: _section,
      );
    });
  }

  void _tweak(GrooveAssign a) =>
      setState(() => h.assign(a, section: _section, coalesce: true));

  Future<void> _rename(GrooveTemplate t) async {
    final ctl = TextEditingController(text: t.name);
    final name = await showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(_ko ? '그루브 이름' : 'Groove name'),
            content: TextField(
              key: const ValueKey('groove-name-field'),
              controller: ctl,
              autofocus: true,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(_ko ? '취소' : 'Cancel'),
              ),
              FilledButton(
                key: const ValueKey('groove-name-save'),
                onPressed: () => Navigator.pop(context, ctl.text.trim()),
                child: Text(_ko ? '저장' : 'Save'),
              ),
            ],
          ),
    );
    ctl.dispose();
    if (name != null && name.isNotEmpty && mounted) {
      setState(() => h.rename(t.id, name));
    }
  }

  Widget _slider(
    String key,
    String label,
    double min,
    double max,
    double value,
    ValueChanged<double> onChanged,
  ) => Row(
    children: [
      SizedBox(
        width: 110,
        child: Text(label, style: const TextStyle(fontSize: 12)),
      ),
      Expanded(
        child: Slider(
          key: ValueKey(key),
          min: min,
          max: max,
          divisions: (max - min).round(),
          value: value.clamp(min, max),
          onChanged: onChanged,
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final now = _current;
    final templates = [...kBuiltinGrooves, ...h.songGrooves];
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_ko ? '그루브' : 'Groove'} — ${h.trackLabel}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            _slider(
              'groove-amount',
              '${_ko ? '전체 양' : 'Amount'} ${(h.amount * 100).round()}%',
              0,
              130,
              h.amount * 100,
              (v) => setState(() => h.setAmount(v / 100, coalesce: true)),
            ),
            SegmentedButton<bool>(
              key: const ValueKey('groove-scope'),
              segments: [
                ButtonSegment(
                  value: false,
                  label: Text(_ko ? '곡 전체' : 'Whole song'),
                ),
                ButtonSegment(
                  value: true,
                  label: Text(_ko ? '이 섹션만' : 'This section'),
                ),
              ],
              selected: {_section},
              onSelectionChanged: (v) => setState(() => _section = v.first),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                ChoiceChip(
                  key: const ValueKey('groove-none'),
                  label: Text(_ko ? '그루브 없음 (Swing)' : 'None (Swing)'),
                  selected:
                      now == null && (!_section || h.hasSectionOverride),
                  onSelected: (_) => _pick(null),
                ),
                for (final t in templates)
                  ChoiceChip(
                    key: ValueKey('groove-${t.id}'),
                    label: Text(t.name),
                    selected: now?.grooveId == t.id,
                    onSelected: (_) => _pick(t.id),
                  ),
              ],
            ),
            if (_section && h.hasSectionOverride)
              TextButton(
                key: const ValueKey('groove-section-clear'),
                onPressed: () => setState(h.clearSectionOverride),
                child: Text(
                  _ko ? '섹션 덮어쓰기 해제' : 'Use the song groove here',
                ),
              ),
            if (now != null) ...[
              _slider(
                'groove-timing',
                '${_ko ? '타이밍' : 'Timing'} ${(now.timing * 100).round()}%',
                0,
                100,
                now.timing * 100,
                (v) => _tweak(now.copyWith(timing: v / 100)),
              ),
              _slider(
                'groove-velocity',
                '${_ko ? '세기' : 'Velocity'} ${(now.velocity * 100).round()}%',
                -100,
                100,
                now.velocity * 100,
                (v) => _tweak(now.copyWith(velocity: v / 100)),
              ),
              _slider(
                'groove-quantize',
                '${_ko ? '퀀타이즈' : 'Quantize'} '
                    '${(now.quantize * 100).round()}%',
                0,
                100,
                now.quantize * 100,
                (v) => _tweak(now.copyWith(quantize: v / 100)),
              ),
            ],
            const Divider(),
            Row(
              children: [
                Text(_ko ? '만들기 길이' : 'Length'),
                const SizedBox(width: 8),
                for (final l in const [16, 32])
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      key: ValueKey('groove-length-$l'),
                      label: Text('$l'),
                      selected: _length == l,
                      onSelected: (_) => setState(() => _length = l),
                    ),
                  ),
              ],
            ),
            Wrap(
              spacing: 6,
              children: [
                OutlinedButton(
                  key: const ValueKey('groove-extract-take'),
                  onPressed:
                      h.hasTake
                          ? () => setState(
                            () => _error = h.extractFromTake(_length),
                          )
                          : null,
                  child: Text(
                    _ko ? '마지막 녹음에서 만들기' : 'From the last take',
                  ),
                ),
                OutlinedButton(
                  key: const ValueKey('groove-extract-track'),
                  onPressed:
                      () => setState(() => _error = h.extractFromTrack(_length)),
                  child: Text(_ko ? '이 트랙에서 만들기' : 'From this track'),
                ),
              ],
            ),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            for (final t in h.songGrooves)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(t.name),
                trailing: IconButton(
                  key: ValueKey('groove-rename-${t.id}'),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  onPressed: () => _rename(t),
                ),
              ),
            const SizedBox(height: 4),
            Text(
              _ko
                  ? 'Swing 노브는 그루브가 없는 트랙에 적용됩니다. 그루브는 재생할 때만 적용되고 노트는 바뀌지 않습니다.'
                  : 'The Swing knob applies to tracks without a groove. '
                      'Grooves change playback only; notes stay as written.',
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
