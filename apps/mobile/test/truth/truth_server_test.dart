import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:partybox_mobile/src/rooms/room_api.dart';
import 'package:partybox_mobile/src/rooms/room_controller.dart';
import 'package:partybox_mobile/src/rooms/room_vault.dart';

import '../rooms/room_server_test.dart' show RealHttp, until;

void main() {
  final server = Platform.environment['ROOM_TEST_SERVER'];
  final certificate = Platform.environment['ROOM_TEST_CA'];
  if (certificate != null) {
    SecurityContext.defaultContext.setTrustedCertificates(certificate);
  }
  for (final count in [2, 12]) {
    test(
      '$count Dart clients play all ten Truth rounds through HTTP and Socket.IO',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final vaults = List.generate(count, (_) => MemoryRoomVault());
          final players = [
            for (final vault in vaults)
              RoomController(
                api: HttpRoomApi(server!, allowInsecure: true),
                vault: vault,
              ),
          ];
          addTearDown(() {
            for (final player in players) {
              player.dispose();
            }
          });

          final host = players.first;
          final guest = players.last;
          await host.initialize();
          await host.enroll('Аня');
          expect(host.snapshot?.protocolVersion, 6);
          final pin = host.snapshot!.pin;
          for (final (index, player) in players.skip(1).indexed) {
            await player.initialize();
            await player.enroll('Игрок ${index + 2}', pin: pin);
            expect(player.error, isNull);
          }
          await until(
            () => players.every(
              (player) =>
                  player.online && player.snapshot?.players.length == count,
            ),
          );

          Future<void> phase(String phase, int round) => until(
            () => players.every(
              (player) =>
                  player.online &&
                  player.snapshot?.truth?.phase == phase &&
                  player.snapshot?.truth?.roundIndex == round,
            ),
          );

          await host.play('truth.start', {
            'topics': ['science'],
          });
          final statements = <String>{};
          var score = 0;
          for (var round = 0; round < 10; round++) {
            await phase('initial', round);
            final truth = host.snapshot!.truth!;
            expect(truth.topic, 'science');
            expect(statements.add(truth.statement), isTrue);
            expect(truth.result, isNull);
            // Submit all decisions from the same phase concurrently.
            await Future.wait([
              host.play('truth.initial', {'answer': false}),
              for (final player in players.skip(1))
                player.play('truth.initial', {'answer': true}),
            ]);
            await phase('discussion', round);
            expect(host.snapshot!.privateTruth?.initialAnswer, isFalse);
            expect(guest.snapshot!.privateTruth?.initialAnswer, isTrue);
            if (round == 0) {
              guest.setActive(false);
              guest.setActive(true);
              await phase('discussion', round);
              expect(guest.snapshot!.privateTruth?.initialAnswer, isTrue);
            }
            await host.play('truth.discussed');
            await phase('betting', round);
            await Future.wait([
              host.play('truth.bet', {'answer': true, 'stake': 3}),
              for (final player in players.skip(1))
                player.play('truth.bet', {'answer': false, 'stake': 2}),
            ]);
            await phase('reveal', round);
            final reveal = host.snapshot!.truth!.result!;
            expect(reveal.sources, isNotEmpty);
            expect(
              players.map((player) => player.snapshot!.truth!.result!.truth),
              everyElement(reveal.truth),
            );
            expect(
              players.every((player) => player.snapshot!.privateTruth == null),
              isTrue,
            );
            score += reveal.truth ? 3 : -3;
            expect(host.snapshot!.truth!.scores.first.score, score);
            expect(vaults.every((vault) => vault.value?.leave == null), isTrue);
            await host.play('truth.next');
          }
          await phase('finished', 9);
          expect(host.snapshot!.truth!.winners, isNotEmpty);
          for (final (index, player)
              in players.reversed.take(count - 1).indexed) {
            final remaining = count - index - 1;
            await until(
              () =>
                  player.online &&
                  player.snapshot?.players.length == remaining + 1,
            );
            await player.leave();
            expect(player.snapshot, isNull);
            await until(() => host.snapshot?.players.length == remaining);
          }
          await host.leave();
          expect(host.snapshot, isNull);
        }, RealHttp(certificate));
      },
      timeout: const Timeout(Duration(seconds: 90)),
      skip: server == null,
    );
  }
}
