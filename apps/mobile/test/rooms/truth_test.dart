import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:partybox_mobile/src/design/night_theme.dart';
import 'package:partybox_mobile/src/rooms/room_controller.dart';
import 'package:partybox_mobile/src/rooms/room_models.dart';
import 'package:partybox_mobile/src/rooms/room_screen.dart';
import 'package:partybox_mobile/src/rooms/room_vault.dart';

import 'support.dart';

Map<String, dynamic> _example() =>
    (jsonDecode(
              File(
                '../../packages/game-contracts/examples/rooms-v6.json',
              ).readAsStringSync(),
            )
            as Map)['V6Snapshot']
        as Map<String, dynamic>;

Map<String, dynamic> _state(Map<String, dynamic> value) =>
    value['publicState'] as Map<String, dynamic>;

Map<String, dynamic> _game(Map<String, dynamic> value) =>
    _state(value)['truth'] as Map<String, dynamic>;

Map<String, dynamic> _betting({bool submitted = false, int round = 0}) {
  final example = _example();
  _game(example)['roundIndex'] = round;
  if (!submitted) {
    _game(example)['betIds'] = <String>[];
    (example['privateTruth'] as Map)
      ..['answer'] = null
      ..['stake'] = null;
  }
  return example;
}

class _TruthApi extends FakeRoomApi {
  bool acceptBet = true;
  @override
  Future<void> command(RoomAccess access) async {
    leaves.add(access);
    if (acceptBet) {
      current = RoomSnapshot.parse(_betting(submitted: true)..['version'] = 2);
      throw const RoomFailure('CONNECTION');
    }
    throw const RoomFailure('VERSION_CONFLICT');
  }
}

