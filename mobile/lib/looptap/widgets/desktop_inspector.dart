// ui-001 stage 4 (docs/specs/ui/ui-001-desktop-b2-layout.md "오른쪽 인스펙터
// (280, 4단계)"): the desktop editor's right panel.
//
// 280 px from under the minimap (edit view) / the top bar (arrange view) to
// the bottom: a 44 px header with the Track | Notes N tabs and a collapse
// button, then the tab. Collapsed it is a 40 px bar with the two tab icons.
// The arrange view only uses the Track tab.
//
// The Notes tab is the active grid's own inspector (GridChrome); the Track
// tab is [InspectorTrackPanel], wired by the editor to the same state and
// handlers as the mixer sheet, the instrument / groove sheets, the hum modal,
// the MIDI passage import and Clear track. The selected tab lives in the
// editor (so collapsing, docking or overlaying never resets it).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../l10n/generated/app_localizations.dart';
import '../music/theory.dart' show TrackMeta;
import '../music/pan.dart' show clampPan, panLabel;
import '../theme/atoms.dart';
import '../theme/tokens.dart';
import 'shortcut_help.dart';
import 'surfaces/grid_chrome.dart';

enum InspectorTab { track, notes }

class DesktopInspector extends StatelessWidget {
  const DesktopInspector({
    super.key,
    required this.tab,
    required this.onTab,
    required this.trackTab,
    required this.chrome,
    required this.notesAvailable,
    required this.onCollapse,
    this.overlay = false,
  });

  final InspectorTab tab;
  final ValueChanged<InspectorTab> onTab;
  final Widget trackTab;
  final GridChrome chrome;

  /// False in the arrange view (Track tab only).
  final bool notesAvailable;
  final VoidCallback onCollapse;

  /// Opened over the editor (narrow window): a shadow on its left edge.
  final bool overlay;

  static const double width = 280, barWidth = 40, headerHeight = 44;

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final showNotes = notesAvailable && tab == InspectorTab.notes;
    Widget tabButton(String key, String label, InspectorTab t) {
      final on = (t == InspectorTab.notes) == showNotes;
      return GestureDetector(
        key: ValueKey(key),
        behavior: HitTestBehavior.opaque,
        onTap: () => onTab(t),
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? LT.surface3 : null,
            borderRadius: BorderRadius.circular(LTRadius.chip),
          ),
          child: Text(
            label,
            maxLines: 1,
            style: LTType.inter(size: 12, weight: FontWeight.w800, color: on ? LT.t1 : LT.t3),
          ),
        ),
      );
    }

    return Container(
      key: const ValueKey('desktop-inspector'),
      width: width,
      decoration: BoxDecoration(
        color: LT.surface,
        border: const Border(left: BorderSide(color: LT.border)),
        boxShadow: overlay ? [BoxShadow(color: LT.bg.withValues(alpha: .7), blurRadius: 18)] : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: headerHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  tabButton('inspector-tab-track', l.inspectorTrack, InspectorTab.track),
                  if (notesAvailable)
                    ListenableBuilder(
                      listenable: chrome,
                      builder:
                          (context, _) => tabButton(
                            'inspector-tab-notes',
                            l.inspectorNotes(chrome.selection.length),
                            InspectorTab.notes,
                          ),
                    ),
                  const Spacer(),
                  IconBtn(
                    key: const ValueKey('inspector-collapse'),
                    icon: Symbols.right_panel_close,
                    size: 36,
                    tooltip: withShortcut(context, l.inspectorCollapse, DesktopShortcutId.inspector),
                    onTap: onCollapse,
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1, thickness: 1, color: LT.border),
          Expanded(
            child:
                showNotes
                    ? ListenableBuilder(
                      listenable: chrome,
                      builder: (context, _) {
                        final content = chrome.content;
                        if (content == null) {
                          return Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              l.inspectorNoNotes,
                              key: const ValueKey('inspector-no-notes'),
                              style: LTType.inter(size: 12, color: LT.t3),
                            ),
                          );
                        }
                        // keys its buttons leave unused reach the grid
                        return GridChromeKeys(content: content, child: content.notes());
                      },
                    )
                    : trackTab,
          ),
        ],
      ),
    );
  }
}

