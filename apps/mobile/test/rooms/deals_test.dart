import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:partybox_mobile/src/design/night_theme.dart';
import 'package:partybox_mobile/src/rooms/room_controller.dart';
import 'package:partybox_mobile/src/rooms/room_models.dart';
import 'package:partybox_mobile/src/rooms/room_screen.dart';

import 'support.dart';

Map<String, dynamic> _example() =>
    (jsonDecode(
              File(
                '../../packages/game-contracts/examples/rooms-v7.json',
              ).readAsStringSync(),
            )
            as Map)['V7Snapshot']
        as Map<String, dynamic>;

Map<String, dynamic> _game(Map<String, dynamic> snapshot) =>
    (snapshot['publicState'] as Map)['deals'] as Map<String, dynamic>;

void main() {
  testWidgets(
    'first sale takes an item and one confirmation on a small phone',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final wire = _example();
      _game(wire)
        ..['phase'] = 'listing'
        ..['deadline'] = null
        ..['lots'] = <Object>[];
      (wire['privateDeals'] as Map)
        ..['inspection'] = null
        ..['inventory'] = <Map<String, Object>>[
          {
            'id': 'toy-5',
            'name': 'Настольный лабиринт',
            'category': 'toys',
            'value': 5,
          },
        ];
      final api = FakeRoomApi()..current = RoomSnapshot.parse(wire);
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

      await tester.tap(find.text('Настольный лабиринт'));
      await tester.pumpAndSettle();
      expect(find.text('Честное объявление'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget.runtimeType.toString().startsWith('DropdownButton'),
        ),
        findsNothing,
      );
      expect(find.text('Выставить за 6').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Выставить за 6'));
      await tester.pumpAndSettle();
      expect(api.leaves.single.leave!['payload'], {
        'itemId': 'toy-5',
        'category': 'toys',
        'value': 5,
        'price': 6,
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('market is visible and the offer draft survives reconnect', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 840));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = FakeRoomApi()..current = RoomSnapshot.parse(_example());
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

    final market = find.text('Что на рынке');
    await tester.ensureVisible(market);
    await tester.tap(market);
    await tester.pumpAndSettle();
    expect(find.text('Карманная метеостанция'), findsOneWidget);
    expect(find.text('7 монет'), findsOneWidget);
    await tester.tap(market);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Торг'));
    await tester.tap(find.text('Торг'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Увеличить цену'));
    await tester.pumpAndSettle();
    expect(find.text('Предложить за 9'), findsOneWidget);

    api.disconnected!();
    await tester.pumpAndSettle();
    expect(find.text('Предложить за 9'), findsNothing);
    expect(find.text('Ждём восстановления связи.'), findsOneWidget);

    final newer = _example()..['version'] = 2;
    _game(newer)['readyIds'] = [api.current.players[1].id];
    api.current = RoomSnapshot.parse(newer);
    api.receive!(api.current);
    await tester.pumpAndSettle();
    final offer = find.text('Предложить за 9');
    expect(offer, findsOneWidget);
    await tester.tap(offer);
    await tester.pumpAndSettle();
    expect(api.leaves.single.leave!['expectedVersion'], 2);
    expect((api.leaves.single.leave!['payload'] as Map)['price'], 9);
  });

  testWidgets('a private sheet clears its goal on disconnect and party exit', (
    tester,
  ) async {
    final api = FakeRoomApi()..current = RoomSnapshot.parse(_example());
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
    await tester.tap(find.byTooltip('Тайная цель'));
    await tester.pumpAndSettle();
    final goal = find.text(
      'Сохраните технику и искусство. Один товар купите у соперника.',
    );
    expect(goal, findsOneWidget);

    api.disconnected!();
    await tester.pumpAndSettle();
    expect(goal, findsNothing);
    api.receive!(api.current);
    await tester.pumpAndSettle();
    expect(goal, findsOneWidget);

    final lobby = _example()
      ..['version'] = 2
      ..['privateDeals'] = null;
    (lobby['publicState'] as Map)['deals'] = null;
    api.receive!(RoomSnapshot.parse(lobby));
    await tester.pumpAndSettle();
    expect(goal, findsNothing);
    expect(find.text('Эта партия больше недоступна.'), findsOneWidget);
  });

  testWidgets('rules can close safely after a phase change', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 1040));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = FakeRoomApi()..current = RoomSnapshot.parse(_example());
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

    final rules = find.text('Правила');
    await tester.ensureVisible(rules);
    await tester.pumpAndSettle();
    await tester.tap(rules);
    await tester.pumpAndSettle();
    expect(find.text('Как играть'), findsOneWidget);
    expect(find.text('Отменить партию'), findsOneWidget);
    final market = _example()..['version'] = 2;
    _game(market)
      ..['phase'] = 'market'
      ..['deadline'] = null;
    api.receive!(RoomSnapshot.parse(market));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отменить партию'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Отменить партию?'), findsNothing);
    expect(find.text('Открытый рынок'), findsOneWidget);
    expect(api.leaves, isEmpty);
  });

  testWidgets('room trading timer advances without another snapshot', (
    tester,
  ) async {
    final api = FakeRoomApi()..current = RoomSnapshot.parse(_example());
    var now = api.current.serverTime;
    final controller = RoomController(
      api: api,
      vault: TestVault()..value = saved(),
      now: () => now,
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
    expect(find.textContaining('Осталось 3:00'), findsOneWidget);

    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('Осталось 2:59'), findsOneWidget);
    expect(api.snapshotCount, 1);
  });

  test(
    'concurrent readiness keeps same phase intent and original version',
    () async {
      final wire = _example();
      final api = FakeRoomApi()..current = RoomSnapshot.parse(wire);
      final vault = TestVault()..value = saved();
      final controller = RoomController(api: api, vault: vault);
      addTearDown(controller.dispose);
      await controller.initialize();
      api.receive!(api.current);
      final captured = controller.snapshot!;

      final newer = _example()..['version'] = 2;
      _game(newer)['readyIds'] = [(captured.players[1]).id];
      api.current = RoomSnapshot.parse(newer);
      api.receive!(api.current);

      await controller.play('deals.buy', {
        'sellerId': captured.players[1].id,
        'insured': false,
      }, captured);
      expect(controller.error?.code, 'VERSION_CONFLICT');
      expect(api.leaves, isEmpty);

      await controller.play('deals.done', const {}, captured);
      expect(api.leaves.single.leave!['expectedVersion'], 1);
      expect(api.leaves.single.leave!['type'], 'deals.done');
      expect(vault.writes, 0);
    },
  );

  test('v7 rejects foreign private offers and early reveal', () {
    final wire = _example();
    _game(wire)['revealedSales'] = <Map<String, Object?>>[];
    expect(() => RoomSnapshot.parse(wire), throwsA(isA<RoomFailure>()));
    final foreign = _example();
    (foreign['privateDeals'] as Map)['incomingOffers'] = [
      {
        'sellerId': _game(foreign)['marketPriorityId'],
        'buyerId': selfId,
        'price': 2,
        'insured': false,
      },
    ];
    expect(() => RoomSnapshot.parse(foreign), throwsA(isA<RoomFailure>()));
  });
}
