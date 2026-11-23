import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:partybox_mobile/src/rooms/room_api.dart';
import 'package:partybox_mobile/src/rooms/room_models.dart';
import 'support.dart';

void main() {
  test('missing v6 and v5 endpoints explain required server update', () async {
    final paths = <String>[];
    final api = HttpRoomApi(
      'https://rooms.example',
      client: MockClient((request) async {
        paths.add(request.url.path);
        return http.Response(
          jsonEncode({'statusCode': 404, 'message': 'Not Found'}),
          404,
        );
      }),
    );
    addTearDown(api.close);
    await expectLater(
      api.snapshot(saved()),
      throwsA(
        isA<RoomFailure>().having(
          (f) => f.code,
          'code',
          'SERVER_UPGRADE_REQUIRED',
        ),
      ),
    );
    expect(paths, ['/v6/rooms/$roomId', '/v5/rooms/$roomId']);
  });

  test('missing v6 endpoint reads a compatible v5 snapshot', () async {
    final paths = <String>[];
    final examples =
        jsonDecode(
              File(
                '../../packages/game-contracts/examples/rooms-v5.json',
              ).readAsStringSync(),
            )
            as Map;
    final api = HttpRoomApi(
      'https://rooms.example',
      client: MockClient((request) async {
        final path = request.url.path;
        paths.add(path);
        if (path.startsWith('/v6/')) {
          return http.Response(
            jsonEncode({'statusCode': 404, 'message': 'Cannot GET $path'}),
            404,
          );
        }
        return http.Response.bytes(
          utf8.encode(jsonEncode(examples['V5Snapshot'])),
          200,
        );
      }),
    );
    addTearDown(api.close);
    final snapshot = await api.snapshot(saved());
    expect(snapshot.protocolVersion, 5);
    expect(snapshot.truth, isNull);
    expect(paths, ['/v6/rooms/$roomId', '/v5/rooms/$roomId']);
  });

  test('structured v6 room errors never trigger downgrade', () async {
    var requests = 0;
    final api = HttpRoomApi(
      'https://rooms.example',
      client: MockClient((request) async {
        requests++;
        return http.Response(
          jsonEncode({'protocolVersion': 6, 'code': 'ROOM_UNAVAILABLE'}),
          404,
        );
      }),
    );
    addTearDown(api.close);
    await expectLater(
      api.snapshot(saved()),
      throwsA(
        isA<RoomFailure>().having(
          (failure) => failure.code,
          'code',
          'ROOM_UNAVAILABLE',
        ),
      ),
    );
    expect(requests, 1);
  });

  test(
    'API binds credentials to origin, disallows redirects and validates errors',
    () async {
      var requests = 0;
      final api = HttpRoomApi(
        'https://rooms.example',
        client: MockClient((request) async {
          requests++;
          expect(request.followRedirects, false);
          expect(request.headers['authorization'], 'Bearer $testToken');
          return http.Response(
            jsonEncode({'protocolVersion': 1, 'code': 'ROOM_EXPIRED'}),
            410,
          );
        }),
      );
      addTearDown(api.close);
      await expectLater(
        api.snapshot(saved(origin: 'https://foreign.example')),
        throwsA(
          isA<RoomFailure>().having((f) => f.code, 'code', 'SERVER_CHANGED'),
        ),
      );
      expect(requests, 0);
      await expectLater(
        api.snapshot(saved()),
        throwsA(
          isA<RoomFailure>().having((f) => f.code, 'code', 'ROOM_EXPIRED'),
        ),
      );
      expect(() => HttpRoomApi('http://rooms.example'), throwsArgumentError);
      expect(
        () => HttpRoomApi('https://user:password@rooms.example'),
        throwsArgumentError,
      );
    },
  );
  test(
    'oversized or incompatible snapshots fail without rendering raw responses',
    () async {
      for (final response in [
        'secret'.padRight(32769, 'x'),
        jsonEncode({'protocolVersion': 2}),
      ]) {
        final api = HttpRoomApi(
          'https://rooms.example',
          client: MockClient((_) async => http.Response(response, 200)),
        );
        await expectLater(
          api.snapshot(saved()),
          throwsA(isA<RoomFailure>().having((f) => f.code, 'code', 'PROTOCOL')),
        );
        api.close();
      }
    },
  );
}