/// The collapsed inspector: a 40 px bar with the two tab icons.
class InspectorBar extends StatelessWidget {
  const InspectorBar({
    super.key,
    required this.onOpen,
    required this.notesAvailable,
    this.notesCount = 0,
  });
  final ValueChanged<InspectorTab> onOpen;
  final bool notesAvailable;
  final int notesCount;

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final expand = withShortcut(context, l.inspectorExpand, DesktopShortcutId.inspector);
    return Container(
      key: const ValueKey('inspector-bar'),
      width: DesktopInspector.barWidth,
      decoration: const BoxDecoration(
        color: LT.surface,
        border: Border(left: BorderSide(color: LT.border)),
      ),
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        children: [
          IconBtn(
            key: const ValueKey('inspector-bar-track'),
            icon: Symbols.tune,
            size: 36,
            tooltip: '${l.inspectorTrack} · $expand',
            onTap: () => onOpen(InspectorTab.track),
          ),
          if (notesAvailable)
            IconBtn(
              key: const ValueKey('inspector-bar-notes'),
              icon: Symbols.music_note,
              size: 36,
              tooltip: '${l.inspectorNotes(notesCount)} · $expand',
              onTap: () => onOpen(InspectorTab.notes),
            ),
        ],
      ),
    );
  }
}

/// The Track tab. Every control calls the editor's existing handler (the
/// same ones the mixer sheet and the old surface header use).
class InspectorTrackPanel extends StatefulWidget {
  const InspectorTrackPanel({
    super.key,
    required this.meta,
    required this.name,
    required this.summary,
    required this.volume,
    required this.onVolume,
    required this.pan,
    required this.onPan,
    required this.onPanReset,
    required this.solo,
    required this.muted,
    required this.onSolo,
    required this.onMute,
    this.instrument,
    this.onInstrument,
    this.octave,
    this.groove,
    this.onGroove,
    this.onHum,
    this.onMidiImport,
    this.onClear,
  });

  final TrackMeta meta;
  final String name, summary;
  final double volume, pan;
  final void Function(String id, double v) onVolume, onPan;
  final ValueChanged<String> onPanReset;
  final bool solo, muted;
  final VoidCallback? onSolo, onMute;
  final String? instrument, groove;
  final VoidCallback? onInstrument, onGroove, onHum, onMidiImport, onClear;

  /// The editor's octave stepper (pitched tracks).
  final Widget? octave;

  @override
  State<InspectorTrackPanel> createState() => _InspectorTrackPanelState();
}

class _InspectorTrackPanelState extends State<InspectorTrackPanel> {
  // Alt+click reset in progress: swallow the slider's own value jump (the
  // mixer sheet's rule)
  bool _altReset = false;

