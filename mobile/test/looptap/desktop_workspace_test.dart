import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';

void main() {
  testWidgets('commands ignore repeats, text editing and modal routes', (tester) async {
    var plays = 0, saves = 0, records = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: DesktopCommands(
      enabled: true, play: () => plays++, record: () => records++, save: () => saves++,
      undo: () {}, redo: () {}, child: Column(children: [
        const TextField(), Builder(builder: (context) => TextButton(onPressed: () => showDialog<void>(context: context,
          builder: (_) => const AlertDialog(content: Text('Dialog'))), child: const Text('Open'))),
      ])))));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    expect(plays, 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(saves, 1); expect(records, 1);
    await tester.tap(find.byType(TextField)); await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(plays, 1);
    await tester.tap(find.text('Open')); await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(plays, 1);
  });
  testWidgets('zoom clamps, scrolls, resets and fits minimum desktop width', (tester) async {
    await tester.binding.setSurfaceSize(const Size(960, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox(height: 230,
      child: DesktopTimeline(child: ColoredBox(color: Colors.black))))));
    for (var i = 0; i < 8; i++) {
      await tester.tap(find.byKey(const ValueKey('timeline-zoom-in'))); await tester.pump();
    }
    expect(find.text('400%'), findsOneWidget);
    final scroll = tester.widget<SingleChildScrollView>(find.byType(SingleChildScrollView));
    expect(scroll.controller!.position.maxScrollExtent, greaterThan(2000));
    scroll.controller!.jumpTo(1000); await tester.pump();
    await tester.tap(find.text('Fit')); await tester.pump();
    expect(find.text('100%'), findsOneWidget);
    expect(scroll.controller!.offset, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets('split handle resizes and double-click resets', (tester) async {
    var moved = 0.0; var resets = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: DesktopSplitHandle(
      onDelta: (d) => moved += d, onReset: () => resets++)))));
    await tester.drag(find.byType(DesktopSplitHandle), const Offset(0, 80));
    expect(moved, greaterThan(0));
    await tester.tap(find.byType(DesktopSplitHandle));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.byType(DesktopSplitHandle)); await tester.pump();
    expect(resets, 1);
    await tester.pump(const Duration(seconds: 3));
  });
}
