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

Map<String, dynamic> ballotFixture({
  bool submitted = false,
  bool host = false,
  int round = 1,
}) {
  final data =
      (jsonDecode(
                File(
                  '../../packages/game-contracts/examples/rooms-v5.json',
                ).readAsStringSync(),
              )
              as Map)['V5Snapshot']
          as Map<String, dynamic>;
  final state = data['publicState'] as Map;
  final players = state['players'] as List;
  if (!host) state['hostId'] = (players[1] as Map)['id'];
  final game = state['game'] as Map;
  final voting = game['voting'] as Map;
  voting['round'] = round;
  voting['votedIds'] = submitted
      ? <String>[data['selfId'] as String]
      : <String>[];
  if (round > 1) {
    voting['candidateIds'] = <String>[
      for (final p in players.take(2)) (p as Map)['id'] as String,
    ];
  }
  final card = data['privateState'] as Map;
  if (submitted) {
    card['ballot'] = {'round': round, 'suspectId': (players[1] as Map)['id']};
  } else {
    card.remove('ballot');
  }
  return data;
}

class BallotApi extends FakeRoomApi {
  bool loseResponse = false;
  @override
  Future<void> command(RoomAccess access) async {
    leaves.add(access);
    current = RoomSnapshot.parse(ballotFixture(submitted: true));
    if (loseResponse) throw const RoomFailure('CONNECTION');
  }
}

void main() {
  test(
    'private voting rejects mismatched submission, round, candidates and foreign voters',
    () {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (v) =>
            ((v['publicState'] as Map)['game'] as Map)['phase'] = 'discussion',
        (v) =>
            (((v['publicState'] as Map)['game'] as Map)['voting']
                    as Map)['votedIds'] =
                <String>[],
        (v) => ((v['privateState'] as Map)['ballot'] as Map)['round'] = 2,
        (v) => ((v['privateState'] as Map)['ballot'] as Map)['suspectId'] =
            '00000000-0000-4000-8000-000000000099',
        (v) =>
            (((v['publicState'] as Map)['game'] as Map)['voting']
                as Map)['votedIds'] = [
              '00000000-0000-4000-8000-000000000099',
            ],
      ]) {
        final v = ballotFixture(submitted: true);
        mutate(v);
        expect(() => RoomSnapshot.parse(v), throwsA(isA<RoomFailure>()));
      }
    },
  );
  test(
    'ballots stay out of persistent storage; uncertain accepted response restores personal vote',
    () async {
      final api = BallotApi()
        ..current = RoomSnapshot.parse(ballotFixture())
        ..loseResponse = true;
      final vault = TestVault()..value = saved();
      final c = RoomController(api: api, vault: vault);
      addTearDown(c.dispose);
      await c.initialize();
      api.receive!(api.current);
      final before = vault.writes;
      final target = c.snapshot!.players[1].id;
      await c.play('spy.ballot', {'round': 1, 'suspectId': target});
      expect(api.leaves.single.leave!['protocolVersion'], 5);
      expect(api.leaves.single.leave!['payload'], {
        'round': 1,
        'suspectId': target,
      });
      expect(vault.writes, before);
      expect(c.hasPending, false);
      expect(c.error, null);
      expect(c.snapshot!.card!.ballotSuspectId, target);
      expect(() => api.leaves.single.toJson(), throwsA(isA<RoomFailure>()));
      final malicious = saved().toJson()..['leave'] = api.leaves.single.leave;
      expect(
        () => RoomAccess.decode(jsonEncode(malicious)),
        throwsA(isA<RoomFailure>()),
      );
    },
  );
  for (final host in [true, false]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'each phone votes: host=$host, text=$scale; tie resets selection',
        (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final api = FakeRoomApi()
            ..current = RoomSnapshot.parse(ballotFixture(host: host));
          final c = RoomController(
            api: api,
            vault: TestVault()..value = saved(),
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: nightTheme(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: RoomScreen(controller: c),
            ),
          );
          await tester.pumpAndSettle();
          await settleRoomContent(tester);
          api.receive!(api.current);
          await tester.pumpAndSettle();
          expect(find.byType(RadioListTile<String>), findsNWidgets(4));
          final target = find.byType(RadioListTile<String>).at(1);
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
          await tester.tap(target);
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
                .groupValue,
            api.current.players[1].id,
          );
          api.current = RoomSnapshot.parse(
            ballotFixture(host: host, round: 2)..['version'] = 2,
          );
          api.receive!(api.current);
          await tester.pumpAndSettle();
          expect(find.textContaining('Ничья. Тур 2'), findsOneWidget);
          expect(find.byType(RadioListTile<String>), findsNWidgets(2));
          expect(
            tester
                .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
                .groupValue,
            null,
          );
          api.current = RoomSnapshot.parse(
            ballotFixture(host: host, round: 2, submitted: true)
              ..['version'] = 3,
          );
          api.receive!(api.current);
          await tester.pumpAndSettle();
          expect(find.textContaining('Ваш голос:'), findsOneWidget);
          expect(find.byType(RadioListTile<String>), findsNothing);
          expect(find.text('Голос принят'), findsOneWidget);
          expect(tester.takeException(), null);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
