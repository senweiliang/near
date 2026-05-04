import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:near/main.dart';

void main() {
  testWidgets('app launches into name prompt', (WidgetTester tester) async {
    await tester.pumpWidget(const NearApp());
    await tester.pump();
    expect(find.text('Near'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
}
