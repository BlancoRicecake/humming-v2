import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/widgets/track_clear_notice.dart';

void main() {
  Future<void> showNotice(WidgetTester tester, VoidCallback onUndo) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Builder(builder: (context) {
        return TextButton(
          onPressed: () => showTrackClearNotice(
            context,
            message: 'Track cleared',
            undoLabel: 'Undo',
            onUndo: onUndo,
          ),
          child: const Text('Clear'),
        );
      })),
    ));
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
  }

  testWidgets('dismisses automatically even with an Undo action', (tester) async {
    await showNotice(tester, () {});
    expect(find.text('Track cleared'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('Track cleared'), findsNothing);
  });

  testWidgets('Undo still works before the notice expires', (tester) async {
    var undone = false;
    await showNotice(tester, () => undone = true);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(undone, isTrue);
    expect(find.text('Track cleared'), findsNothing);
  });
}
