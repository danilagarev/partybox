import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:partybox_mobile/src/rooms/room_controller.dart';
import 'package:partybox_mobile/src/rooms/room_models.dart';
import 'package:partybox_mobile/src/rooms/room_vault.dart';
import 'package:partybox_mobile/src/rooms/session_room_vault.dart';

import 'support.dart';

SessionRoomVault vaultFor(Map<String, String> tab) => SessionRoomVault(
  read: (key) => tab[key],
  write: (key, value) => tab[key] = value,
  remove: tab.remove,
);

Matcher failure(String code) =>
    isA<RoomFailure>().having((error) => error.code, 'code', code);

void main() {
  test('reload restores access and server snapshot in the same tab', () async {
    final tab = <String, String>{};
    await vaultFor(tab).save(saved());
    final api = FakeRoomApi();
    final controller = RoomController(api: api, vault: vaultFor(tab));
    addTearDown(controller.dispose);

    await controller.initialize();

    expect(api.snapshotCount, 1);
    expect(controller.snapshot, isNotNull);
    expect((await vaultFor(tab).load())!.token, testToken);
    expect(jsonDecode(tab[SessionRoomVault.key]!), saved().toJson());
  });

  test('tabs are independent and clear removes only its access key', () async {
    final first = <String, String>{
      'unrelated': 'keep',
      SecureRoomVault.key: 'native credential',
    };
    final second = <String, String>{};
    await vaultFor(first).save(saved());

    expect(await vaultFor(second).load(), isNull);
    await vaultFor(first).clear();
    expect(first, {
      'unrelated': 'keep',
      SecureRoomVault.key: 'native credential',
    });
  });

  test('invalid JSON and foreign fields fail with SAVED_DATA', () async {
    for (final value in [
      '{',
      jsonEncode({
        ...saved().toJson(),
        'privateState': {'role': 'spy'},
      }),
      jsonEncode({...saved().toJson(), 'token': 'invalid'}),
    ]) {
      final tab = {SessionRoomVault.key: value};
      await expectLater(vaultFor(tab).load(), throwsA(failure('SAVED_DATA')));
      expect(tab[SessionRoomVault.key], value);
    }
  });

  test('storage access failures are surfaced as STORAGE', () async {
    final vault = SessionRoomVault(
      read: (_) => throw StateError('denied'),
      write: (_, _) => throw StateError('quota'),
      remove: (_) => throw StateError('denied'),
    );
    await expectLater(vault.load(), throwsA(failure('STORAGE')));
    await expectLater(vault.save(saved()), throwsA(failure('STORAGE')));
    await expectLater(vault.clear(), throwsA(failure('STORAGE')));
  });

  test('secret commands cannot be saved or loaded', () async {
    for (final type in ['tolerance.rank', 'tolerance.guess']) {
      final tab = <String, String>{};
      final vault = vaultFor(tab);
      await expectLater(
        vault.save(saved(leave: {'type': type, 'secret': 'private answer'})),
        throwsA(failure('STORAGE')),
      );
      expect(tab, isEmpty);
      tab[SessionRoomVault.key] = jsonEncode({
        ...saved().toJson(),
        'leave': {'type': type, 'secret': 'private answer'},
      });
      await expectLater(vault.load(), throwsA(failure('SAVED_DATA')));
    }
  });
}
