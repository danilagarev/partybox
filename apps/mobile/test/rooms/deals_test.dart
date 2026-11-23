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
