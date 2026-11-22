import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:partybox_mobile/src/design/night_theme.dart';
import 'package:partybox_mobile/src/design/role_peek_card.dart';
import 'package:partybox_mobile/src/spy/local_session_adapter.dart';
import 'package:partybox_mobile/src/spy/spy_game_screen.dart';
import 'package:partybox_mobile/src/storage/spy_setup.dart';

class EmptySetupStore implements SpySetupStore {
  @override
  Future<SetupRestore> load() async =>
      const SetupRestore(SetupRestoreStatus.empty);
  @override
  Future<void> save(SpySetup setup) async {}
  @override
  Future<void> clear() async {}
}

void main() {
  for (final size in [
    const Size(320, 640),
    const Size(360, 800),
    const Size(390, 844),
  ]) {
    testWidgets('four-player Spy fits $size without scrolling to advance', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: SpyGameScreen(
            setupStore: EmptySetupStore(),
            adapter: LocalSessionAdapter(
              pack: SpyPack(
                id: 'viewport',
                version: 1,
                title: 'Знакомые места',
                locations: ['Музей'],
              ),
              random: Random(42),
            ),
            now: () => DateTime.utc(2026, 11, 8),
          ),
        ),
      );
      await tester.pumpAndSettle();

      void inViewport(Finder finder) {
        final rect = tester.getRect(finder);
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.bottom, lessThanOrEqualTo(size.height));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(size.width));
      }

      void fits() {
        inViewport(find.byKey(const ValueKey('spy-primary-action')));
        final scrollable = find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first;
        final position = tester.state<ScrollableState>(scrollable).position;
        expect(position.pixels, 0);
        expect(position.maxScrollExtent, 0);
        expect(tester.takeException(), isNull);
      }

      Future<void> press(String label) async {
        inViewport(find.text(label));
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }

      fits();
      for (var i = 0; i < 4; i++) {
        final field = find.byKey(ValueKey('player-name-$i'));
        inViewport(field);
        await tester.enterText(field, ['Анна', 'Борис', 'Вера', 'Глеб'][i]);
      }
      await press('К настройкам');
      fits();
      await press('Раздать роли');
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 600));
        fits();
        final surface = find.byKey(const ValueKey('role-peek-surface'));
        inViewport(surface);
        final before = tester.getRect(surface);
        final gesture = await tester.startGesture(tester.getCenter(surface));
        await gesture.moveBy(const Offset(0, -24));
        await tester.pump();
        await gesture.moveBy(const Offset(0, -90));
        await tester.pump();
        expect(find.byType(RoleSecretFace), findsOneWidget);
        expect(tester.getRect(surface), before);
        fits();
        await gesture.up();
        await tester.pumpAndSettle();
        expect(find.byType(RoleSecretFace), findsNothing);
        fits();
        await press('Передать телефон');
      }
      fits();
      await press('Завершить обсуждение');
      fits();
      await press('Анна');
      fits();
      await press('Подтвердить и раскрыть');
      fits();
      await press('Ещё раз с теми же игроками');
      expect(find.text('Карточка 1 из 4'), findsOneWidget);
      fits();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('preparation action remains above the keyboard', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: SpyGameScreen(
          adapter: LocalSessionAdapter(
            pack: SpyPack(
              id: 'keyboard',
              version: 1,
              title: 'Тест',
              locations: ['Музей'],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('player-name-3')));
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.pumpAndSettle();
    final action = tester.getRect(
      find.byKey(const ValueKey('spy-primary-action')),
    );
    expect(action.top, greaterThanOrEqualTo(0));
    expect(action.bottom, lessThanOrEqualTo(380));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
