import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:partybox_mobile/src/app.dart';
import 'package:partybox_mobile/src/rooms/room_controller.dart';
import 'package:partybox_mobile/src/rooms/room_screen.dart';
import 'package:partybox_mobile/src/design/night_theme.dart';
import '../support/design_fonts.dart';
import 'support.dart';

void main() {
  testWidgets('create, roster, explicit leave confirmation and retry', (
    tester,
  ) async {
    final api = FakeRoomApi();
    final vault = TestVault();
    final controller = RoomController(api: api, vault: vault);
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: RoomScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Создать комнату'));
    await tester.pumpAndSettle();
    expect(api.enrollments, isEmpty);
    await tester.enterText(find.byType(TextFormField).first, 'Участник');
    await tester.tap(find.text('Создать комнату'));
    await tester.pumpAndSettle();
    expect(find.text('001 234'), findsOneWidget);
    expect(find.text('Это вы · Ведущий'), findsOneWidget);
    await tester.ensureVisible(find.text('Выйти из комнаты'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выйти из комнаты'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(api.leaves, isEmpty);
    await tester.tap(find.text('Выйти из комнаты'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выйти'));
    await tester.pumpAndSettle();
    expect(api.leaves, hasLength(1));
    expect(find.text('Создать комнату'), findsOneWidget);
  });
  testWidgets('join PIN and catalogue back preserve membership', (
    tester,
  ) async {
    final vault = TestVault();
    final api = FakeRoomApi();
    var factories = 0;
    await tester.pumpWidget(
      PartyBoxApp(
        roomControllerFactory: () {
          factories++;
          return RoomController(api: api, vault: vault);
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Войти по коду'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Войти по коду'));
    await tester.pumpAndSettle();
    expect(factories, 1);
    await tester.tap(find.text('Войти по коду'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Игрок');
    await tester.enterText(find.byType(TextFormField).last, '001234');
    await tester.ensureVisible(find.text('Войти в комнату'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Войти в комнату'));
    await tester.pumpAndSettle();
    expect(api.enrollments.single.pin, '001234');
    await tester.tap(find.byTooltip('Назад'));
    await tester.pumpAndSettle();
    expect(vault.value!.token, testToken);
    expect(api.leaves, isEmpty);
    await tester.ensureVisible(find.text('Войти по коду'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Войти по коду'));
    await tester.pumpAndSettle();
    expect(factories, 2);
    expect(api.enrollments, hasLength(1));
    expect(find.text('001 234'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('small screen, 12 long names and large text do not overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final vault = TestVault()..value = saved();
    final api = FakeRoomApi()..current = view(count: 12);
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: RoomScreen(
          controller: RoomController(api: api, vault: vault),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await settleRoomContent(tester);
    await tester.scrollUntilVisible(find.text('Выйти из комнаты'), 300);
    for (
      var i = 0;
      i < 40 && find.text('Выйти из комнаты').hitTestable().evaluate().isEmpty;
      i++
    ) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -200));
      await tester.pumpAndSettle();
    }
    expect(find.text('Выйти из комнаты').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Выйти из комнаты'));
    await tester.pumpAndSettle();
    expect(find.text('Выйти из комнаты?'), findsOneWidget);
    expect(tester.takeException(), null);
  });
  testWidgets('room lobby design', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await loadDesignFonts(tester);
    final vault = TestVault()..value = saved();
    final api = FakeRoomApi()..current = view(count: 4);
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: RepaintBoundary(
          key: const Key('lobby-capture'),
          child: RoomScreen(
            controller: RoomController(api: api, vault: vault),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    api.receive!(api.current);
    await tester.pumpAndSettle();
    await settleRoomContent(tester);
    await expectLater(
      find.byKey(const Key('lobby-capture')),
      matchesGoldenFile('goldens/lobby.png'),
    );
  });
}
