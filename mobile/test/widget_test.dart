// 기본 스모크 테스트 — 앱이 빌드되고 Songs 화면이 뜨는지.
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/main.dart';

void main() {
  testWidgets('App builds and shows start CTA', (tester) async {
    await tester.pumpWidget(const HummingApp());
    await tester.pump();
    expect(find.text('작업 시작'), findsOneWidget);
  });
}
