// ui-001 stage 3: the desktop editor opens in the edit view (minimap + the
// editing surface). Tests that work on the timeline (Arrangement, section
// band, ruler) switch views the way a user does: the top bar's view switch,
// and a track row's double-click callback to edit that track.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/widgets/arrangement.dart';

/// The arrange view (no-op when the timeline is already on screen).
Future<void> showArrange(WidgetTester tester) async {
  if (find.byType(Arrangement).evaluate().isNotEmpty) return;
  await tester.tap(find.byKey(const ValueKey('view-arrange')));
  await tester.pump();
  await tester.pump();
}

/// The edit view (no-op when it is already shown).
Future<void> showEdit(WidgetTester tester) async {
  if (find.byType(Arrangement).evaluate().isEmpty) return;
  await tester.tap(find.byKey(const ValueKey('view-edit')));
  await tester.pump();
  await tester.pump();
}

/// The timeline, switching to the arrange view first.
Future<Arrangement> arrangeTimeline(WidgetTester tester) async {
  await showArrange(tester);
  return tester.widget<Arrangement>(find.byType(Arrangement));
}

/// Edit track [id]: arrange view, then the row's double-click path.
Future<void> editTrack(WidgetTester tester, String id) async {
  await showArrange(tester);
  tester.widget<Arrangement>(find.byType(Arrangement)).onOpenTrack!(id);
  await tester.pump();
  await tester.pump();
}
