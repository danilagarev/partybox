import 'dart:convert';
import 'dart:math';
import 'generated/room_schema.dart';
import 'generated/room_game_schema.dart';

final class RoomFailure implements Exception {
  const RoomFailure(this.code);
  final String code;
  bool get terminal => const {
    'UNAUTHORIZED',
    'ROOM_EXPIRED',
    'ROOM_CLOSED',
    'ROOM_UNAVAILABLE',
  }.contains(code);
  String get message => switch (code) {
    'ROOM_FULL' => 'В комнате уже 12 участников.',
    'ROOM_UNAVAILABLE' => 'Комната не найдена или уже закрыта.',
    'ROOM_EXPIRED' => 'Время комнаты истекло. Можно создать новую.',
    'ROOM_CLOSED' => 'Комната закрыта.',
    'UNAUTHORIZED' => 'Доступ к комнате завершён.',
    'RATE_LIMITED' => 'Слишком много попыток. Подождите минуту.',
    'STORAGE' => 'Не удалось сохранить доступ на телефоне. Попробуйте ещё раз.',
    'SAVED_DATA' =>
      'Сохранённый доступ не удалось прочитать. Попробуйте ещё раз или удалите его с телефона.',
    'SERVER_CHANGED' =>
      'Сохранённый доступ недоступен в этой сборке. Можно удалить его с телефона.',
    'VERSION_CONFLICT' => 'Состояние комнаты изменилось. Повторите действие.',
    'FORBIDDEN' => 'Это действие доступно ведущему.',
    'INVALID_PHASE' => 'Этап игры уже изменился. Обновите комнату.',
    'SESSION_CONFLICT' => 'Эта партия уже закончилась. Обновите комнату.',
    'CLIENT_UPGRADE_REQUIRED' =>
      'Все участники должны открыть комнату в новой версии приложения.',
    'INVALID_REQUEST' => 'Проверьте имя и код комнаты.',
    'PROTOCOL' => 'Не удалось прочитать ответ сервера. Попробуйте позже.',
    _ => 'Нет связи с комнатой. Попробуйте ещё раз.',
  };
  @override
  String toString() => 'RoomFailure($code)';
}

/// Supports exactly the keywords used by rooms-v1; unknown schema keywords fail closed.
final class RoomContract {
  static final Map<String, dynamic> _schema = (() {
    final base = jsonDecode(roomSchemaJson) as Map<String, dynamic>;
    (base[r'$defs'] as Map).addAll(
      (jsonDecode(roomGameSchemaJson) as Map)[r'$defs'] as Map,
    );
    return base;
  })();
  static bool accepts(String definition, Object? value) =>
      _check(_schema[r'$defs'][definition] as Map<String, dynamic>, value);
  static bool validName(String value) => _check(
    (_schema[r'$defs']['Enrollment']['properties']['name']
        as Map<String, dynamic>),
    value,
  );
  static void require(String definition, Object? value) {
    if (!accepts(definition, value)) throw const RoomFailure('PROTOCOL');
  }

  static bool _check(Map<String, dynamic> schema, Object? value) {
    const supported = {
      r'$ref',
      'allOf',
      'oneOf',
      'maximum',
      'const',
      'enum',
      'type',
      'minimum',
      'minLength',
      'maxLength',
      'pattern',
      'properties',
      'required',
      'additionalProperties',
      'items',
      'minItems',
      'maxItems',
    };
    if (schema.keys.any((key) => !supported.contains(key))) return false;
    if (schema.containsKey('oneOf') &&
        (schema['oneOf'] as List)
                .where((s) => _check(s as Map<String, dynamic>, value))
                .length !=
            1) {
      return false;
    }
    if (schema.containsKey(r'$ref')) {
      final name = (schema[r'$ref'] as String).split('/').last;
      return _check(_schema[r'$defs'][name] as Map<String, dynamic>, value);
    }
    if (schema.containsKey('allOf') &&
        !(schema['allOf'] as List).every(
          (s) => _check(s as Map<String, dynamic>, value),
        )) {
      return false;
    }
    if (schema.containsKey('const') && schema['const'] != value) return false;
    if (schema.containsKey('enum') &&
        !(schema['enum'] as List).contains(value)) {
      return false;
    }
    switch (schema['type']) {
      case 'null':
        if (value != null) return false;
      case 'integer':
        if (schema['maximum'] != null &&
            value is num &&
            value > (schema['maximum'] as num)) {
          return false;
        }
        if (value is! int ||
            (schema['minimum'] != null && value < (schema['minimum'] as int))) {
          return false;
        }
      case 'string':
        if (value is! String) return false;
        if (schema['minLength'] != null &&
            value.runes.length < (schema['minLength'] as int)) {
          return false;
        }
        if (schema['maxLength'] != null &&
            value.runes.length > (schema['maxLength'] as int)) {
          return false;
        }
        if (schema['pattern'] != null &&
            !RegExp(
              schema['pattern'] as String,
              unicode: true,
            ).hasMatch(value)) {
          return false;
        }
      case 'object':
        if (value is! Map) return false;
        final properties = schema['properties'] as Map<String, dynamic>;
        if ((schema['required'] as List).any(
          (key) => !value.containsKey(key),
        )) {
          return false;
        }
        if (schema['additionalProperties'] == false &&
            value.keys.any((key) => !properties.containsKey(key))) {
          return false;
        }
        for (final key in value.keys) {
          if (!_check(properties[key] as Map<String, dynamic>, value[key])) {
            return false;
          }
        }
      case 'array':
        if (value is! List ||
            value.length < (schema['minItems'] as int? ?? 0) ||
            value.length > (schema['maxItems'] as int? ?? 1 << 30)) {
          return false;
        }
        if (!value.every(
          (v) => _check(schema['items'] as Map<String, dynamic>, v),
        )) {
          return false;
        }
    }
    return true;
  }
}

