// ui-001 stage 1: the desktop shortcut catalog. [DesktopCommands] dispatches
// from [kDesktopShortcuts]; [kEditShortcuts] lists what the piano roll
// (StepGrid) and the drum grid (DrumSurface) handle in their own key
// handlers (unchanged). The help window and the top-bar tooltips read these
// lists, and desktop_top_bar_test checks both against the real handlers.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/generated/app_localizations.dart';
import '../theme/tokens.dart';
import 'sheets/lt_modal.dart';

enum DesktopShortcutId {
  play,
  record,
  save,
  undo,
  redo,
  groove,
  duplicateLinked,
  rangeLoop,
  mixer,
  help,
  viewToggle,
  openEditor,
  inspector,
  hum,
}

/// One registered key combination. [command] = Ctrl (Windows/Linux) or Cmd
/// (macOS); modifiers must match exactly (Alt is never part of a shortcut).
class DesktopShortcut {
  const DesktopShortcut(this.id, this.key, {this.command = false, this.shift = false});
  final DesktopShortcutId id;
  final LogicalKeyboardKey key;
  final bool command, shift;

  /// Letter keys use [DesktopCommands]' layout-independent letter match.
  bool get letter {
    final i = key.keyId - LogicalKeyboardKey.keyA.keyId;
    return i >= 0 && i < 26;
  }

  String keysLabel({required bool mac}) {
    final parts = <String>[
      if (command) mac ? '⌘' : 'Ctrl',
      if (shift) 'Shift',
      _keyName(key),
    ];
    return parts.join('+');
  }

  static String _keyName(LogicalKeyboardKey k) {
    if (k == LogicalKeyboardKey.space) return 'Space';
    if (k == LogicalKeyboardKey.slash) return '/';
    if (k == LogicalKeyboardKey.f1) return 'F1';
    if (k == LogicalKeyboardKey.tab) return 'Tab';
    if (k == LogicalKeyboardKey.enter) return 'Enter';
    return k.keyLabel.toUpperCase();
  }
}

/// Every desktop shortcut [DesktopCommands] handles, in help-window order.
const List<DesktopShortcut> kDesktopShortcuts = [
  DesktopShortcut(DesktopShortcutId.play, LogicalKeyboardKey.space),
  DesktopShortcut(DesktopShortcutId.record, LogicalKeyboardKey.keyR, command: true, shift: true),
  DesktopShortcut(DesktopShortcutId.save, LogicalKeyboardKey.keyS, command: true),
  DesktopShortcut(DesktopShortcutId.undo, LogicalKeyboardKey.keyZ, command: true),
  DesktopShortcut(DesktopShortcutId.redo, LogicalKeyboardKey.keyZ, command: true, shift: true),
  DesktopShortcut(DesktopShortcutId.rangeLoop, LogicalKeyboardKey.keyL, command: true),
  DesktopShortcut(DesktopShortcutId.mixer, LogicalKeyboardKey.keyM, command: true),
  DesktopShortcut(DesktopShortcutId.groove, LogicalKeyboardKey.keyG, command: true),
  DesktopShortcut(DesktopShortcutId.duplicateLinked, LogicalKeyboardKey.keyD, command: true, shift: true),
  DesktopShortcut(DesktopShortcutId.help, LogicalKeyboardKey.f1),
  DesktopShortcut(DesktopShortcutId.help, LogicalKeyboardKey.slash, command: true),
  // ui-001 stage 3: arrange <-> edit view; Enter (arrange view, nothing else
  // focused) edits the selected track
  DesktopShortcut(DesktopShortcutId.viewToggle, LogicalKeyboardKey.tab),
  DesktopShortcut(DesktopShortcutId.openEditor, LogicalKeyboardKey.enter),
  // ui-001 stage 4 (Ctrl/Cmd+Shift+I stays the guitar grid's ring)
  DesktopShortcut(DesktopShortcutId.inspector, LogicalKeyboardKey.keyI, command: true),
  // ui-001 stage 5. A focused piano roll / drum grid with notes to edit keeps
  // its Ctrl/Cmd+Shift+H (humanize): it handles the key first.
  DesktopShortcut(DesktopShortcutId.hum, LogicalKeyboardKey.keyH, command: true, shift: true),
];

