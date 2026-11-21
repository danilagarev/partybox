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

const thirdId = '00000000-0000-4000-8000-000000000004';
const fourthId = '00000000-0000-4000-8000-000000000005';
const sessionId = '00000000-0000-4000-8000-000000000006';
const toleranceIds = [selfId, otherId, thirdId, fourthId];
const cardIds = [
  'tolerance-01',
  'tolerance-02',
  'tolerance-03',
  'tolerance-04',
];

Map<String, dynamic> toleranceFixture({
  String phase = 'ranking',
  String self = selfId,
  String hero = selfId,
  int round = 0,
  int version = 1,
  bool submitted = false,
}) {
  final reveal = phase == 'reveal' || phase == 'finished';
  final guessing = phase == 'guessing';
  final guessers = toleranceIds.where((id) => id != hero).toList();
  return {
    'protocolVersion': 3,
    'roomId': roomId,
    'version': version,
    'selfId': self,
    'serverTime': '2026-11-08T12:00:00.000Z',
    'privateState': null,
    'privateTolerance': reveal
        ? null
        : {
            'order': hero == self && guessing ? cardIds : null,
            'guess': submitted && self != hero ? 3 : null,
          },
    'publicState': {
      'phase': 'lobby',
      'pin': '001234',
      'hostId': selfId,
      'expiresAt': '2026-11-09T12:00:00.000Z',
      'players': [
        for (final (index, id) in toleranceIds.indexed)
          {'id': id, 'name': 'Игрок ${index + 1}'},
      ],
      'game': null,
      'tolerance': {
        'sessionId': sessionId,
        'phase': phase,
        'roundIndex': round,
        'heroId': hero,
        'cards': [
          {'id': cardIds[0], 'text': 'Мокрый носок'},
          {'id': cardIds[1], 'text': 'Голосовое на семь минут'},
          {'id': cardIds[2], 'text': 'Севшие в дороге наушники'},
          {'id': cardIds[3], 'text': 'Открыл сайт вместо пропуска рекламы'},
        ],
        'visibleOrder': phase == 'ranking'
            ? <String>[]
            : cardIds.take(3).toList(),
        'targetId': cardIds[3],
        'submittedIds': reveal
            ? guessers
            : submitted
            ? [self]
            : <String>[],
        'scores': [
          for (final id in toleranceIds)
            {'playerId': id, 'score': reveal && id != hero ? 1 : 0},
        ],
        'result': reveal
            ? {
                'order': cardIds,
                'guesses': [
                  for (final id in guessers)
                    {'playerId': id, 'position': 3, 'correct': true},
                ],
              }
            : null,
        'winners': phase == 'finished' ? guessers : <String>[],
      },
    },
  };
}

class ToleranceApi extends FakeRoomApi {
  Map<String, dynamic>? afterCommand;
  @override
  Future<void> command(RoomAccess access) async {
    leaves.add(access);
    if (afterCommand != null) current = RoomSnapshot.parse(afterCommand);
    if (leaveError != null) throw leaveError!;
  }
}

