import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'room_models.dart';
import 'room_vault.dart';

abstract interface class RoomApi {
  String get origin;
  Future<({String token, RoomSnapshot snapshot})> enroll(RoomAccess request);
  Future<RoomSnapshot> snapshot(RoomAccess access);
  Future<void> leave(RoomAccess access);
  Future<void> command(RoomAccess access);
  void watch(
    RoomAccess access,
    void Function(RoomSnapshot) onSnapshot,
    void Function(RoomFailure) onError,
    void Function() onDisconnect,
  );
  void stopWatching();
  void close();
}

final class HttpRoomApi implements RoomApi {
  HttpRoomApi(String server, {http.Client? client, bool allowInsecure = false})
    : _client = client ?? http.Client() {
    final uri = Uri.parse(server);
    if (!uri.hasAuthority ||
        uri.userInfo.isNotEmpty ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        (uri.scheme != 'https' && !(allowInsecure && uri.scheme == 'http'))) {
      throw ArgumentError('Invalid room server origin');
    }
    origin = uri.origin;
  }
  @override
  late final String origin;
  final http.Client _client;
  io.Socket? _socket;
  Future<Object?> _request(
    String path, {
    Map<String, dynamic>? body,
    String? token,
  }) async {
    try {
      final request =
          http.Request(body == null ? 'GET' : 'POST', Uri.parse('$origin$path'))
            ..followRedirects = false
            ..headers.addAll({
              'Content-Type': 'application/json',
              if (token != null) 'Authorization': 'Bearer $token',
            });
      if (body != null) request.body = jsonEncode(body);
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 10));
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 10),
      )) {
        if (bytes.length + chunk.length > 32768) {
          throw const RoomFailure('PROTOCOL');
        }
        bytes.addAll(chunk);
      }
      final value = jsonDecode(utf8.decode(bytes));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if ((RoomContract.accepts('Error', value) ||
            RoomContract.accepts('GameError', value))) {
          throw RoomFailure((value as Map)['code'] as String);
        }
        throw const RoomFailure('CONNECTION');
      }
      return value;
    } on RoomFailure {
      rethrow;
    } on FormatException {
      throw const RoomFailure('PROTOCOL');
    } catch (_) {
      throw const RoomFailure('CONNECTION');
    }
  }

  @override
  Future<({String token, RoomSnapshot snapshot})> enroll(
    RoomAccess request,
  ) async {
    _checkOrigin(request);
    final value = await _request(
      request.enrollment!['protocolVersion'] == 1
          ? (request.pin == null ? '/rooms' : '/rooms/join/${request.pin}')
          : (request.pin == null
                ? '/v2/rooms'
                : '/v2/rooms/join/${request.pin}'),
      body: request.enrollment,
    );
    RoomContract.require(
      request.enrollment!['protocolVersion'] == 1
          ? 'EnrollmentResult'
          : 'GameEnrollmentResult',
      value,
    );
    final map = value as Map;
    return (
      token: map['guestToken'] as String,
      snapshot: RoomSnapshot.parse(map['snapshot']),
    );
  }

  @override
  Future<RoomSnapshot> snapshot(RoomAccess access) async {
    _checkOrigin(access);
    return RoomSnapshot.parse(
      await _request('/v2/rooms/${access.roomId}', token: access.token),
    );
  }

  @override
  Future<void> leave(RoomAccess access) async {
    _checkOrigin(access);
    final value = await _request(
      access.leave!['protocolVersion'] == 1
          ? '/rooms/${access.roomId}/commands'
          : '/v2/rooms/${access.roomId}/commands',
      body: access.leave,
      token: access.token,
    );
    RoomContract.require(
      access.leave!['protocolVersion'] == 1 ? 'Ack' : 'GameAck',
      value,
    );
    if ((value as Map)['commandId'] != access.leave!['commandId']) {
      throw const RoomFailure('PROTOCOL');
    }
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
    _checkOrigin(access);
    stopWatching();
    final socket = _socket = io.io(
      origin,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .disableAutoConnect()
          .enableForceNew()
          .setAuth({
            'roomId': access.roomId,
            'guestToken': access.token,
            'protocolVersion': 2,
          })
          .setReconnectionAttempts(5)
          .setReconnectionDelay(2000)
          .build(),
    );
    socket.on('room.snapshot', (value) {
      try {
        onSnapshot(RoomSnapshot.parse(value));
      } on RoomFailure catch (e) {
        onError(e);
      }
    });
    socket.on(
      'room.error',
      (value) => onError(
        RoomFailure(
          (RoomContract.accepts('Error', value) ||
                  RoomContract.accepts('GameError', value))
              ? (value as Map)['code'] as String
              : 'PROTOCOL',
        ),
      ),
    );
    socket.onConnectError((value) {
      final code = value is String
          ? value
          : value is Map
          ? value['message']
          : null;
      onError(
        RoomFailure(
          const {
                'UNAUTHORIZED',
                'ROOM_EXPIRED',
                'ROOM_CLOSED',
                'ROOM_UNAVAILABLE',
                'RATE_LIMITED',
              }.contains(code)
              ? code as String
              : 'CONNECTION',
        ),
      );
    });
    socket.onDisconnect((_) => onDisconnect());
    socket.connect();
  }

  void _checkOrigin(RoomAccess access) {
    if (access.origin != origin) throw const RoomFailure('SERVER_CHANGED');
  }

  @override
  void stopWatching() {
    final socket = _socket;
    _socket = null;
    socket?.dispose();
  }

  @override
  void close() {
    stopWatching();
    _client.close();
  }
}
