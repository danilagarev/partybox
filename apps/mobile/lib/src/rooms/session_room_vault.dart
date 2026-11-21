import 'dart:convert';

import 'room_models.dart';
import 'room_vault.dart';
import 'session_storage_stub.dart'
    if (dart.library.js_interop) 'session_storage_web.dart'
    as storage;

/// Browser rooms retain access only for the current browser tab.
/// Uses the same access-only format as the native vault; never stores snapshots.
final class SessionRoomVault implements RoomVault {
  SessionRoomVault({
    String? Function(String key)? read,
    void Function(String key, String value)? write,
    void Function(String key)? remove,
  }) : _read = read ?? storage.read,
       _write = write ?? storage.write,
       _remove = remove ?? storage.remove;

  static const key = 'partybox.rooms.browser.v1';
  final String? Function(String key) _read;
  final void Function(String key, String value) _write;
  final void Function(String key) _remove;

  @override
  Future<RoomAccess?> load() async {
    final String? value;
    try {
      value = _read(key);
    } catch (_) {
      throw const RoomFailure('STORAGE');
    }
    return value == null ? null : RoomAccess.decode(value);
  }

  @override
  Future<void> save(RoomAccess access) async {
    try {
      _write(key, jsonEncode(access.toJson()));
    } catch (_) {
      throw const RoomFailure('STORAGE');
    }
  }

  @override
  Future<void> clear() async {
    try {
      _remove(key);
    } catch (_) {
      throw const RoomFailure('STORAGE');
    }
  }
}
