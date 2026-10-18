// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

import 'package:walk_pin_navigator/main.dart';

void main() {
  testWidgets('legal page shows app information', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: AppLegalPage()));

    expect(find.text('좌표 도보 길안내'), findsOneWidget);
    expect(find.textContaining('제작자: 김완호'), findsOneWidget);
  });
}
