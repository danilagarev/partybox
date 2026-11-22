import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:partybox_mobile/src/rooms/room_api.dart';
import 'package:partybox_mobile/src/rooms/room_models.dart';
import 'support.dart';

void main() {
  test('missing v5 endpoint explains required server update', () async {
    final api = HttpRoomApi(
      'https://rooms.example',
      client: MockClient((request) async {
        expect(request.url.path, '/v5/rooms/$roomId');
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
