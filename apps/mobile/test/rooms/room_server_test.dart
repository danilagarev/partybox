import 'dart:io';
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
          'packId': 'spy-ru-base',
        });
        expect(host.error, null);
        await until(
          () => members.every(
            (m) => m.online && m.snapshot!.game?.phase == 'distribution',
          ),
        );
        expect(
          members.where((m) => m.snapshot!.card?.role == 'spy'),
          hasLength(1),
        );
        for (final member in members.reversed) {
          member.revealRole();
          expect(member.cardVisible, true);
          await member.play('spy.ready');
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