/// Where an editing shortcut works.
enum EditShortcutContext { pianoRoll, guitar, drums }

/// One editing shortcut: one or more keys (e.g. left/right) with the same
/// modifiers.
class EditShortcut {
  const EditShortcut(
    this.context,
    this.label,
    this.keys, {
    this.command = false,
    this.shift = false,
    this.anyShift = false,
    this.anyCommand = false,
  });
  final EditShortcutContext context;
  final String Function(L10n l) label;
  final List<LogicalKeyboardKey> keys;
  final bool command, shift;

  /// The handler does not look at Shift / Ctrl(Cmd) for this key (e.g. Esc,
  /// Delete): the help shows the plain key, and it also fires with them.
  final bool anyShift, anyCommand;

  /// Whether this entry covers [key] pressed with these modifiers.
  bool matches(LogicalKeyboardKey key, {required bool command, required bool shift}) =>
      keys.contains(key) && (anyCommand || command == this.command) && (anyShift || shift == this.shift);

  String keysLabel({required bool mac}) => [
    if (command) mac ? '⌘' : 'Ctrl',
    if (shift) 'Shift',
    keys.map(_editKeyName).join('/'),
  ].join('+');
}

String _editKeyName(LogicalKeyboardKey k) {
  if (k == LogicalKeyboardKey.escape) return 'Esc';
  if (k == LogicalKeyboardKey.delete) return 'Delete';
  if (k == LogicalKeyboardKey.backspace) return 'Backspace';
  if (k == LogicalKeyboardKey.arrowLeft) return '←';
  if (k == LogicalKeyboardKey.arrowRight) return '→';
  if (k == LogicalKeyboardKey.arrowUp) return '↑';
  if (k == LogicalKeyboardKey.arrowDown) return '↓';
  return k.keyLabel.toUpperCase();
}

const _pr = EditShortcutContext.pianoRoll;
const _gt = EditShortcutContext.guitar;
const _dr = EditShortcutContext.drums;
const _l = LogicalKeyboardKey.arrowLeft, _r = LogicalKeyboardKey.arrowRight;
const _u = LogicalKeyboardKey.arrowUp, _d = LogicalKeyboardKey.arrowDown;

