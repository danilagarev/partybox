import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'room_models.dart';

const privateRoomCommandTypes = {
  'tolerance.rank',
  'tolerance.guess',
  'clues.answer',
  'spy.ballot',
  'truth.initial',
  'truth.bet',
  'deals.choose',
  'deals.list',
  'deals.offer',
  'deals.accept',
  'deals.buy',
  'deals.inspect',
  'deals.done',
  'deals.market',
  'deals.next',
};

/// Only access/retry metadata. No snapshots, names of other players or game secrets.
final class RoomAccess {
  const RoomAccess({
    required this.origin,
    this.enrollment,
    this.pin,
    this.roomId,
    this.token,
    this.leave,
  });
  final String origin;
  final Map<String, dynamic>? enrollment, leave;
  final String? pin, roomId, token;
  Map<String, dynamic> toJson() {
    if (privateRoomCommandTypes.contains(leave?['type'])) {
      throw const RoomFailure('STORAGE');
    }
    return {
      'schemaVersion': 2,
      'origin': origin,
      if (enrollment != null) 'enrollment': enrollment,
      if (pin != null) 'pin': pin,
      if (roomId != null) 'roomId': roomId,
      if (token != null) 'token': token,
      if (leave != null) 'leave': leave,
    };
  }

  factory RoomAccess.decode(String value) {
    try {
      final map = jsonDecode(value) as Map<String, dynamic>;
      if (!const {1, 2}.contains(map['schemaVersion']) ||
          map.keys.any(
            (k) => !{
              'schemaVersion',
              'origin',
              'enrollment',
              'pin',
              'roomId',
              'token',
              'leave',
            }.contains(k),
          )) {
        throw const FormatException();
      }
      final origin = map['origin'] as String;
      if (map.containsKey('enrollment')) {
        RoomContract.require(switch ((map['enrollment']
            as Map)['protocolVersion']) {
          1 => 'Enrollment',
          2 => 'V2Enrollment',
          3 => 'V3Enrollment',
          4 => 'V4Enrollment',
          5 => 'V5Enrollment',
          6 => 'V6Enrollment',
          _ => 'V7Enrollment',
        }, map['enrollment']);
        if (map.containsKey('roomId') ||
            map.containsKey('token') ||
            map.containsKey('leave') ||
            (map['pin'] != null &&
                !RegExp(r'^\d{6}$').hasMatch(map['pin'] as String))) {
          throw const FormatException();
        }
        return RoomAccess(
          origin: origin,
          enrollment: map['enrollment'] as Map<String, dynamic>,
          pin: map['pin'] as String?,
        );
      }
      if (!RegExp(
            r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
          ).hasMatch(map['roomId'] as String) ||
          !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(map['token'] as String) ||
          map.containsKey('pin')) {
        throw const FormatException();
      }
      if (map['leave'] != null) {
        if (privateRoomCommandTypes.contains((map['leave'] as Map)['type'])) {
          throw const FormatException();
        }
        RoomContract.require(switch ((map['leave'] as Map)['protocolVersion']) {
          1 => 'LeaveRoom',
          2 => 'GameCommand',
          3 => 'V3Command',
          4 => 'V4Command',
          5 => 'V5Command',
          6 => 'V6Command',
          _ => 'V7Command',
        }, map['leave']);
      }
      return RoomAccess(
        origin: origin,
        roomId: map['roomId'] as String,
        token: map['token'] as String,
        leave: map['leave'] as Map<String, dynamic>?,
      );
    } catch (_) {
      throw const RoomFailure('SAVED_DATA');
    }
  }
  @override
  String toString() => 'RoomAccess(<redacted>)';
}

abstract interface class RoomVault {
  Future<RoomAccess?> load();
  Future<void> save(RoomAccess access);
  Future<void> clear();
}

final class SecureRoomVault implements RoomVault {
  SecureRoomVault({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.unlocked_this_device,
            ),
          );
  static const key = 'partybox.rooms.access.v1';
  final FlutterSecureStorage _storage;
  Future<void> _pending = Future.value();
  Future<void> _write(Future<void> Function() action) {
    final operation = _pending.then((_) => action());
    _pending = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  @override
  Future<RoomAccess?> load() async {
    await _pending;
    final value = await _storage.read(key: key);
    return value == null ? null : RoomAccess.decode(value);
  }

  @override
  Future<void> save(RoomAccess access) => _write(
    () => _storage.write(key: key, value: jsonEncode(access.toJson())),
  );
  @override
  Future<void> clear() => _write(() => _storage.delete(key: key));
}

/// Browser preview keeps credentials only for this app instance, never in localStorage.
final class MemoryRoomVault implements RoomVault {
  RoomAccess? value;
  @override
  Future<RoomAccess?> load() async => value;
  @override
  Future<void> save(RoomAccess access) async {
    value = access;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}
