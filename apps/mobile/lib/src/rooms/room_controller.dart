import 'dart:async';
import 'package:flutter/foundation.dart';
import 'room_api.dart';
import 'room_models.dart';
import 'room_vault.dart';

final class RoomController extends ChangeNotifier {
  RoomController({required this.api, required this.vault});
  final RoomApi api;
  final RoomVault vault;
  RoomAccess? _access;
  RoomSnapshot? snapshot;
  RoomFailure? error;
  String? notice;
  bool busy = false, online = false, initialized = false;
  bool cardVisible = false;
  Duration _serverOffset = Duration.zero;
  Duration get remaining {
    final end = snapshot?.game?.deadline;
    if (end == null) return Duration.zero;
    final left = end.difference(DateTime.now().add(_serverOffset));
    return left.isNegative ? Duration.zero : left;
  }

  void hideRole() {
    cardVisible = false;
    _notify();
  }

  void revealRole() {
    if (!busy &&
        online &&
        snapshot?.game?.phase == 'distribution' &&
        snapshot?.card != null &&
        !snapshot!.game!.readyIds.contains(snapshot!.selfId)) {
      cardVisible = true;
      _notify();
    }
  }

  bool _disposed = false,
      _clearPending = false,
      _blocked = false,
      _active = true;
  int _watchGeneration = 0;
  bool _resumePending = false;
  RoomFailure? _deferredTerminal;
  bool get canEnroll =>
      initialized && _access == null && !_blocked && !_clearPending;
  bool get hasPending =>
      _access?.enrollment != null || _access?.leave != null || _clearPending;
  bool get canForget => _blocked || _access != null || _clearPending;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _save(RoomAccess access) async {
    try {
      await vault.save(access);
    } catch (_) {
      throw const RoomFailure('STORAGE');
    }
  }

  void _stop() {
    cardVisible = false;
    _watchGeneration++;
    online = false;
    api.stopWatching();
  }

