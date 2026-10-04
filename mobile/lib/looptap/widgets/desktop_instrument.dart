import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../state/loop_prefs.dart';
import '../theme/tokens.dart';

const pianoKeys = [
  PhysicalKeyboardKey.keyA,
  PhysicalKeyboardKey.keyS,
  PhysicalKeyboardKey.keyD,
  PhysicalKeyboardKey.keyF,
  PhysicalKeyboardKey.keyG,
  PhysicalKeyboardKey.keyH,
  PhysicalKeyboardKey.keyJ,
  PhysicalKeyboardKey.keyK,
  PhysicalKeyboardKey.keyL,
  PhysicalKeyboardKey.semicolon,
  PhysicalKeyboardKey.quote,
  PhysicalKeyboardKey.backslash,
];
const drumKeys = [
  PhysicalKeyboardKey.keyD,
  PhysicalKeyboardKey.keyS,
  PhysicalKeyboardKey.keyA,
  PhysicalKeyboardKey.keyF,
  PhysicalKeyboardKey.keyG,
  PhysicalKeyboardKey.keyH,
];
final allowedInstrumentKeys = <PhysicalKeyboardKey>[
  for (int i = 4; i <= 39; i++) PhysicalKeyboardKey(0x70000 + i),
  PhysicalKeyboardKey.semicolon,
  PhysicalKeyboardKey.quote,
  PhysicalKeyboardKey.backslash,
  PhysicalKeyboardKey.comma,
  PhysicalKeyboardKey.period,
  PhysicalKeyboardKey.slash,
  PhysicalKeyboardKey.bracketLeft,
  PhysicalKeyboardKey.bracketRight,
];
String instrumentKeyLabel(PhysicalKeyboardKey key) {
  final usage = key.usbHidUsage;
  if (usage >= 0x70004 && usage <= 0x7001d) {
    return String.fromCharCode(65 + usage - 0x70004);
  }
  if (usage >= 0x7001e && usage <= 0x70027) {
    return '${(usage - 0x7001e + 1) % 10}';
  }
  return {
        PhysicalKeyboardKey.semicolon: ';',
        PhysicalKeyboardKey.quote: "'",
        PhysicalKeyboardKey.backslash: '\\',
        PhysicalKeyboardKey.comma: ',',
        PhysicalKeyboardKey.period: '.',
        PhysicalKeyboardKey.slash: '/',
        PhysicalKeyboardKey.bracketLeft: '[',
        PhysicalKeyboardKey.bracketRight: ']',
      }[key] ??
      '?';
}

List<PhysicalKeyboardKey> instrumentKeys(String group, List<int>? saved) {
  final defaults = group == 'piano' ? pianoKeys : drumKeys;
  if (saved == null ||
      saved.length != defaults.length ||
      saved.toSet().length != saved.length ||
      saved.any(
        (id) => !allowedInstrumentKeys.any((k) => k.usbHidUsage == id),
      )) {
    return defaults;
  }
  return saved.map(PhysicalKeyboardKey.new).toList();
}

/// Focus-scoped physical keys keep Korean IME and text editing independent.
class DesktopInstrument extends StatefulWidget {
  const DesktopInstrument({
    super.key,
    required this.group,
    required this.identity,
    required this.labels,
    required this.onDown,
    required this.child,
  });
  final String group;
  final Object identity;
  final List<String> labels;
  final VoidCallback Function(int) onDown;
  final Widget child;
  @override
  State<DesktopInstrument> createState() => _DesktopInstrumentState();
}

