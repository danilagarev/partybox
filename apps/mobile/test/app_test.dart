import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:partybox_mobile/src/rooms/room_controller.dart';
import 'package:partybox_mobile/src/rooms/room_models.dart';
import 'package:partybox_mobile/src/rooms/room_screen.dart';
import 'package:partybox_mobile/src/rooms/room_game_panel.dart';
import 'package:partybox_mobile/src/design/night_theme.dart';
import 'package:partybox_mobile/src/design/role_peek_card.dart';
import 'rooms/support.dart';
import 'support/design_fonts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:partybox_game_content/partybox_game_content.dart';
import 'package:partybox_mobile/src/app.dart';

import 'support/local_game_flow.dart';

void main() {
  testWidgets('catalog opens rules and can return', (tester) async {
    await tester.pumpWidget(const PartyBoxApp());
    expect(find.text('Шпион'), findsOneWidget);
    await tapVisible(tester, find.text('Играть в «Шпиона»'));
    await tester.pumpAndSettle();
    expect(find.text('Один из вас не в курсе.'), findsOneWidget);
    await showWidget(tester, find.textContaining('Голосуйте вслух'));
    expect(find.textContaining('Один телефон · без интернета'), findsOneWidget);
    await showWidget(tester, find.textContaining('новый тур среди лидеров'));
    expect(find.textContaining('голоса тайные'), findsOneWidget);
    await goBack(tester);
    await tester.pumpAndSettle();
    expect(find.text('Играть в «Шпиона»'), findsOneWidget);
  });

  testWidgets('room code entry is visible on the first screen of the catalog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      PartyBoxApp(
        roomControllerFactory: () =>
            RoomController(api: FakeRoomApi(), vault: TestVault()),
      ),
    );
    await tester.pumpAndSettle();
    final join = find.text('Войти по коду').hitTestable();
    expect(join, findsOneWidget);
    await tester.tap(join);
    await tester.pumpAndSettle();
    expect(find.byType(RoomScreen), findsOneWidget);
    expect(find.text('Код комнаты'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('small screen and large text remain scrollable', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(const PartyBoxApp());
    await tester.scrollUntilVisible(find.text('Играть в «Шпиона»'), 200);
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('Играть в «Шпиона»'));
    await tester.pumpAndSettle();
    expect(find.text('Один из вас не в курсе.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('both games are visible without server at normal phone size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await loadDesignFonts(tester);
    await tester.pumpWidget(const PartyBoxApp());
    await tester.pumpAndSettle();
    expect(find.text('Шпион').hitTestable(), findsOneWidget);
    expect(find.text('Шкала терпения').hitTestable(), findsOneWidget);
    expect(find.text('Играть в «Шкалу»').hitTestable(), findsOneWidget);
  });

  testWidgets(
    'tolerance stays discoverable with large text and reduced motion',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(const PartyBoxApp());
      await tapVisible(tester, find.text('Играть в «Шкалу»'));
      expect(find.text('У каждого\nсвой предел.'), findsOneWidget);
      await showWidget(tester, find.text('Создать комнату «Шкалы»'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tolerance selection reaches configured room and remains selected',
    (tester) async {
      final api = FakeRoomApi()..current = catalogLobby();
      var resolved = 0;
      await tester.pumpWidget(
        PartyBoxApp(
          resolveRoomController: (context) async {
            resolved++;
            return RoomController(api: api, vault: TestVault());
          },
        ),
      );
      await tapVisible(tester, find.text('Играть в «Шкалу»'));
      await tapVisible(tester, find.text('Создать комнату «Шкалы»'));
      expect(resolved, 1);
      await tester.enterText(find.byType(TextFormField).first, 'Анна');
      await tapVisible(tester, find.text('Создать комнату'));
      expect(find.text('Начать «Шкалу терпения»'), findsOneWidget);
      final chip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'Шкала терпения'),
      );
      expect(chip.selected, isTrue);
      expect(api.enrollments, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('restored active spy overrides tolerance catalog selection', (
    tester,
  ) async {
    final data =
        (jsonDecode(
                  File(
                    '../../packages/game-contracts/examples/rooms-v2.json',
                  ).readAsStringSync(),
                )
                as Map)['GameSnapshot']
            as Map<String, dynamic>;
    data['protocolVersion'] = 3;
    data['privateTolerance'] = null;
    (data['publicState'] as Map)['tolerance'] = null;
    final api = FakeRoomApi()..current = RoomSnapshot.parse(data);
    final vault = TestVault()..value = saved();
    await tester.pumpWidget(
      PartyBoxApp(
        roomControllerFactory: () => RoomController(api: api, vault: vault),
      ),
    );
    await tapVisible(tester, find.text('Играть в «Шкалу»'));
    await tapVisible(tester, find.text('Создать комнату «Шкалы»'));
    expect(find.byType(RolePeekCard), findsOneWidget);
    expect(find.text('Начать «Шкалу терпения»'), findsNothing);
    expect(api.enrollments, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('guest cannot change selected game', (tester) async {
    final api = FakeRoomApi()..current = catalogLobby(guest: true);
    final controller = RoomController(
      api: api,
      vault: TestVault()..value = saved(),
    );
    await controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: Scaffold(
          body: RoomGamePanel(controller: controller, initialGame: 'tolerance'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final chip in tester.widgetList<ChoiceChip>(find.byType(ChoiceChip))) {
      expect(chip.onSelected, isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets(
    'deferred room navigation ignores double taps and cancellation permits retry',
    (tester) async {
      final pending = <Completer<RoomController?>>[];
      await tester.pumpWidget(
        PartyBoxApp(
          resolveRoomController: (_) {
            final result = Completer<RoomController?>();
            pending.add(result);
            return result.future;
          },
        ),
      );
      final join = find.text('Войти по коду');
      await tapVisible(tester, join);
      await tapVisible(tester, join);
      expect(pending, hasLength(1));
      pending.first.complete(null);
      await tester.pumpAndSettle();
      await tapVisible(tester, join);
      await tapVisible(tester, join);
      expect(pending, hasLength(2));
      pending.last.complete(
        RoomController(api: FakeRoomApi(), vault: TestVault()),
      );
      await tester.pumpAndSettle();
      expect(find.byType(RoomScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'details double tap resolves once and abandoned controller is disposed',
    (tester) async {
      final pending = Completer<RoomController?>();
      var calls = 0;
      final api = FakeRoomApi();
      await tester.pumpWidget(
        PartyBoxApp(
          resolveRoomController: (_) {
            calls++;
            return pending.future;
          },
        ),
      );
      await tapVisible(tester, find.text('Играть в «Шкалу»'));
      final create = find.text('Создать комнату «Шкалы»');
      await tapVisible(tester, create);
      await tapVisible(tester, create);
      expect(calls, 1);
      await goBack(tester);
      pending.complete(RoomController(api: api, vault: TestVault()));
      await tester.pumpAndSettle();
      expect(api.closed, isTrue);
      expect(find.byType(RoomScreen), findsNothing);
    },
  );

  testWidgets('settings navigation shares guard with room and game entries', (
    tester,
  ) async {
    final configured = Completer<void>();
    var settingsCalls = 0, roomCalls = 0;
    await tester.pumpWidget(
      PartyBoxApp(
        onConfigureServer: (_) {
          settingsCalls++;
          return configured.future;
        },
        resolveRoomController: (_) async {
          roomCalls++;
          return null;
        },
      ),
    );
    final settings = find.text('Подключение комнат');
    await tapVisible(tester, settings);
    await tapVisible(tester, settings);
    await tapVisible(tester, find.text('Войти по коду'));
    await tapVisible(tester, find.text('Играть в «Шпиона»'));
    expect(settingsCalls, 1);
    expect(roomCalls, 0);
    expect(find.byType(SpyRulesScreen), findsNothing);
    configured.complete();
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('Войти по коду'));
    expect(roomCalls, 1);
  });

  testWidgets('starter location pack is included in the asset bundle', (
    tester,
  ) async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    expect(manifest.listAssets(), contains(spyBasePackAsset));
    final content = await rootBundle.loadString(spyBasePackAsset);
    expect(content, contains('spy-ru-base'));
  });
}

RoomSnapshot catalogLobby({bool guest = false}) => RoomSnapshot.parse({
  'protocolVersion': 3,
  'roomId': roomId,
  'version': 1,
  'selfId': guest ? otherId : selfId,
  'serverTime': '2026-11-08T12:00:00.000Z',
  'privateState': null,
  'privateTolerance': null,
  'publicState': {
    'phase': 'lobby',
    'pin': '001234',
    'hostId': selfId,
    'expiresAt': '2026-11-09T12:00:00.000Z',
    'game': null,
    'tolerance': null,
    'players': [
      {'id': selfId, 'name': 'Анна'},
      {'id': otherId, 'name': 'Борис'},
    ],
  },
});
