import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:partybox_mobile/src/rooms/room_controller.dart';
import 'package:partybox_mobile/src/rooms/room_models.dart';
import 'package:partybox_mobile/src/rooms/room_vault.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'shared v1 examples parse in Dart and reject secrets and unknown versions',
    () {
      final examples =
          jsonDecode(
                File(
                  '../../packages/game-contracts/examples/rooms-v1.json',
                ).readAsStringSync(),
              )
              as Map;
      for (final key in examples.keys) {
        expect(RoomContract.accepts(key as String, examples[key]), true);
      }
      final snapshot = examples['Snapshot'] as Map;
      expect(
        () => RoomSnapshot.parse({
          ...snapshot,
          'privateState': {'spyId': 'foreign'},
        }),
        throwsA(isA<RoomFailure>()),
      );
      expect(
        RoomContract.accepts('Snapshot', {...snapshot, 'protocolVersion': 2}),
        false,
      );
      expect(
        RoomContract.accepts('Enrollment', {
          ...examples['Enrollment'] as Map,
          'name': '\u0000name',
        }),
        false,
      );
      expect(
        RoomContract.accepts('Enrollment', {
          ...examples['Enrollment'] as Map,
          'name': '\ud800',
        }),
        false,
      );
      expect(
        RoomContract.accepts('Enrollment', {
          ...examples['Enrollment'] as Map,
          'name': 'Игрок 🎲',
        }),
        true,
      );
    },
  );
  test(
    'lost enrollment response retries the persisted identity after restart',
    () async {
      final vault = TestVault();
      final api = FakeRoomApi()..enrollError = const RoomFailure('CONNECTION');
      final first = RoomController(api: api, vault: vault);
      await first.initialize();
      await first.enroll('Игрок');
      final request = vault.value!;
      expect(first.snapshot, null);
      expect(first.hasPending, true);
      first.dispose();
      final secondApi = FakeRoomApi();
      final second = RoomController(api: secondApi, vault: vault);
      addTearDown(second.dispose);
      await second.initialize();
      expect(secondApi.enrollments.single.enrollment, request.enrollment);
      expect(vault.value!.token, testToken);
      expect(second.snapshot!.selfId, selfId);
      expect(jsonEncode(vault.value!.toJson()), isNot(contains('Игрок')));
    },
  );
  test(
    'storage failure prevents network, double start cannot duplicate enrollment',
    () async {
      final vault = TestVault()..failSave = true;
      final api = FakeRoomApi();
      final controller = RoomController(api: api, vault: vault);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.enroll('Игрок');
      expect(api.enrollments, isEmpty);
      expect(controller.error!.code, 'STORAGE');
      vault.failSave = false;
      api.enrollmentGate = Completer<void>();
      final retry = controller.retry();
      await Future<void>.delayed(Duration.zero);
      await controller.enroll('Другой');
      expect(api.enrollments, hasLength(1));
      api.enrollmentGate!.complete();
      await retry;
      expect(controller.snapshot, isNotNull);
    },
  );
  test(
    'closing during HTTP enrollment persists access without touching disposed UI',
    () async {
      final vault = TestVault();
      final api = FakeRoomApi()..enrollmentGate = Completer<void>();
      final controller = RoomController(api: api, vault: vault);
      await controller.initialize();
      final request = controller.enroll('Игрок');
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
      api.enrollmentGate!.complete();
      await request;
      expect(vault.value!.enrollment, isNotNull);
      expect(api.watchCount, 0);
      final restored = RoomController(api: FakeRoomApi(), vault: vault);
      addTearDown(restored.dispose);
      await restored.initialize();
      expect(vault.value!.token, testToken);
    },
  );
  test(
    'old snapshots and stale callbacks cannot replace a newer roster; resume resyncs',
    () async {
      final vault = TestVault()..value = saved();
      final api = FakeRoomApi();
      final controller = RoomController(api: api, vault: vault);
      addTearDown(controller.dispose);
      await controller.initialize();
      final oldReceive = api.receive!;
      oldReceive(view(version: 3, count: 2));
      oldReceive(view(version: 2));
      expect(controller.snapshot!.version, 3);
      controller.setActive(false);
      oldReceive(view(version: 9));
      expect(controller.snapshot!.version, 3);
      expect(controller.online, false);
      api.current = view(version: 4, count: 2);
      controller.setActive(true);
      await Future<void>.delayed(Duration.zero);
      expect(controller.snapshot!.version, 4);
      expect(api.snapshotCount, greaterThanOrEqualTo(2));
    },
  );
  test(
    'backgrounding again cancels a queued resume without a second reconnect',
    () async {
      final vault = TestVault()..value = saved();
      final api = FakeRoomApi();
      final controller = RoomController(api: api, vault: vault);
      addTearDown(controller.dispose);
      await controller.initialize();
      api.snapshotGate = Completer<void>();
      final pending = controller.retry();
      controller.setActive(false);
      controller.setActive(true);
      controller.setActive(false);
      api.snapshotGate!.complete();
      await pending;
      controller.setActive(true);
      await Future<void>.delayed(Duration.zero);
      expect(api.snapshotCount, 3);
      expect(api.watchCount, 2);
    },
  );
  test(
    'uncertain leave keeps command ID, even if local clear fails after ack',
    () async {
      final vault = TestVault()..value = saved();
      final api = FakeRoomApi()..leaveError = const RoomFailure('CONNECTION');
      final controller = RoomController(api: api, vault: vault);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.leave();
      final command = vault.value!.leave!;
      expect(controller.hasPending, true);
      api.leaveError = null;
      vault.failClear = true;
      await controller.retry();
      expect(api.leaves.last.leave, command);
      expect(controller.error!.code, 'STORAGE');
      vault.failClear = false;
      await controller.retry();
      expect(api.leaves, hasLength(2));
      expect(vault.value, null);
      expect(controller.canEnroll, true);
    },
  );
  test(
    'version conflict restores roster and requires a fresh explicit leave',
    () async {
      final vault = TestVault()..value = saved();
      final api = FakeRoomApi()
        ..leaveError = const RoomFailure('VERSION_CONFLICT');
      final controller = RoomController(api: api, vault: vault);
      addTearDown(controller.dispose);
      await controller.initialize();
      api.current = view(version: 2, count: 2);
      await controller.leave();
      expect(controller.error!.code, 'VERSION_CONFLICT');
      api.receive!(api.current);
      expect(controller.error!.code, 'VERSION_CONFLICT');
      expect(controller.hasPending, false);
      expect(controller.snapshot!.version, 2);
      final oldId = api.leaves.single.leave!['commandId'];
      api.leaveError = null;
      await controller.leave();
      expect(api.leaves.last.leave!['commandId'], isNot(oldId));
      expect(vault.value, null);
    },
  );
  test(
    'terminal access is cleared but storage failure must not permit a new guest',
    () async {
      final vault = TestVault()
        ..value = saved()
        ..failClear = true;
      final api = FakeRoomApi()
        ..snapshotError = const RoomFailure('ROOM_EXPIRED');
      final controller = RoomController(api: api, vault: vault);
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.canEnroll, false);
      expect(controller.error!.code, 'STORAGE');
      vault.failClear = false;
      await controller.retry();
      expect(controller.canEnroll, true);
      expect(vault.value, null);
    },
  );
  test(
    'origin mismatch and unreadable store block network until explicit forget',
    () async {
      final vault = TestVault()..value = saved(origin: 'https://other.example');
      final api = FakeRoomApi();
      final controller = RoomController(api: api, vault: vault);
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.error!.code, 'SERVER_CHANGED');
      expect(api.snapshotCount, 0);
      expect(controller.canEnroll, false);
      await controller.forget();
      expect(controller.canEnroll, true);
      vault.failLoad = true;
      await controller.initialize();
      expect(controller.canEnroll, false);
      expect(controller.canForget, true);
    },
  );
  test(
    'secure adapter clears only its key, and rejects future or malformed records',
    () async {
      FlutterSecureStorage.setMockInitialValues({'other-key': 'keep'});
      final vault = SecureRoomVault();
      await vault.save(saved());
      expect((await SecureRoomVault().load())!.token, testToken);
      expect(
        () => RoomAccess.decode('{"schemaVersion":99}'),
        throwsA(isA<RoomFailure>()),
      );
      await vault.clear();
      expect(await vault.load(), null);
      expect(await const FlutterSecureStorage().read(key: 'other-key'), 'keep');
    },
  );
}
