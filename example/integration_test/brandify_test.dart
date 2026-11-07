// Store screenshots for the example app. Run with:
//   dart run brandify capture
import 'package:brandify_example/main.dart';
import 'package:brandify_flutter/brandify_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  brandifyTest('store screenshots', (tester, shot) async {
    await tester.pumpWidget(const BrandifyExampleApp());
    await shot('home');

    await tester.tap(find.byKey(const Key('add_task')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Buy oat milk');
    await shot('add_task'); // keyboard hidden (the default)
    await shot('add_task_keyboard', keyboard: Keyboard.show);
  });
}
