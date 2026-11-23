import 'dart:async';
import 'package:flutter/foundation.dart';
import 'room_api.dart';
import 'room_models.dart';
import 'room_vault.dart';

final class RoomController extends ChangeNotifier {
  RoomController({
    required this.api,
    required this.vault,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final RoomApi api;
  final RoomVault vault;
  final DateTime Function() _now;
  RoomAccess? _access;
  RoomSnapshot? snapshot;
  RoomFailure? error;
  String? notice;
  bool busy = false, online = false, initialized = false;
  bool cardVisible = false;
  bool toleranceVisible = false;
  bool roleViewed = false;
  int roleConcealEpoch = 0;

  void _concealRole() {
    cardVisible = false;
    toleranceVisible = false;
    roleConcealEpoch++;
  }

  Duration _serverOffset = Duration.zero;
  Duration get remaining {
    final end = snapshot?.deals?.deadline ?? snapshot?.game?.deadline;
    if (end == null) return Duration.zero;
    final left = end.difference(_now().add(_serverOffset));
    return left.isNegative ? Duration.zero : left;
  }

  void hideRole() {
    _concealRole();
    _notify();
  }

  void revealTolerance() {
    if (_active &&
        !hasPending &&
        !busy &&
        online &&
        snapshot?.tolerance != null) {
      toleranceVisible = true;
      _notify();
    }
  }

  void revealRole() {
    if (_active &&
        !hasPending &&
        !busy &&
        online &&
        snapshot?.game?.phase == 'distribution' &&
        snapshot?.card != null &&
        !snapshot!.game!.readyIds.contains(snapshot!.selfId)) {
      cardVisible = true;
      roleViewed = true;
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
    _concealRole();
    _watchGeneration++;
    online = false;
    api.stopWatching();
  }

  Future<void> _clear() async {
    _stop();
    roleViewed = false;
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
      'protocolVersion': roomProtocolVersion,
      'requestId': roomCommandId(),
      'retryKey': randomRoomKey(),
      'name': name.trim(),
    };
    if (!RoomContract.accepts('V7Enrollment', request) ||
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

  Future<void> _recover({bool reconnectOnRejection = true}) async {
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
      final ({String token, RoomSnapshot snapshot}) result;
      try {
        result = await api.enroll(access);
      } on RoomFailure catch (failure) {
        final version = access.enrollment!['protocolVersion'] as int;
        if (failure.code != 'SERVER_UPGRADE_REQUIRED' || version <= 5) {
          rethrow;
        }
        if (_disposed) return;
        _access = RoomAccess(
          origin: access.origin,
          enrollment: {...access.enrollment!, 'protocolVersion': version - 1},
          pin: access.pin,
        );
        await _recover();
        return;
      }
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
      if ((access.enrollment!['protocolVersion'] as int) <
          roomProtocolVersion) {
        // A recovered registration keeps its old endpoint. Read the latest
        // protocol with the issued token before subscribing to room updates.
        final fresh = await api.snapshot(joined);
        if (_disposed) return;
        _accept(fresh);
      }
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
        if (reconnectOnRejection) _watch();
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
    _serverOffset = fresh.serverTime.difference(_now());
    if (fresh.truth != null
        ? fresh.truth?.sessionId != snapshot?.truth?.sessionId ||
              fresh.truth?.roundIndex != snapshot?.truth?.roundIndex ||
              fresh.truth?.phase != snapshot?.truth?.phase
        : fresh.tolerance != null
        ? fresh.tolerance?.sessionId != snapshot?.tolerance?.sessionId ||
              fresh.tolerance?.roundIndex != snapshot?.tolerance?.roundIndex ||
              fresh.tolerance?.phase != snapshot?.tolerance?.phase
        : fresh.game?.sessionId != snapshot?.game?.sessionId ||
              fresh.game?.phase != 'distribution' ||
              (fresh.game?.readyIds.contains(fresh.selfId) ?? false)) {
      _concealRole();
      roleViewed = false;
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
        // Truth and Deals revisions include the complete personal view.
        // Skipped intermediate revisions are normal when a room votes together.
        if (gap && fresh.truth == null && fresh.deals == null) {
          unawaited(retry());
        }
      },
      (failure) {
        if (_disposed || generation != _watchGeneration) return;
        online = false;
        _concealRole();
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
        _concealRole();
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
        'protocolVersion': current.protocolVersion >= 3
            ? current.protocolVersion
            : 2,
        'sessionId': current.sessionId,
        'commandId': roomCommandId(),
        'expectedVersion': current.version,
        'type': 'room.leave',
        'payload': <String, dynamic>{},
      },
    );
    await _recover();
  });
  Future<void> play(
    String type, [
    Map<String, dynamic> payload = const {},
    RoomSnapshot? intent,
  ]) => _run(() async {
    final access = _access;
    final initial = snapshot;
    if (access == null || initial == null || hasPending) return;
    final deals = type.startsWith('deals.');
    if (deals && (!online || initial.protocolVersion < roomProtocolVersion)) {
      return;
    }
    if (intent != null &&
        (!online ||
            intent.roomId != initial.roomId ||
            intent.sessionId != initial.sessionId ||
            intent.truth?.phase != initial.truth?.phase ||
            intent.truth?.roundIndex != initial.truth?.roundIndex)) {
      return;
    }
    if (deals && intent != null && intent.version != initial.version) {
      final independent = const {
        'deals.choose',
        'deals.list',
        'deals.done',
        'deals.market',
        'deals.next',
      }.contains(type);
      if (!independent ||
          intent.deals?.phase != initial.deals?.phase ||
          intent.deals?.round != initial.deals?.round) {
        throw const RoomFailure('VERSION_CONFLICT');
      }
    }
    RoomSnapshot current = intent ?? initial;
    final sessionId = current.sessionId;
    if (privateRoomCommandTypes.contains(type)) {
      if (!deals && !type.startsWith('truth.')) _stop();
      await _sendSecret(access, current, type, payload);
      return;
    }
    for (var attempt = 0; ; attempt++) {
      _stop();
      _access = RoomAccess(
        origin: access.origin,
        roomId: access.roomId,
        token: access.token,
        leave: {
          'protocolVersion': current.protocolVersion >= 3
              ? current.protocolVersion
              : 2,
          'commandId': roomCommandId(),
          'expectedVersion': current.version,
          'sessionId': current.sessionId,
          'type': type,
          'payload': payload,
        },
      );
      try {
        await _recover(reconnectOnRejection: type != 'spy.ready');
        return;
      } on RoomFailure catch (failure) {
        final fresh = snapshot;
        // Independent confirmations can race. Only a definite version
        // rejection permits a new ID; uncertain requests keep their ID.
        if (type != 'spy.ready' ||
            failure.code != 'VERSION_CONFLICT' ||
            fresh == null ||
            fresh.sessionId != sessionId) {
          if (type == 'spy.ready' && !hasPending) _watch();
          rethrow;
        }
        if (fresh.game?.readyIds.contains(fresh.selfId) ?? false) {
          _watch();
          return;
        }
        if (!_active ||
            _disposed ||
            fresh.game?.phase != 'distribution' ||
            attempt >= fresh.players.length - 1) {
          _watch();
          rethrow;
        }
        current = fresh;
      }
    }
  });
  // Secret decisions stay in memory. After an uncertain response, read the
  // authoritative personal view; a retry requires another explicit user action.
  Future<void> _sendSecret(
    RoomAccess access,
    RoomSnapshot current,
    String type,
    Map<String, dynamic> payload,
  ) async {
    for (var attempt = 0; ; attempt++) {
      final request = RoomAccess(
        origin: access.origin,
        roomId: access.roomId,
        token: access.token,
        leave: {
          'protocolVersion': current.protocolVersion >= 3
              ? current.protocolVersion
              : 3,
          'commandId': roomCommandId(),
          'expectedVersion': current.version,
          'sessionId': current.sessionId,
          'type': type,
          'payload': payload,
        },
      );
      RoomFailure? failure;
      try {
        await api.command(request);
      } on RoomFailure catch (e) {
        if (e.terminal) rethrow;
        failure = e;
      } catch (_) {
        failure = const RoomFailure('CONNECTION');
      }
      if (_disposed) return;
      final RoomSnapshot fresh;
      try {
        fresh = await api.snapshot(access);
      } catch (_) {
        // Even an uncertain command followed by a failed read must not leave
        // live updates permanently disconnected. Never resend the secret here.
        if (!online) _watch();
        rethrow;
      }
      if (_disposed) return;
      _accept(fresh);
      // Independent answers may race. Retry only a definite rejection, with
      // the original text/round/clue, never an uncertain accepted command.
      if (type == 'clues.answer' &&
          failure?.code == 'VERSION_CONFLICT' &&
          _active &&
          attempt < fresh.players.length - 1 &&
          fresh.sessionId == current.sessionId &&
          fresh.clues?.phase == 'playing' &&
          fresh.clues?.roundIndex == current.clues?.roundIndex &&
          fresh.clues?.clueIndex == payload['clueIndex'] &&
          !fresh.clues!.solvedIds.contains(fresh.selfId) &&
          !fresh.clues!.attemptedIds.contains(fresh.selfId)) {
        current = fresh;
        continue;
      }
      if (type == 'spy.ballot' &&
          fresh.sessionId == current.sessionId &&
          (fresh.game?.phase == 'results' ||
              (fresh.game?.votingRound ?? 0) > (payload['round'] as int) ||
              (fresh.card?.ballotRound == payload['round'] &&
                  fresh.card?.ballotSuspectId == payload['suspectId']))) {
        failure = null;
      }
      final truth = fresh.truth;
      if (truth != null &&
          truth.sessionId == current.truth?.sessionId &&
          truth.roundIndex == current.truth?.roundIndex &&
          (type == 'truth.initial' &&
                  truth.initialAnsweredIds.contains(fresh.selfId) ||
              type == 'truth.bet' && truth.betIds.contains(fresh.selfId))) {
        failure = null;
      }
      if (!online) _watch();
      if (failure != null) {
        notice = type.startsWith('deals.')
            ? 'Комната обновлена. Проверьте, применилось ли действие.'
            : 'Проверили состояние на сервере. Если ответ не принят, отправьте его ещё раз.';
        if (failure.code != 'CONNECTION') throw failure;
      }
      return;
    }
  }

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
