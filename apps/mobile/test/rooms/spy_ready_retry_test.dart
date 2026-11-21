import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:partybox_mobile/src/rooms/room_controller.dart';
import 'package:partybox_mobile/src/rooms/room_models.dart';
import 'package:partybox_mobile/src/rooms/room_vault.dart';
import 'support.dart';

Map<String, dynamic> distribution() =>
    (jsonDecode(
              File(
                '../../packages/game-contracts/examples/rooms-v2.json',
              ).readAsStringSync(),
            )
            as Map)['GameSnapshot']
        as Map<String, dynamic>;

class RacingReadyApi extends FakeRoomApi {
  int conflicts = 1;
  bool loseResponse = false;
  bool changeSession = false;

  @override
  Future<void> command(RoomAccess access) async {
    leaves.add(access);
    if (loseResponse) throw const RoomFailure('CONNECTION');
    final fresh = distribution();
    fresh['version'] = current.version + 1;
    if (changeSession) {
      fresh['publicState']['game']['sessionId'] = roomCommandId();
    }
    if (conflicts-- > 0) {
      current = RoomSnapshot.parse(fresh);
      throw const RoomFailure('VERSION_CONFLICT');
    }
    fresh['publicState']['game']['readyIds'] = [current.selfId];
    current = RoomSnapshot.parse(fresh);
  }
}

void main() {
  test(
    'one confirmation survives a definite version race in the same round',
    () async {
      final api = RacingReadyApi()
        ..current = RoomSnapshot.parse(distribution());
      final vault = TestVault()..value = saved();
      final controller = RoomController(api: api, vault: vault);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.play('spy.ready');
      expect(controller.error, null);
      expect(api.leaves, hasLength(2));
      expect(
        api.leaves[1].leave!['expectedVersion'],
        greaterThan(api.leaves[0].leave!['expectedVersion'] as int),
      );
      expect(
        api.leaves[1].leave!['commandId'],
        isNot(api.leaves[0].leave!['commandId']),
      );
      expect(
        controller.snapshot!.game!.readyIds,
        contains(controller.snapshot!.selfId),
      );
      expect(vault.value!.leave, null);
      expect(
        api.watchCount,
        2,
      ); // Initial connect plus accepted confirmation only.
    },
  );

  test(
    'lost response keeps the original command and does not create another intent',
    () async {
      final api = RacingReadyApi()
        ..current = RoomSnapshot.parse(distribution())
        ..loseResponse = true;
      final vault = TestVault()..value = saved();
      final controller = RoomController(api: api, vault: vault);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.play('spy.ready');
      expect(api.leaves, hasLength(1));
      expect(controller.error!.code, 'CONNECTION');
      expect(
        vault.value!.leave!['commandId'],
        api.leaves.single.leave!['commandId'],
      );
    },
  );

  test('a new session never inherits the previous confirmation', () async {
    final api = RacingReadyApi()
      ..current = RoomSnapshot.parse(distribution())
      ..changeSession = true;
    final controller = RoomController(
      api: api,
      vault: TestVault()..value = saved(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.play('spy.ready');
    expect(api.leaves, hasLength(1));
    expect(controller.error!.code, 'VERSION_CONFLICT');
    expect(controller.hasPending, false);
  });

  test('repeated conflicts have a finite retry bound', () async {
    final api = RacingReadyApi()
      ..current = RoomSnapshot.parse(distribution())
      ..conflicts = 100;
    final controller = RoomController(
      api: api,
      vault: TestVault()..value = saved(),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.play('spy.ready');
    expect(api.leaves, hasLength(controller.snapshot!.players.length));
    expect(controller.error!.code, 'VERSION_CONFLICT');
    expect(controller.hasPending, false);
  });
}
