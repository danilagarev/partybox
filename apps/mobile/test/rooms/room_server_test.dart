import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:partybox_mobile/src/rooms/room_api.dart';
import 'package:partybox_mobile/src/rooms/room_controller.dart';
import 'package:partybox_mobile/src/rooms/room_vault.dart';

class RealHttp extends HttpOverrides {
  RealHttp(this.certificate);
  final String? certificate;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final trust = context ?? SecurityContext(withTrustedRoots: true);
    if (certificate != null) trust.setTrustedCertificates(certificate!);
    return super.createHttpClient(trust);
  }
}

class LoseResponse extends http.BaseClient {
  final http.Client inner = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await inner.send(request);
    await response.stream.drain<void>();
    throw const SocketException('Synthetic lost response');
  }

  @override
  void close() => inner.close();
}

Future<void> until(bool Function() ready) async {
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (!ready()) {
    if (DateTime.now().isAfter(end)) {
      throw StateError('Timed out waiting for room update');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  final certificate = Platform.environment['ROOM_TEST_CA'];
  // WebSocket caches its HttpClient; trust this CA in the test isolate as well.
  if (certificate != null) {
    SecurityContext.defaultContext.setTrustedCertificates(certificate);
  }
  final server = Platform.environment['ROOM_TEST_SERVER'];
  test(
    'four Dart clients: lost response, restore, live roster, disconnect and host transfer',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final vault = MemoryRoomVault();
        final lost = RoomController(
          api: HttpRoomApi(
            server!,
            client: LoseResponse(),
            allowInsecure: true,
          ),
          vault: vault,
        );
        await lost.initialize();
        await lost.enroll('Тестовый ведущий');
        expect(lost.hasPending, true);
        expect(vault.value!.enrollment, isNotNull);
        lost.dispose();
        final host = RoomController(
          api: HttpRoomApi(server, allowInsecure: true),
          vault: vault,
        );
        final members = [host];
        addTearDown(() {
          for (final member in members) {
            member.dispose();
          }
        });
        await host.initialize();
        expect(host.snapshot!.players, hasLength(1));
        await until(() => host.online);
        final pin = host.snapshot!.pin;
        for (var i = 0; i < 3; i++) {
          final member = RoomController(
            api: HttpRoomApi(server, allowInsecure: true),
            vault: MemoryRoomVault(),
          );
          members.add(member);
          await member.initialize();
          await member.enroll('Тестовый участник', pin: pin);
          expect(member.error, null);
        }
        await until(
          () =>
              members.every((m) => m.online && m.snapshot!.players.length == 4),
        );
        expect(members.map((m) => m.snapshot!.selfId).toSet(), hasLength(4));
        host.setActive(false);
        expect(host.online, false);
        host.setActive(true);
        await until(() => host.online);
        expect(host.snapshot!.players, hasLength(4));
        await host.play('spy.start', {
          'discussionMinutes': 3,
          'packId': 'spy-ru-travel',
        });
        expect(host.error, null);
        expect(host.snapshot!.game!.packId, 'spy-ru-travel');
        await until(
          () => members.every(
            (m) => m.online && m.snapshot!.game?.phase == 'distribution',
          ),
        );
        expect(
          members.where((m) => m.snapshot!.card?.role == 'spy'),
          hasLength(1),
        );
        for (final member in members) {
          member.revealRole();
          expect(member.cardVisible, true);
        }
        // Friends confirm at the same time, without extra taps after a race.
        await Future.wait(members.map((member) => member.play('spy.ready')));
        for (final member in members) {
          expect(member.cardVisible, false);
          expect(member.error, null);
        }
        await until(
          () => members.every((m) => m.snapshot!.game?.phase == 'discussion'),
        );
        await until(() => host.online);
        await host.play('spy.vote');
        expect(host.error, null);
        await until(
          () => members.every((m) => m.snapshot!.game?.phase == 'voting'),
        );
        await until(() => host.online);
        final spy = members
            .firstWhere((m) => m.snapshot!.card!.role == 'spy')
            .snapshot!
            .selfId;
        await host.play('spy.accuse', {'suspectId': spy});
        expect(host.error, null);
        await until(
          () => members.every((m) => m.snapshot!.game?.phase == 'results'),
        );
        expect(host.snapshot!.game!.result!['winner'], 'civilians');
        expect(members.every((m) => m.snapshot!.card == null), true);
        await host.retry();
        await host.play('tolerance.start');
        expect(host.error, null);
        for (var round = 0; round < members.length; round++) {
          await until(
            () => members.every(
              (m) =>
                  m.snapshot!.tolerance?.phase == 'ranking' &&
                  m.snapshot!.tolerance?.roundIndex == round,
            ),
          );
          final game = host.snapshot!.tolerance!;
          final hero = members.firstWhere(
            (m) => m.snapshot!.selfId == game.heroId,
          );
          final order = game.cards.map((c) => c.id).toList();
          await hero.retry();
          await hero.play('tolerance.rank', {'order': order});
          expect(hero.error, null);
          await until(
            () => members.every(
              (m) => m.snapshot!.tolerance?.phase == 'guessing',
            ),
          );
          for (final member in members.where((m) => m != hero)) {
            // Refresh the optimistic room version after the preceding vote.
            await member.retry();
            await member.play('tolerance.guess', {
              'position': order.indexOf(game.targetId),
            });
            expect(member.error, null);
          }
          await until(
            () =>
                members.every((m) => m.snapshot!.tolerance?.phase == 'reveal'),
          );
          expect(host.snapshot!.tolerance!.result!['order'], order);
          for (final member in members.where((m) => m != hero)) {
            expect(member.snapshot!.privateTolerance?.order, null);
          }
          await host.retry();
          await host.play('tolerance.next');
          expect(host.error, null);
        }
        await until(
          () =>
              members.every((m) => m.snapshot!.tolerance?.phase == 'finished'),
        );
        expect(host.snapshot!.tolerance!.winners, hasLength(4));
        expect(
          host.snapshot!.tolerance!.scores.map((s) => s.score),
          everyElement(3),
        );
        // The same real clients now exercise V4 answer races across all five rounds.
        final cluePack =
            jsonDecode(
                  File(
                    '../../packages/game-content/packs/clues-ru-base.json',
                  ).readAsStringSync(),
                )
                as Map;
        await host.retry();
        await host.play('clues.start');
        expect(host.error, null);
        for (var round = 0; round < 5; round++) {
          await until(
            () => members.every(
              (m) =>
                  m.online &&
                  m.snapshot!.clues?.phase == 'playing' &&
                  m.snapshot!.clues?.roundIndex == round,
            ),
          );
          final game = host.snapshot!.clues!;
          final answer =
              (cluePack['items'] as List)
                      .cast<Map<String, dynamic>>()
                      .singleWhere(
                        (q) => (q['clues'] as List).first == game.clues.first,
                      )['answer']
                  as String;
          await Future.wait(
            members.map(
              (m) => m.play('clues.answer', {'answer': answer, 'clueIndex': 0}),
            ),
          );
          expect(members.map((m) => m.error), everyElement(null));
          await until(
            () => members.every((m) => m.snapshot!.clues?.phase == 'reveal'),
          );
          expect(members.every((m) => m.snapshot!.privateClues == null), true);
          expect(
            host.snapshot!.clues!.scores.map((s) => s.score),
            everyElement((round + 1) * 4),
          );
          await host.retry();
          await host.play('clues.next');
          expect(host.error, null);
        }
        await until(
          () => members.every((m) => m.snapshot!.clues?.phase == 'finished'),
        );
        expect(host.snapshot!.clues!.winners, hasLength(4));
        final next = members[1];
        await host.leave();
        expect(vault.value, null);
        await until(() => next.snapshot!.players.length == 3);
        expect(next.snapshot!.hostId, next.snapshot!.selfId);
        for (final member in members.skip(1)) {
          await member.retry();
          await member.leave();
          expect(member.error, null);
        }
      }, RealHttp(Platform.environment['ROOM_TEST_CA']));
    },
    skip: server == null,
  );
}
