// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:lg_webos_remote/main.dart';

void main() {
  testWidgets('LG remote opens', (WidgetTester tester) async {
    await tester.pumpWidget(const LgRemoteApp());
    expect(find.text('OFFLINE'), findsOneWidget);
    expect(find.text('Remote'), findsOneWidget);
  });
}