void main() {
  test(
    'v6 rejects early reveal and submitted choices missing from progress',
    () {
      expect(RoomSnapshot.parse(_example()).privateTruth?.stake, 3);
      final unexpectedResult = _example();
      final players = (_state(unexpectedResult)['players'] as List)
          .cast<Map<String, dynamic>>();
      _game(unexpectedResult)['result'] = {
        'truth': true,
        'explanation': 'У осьминога несколько сердец.',
        'sources': [
          {'title': 'Проверка', 'url': 'https://example.org/'},
        ],
        'answers': [
          for (final player in players)
            {
              'playerId': player['id'],
              'initialAnswer': false,
              'answer': true,
              'stake': 3,
              'points': 3,
            },
        ],
      };
      expect(
        () => RoomSnapshot.parse(unexpectedResult),
        throwsA(isA<RoomFailure>()),
      );
      final missingProgress = _example();
      _game(missingProgress)['betIds'] = <String>[];
      expect(
        () => RoomSnapshot.parse(missingProgress),
        throwsA(isA<RoomFailure>()),
      );
    },
  );

  test(
    'lost response restores accepted bet without writing secret to vault',
    () async {
      final api = _TruthApi()..current = RoomSnapshot.parse(_betting());
      final vault = TestVault()..value = saved();
      final controller = RoomController(api: api, vault: vault);
      addTearDown(controller.dispose);
      await controller.initialize();
      api.receive!(api.current);
      final watchCount = api.watchCount;
      await controller.play('truth.bet', {
        'answer': true,
        'stake': 3,
      }, controller.snapshot);
      final sent = api.leaves.single.leave!;
      expect(sent['protocolVersion'], 6);
      expect(sent['expectedVersion'], 1);
      expect(vault.writes, 0);
      expect(api.watchCount, watchCount);
      expect(vault.value!.leave, isNull);
      expect(controller.snapshot!.privateTruth!.stake, 3);
      expect(controller.notice, isNull);
      expect(() => saved(leave: sent).toJson(), throwsA(isA<RoomFailure>()));
      expect(
        () =>
            RoomAccess.decode(jsonEncode({...saved().toJson(), 'leave': sent})),
        throwsA(isA<RoomFailure>()),
      );
    },
  );

  test(
    'version rejection syncs without sending an old intent to the next round',
    () async {
      final api = _TruthApi()
        ..current = RoomSnapshot.parse(_betting())
        ..acceptBet = false;
      final vault = TestVault()..value = saved();
      final controller = RoomController(api: api, vault: vault);
      addTearDown(controller.dispose);
      await controller.initialize();
      api.receive!(api.current);
      final roundOne = controller.snapshot!;
      await controller.play('truth.bet', {
        'answer': true,
        'stake': 3,
      }, roundOne);
      expect(controller.error?.code, 'VERSION_CONFLICT');
      expect(vault.writes, 0);
      api.current = RoomSnapshot.parse(_betting(round: 1)..['version'] = 2);
      api.receive!(api.current);
      await controller.play('truth.bet', {
        'answer': true,
        'stake': 3,
      }, roundOne);
      expect(api.leaves, hasLength(1));
      expect(controller.snapshot!.truth!.roundIndex, 1);
    },
  );

  testWidgets('finished Truth shows winners after entering from Spy', (
    tester,
  ) async {
    final last = _betting(round: 9);
    final ids = (_state(last)['players'] as List)
        .cast<Map<String, dynamic>>()
        .map((player) => player['id'] as String)
        .toList();
    last['privateTruth'] = null;
    _game(last)
      ..['phase'] = 'reveal'
      ..['betIds'] = ids
      ..['scores'] = [
        for (final (index, id) in ids.indexed)
          {'playerId': id, 'score': index == 0 ? 3 : -3},
      ]
      ..['result'] = {
        'truth': true,
        'explanation': 'У осьминога несколько сердец.',
        'sources': [
          {'title': 'Проверка', 'url': 'https://example.org/'},
        ],
        'answers': [
          for (final (index, id) in ids.indexed)
            {
              'playerId': id,
              'initialAnswer': true,
              'answer': index == 0,
              'stake': 3,
              'points': index == 0 ? 3 : -3,
            },
        ],
      };
    final api = _TruthApi()..current = RoomSnapshot.parse(last);
    final controller = RoomController(
      api: api,
      vault: TestVault()..value = saved(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RoomScreen(controller: controller, initialGame: 'spy'),
        theme: nightTheme(),
      ),
    );
    await tester.pumpAndSettle();
    api.receive!(api.current);
    await tester.pumpAndSettle();
    expect(find.text('Посмотреть итоги'), findsOneWidget);

    last['version'] = 2;
    _game(last)
      ..['phase'] = 'finished'
      ..['winners'] = [ids[0]];
    api.receive!(RoomSnapshot.parse(last));
    await tester.pumpAndSettle();
    expect(find.text('Победитель'), findsOneWidget);
    expect(find.text('Выбрать игру'), findsOneWidget);
  });

  testWidgets(
    'draft survives other players answering and clears when disconnected',
    (tester) async {
      final api = _TruthApi()..current = RoomSnapshot.parse(_betting());
      final controller = RoomController(
        api: api,
        vault: TestVault()..value = saved(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: RoomScreen(controller: controller),
          theme: nightTheme(),
        ),
      );
      await tester.pumpAndSettle();
      api.receive!(api.current);
      await tester.pumpAndSettle();
      final truthChip = find.widgetWithText(ChoiceChip, 'Правда');
      await tester.ensureVisible(truthChip);
      await tester.tap(truthChip);
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(truthChip).selected, isTrue);
      final watchCount = api.watchCount;
      final peerBet = _betting()..['version'] = 8;
      _game(peerBet)['betIds'] = [
        ((_state(peerBet)['players'] as List)[1] as Map)['id'],
      ];
      api.receive!(RoomSnapshot.parse(peerBet));
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(truthChip).selected, isTrue);
      expect(controller.snapshot!.version, 8);
      expect(api.watchCount, watchCount);
      api.disconnected!();
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(truthChip).selected, isFalse);
      expect(tester.widget<ChoiceChip>(truthChip).onSelected, isNull);
      expect(find.text('Как ответили'), findsNothing);
    },
  );
}