class _DesktopInstrumentState extends State<DesktopInstrument>
    with WidgetsBindingObserver {
  final _focus = FocusNode(debugLabel: 'Instrument keyboard');
  final _held = <PhysicalKeyboardKey, VoidCallback>{};
  bool get _ko => Localizations.localeOf(context).languageCode == 'ko';
  void _release() {
    final callbacks = _held.values.toList();
    _held.clear();
    for (final callback in callbacks) {
      callback();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(DesktopInstrument old) {
    super.didUpdateWidget(old);
    if (old.identity != widget.identity || old.group != widget.group) {
      _release();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _release();
  }

  @override
  void dispose() {
    _release();
    WidgetsBinding.instance.removeObserver(this);
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _key(KeyEvent event, List<PhysicalKeyboardKey> keys) {
    if (event is KeyUpEvent) {
      final release = _held.remove(event.physicalKey);
      release?.call();
      return release == null ? KeyEventResult.ignored : KeyEventResult.handled;
    }
    if (ModalRoute.of(context)?.isCurrent == false ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final index = keys.indexOf(event.physicalKey);
    if (index < 0 || index >= widget.labels.length) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent && !_held.containsKey(event.physicalKey)) {
      _held[event.physicalKey] = widget.onDown(index);
    }
    return KeyEventResult.handled;
  }

  Future<void> _settings(List<PhysicalKeyboardKey> current) async {
    _release();
    final draft = List<PhysicalKeyboardKey>.of(current);
    int? selected;
    String? error;
    final result = await showDialog<List<PhysicalKeyboardKey>>(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder:
                (context, update) => Focus(
                  autofocus: true,
                  onKeyEvent: (_, event) {
                    if (selected == null || event is! KeyDownEvent) {
                      return KeyEventResult.ignored;
                    }
                    if (event.logicalKey == LogicalKeyboardKey.escape) {
                      update(() => selected = null);
                      return KeyEventResult.handled;
                    }
                    final key = event.physicalKey;
                    update(() {
                      if (!allowedInstrumentKeys.contains(key)) {
                        error =
                            _ko
                                ? '문자·숫자 키를 선택하세요.'
                                : 'Choose a letter, number or punctuation key.';
                      } else if (draft.contains(key) &&
                          draft[selected!] != key) {
                        error =
                            _ko
                                ? '이미 사용 중인 키입니다.'
                                : 'This key is already assigned.';
                      } else {
                        draft[selected!] = key;
                        selected = null;
                        error = null;
                      }
                    });
                    return KeyEventResult.handled;
                  },
                  child: AlertDialog(
                    title: Text(_ko ? '연주 키 설정' : 'Instrument keys'),
                    content: SizedBox(
                      width: 520,
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _ko
                                  ? '버튼을 선택하고 새 키를 누르세요. 키는 자판의 물리적 위치를 따릅니다.'
                                  : 'Select a button, then press a new key. Bindings follow physical keyboard positions.',
                            ),
                            const SizedBox(height: 16),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (var i = 0; i < draft.length; i++)
                                  OutlinedButton(
                                    onPressed:
                                        () => update(() {
                                          selected = i;
                                          error = null;
                                        }),
                                    child: Text(
                                      '${i + 1}: ${selected == i ? '…' : instrumentKeyLabel(draft[i])}',
                                    ),
                                  ),
                              ],
                            ),
                            if (error != null)
                              Text(
                                error!,
                                style: const TextStyle(color: LT.danger),
                              ),
                          ],
                        ),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed:
                            () => update(() {
                              draft.setAll(
                                0,
                                widget.group == 'piano' ? pianoKeys : drumKeys,
                              );
                              selected = null;
                              error = null;
                            }),
                        child: Text(_ko ? '기본값' : 'Reset'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(_ko ? '취소' : 'Cancel'),
                      ),
                      FilledButton(
                        onPressed:
                            selected == null
                                ? () => Navigator.pop(context, draft)
                                : null,
                        child: Text(_ko ? '저장' : 'Save'),
                      ),
                    ],
                  ),
                ),
          ),
    );
    if (result != null) {
      await LoopPrefs.instance.setKeyboardBindings(
        widget.group,
        result.map((k) => k.usbHidUsage).toList(),
      );
    }
    if (mounted) _focus.requestFocus();
  }

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<Map<String, List<int>>>(
    valueListenable: LoopPrefs.instance.keyboardBindings,
    builder: (context, saved, _) {
      final keys = instrumentKeys(widget.group, saved[widget.group]);
      return Focus(
        focusNode: _focus,
        autofocus: true,
        onFocusChange: (focused) {
          if (!focused) _release();
        },
        onKeyEvent: (_, event) => _key(event, keys),
        child: Listener(
          onPointerDown: (_) => _focus.requestFocus(),
          child: Column(
            children: [
              SizedBox(
                height: 40,
                child: Row(
                  children: [
                    Expanded(
                      child: Row(children: [
                        for (var i = 0; i < widget.labels.length && i < keys.length; i++)
                          Expanded(child: Center(child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(color: LT.surface2,
                              border: Border.all(color: LT.borderStrong),
                              borderRadius: BorderRadius.circular(5)),
                            child: Text(widget.group == 'piano'
                              ? instrumentKeyLabel(keys[i])
                              : '${instrumentKeyLabel(keys[i])} · ${widget.labels[i]}',
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: LT.t2, fontSize: 12)),
                          ))),
                      ]),
                    ),
                    IconButton(
                      tooltip: _ko ? '연주 키 설정' : 'Instrument keys',
                      onPressed: () => _settings(keys),
                      icon: const Icon(Icons.keyboard_outlined, size: 20),
                    ),
                  ],
                ),
              ),
              Expanded(child: widget.child),
            ],
          ),
        ),
      );
    },
  );
}
