import 'dart:async';
import 'package:partybox_mobile/src/rooms/room_api.dart';
import 'package:partybox_mobile/src/rooms/room_models.dart';
import 'package:partybox_mobile/src/rooms/room_vault.dart';

const roomId = '00000000-0000-4000-8000-000000000001';
const selfId = '00000000-0000-4000-8000-000000000002';
const otherId = '00000000-0000-4000-8000-000000000003';
const testToken = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
RoomSnapshot view({
  int version = 1,
  String host = selfId,
  String self = selfId,
  int count = 1,
}) => RoomSnapshot.parse({
  'protocolVersion': 1,
  'roomId': roomId,
  'version': version,
  'selfId': self,
  'serverTime': '2026-11-08T12:00:00.000Z',
  'privateState': null,
  'publicState': {
    'phase': 'lobby',
    'pin': '001234',
    'hostId': host,
    'expiresAt': '2026-11-09T12:00:00.000Z',
    'players': [
      {'id': selfId, 'name': 'Игрок с длинным именем'},
      if (count > 1) {'id': otherId, 'name': 'Игрок с длинным именем'},
      for (var i = 2; i < count; i++)
        {
          'id':
              '00000000-0000-4000-8000-${(i + 10).toString().padLeft(12, '0')}',
          'name': 'Длинное имя участника компании',
        },
    ],
  },
});
RoomAccess saved({
  Map<String, dynamic>? leave,
  String origin = 'https://rooms.example',
}) =>
    RoomAccess(origin: origin, roomId: roomId, token: testToken, leave: leave);

class FakeRoomApi implements RoomApi {
  @override
  String origin = 'https://rooms.example';
  final enrollments = <RoomAccess>[], leaves = <RoomAccess>[];
  RoomSnapshot current = view();
  RoomFailure? enrollError, leaveError, snapshotError;
  Completer<void>? enrollmentGate, snapshotGate;
  void Function(RoomSnapshot)? receive;
  void Function(RoomFailure)? fail;
  void Function()? disconnected;
  int snapshotCount = 0, watchCount = 0;
  bool closed = false;
  @override
  Future<({String token, RoomSnapshot snapshot})> enroll(
    RoomAccess access,
  ) async {
    enrollments.add(access);
    if (enrollmentGate != null) await enrollmentGate!.future;
    if (enrollError != null) throw enrollError!;
    return (token: testToken, snapshot: current);
  }

  @override
  Future<RoomSnapshot> snapshot(RoomAccess access) async {
    snapshotCount++;
    if (snapshotGate != null) await snapshotGate!.future;
    if (snapshotError != null) throw snapshotError!;
    return current;
  }

  @override
  Future<void> leave(RoomAccess access) async {
    leaves.add(access);
    if (leaveError != null) throw leaveError!;
  }

  @override
  Future<void> command(RoomAccess access) => leave(access);
  @override
  void watch(
    RoomAccess access,
    void Function(RoomSnapshot) onSnapshot,
    void Function(RoomFailure) onError,
    void Function() onDisconnect,
  ) {
    watchCount++;
    receive = onSnapshot;
    fail = onError;
    disconnected = onDisconnect;
  }

  @override
  void stopWatching() {}
  @override
  void close() {
    closed = true;
  }
}

class TestVault implements RoomVault {
  RoomAccess? value;
  bool failSave = false, failClear = false, failLoad = false;
  int writes = 0;
  @override
  Future<RoomAccess?> load() async {
    if (failLoad) throw Exception('storage');
    return value;
  }

  @override
  Future<void> save(RoomAccess access) async {
    writes++;
    if (failSave) throw Exception('storage');
    value = access;
  }

  @override
  Future<void> clear() async {
    if (failClear) throw Exception('storage');
    value = null;
  }
}