  Widget _label(String text, [String? value, Key? valueKey]) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 2),
    child: Row(
      children: [
        Text(text, style: LTType.inter(size: 11, weight: FontWeight.w700, color: LT.t2)),
        const Spacer(),
        if (value != null) Text(value, key: valueKey, style: LTType.mono(size: 11, color: LT.t2)),
      ],
    ),
  );

  Widget _menuRow(String key, IconData icon, String label, VoidCallback? onTap, {String? value, Color? color}) =>
      Opacity(
        opacity: onTap == null ? .4 : 1,
        child: GestureDetector(
          key: ValueKey(key),
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            height: 34,
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: LT.surface2,
              borderRadius: BorderRadius.circular(LTRadius.chip),
              border: Border.all(color: LT.border),
            ),
            child: Row(
              children: [
                Ms(icon, size: 16, color: color ?? LT.t2),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: LTType.inter(size: 12, weight: FontWeight.w700, color: color ?? LT.t1),
                  ),
                ),
                if (value != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 90),
                    child: Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: LTType.inter(size: 11, color: LT.t3),
                    ),
                  ),
                const Ms(Symbols.chevron_right, size: 16, color: LT.t3),
              ],
            ),
          ),
        ),
      );

  Widget _toggle(String key, String label, bool on, VoidCallback? onTap) => Expanded(
    child: GestureDetector(
      key: ValueKey(key),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? LT.lime : LT.surface2,
          borderRadius: BorderRadius.circular(LTRadius.chip),
          border: Border.all(color: on ? LT.lime : LT.border),
        ),
        child: Text(
          label,
          style: LTType.inter(size: 12, weight: FontWeight.w800, color: on ? LT.bg : LT.t2),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final w = widget;
    final id = w.meta.id;
    final p = clampPan(w.pan);
    return SingleChildScrollView(
      key: const ValueKey('inspector-track-tab'),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: w.meta.color.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(LTRadius.chip),
                ),
                child: Center(child: Ms(w.meta.icon, size: 20, color: w.meta.color)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      w.name,
                      key: const ValueKey('inspector-track-name'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: LTType.inter(size: 14, weight: FontWeight.w800, color: LT.t1),
                    ),
                    Text(
                      w.summary,
                      key: const ValueKey('inspector-track-summary'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: LTType.inter(size: 11, color: LT.t3),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (w.instrument != null)
            _menuRow('inspector-instrument', Symbols.piano, l.inspectorInstrument, w.onInstrument, value: w.instrument),
          if (w.octave != null) ...[
            _label(l.inspectorOctave),
            Align(alignment: Alignment.centerLeft, child: w.octave!),
          ],
          _label(l.inspectorVolume, '${(w.volume * 100).round()}', const ValueKey('inspector-volume-label')),
          Slider(
            key: const ValueKey('inspector-volume'),
            min: 0,
            max: 100,
            value: (w.volume * 100).clamp(0, 100).toDouble(),
            activeColor: w.meta.color,
            // the mixer's rule: no volume drag while muted
            onChanged: w.muted ? null : (v) => w.onVolume(id, v / 100),
          ),
          _label(l.inspectorPan, panLabel(p), const ValueKey('inspector-pan-label')),
          Tooltip(
            message: l.inspectorPanHint,
            waitDuration: const Duration(milliseconds: 700),
            child: GestureDetector(
              key: const ValueKey('inspector-pan'),
              onDoubleTap: () => w.onPanReset(id),
              child: Slider(
                min: -100,
                max: 100,
                value: p * 100,
                activeColor: w.meta.color,
                onChangeStart: (_) {
                  if (HardwareKeyboard.instance.isAltPressed) {
                    _altReset = true;
                    w.onPanReset(id);
                  }
                },
                onChanged: (v) {
                  if (_altReset) return;
                  w.onPan(id, v.round() / 100);
                },
                onChangeEnd: (_) => _altReset = false,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _toggle('inspector-solo', 'Solo', w.solo, w.onSolo),
              const SizedBox(width: 6),
              _toggle('inspector-mute', l.inspectorMute, w.muted, w.onMute),
            ],
          ),
          const SizedBox(height: 6),
          if (w.onGroove != null || w.groove != null)
            _menuRow('inspector-groove', Symbols.graphic_eq, l.inspectorGroove, w.onGroove, value: w.groove ?? l.inspectorGrooveNone),
          if (w.onHum != null) _menuRow('inspector-hum', Symbols.mic, l.inspectorHum, w.onHum),
          if (w.onMidiImport != null)
            _menuRow('inspector-midi-import', Symbols.library_music, l.inspectorMidiImport, w.onMidiImport),
          if (w.onClear != null) _menuRow('inspector-clear', Symbols.delete, l.inspectorClear, w.onClear, color: LT.danger),
        ],
      ),
    );
  }
}