Future<void> showControl(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    180,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> tapControl(WidgetTester tester, Finder finder) async {
  await showControl(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'finished scale respects explicit Spy choice and generic return',
    (tester) async {
      for (final requested in <String?>['spy', null]) {
        final api = ToleranceApi()
          ..current = RoomSnapshot.parse(toleranceFixture(phase: 'finished'));
        final controller = RoomController(
          api: api,
          vault: TestVault()..value = saved(),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: nightTheme(),
            home: RoomScreen(controller: controller, initialGame: requested),
          ),
        );
        await tester.pumpAndSettle();
        await settleRoomContent(tester);
        expect(api.enrollments, isEmpty);
        if (requested == 'spy') {
          expect(find.text('Начать партию'), findsOneWidget);
          expect(find.textContaining('Победители:'), findsNothing);
        } else {
          expect(find.textContaining('Победители:'), findsOneWidget);
          expect(find.text('Ещё одна шкала'), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
  test('v3 shared examples and semantic privacy invariants parse in Dart', () {
    final examples =
        jsonDecode(
              File(
                '../../packages/game-contracts/examples/rooms-v3.json',
              ).readAsStringSync(),
            )
            as Map;
    for (final key in examples.keys) {
      expect(
        RoomContract.accepts(key as String, examples[key]),
        true,
        reason: key,
      );
    }
    for (final phase in ['ranking', 'guessing', 'reveal', 'finished']) {
      expect(
        RoomSnapshot.parse(toleranceFixture(phase: phase)).tolerance!.phase,
        phase,
      );
    }
    final foreignOrder = toleranceFixture(phase: 'guessing', self: otherId);
    foreignOrder['privateTolerance'] = {'order': cardIds, 'guess': null};
    expect(() => RoomSnapshot.parse(foreignOrder), throwsA(isA<RoomFailure>()));
    final earlyResult = toleranceFixture();
    (earlyResult['publicState']['tolerance'] as Map)['result'] = {
      'order': cardIds,
      'guesses': <Map<String, dynamic>>[],
    };
    expect(() => RoomSnapshot.parse(earlyResult), throwsA(isA<RoomFailure>()));
    final duplicateOrder = toleranceFixture(phase: 'reveal');
    duplicateOrder['publicState']['tolerance']['result']['order'] = List.filled(
      4,
      cardIds.first,
    );
    expect(
      () => RoomSnapshot.parse(duplicateOrder),
      throwsA(isA<RoomFailure>()),
    );
    final badBoolean = toleranceFixture(phase: 'reveal');
    badBoolean['publicState']['tolerance']['result']['guesses'][0]['correct'] =
        'true';
    expect(() => RoomSnapshot.parse(badBoolean), throwsA(isA<RoomFailure>()));
  });

  test(
    'secret rank resyncs a lost ack without storing or replaying its payload',
    () async {
      final api = ToleranceApi()
        ..current = RoomSnapshot.parse(toleranceFixture())
        ..afterCommand = toleranceFixture(phase: 'guessing', version: 2)
        ..leaveError = const RoomFailure('CONNECTION');
      final vault = TestVault()..value = saved();
      final controller = RoomController(api: api, vault: vault);
      addTearDown(controller.dispose);
      await controller.initialize();
      api.receive!(api.current);
      controller.revealTolerance();
      final writes = vault.writes;
      await controller.play('tolerance.rank', {'order': cardIds});
      expect(controller.snapshot!.tolerance!.phase, 'guessing');
      expect(controller.toleranceVisible, false);
      expect(controller.hasPending, false);
      expect(vault.writes, writes);
      expect(vault.value!.leave, null);
      expect(jsonEncode(vault.value!.toJson()), isNot(contains(cardIds.first)));
      await controller.retry();
      expect(api.leaves, hasLength(1));
      expect(() => api.leaves.single.toJson(), throwsA(isA<RoomFailure>()));
      expect(
        () => RoomAccess.decode(
          jsonEncode({...saved().toJson(), 'leave': api.leaves.single.leave}),
        ),
        throwsA(isA<RoomFailure>()),
      );
    },
  );

  test(
    'secret guess failure recovers explicitly and durable commands keep retry IDs',
    () async {
      final api = ToleranceApi()
        ..current = RoomSnapshot.parse(
          toleranceFixture(phase: 'guessing', self: otherId),
        )
        ..leaveError = const RoomFailure('CONNECTION');
      final vault = TestVault()..value = saved();
      final controller = RoomController(api: api, vault: vault);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.play('tolerance.guess', {'position': 1});
      expect(controller.hasPending, false);
      expect(controller.snapshot!.tolerance!.submittedIds, isEmpty);
      api.leaveError = null;
      api.afterCommand = toleranceFixture(
        phase: 'guessing',
        self: otherId,
        submitted: true,
        version: 2,
      );
      await controller.play('tolerance.guess', {'position': 3});
      expect(
        api.leaves.last.leave!['commandId'],
        isNot(api.leaves.first.leave!['commandId']),
      );
      expect(controller.snapshot!.privateTolerance!.guess, 3);
      api.leaveError = const RoomFailure('CONNECTION');
      await controller.play('tolerance.cancel');
      final pendingId = vault.value!.leave!['commandId'];
      expect(controller.hasPending, true);
      await controller.retry();
      expect(api.leaves.last.leave!['commandId'], pendingId);
    },
  );

  testWidgets(
    'host chooses the new game and completes ranking, reveal, next and finish',
    (tester) async {
      final lobby = toleranceFixture();
      lobby['publicState']['tolerance'] = null;
      lobby['privateTolerance'] = null;
      final api = ToleranceApi()..current = RoomSnapshot.parse(lobby);
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
      await tapControl(tester, find.text('Шкала терпения'));
      expect(
        find.textContaining('Каждый по очереди становится героем.'),
        findsOneWidget,
      );
      api.afterCommand = toleranceFixture(version: 2);
      await tapControl(tester, find.text('Начать «Шкалу терпения»'));
      expect(api.leaves.last.leave!['type'], 'tolerance.start');
      api.receive!(api.current);
      await tester.pumpAndSettle();
      await tapControl(tester, find.text('Составить тайную шкалу'));
      await tapControl(
        tester,
        find.byKey(ValueKey('rank-down-${cardIds.first}')),
      );
      api.afterCommand = toleranceFixture(phase: 'guessing', version: 3);
      await tapControl(tester, find.text('Скрыть и зафиксировать порядок'));
      expect(api.leaves.last.leave!['payload']['order'], [
        cardIds[1],
        cardIds[0],
        cardIds[2],
        cardIds[3],
      ]);
      api.current = RoomSnapshot.parse(
        toleranceFixture(phase: 'reveal', version: 4),
      );
      api.receive!(api.current);
      await tester.pumpAndSettle();
      expect(find.text('Вот как решил герой:'), findsOneWidget);
      api.afterCommand = toleranceFixture(hero: otherId, round: 1, version: 5);
      await tapControl(tester, find.text('Следующий герой'));
      expect(controller.snapshot!.tolerance!.heroId, otherId);
      api.current = RoomSnapshot.parse(
        toleranceFixture(phase: 'reveal', hero: fourthId, round: 3, version: 6),
      );
      api.receive!(api.current);
      await tester.pumpAndSettle();
      api.afterCommand = toleranceFixture(
        phase: 'finished',
        hero: fourthId,
        round: 3,
        version: 7,
      );
      await tapControl(tester, find.text('Подвести итоги'));
      expect(controller.snapshot!.tolerance!.phase, 'finished');
      expect(find.textContaining('Победители:'), findsOneWidget);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'draft and secret controls disappear on disconnect and background at text scale 2',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = ToleranceApi()
        ..current = RoomSnapshot.parse(toleranceFixture());
      final controller = RoomController(
        api: api,
        vault: TestVault()..value = saved(),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: nightTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: RoomScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      api.receive!(api.current);
      await tester.pumpAndSettle();
      await tapControl(tester, find.text('Составить тайную шкалу'));
      await tapControl(
        tester,
        find.byKey(ValueKey('rank-down-${cardIds.first}')),
      );
      api.disconnected!();
      await tester.pump();
      expect(find.byKey(ValueKey('rank-card-${cardIds.first}')), findsNothing);
      expect(find.text('Скрыть и зафиксировать порядок'), findsNothing);
      api.receive!(api.current);
      await tester.pumpAndSettle();
      await tapControl(tester, find.text('Составить тайную шкалу'));
      expect(
        tester
            .widget<Text>(find.byKey(ValueKey('rank-card-${cardIds.first}')))
            .data,
        startsWith('1.'),
      );
      controller.setActive(false);
      await tester.pump();
      expect(find.byKey(ValueKey('rank-card-${cardIds.first}')), findsNothing);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