  Future<void> _clear() async {
    _stop();
    snapshot = null;
    _clearPending = true;
    try {
      await vault.clear();
    } catch (_) {
      throw const RoomFailure('STORAGE');
    }
    _access = null;
    _blocked = false;
    _clearPending = false;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy || _disposed) return;
    busy = true;
    error = null;
    notice = null;
    _notify();
    try {
      await action();
    } on RoomFailure catch (failure) {
      if (_disposed) return;
      if (failure.terminal ||
          (_access?.enrollment != null &&
              const {'ROOM_FULL', 'INVALID_REQUEST'}.contains(failure.code))) {
        try {
          await _clear();
          notice = failure.message;
        } on RoomFailure catch (storage) {
          error = storage;
        }
      } else {
        error = failure;
      }
    } catch (_) {
      error = const RoomFailure('CONNECTION');
    } finally {
      busy = false;
      _notify();
      final terminal = _deferredTerminal;
      _deferredTerminal = null;
      if (terminal != null && _access != null && !_disposed) {
        _resumePending = false;
        unawaited(
          _run(() async {
            await _clear();
            notice = terminal.message;
          }),
        );
      } else if (_resumePending && _active && !_disposed) {
        _resumePending = false;
        unawaited(retry());
      }
    }
  }

  Future<void> initialize() => _run(() async {
    try {
      _access = await vault.load();
    } on RoomFailure {
      _blocked = true;
      rethrow;
    } catch (_) {
      _blocked = true;
      throw const RoomFailure('SAVED_DATA');
    } finally {
      initialized = true;
    }
    if (_disposed) return;
    _blocked = false;
    await _recover();
  });
  Future<void> enroll(String name, {String? pin}) => _run(() async {
    if (!canEnroll) return;
    final request = <String, dynamic>{
      'protocolVersion': 2,
      'requestId': roomCommandId(),
      'retryKey': randomRoomKey(),
      'name': name.trim(),
    };
    if (!RoomContract.accepts('V2Enrollment', request) ||
        (pin != null && !RegExp(r'^\d{6}$').hasMatch(pin))) {
      throw const RoomFailure('INVALID_REQUEST');
    }
    _access = RoomAccess(origin: api.origin, enrollment: request, pin: pin);
    await _recover();
  });
  Future<void> retry() {
    if (_blocked && _access == null) return initialize();
    return _run(_recover);
  }

  Future<void> _recover() async {
    if (_clearPending) {
      await _clear();
      return;
    }
    final access = _access;
    if (access == null) return;
    if (access.origin != api.origin) {
      _blocked = true;
      throw const RoomFailure('SERVER_CHANGED');
    }
    if (access.enrollment != null) {
      // Persist retry identity BEFORE sending. Lost responses can never create a second guest.
      await _save(access);
      if (_disposed) return;
      final result = await api.enroll(access);
      if (_disposed) return;
      final joined = RoomAccess(
        origin: api.origin,
        roomId: result.snapshot.roomId,
        token: result.token,
      );
      await _save(joined);
      _access = joined;
      if (_disposed) return;
      _accept(result.snapshot);
      _watch();
    } else if (access.leave != null) {
      await _save(access);
      if (_disposed) return;
      try {
        if (access.leave!['type'] == 'room.leave') {
          await api.leave(access);
        } else {
          await api.command(access);
        }
      } on RoomFailure catch (failure) {
        if (!const {
          'VERSION_CONFLICT',
          'FORBIDDEN',
          'INVALID_PHASE',
          'SESSION_CONFLICT',
          'CLIENT_UPGRADE_REQUIRED',
        }.contains(failure.code)) {
          rethrow;
        }
        final fresh = await api.snapshot(access);
        if (_disposed) return;
        final restored = RoomAccess(
          origin: api.origin,
          roomId: access.roomId,
          token: access.token,
        );
        await _save(restored);
        _access = restored;
        _accept(fresh);
        _watch();
        rethrow;
      }
      if (_disposed) return;
      if (access.leave!['type'] == 'room.leave') {
        await _clear();
        notice = 'Вы вышли из комнаты.';
      } else {
        final restored = RoomAccess(
          origin: access.origin,
          roomId: access.roomId,
          token: access.token,
        );
        await _save(restored);
        _access = restored;
        final fresh = await api.snapshot(restored);
        if (_disposed) return;
        _accept(fresh);
        _watch();
      }
    } else {
      final fresh = await api.snapshot(access);
      if (_disposed) return;
      _accept(fresh);
      _watch();
    }
  }

  void _accept(RoomSnapshot fresh) {
    final access = _access;
    if (_disposed ||
        access?.roomId != fresh.roomId ||
        (snapshot != null &&
            (fresh.selfId != snapshot!.selfId ||
                fresh.version < snapshot!.version))) {
      return;
    }
    _serverOffset = fresh.serverTime.difference(DateTime.now());
    if (fresh.game?.sessionId != snapshot?.game?.sessionId ||
        fresh.game?.phase != 'distribution' ||
        (fresh.game?.readyIds.contains(fresh.selfId) ?? false)) {
      cardVisible = false;
    }
    snapshot = fresh;
  }

  void _watch() {
    _stop();
    final access = _access;
    if (_disposed ||
        !_active ||
        access?.roomId == null ||
        access!.leave != null) {
      return;
    }
    final generation = _watchGeneration;
    api.watch(
      access,
      (fresh) {
        if (_disposed || generation != _watchGeneration) return;
        if (fresh.roomId != access.roomId ||
            (snapshot != null && fresh.selfId != snapshot!.selfId)) {
          error = const RoomFailure('PROTOCOL');
          _notify();
          return;
        }
        if (snapshot != null && fresh.version < snapshot!.version) return;
        final gap = snapshot != null && fresh.version > snapshot!.version + 1;
        _accept(fresh);
        online = true;
        if (const {
          'CONNECTION',
          'SERVICE_UNAVAILABLE',
          'RATE_LIMITED',
          'PROTOCOL',
        }.contains(error?.code)) {
          error = null;
        }
        _notify();
        if (gap) unawaited(retry());
      },
      (failure) {
        if (_disposed || generation != _watchGeneration) return;
        online = false;
        cardVisible = false;
        if (failure.terminal) {
          // Notify privacy changes now; serialize credential removal after the pending write/request.
          if (busy) {
            _deferredTerminal = failure;
            _notify();
            return;
          }
          unawaited(
            _run(() async {
              await _clear();
              notice = failure.message;
            }),
          );
        } else {
          error = failure;
          _notify();
        }
      },
      () {
        if (_disposed || generation != _watchGeneration) return;
        online = false;
        cardVisible = false;
        _notify();
      },
    );
  }

  Future<void> leave() => _run(() async {
    final access = _access;
    final current = snapshot;
    if (access == null || current == null || access.enrollment != null) return;
    _stop();
    _access = RoomAccess(
      origin: access.origin,
      roomId: access.roomId,
      token: access.token,
      leave: {
        'protocolVersion': 2,
        'sessionId': current.game?.sessionId,
        'commandId': roomCommandId(),
        'expectedVersion': current.version,
        'type': 'room.leave',
        'payload': <String, dynamic>{},
      },
    );
    await _recover();
  });
  Future<void> play(String type, [Map<String, dynamic> payload = const {}]) =>
      _run(() async {
        final access = _access;
        final current = snapshot;
        if (access == null || current == null || hasPending) return;
        _stop();
        _access = RoomAccess(
          origin: access.origin,
          roomId: access.roomId,
          token: access.token,
          leave: {
            'protocolVersion': 2,
            'commandId': roomCommandId(),
            'expectedVersion': current.version,
            'sessionId': current.game?.sessionId,
            'type': type,
            'payload': payload,
          },
        );
        await _recover();
      });
  Future<void> forget() => _run(() async {
    await _clear();
    notice = 'Доступ удалён с этого телефона.';
  });
  void setActive(bool active) {
    if (_active == active || _disposed) return;
    _active = active;
    if (!active) {
      _resumePending = false;
      _stop();
      _notify();
    } else if (_access != null && !_blocked) {
      if (busy) {
        _resumePending = true;
      } else {
        _resumePending = false;
        unawaited(retry());
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stop();
    api.close();
    super.dispose();
  }
}
