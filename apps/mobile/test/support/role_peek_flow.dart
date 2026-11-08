import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<TestGesture> holdCard(WidgetTester tester, {int pointer = 1}) async {
  final surface = find.byKey(const ValueKey('role-peek-surface'));
  final gesture = await tester.startGesture(
    tester.getCenter(surface),
    pointer: pointer,
  );
  await gesture.moveBy(const Offset(0, -24));
  await tester.pump();
  await gesture.moveBy(const Offset(0, -90));
  await tester.pump(const Duration(milliseconds: 150));
  return gesture;
}