/// The piano-roll and drum-grid shortcuts (StepGrid._key / DrumSurface._key).
final List<EditShortcut> kEditShortcuts = [
  EditShortcut(_pr, (l) => l.shortcutEditChordStampMode, const [LogicalKeyboardKey.keyC], command: true, shift: true),
  EditShortcut(_pr, (l) => l.shortcutEditDeselect, const [LogicalKeyboardKey.escape], anyShift: true, anyCommand: true),
  EditShortcut(_pr, (l) => l.shortcutEditSelectAll, const [LogicalKeyboardKey.keyA], command: true),
  EditShortcut(_pr, (l) => l.shortcutEditArpeggiate, const [LogicalKeyboardKey.keyA], command: true, shift: true),
  EditShortcut(_pr, (l) => l.shortcutEditCopy, const [LogicalKeyboardKey.keyC], command: true),
  EditShortcut(_pr, (l) => l.shortcutEditPaste, const [LogicalKeyboardKey.keyV], command: true, anyShift: true),
  EditShortcut(_pr, (l) => l.shortcutEditDuplicate, const [LogicalKeyboardKey.keyD], command: true),
  EditShortcut(_pr, (l) => l.shortcutEditSplitPlayhead, const [LogicalKeyboardKey.keyE], command: true),
  EditShortcut(_pr, (l) => l.shortcutEditSplitSheet, const [LogicalKeyboardKey.keyE], command: true, shift: true),
  EditShortcut(_pr, (l) => l.shortcutEditGlue, const [LogicalKeyboardKey.keyJ], command: true, anyShift: true),
  EditShortcut(_pr, (l) => l.shortcutEditLegato, const [LogicalKeyboardKey.keyL], command: true, anyShift: true),
  EditShortcut(_pr, (l) => l.shortcutEditQuantize, const [LogicalKeyboardKey.keyU], command: true),
  EditShortcut(_pr, (l) => l.shortcutEditQuantizeSettings, const [LogicalKeyboardKey.keyU], command: true, shift: true),
  EditShortcut(_pr, (l) => l.shortcutEditHumanize, const [LogicalKeyboardKey.keyH], command: true, shift: true),
  EditShortcut(_pr, (l) => l.shortcutEditFitScale, const [LogicalKeyboardKey.keyK], command: true, anyShift: true),
  EditShortcut(_pr, (l) => l.shortcutEditChance, const [_u, _d], command: true, anyShift: true),
  EditShortcut(_pr, (l) => l.shortcutEditDelete, const [LogicalKeyboardKey.delete, LogicalKeyboardKey.backspace], anyShift: true),
  EditShortcut(_pr, (l) => l.shortcutEditMute, const [LogicalKeyboardKey.keyM]),
  EditShortcut(_pr, (l) => l.shortcutEditChordBelow, const [LogicalKeyboardKey.keyC]),
  EditShortcut(_pr, (l) => l.shortcutEditChordType, const [LogicalKeyboardKey.keyC], shift: true),
  EditShortcut(_pr, (l) => l.shortcutEditMove, const [_l, _r]),
  EditShortcut(_pr, (l) => l.shortcutEditLength, const [_l, _r], shift: true),
  EditShortcut(_pr, (l) => l.shortcutEditSemitone, const [_u, _d]),
  EditShortcut(_pr, (l) => l.shortcutEditOctave, const [_u, _d], shift: true),
  EditShortcut(_gt, (l) => l.shortcutGuitarStroke, const [_d, _u], command: true, shift: true),
  EditShortcut(_gt, (l) => l.shortcutGuitarStrings, const [LogicalKeyboardKey.keyG], command: true, shift: true),
  EditShortcut(_gt, (l) => l.shortcutGuitarRing, const [LogicalKeyboardKey.keyI], command: true, shift: true),
  EditShortcut(_dr, (l) => l.shortcutDrumToggleSelect, const [LogicalKeyboardKey.keyB], command: true, anyShift: true),
  EditShortcut(_dr, (l) => l.shortcutEditDeselect, const [LogicalKeyboardKey.escape], anyShift: true, anyCommand: true),
  EditShortcut(_dr, (l) => l.shortcutEditSelectAll, const [LogicalKeyboardKey.keyA], command: true, anyShift: true),
  EditShortcut(_dr, (l) => l.shortcutEditQuantize, const [LogicalKeyboardKey.keyU], command: true),
  EditShortcut(_dr, (l) => l.shortcutEditQuantizeSettings, const [LogicalKeyboardKey.keyU], command: true, shift: true),
  EditShortcut(_dr, (l) => l.shortcutEditHumanize, const [LogicalKeyboardKey.keyH], command: true, shift: true),
  EditShortcut(_dr, (l) => l.shortcutEditChance, const [_u, _d], command: true, anyShift: true),
  EditShortcut(_dr, (l) => l.shortcutEditDelete, const [LogicalKeyboardKey.delete, LogicalKeyboardKey.backspace], anyShift: true),
  EditShortcut(_dr, (l) => l.shortcutEditMute, const [LogicalKeyboardKey.keyM]),
  EditShortcut(_dr, (l) => l.shortcutEditMove, const [_l, _r]),
  EditShortcut(_dr, (l) => l.shortcutDrumMoveFine, const [_l, _r], shift: true),
  EditShortcut(_dr, (l) => l.shortcutDrumVelocity, const [_u, _d]),
  EditShortcut(_dr, (l) => l.shortcutDrumVelocityBig, const [_u, _d], shift: true),
];