final class RoomSnapshot {
  RoomSnapshot._(
    this.roomId,
    this.version,
    this.selfId,
    this.hostId,
    this.pin,
    this.expiresAt,
    this.players,
    this.serverTime,
    this.game,
    this.card,
  );
  factory RoomSnapshot.parse(Object? json) {
    RoomContract.require(
      json is Map && json['protocolVersion'] == 2 ? 'GameSnapshot' : 'Snapshot',
      json,
    );
    final map = json as Map;
    final state = map['publicState'] as Map;
    final players = List<RoomPlayer>.unmodifiable(
      (state['players'] as List).map(
        (p) => RoomPlayer((p as Map)['id'] as String, p['name'] as String),
      ),
    );
    final ids = players.map((p) => p.id).toSet();
    final expiry = DateTime.tryParse(state['expiresAt'] as String);
    if (ids.length != players.length ||
        !ids.contains(map['selfId']) ||
        !ids.contains(state['hostId']) ||
        expiry == null ||
        DateTime.tryParse(map['serverTime'] as String) == null) {
      throw const RoomFailure('PROTOCOL');
    }
    final gameValue = state['game'] as Map?;
    final cardValue = map['privateState'] as Map?;
    if (gameValue == null && cardValue != null) {
      throw const RoomFailure('PROTOCOL');
    }
    if (gameValue != null) {
      final ready = gameValue['readyIds'] as List;
      final phase = gameValue['phase'];
      final result = gameValue['result'] as Map?;
      if (ready.toSet().length != ready.length ||
          ready.any((id) => !ids.contains(id)) ||
          (phase == 'results') != (result != null) ||
          (phase == 'distribution'
              ? gameValue['deadline'] != null
              : DateTime.tryParse(gameValue['deadline'] as String? ?? '') ==
                    null)) {
        throw const RoomFailure('PROTOCOL');
      }
      if (result != null &&
          (!ids.contains(result['spyId']) ||
              !ids.contains(result['suspectId']))) {
        throw const RoomFailure('PROTOCOL');
      }
      if (phase == 'results' && cardValue != null ||
          phase != 'results' && cardValue == null) {
        throw const RoomFailure('PROTOCOL');
      }
    }
    if (cardValue != null &&
        ((cardValue['role'] == 'spy') != (cardValue['location'] == null))) {
      throw const RoomFailure('PROTOCOL');
    }
    return RoomSnapshot._(
      map['roomId'] as String,
      map['version'] as int,
      map['selfId'] as String,
      state['hostId'] as String,
      state['pin'] as String,
      expiry,
      players,
      DateTime.parse(map['serverTime'] as String),
      state['game'] == null
          ? null
          : RoomGame(state['game'] as Map<String, dynamic>),
      map['privateState'] == null
          ? null
          : RoomCard(map['privateState'] as Map<String, dynamic>),
    );
  }
  final String roomId, selfId, hostId, pin;
  final int version;
  final DateTime expiresAt;
  final List<RoomPlayer> players;
  final DateTime serverTime;
  final RoomGame? game;
  final RoomCard? card;
}

final class RoomPlayer {
  const RoomPlayer(this.id, this.name);
  final String id, name;
}

String randomRoomKey() {
  final random = Random.secure();
  return base64UrlEncode(
    List.generate(32, (_) => random.nextInt(256)),
  ).replaceAll('=', '');
}

String roomCommandId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final s = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}

final class RoomGame {
  RoomGame(Map<String, dynamic> value)
    : sessionId = value['sessionId'] as String,
      packId = value['packId'] as String,
      phase = value['phase'] as String,
      readyIds = List<String>.unmodifiable(value['readyIds'] as List),
      deadline = value['deadline'] == null
          ? null
          : DateTime.parse(value['deadline'] as String),
      result = value['result'] as Map<String, dynamic>?;
  final String sessionId, phase, packId;
  final List<String> readyIds;
  final DateTime? deadline;
  final Map<String, dynamic>? result;
}

final class RoomCard {
  RoomCard(Map<String, dynamic> value)
    : role = value['role'] as String,
      location = value['location'] as String?;
  final String role;
  final String? location;
  @override
  String toString() => 'RoomCard(<redacted>)';
}
