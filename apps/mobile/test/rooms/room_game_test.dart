import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:partybox_mobile/src/rooms/room_controller.dart';
import 'package:partybox_mobile/src/rooms/room_models.dart';
import 'package:partybox_mobile/src/rooms/room_screen.dart';
import 'package:partybox_mobile/src/rooms/room_vault.dart';
import 'package:partybox_mobile/src/design/night_theme.dart';
import 'support.dart';
import '../support/design_fonts.dart';
import '../support/local_game_flow.dart';
import '../support/role_peek_flow.dart';

Map<String, dynamic> fixture() =>
    ((jsonDecode(
              File(
                '../../packages/game-contracts/examples/rooms-v2.json',
              ).readAsStringSync(),
            )
            as Map)['GameSnapshot']
        as Map<String, dynamic>);
void main() {
  for (final size in [
    const Size(320, 640),
    const Size(360, 800),
    const Size(390, 844),
  ]) {
    testWidgets('network role and confirmation fit $size without page scroll', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = FakeRoomApi()..current = RoomSnapshot.parse(fixture());
      final controller = RoomController(
        api: api,
        vault: TestVault()..value = saved(),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: RoomScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      api.receive!(api.current);
      await tester.pumpAndSettle();
      final action = find.text('Подтвердить роль');
      final rect = tester.getRect(action);
      expect(rect.bottom, lessThanOrEqualTo(size.height));
      expect(rect.top, greaterThanOrEqualTo(0));
      for (final element in find.byType(Scrollable).evaluate()) {
        expect((element as StatefulElement).state is ScrollableState, true);
        final position = (element.state as ScrollableState).position;
        expect(position.maxScrollExtent, 0);
      }
      final before = tester.getRect(
        find.byKey(const ValueKey('role-peek-surface')),
      );
      final gesture = await holdCard(tester);
      expect(controller.cardVisible, true);
      expect(
        tester.getRect(find.byKey(const ValueKey('role-peek-surface'))),
        before,
      );
      await gesture.up();
      await tester.pump();
      expect(controller.cardVisible, false);
      expect(find.text('Учебная локация'), findsNothing);
      expect(tester.getRect(action).bottom, lessThanOrEqualTo(size.height));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'catalogue choice replaces finished Spy but preserves active Spy',
    (tester) async {
      for (final finished in [true, false]) {
        final value = fixture();
        value['protocolVersion'] = 3;
        value['privateTolerance'] = null;
        final state = value['publicState'] as Map<String, dynamic>;
        state['tolerance'] = null;
        final game = state['game'] as Map<String, dynamic>;
        if (finished) {
          game['phase'] = 'results';
          game['readyIds'] = [
            for (final p in state['players'] as List) (p as Map)['id'],
          ];
          game['deadline'] = '2026-11-08T12:03:00.000Z';
          game['result'] = {
            'spyId': selfId,
            'suspectId': selfId,
            'location': 'Учебная локация',
            'winner': 'civilians',
          };
          value['privateState'] = null;
        }
        final api = FakeRoomApi()..current = RoomSnapshot.parse(value);
        final controller = RoomController(
          api: api,
          vault: TestVault()..value = saved(),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: nightTheme(),
            home: RoomScreen(controller: controller, initialGame: 'tolerance'),
          ),
        );
        await tester.pumpAndSettle();
        await settleRoomContent(tester);
        expect(api.enrollments, isEmpty);
        if (finished) {
          expect(find.text('Начать «Шкалу терпения»'), findsOneWidget);
        } else {
          expect(find.text('Начать «Шкалу терпения»'), findsNothing);
          expect(
            find.byKey(const ValueKey('role-peek-surface')),
            findsOneWidget,
          );
        }
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
  testWidgets(
    'room peek hides on disconnect; reconnect cannot revive held gesture',
    (tester) async {
      final api = FakeRoomApi()..current = RoomSnapshot.parse(fixture());
      final controller = RoomController(
        api: api,
        vault: TestVault()..value = saved(),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: RoomScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      api.receive!(api.current);
      await tester.pumpAndSettle();
      await showWidget(tester, find.byKey(const ValueKey('role-peek-surface')));
      final gesture = await holdCard(tester);
      expect(find.text('Учебная локация'), findsOneWidget);
      api.disconnected!();
      await tester.pump();
      expect(find.text('Учебная локация'), findsNothing);
      api.receive!(api.current);
      await tester.pump();
      await gesture.moveBy(const Offset(0, -120));
      await tester.pump();
      expect(find.text('Учебная локация'), findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();
      final fresh = await holdCard(tester, pointer: 2);
      expect(find.text('Учебная локация'), findsOneWidget);
      await fresh.up();
      await tester.pump();
      expect(controller.roleViewed, true);
      expect(find.text('Учебная локация'), findsNothing);
      await tapVisible(tester, find.text('Подтвердить роль'));
      expect(api.leaves.single.leave!['type'], 'spy.ready');
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('host starts a room with the selected theme', (tester) async {
    final value = fixture();
    (value['publicState'] as Map)['game'] = null;
    value['privateState'] = null;
    final api = FakeRoomApi()..current = RoomSnapshot.parse(value);
    final controller = RoomController(
      api: api,
      vault: TestVault()..value = saved(),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: nightTheme(),
        home: RoomScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    api.receive!(api.current);
    await tester.pumpAndSettle();
    await settleRoomContent(tester);
    await tapVisible(
      tester,
      find.byKey(const ValueKey('room-pack-spy-ru-base')),
    );
    await tester.tap(find.text('За гранью обычного').last);
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('Начать партию'));
    expect(api.leaves.single.leave!['type'], 'spy.start');
    expect(api.leaves.single.leave!['payload'], {
      'packId': 'spy-ru-unusual',
      'discussionMinutes': 5,
    });
    await tester.pumpWidget(const SizedBox());
  });
  test(
    'room access v1 migrates to v2 without losing token or retry identity',
    () {
      final legacy = jsonDecode(
        File('test/fixtures/room_access_v1.json').readAsStringSync(),
      );
      final restored = RoomAccess.decode(jsonEncode(legacy));
      expect(restored.token, testToken);
      expect(restored.toJson()['schemaVersion'], 2);
      expect(RoomAccess.decode(jsonEncode(restored.toJson())).token, testToken);
      final pending = RoomAccess.decode(
        File('test/fixtures/room_access_v2.json').readAsStringSync(),
      );
      expect(pending.leave!['type'], 'spy.ready');
      expect(
        RoomAccess.decode(jsonEncode(pending.toJson())).leave,
        pending.leave,
      );
    },
  );
  test(
    'v2 shared examples and private card consistency are checked in Dart',
    () {
      final examples =
          jsonDecode(
                File(
                  '../../packages/game-contracts/examples/rooms-v2.json',
                ).readAsStringSync(),
              )
              as Map;
      for (final key in examples.keys) {
        expect(RoomContract.accepts(key as String, examples[key]), true);
      }
      final starts =
          jsonDecode(
                File(
                  '../../packages/game-contracts/examples/spy-start-v2.json',
                ).readAsStringSync(),
              )
              as List;
      for (final start in starts) {
        expect(RoomContract.accepts('GameCommand', start), true);
      }
      final value = fixture();
      value['privateState'] = {'role': 'spy', 'location': 'Учебная локация'};
      expect(() => RoomSnapshot.parse(value), throwsA(isA<RoomFailure>()));
    },
  );
  test(
    'revocation during HTTP hides the card immediately and clears access after a failed request',
    () async {
      final parsed = RoomSnapshot.parse(fixture());
      final api = FakeRoomApi()..current = parsed;
      final vault = TestVault()..value = saved();
      final controller = RoomController(api: api, vault: vault);
      addTearDown(controller.dispose);
      await controller.initialize();
      api.receive!(parsed);
      controller.revealRole();
      expect(controller.cardVisible, true);
      var hiddenNotified = false;
      controller.addListener(() {
        if (!controller.cardVisible) hiddenNotified = true;
      });
      api.snapshotGate = Completer<void>();
      api.snapshotError = const RoomFailure('CONNECTION');
      final request = controller.retry();
      api.fail!(const RoomFailure('UNAUTHORIZED'));
      expect(controller.cardVisible, false);
      expect(hiddenNotified, true);
      api.snapshotGate!.complete();
      await request;
      await Future<void>.delayed(Duration.zero);
      expect(vault.value, null);
      expect(controller.canEnroll, true);
      expect(controller.error, null);
      expect(controller.notice, const RoomFailure('UNAUTHORIZED').message);
    },
  );
  testWidgets(
    'own role is removed on background and disconnect, including semantics',
    (tester) async {
      final value = fixture();
      final parsed = RoomSnapshot.parse(value);
      final vault = TestVault()..value = saved();
      final api = FakeRoomApi()..current = parsed;
      final controller = RoomController(api: api, vault: vault);
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: RoomScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      api.receive!(parsed);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Показать мою роль'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Показать мою роль'));
      await tester.pumpAndSettle();
      expect(find.text('Учебная локация'), findsOneWidget);
      controller.setActive(false);
      await tester.pump();
      expect(find.text('Учебная локация'), findsNothing);
      controller.setActive(true);
      await tester.pumpAndSettle();
      api.receive!(parsed);
      controller.revealRole();
      await tester.pump();
      expect(find.text('Учебная локация'), findsOneWidget);
      api.disconnected!();
      await tester.pump();
      expect(find.text('Учебная локация'), findsNothing);
      expect(controller.cardVisible, false);
    },
  );
  test(
    'uncertain game command preserves ID across controller restart without persisting card',
    () async {
      final parsed = RoomSnapshot.parse(fixture());
      final vault = TestVault()..value = saved();
      final api = FakeRoomApi()
        ..current = parsed
        ..leaveError = const RoomFailure('CONNECTION');
      final first = RoomController(api: api, vault: vault);
      await first.initialize();
      await first.play('spy.ready');
      final command = vault.value!.leave!;
      expect(
        jsonEncode(vault.value!.toJson()),
        isNot(contains('Учебная локация')),
      );
      first.dispose();
      final nextApi = FakeRoomApi()..current = parsed;
      final second = RoomController(api: nextApi, vault: vault);
      addTearDown(second.dispose);
      await second.initialize();
      expect(nextApi.leaves.single.leave, command);
      expect(vault.value!.leave, null);
    },
  );
  testWidgets('network role and result visuals', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await loadDesignFonts(tester);
    for (final phase in ['distribution', 'results']) {
      final value = fixture();
      final game = (value['publicState'] as Map)['game'] as Map;
      if (phase == 'distribution') {
        value['privateState'] = {'role': 'spy', 'location': null};
      } else {
        game['phase'] = 'results';
        game['readyIds'] = [
          for (final p in (value['publicState'] as Map)['players'] as List)
            (p as Map)['id'],
        ];
        game['deadline'] = '2026-11-08T12:03:00.000Z';
        game['result'] = {
          'spyId': selfId,
          'suspectId': selfId,
          'location': 'Учебная локация',
          'winner': 'civilians',
        };
        value['privateState'] = null;
      }
      final api = FakeRoomApi()..current = RoomSnapshot.parse(value);
      final controller = RoomController(
        api: api,
        vault: TestVault()..value = saved(),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          home: RepaintBoundary(
            key: const Key('game-capture'),
            child: RoomScreen(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      api.receive!(api.current);
      if (phase == 'distribution') controller.revealRole();
      await tester.pumpAndSettle();
      await settleRoomContent(tester);
      await expectLater(
        find.byKey(const Key('game-capture')),
        matchesGoldenFile('goldens/network-$phase.png'),
      );
      await tester.pumpWidget(const SizedBox());
    }
  });
}