String desktopShortcutLabel(L10n l, DesktopShortcutId id) => switch (id) {
  DesktopShortcutId.play => l.shortcutPlay,
  DesktopShortcutId.record => l.shortcutRecord,
  DesktopShortcutId.save => l.shortcutSave,
  DesktopShortcutId.undo => l.shortcutUndo,
  DesktopShortcutId.redo => l.shortcutRedo,
  DesktopShortcutId.groove => l.shortcutGroove,
  DesktopShortcutId.duplicateLinked => l.shortcutDuplicateLinked,
  DesktopShortcutId.rangeLoop => l.shortcutRangeLoop,
  DesktopShortcutId.mixer => l.shortcutMixer,
  DesktopShortcutId.help => l.shortcutHelp,
  DesktopShortcutId.viewToggle => l.shortcutViewToggle,
  DesktopShortcutId.openEditor => l.shortcutOpenEditor,
  DesktopShortcutId.inspector => l.shortcutInspector,
  DesktopShortcutId.hum => l.shortcutHum,
};

bool _isMac(BuildContext context) => Theme.of(context).platform == TargetPlatform.macOS;

/// "Ctrl+Z" / "F1, Ctrl+/" — all registered keys of [id].
String desktopShortcutKeys(BuildContext context, DesktopShortcutId id) => [
  for (final s in kDesktopShortcuts)
    if (s.id == id) s.keysLabel(mac: _isMac(context)),
].join(', ');

/// Tooltip text: the label, plus its keys when [id] has a shortcut.
String withShortcut(BuildContext context, String label, DesktopShortcutId? id) {
  if (id == null) return label;
  final keys = desktopShortcutKeys(context, id);
  return keys.isEmpty ? label : '$label ($keys)';
}

/// The shortcut help window (F1, Ctrl/Cmd+/, top bar ?): workspace commands,
/// then the piano-roll, guitar and drum editing shortcuts by context.
Future<void> showShortcutHelp(BuildContext context) {
  final l = L10n.of(context);
  final mac = _isMac(context);
  final ids = <DesktopShortcutId>[];
  for (final s in kDesktopShortcuts) {
    if (!ids.contains(s.id)) ids.add(s.id);
  }
  Widget row(Key key, String label, String keys) => Padding(
    key: key,
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(label, style: LTType.inter(size: 13, color: LT.t1))),
        const SizedBox(width: 12),
        Text(keys, style: LTType.mono(size: 12, weight: FontWeight.w700, color: LT.lime)),
      ],
    ),
  );
  Widget header(String text) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 4),
    child: Text(text, style: LTType.inter(size: 11, weight: FontWeight.w800, color: LT.t2)),
  );
  final sections = {
    EditShortcutContext.pianoRoll: l.shortcutSectionPianoRoll,
    EditShortcutContext.guitar: l.shortcutSectionGuitar,
    EditShortcutContext.drums: l.shortcutSectionDrums,
  };
  return showLtModal<void>(
    context,
    width: 520,
    child: Column(
      key: const ValueKey('shortcut-help'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l.topBarShortcuts, style: LTType.inter(size: 16, weight: FontWeight.w800)),
        header(l.shortcutSectionWorkspace),
        for (final id in ids)
          row(ValueKey('shortcut-help-${id.name}'), desktopShortcutLabel(l, id), desktopShortcutKeys(context, id)),
        for (final e in sections.entries) ...[
          header(e.value),
          for (final (i, s) in kEditShortcuts.indexed)
            if (s.context == e.key) row(ValueKey('shortcut-help-edit-$i'), s.label(l), s.keysLabel(mac: mac)),
        ],
        const SizedBox(height: 12),
        Text(l.shortcutHelpLegatoNote, style: LTType.inter(size: 11, color: LT.t3)),
        const SizedBox(height: 4),
        Text(l.shortcutHelpHumNote, style: LTType.inter(size: 11, color: LT.t3)),
        const SizedBox(height: 4),
        Text(l.shortcutHelpTypingNote, style: LTType.inter(size: 11, color: LT.t3)),
      ],
    ),
  );
}
