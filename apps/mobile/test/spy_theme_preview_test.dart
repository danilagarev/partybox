import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:partybox_mobile/src/design/night_theme.dart';
import 'package:partybox_mobile/src/spy/local_session_adapter.dart';
import 'package:partybox_mobile/src/spy/spy_theme_preview.dart';

void main() {
  testWidgets('pack contents can be browsed and dismissed with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final pack = SpyPack(
      id: 'spy-ru-travel',
      version: 1,
      title: 'Вокруг света',
      description: 'Путешествия и остановки в пути.',
      locations: List.generate(60, (i) => 'Место ${i + 1}'),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: Scaffold(
          body: ListView(children: [SpyThemePreview(pack: pack)]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Посмотреть локации'));
    await tester.tap(find.text('Посмотреть локации'));
    await tester.pumpAndSettle();
    expect(find.text('Вокруг света'), findsOneWidget);
    final sheet = find.byType(BottomSheet);
    await tester.scrollUntilVisible(
      find.text('Место 60'),
      300,
      scrollable: find.descendant(of: sheet, matching: find.byType(Scrollable)),
      maxScrolls: 60,
    );
    await tester.pumpAndSettle();
    expect(find.text('Место 60').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Готово'));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
