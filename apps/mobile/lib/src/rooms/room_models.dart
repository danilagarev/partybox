import 'dart:convert';
import 'dart:math';
import 'generated/room_schema.dart';
import 'generated/room_game_schema.dart';
import 'generated/room_tolerance_schema.dart';

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
      'Сохранённая комната находится на другом сервере. Вернитесь к прежнему адресу или удалите доступ с телефона.',
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
    (base[r'$defs'] as Map).addAll(
      (jsonDecode(roomToleranceSchemaJson) as Map)[r'$defs'] as Map,
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
      case 'boolean':
        if (value is! bool) return false;
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
    this.tolerance,
    this.privateTolerance,
    this.protocolVersion,
  );
  factory RoomSnapshot.parse(Object? json) {
    RoomContract.require(
      json is Map && json['protocolVersion'] == 3
          ? 'V3Snapshot'
          : json is Map && json['protocolVersion'] == 2
          ? 'GameSnapshot'
          : 'Snapshot',
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
    final tolerance = state['tolerance'] as Map<String, dynamic>?;
    final privateTolerance = map['privateTolerance'] as Map<String, dynamic>?;
    _validateTolerance(
      tolerance,
      privateTolerance,
      ids,
      map['selfId'] as String,
      gameValue != null,
    );
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
      tolerance == null ? null : ToleranceGame(tolerance),
      privateTolerance == null ? null : TolerancePrivate(privateTolerance),
      map['protocolVersion'] as int,
    );
  }
  final String roomId, selfId, hostId, pin;
  final int version, protocolVersion;
  final DateTime expiresAt;
  final List<RoomPlayer> players;
  final DateTime serverTime;
  final RoomGame? game;
  final RoomCard? card;
  final ToleranceGame? tolerance;
  final TolerancePrivate? privateTolerance;
  String? get sessionId => tolerance?.sessionId ?? game?.sessionId;

  static void _validateTolerance(
    Map<String, dynamic>? value,
    Map<String, dynamic>? personal,
    Set<String> players,
    String self,
    bool spyPresent,
  ) {
    void require(bool valid) {
      if (!valid) throw const RoomFailure('PROTOCOL');
    }

    if (value == null) {
      require(personal == null);
      return;
    }
    require(!spyPresent && players.length >= 4);
    final cards = (value['cards'] as List).cast<Map<String, dynamic>>();
    final ids = cards.map((c) => c['id'] as String).toSet();
    final visible = (value['visibleOrder'] as List).cast<String>();
    final submitted = (value['submittedIds'] as List).cast<String>();
    final scores = (value['scores'] as List).cast<Map<String, dynamic>>();
    final winners = (value['winners'] as List).cast<String>();
    final hero = value['heroId'] as String;
    final phase = value['phase'] as String;
    require(ids.length == 4 && ids.contains(value['targetId']));
    require(
      players.contains(hero) && (value['roundIndex'] as int) < players.length,
    );
    require(visible.toSet().length == visible.length);
    require(
      phase == 'ranking'
          ? visible.isEmpty
          : visible.length == 3 &&
                visible.every(ids.contains) &&
                !visible.contains(value['targetId']),
    );
    require(
      submitted.toSet().length == submitted.length &&
          submitted.every((p) => players.contains(p) && p != hero),
    );
    require(
      scores.length == players.length &&
          scores.map((s) => s['playerId']).toSet().length == players.length &&
          scores.every(
            (s) =>
                players.contains(s['playerId']) &&
                (s['score'] as int) <= players.length - 1,
          ),
    );
    require(
      winners.toSet().length == winners.length &&
          winners.every(players.contains),
    );
    require(phase == 'finished' ? winners.isNotEmpty : winners.isEmpty);
    final result = value['result'] as Map?;
    require((phase == 'reveal' || phase == 'finished') == (result != null));
    if (result != null) {
      final order = (result['order'] as List).cast<String>();
      final guesses = (result['guesses'] as List).cast<Map<String, dynamic>>();
      require(
        order.length == 4 &&
            order.toSet().length == 4 &&
            order.every(ids.contains),
      );
      require(
        order.where((id) => id != value['targetId']).toList().join(',') ==
            visible.join(','),
      );
      require(
        guesses.length == players.length - 1 &&
            guesses.map((g) => g['playerId']).toSet().length == guesses.length,
      );
      require(
        guesses.every(
          (g) =>
              players.contains(g['playerId']) &&
              g['playerId'] != hero &&
              g['correct'] ==
                  (g['position'] == order.indexOf(value['targetId'] as String)),
        ),
      );
      require(submitted.length == players.length - 1);
    }
    if (personal != null) {
      final order = (personal['order'] as List?)?.cast<String>();
      final guess = personal['guess'] as int?;
      require(
        order == null ||
            self == hero &&
                order.length == 4 &&
                order.toSet().length == 4 &&
                order.every(ids.contains),
      );
      require(
        guess == null ||
            self != hero && phase != 'ranking' && submitted.contains(self),
      );
      require(self != hero || guess == null);
      require(phase != 'ranking' || order == null && guess == null);
    }
  }
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

final class ToleranceGame {
  ToleranceGame(Map<String, dynamic> value)
    : sessionId = value['sessionId'] as String,
      phase = value['phase'] as String,
      roundIndex = value['roundIndex'] as int,
      heroId = value['heroId'] as String,
      targetId = value['targetId'] as String,
      cards = List.unmodifiable(
        (value['cards'] as List).map(
          (c) => ToleranceCard(c as Map<String, dynamic>),
        ),
      ),
      visibleOrder = List<String>.unmodifiable(value['visibleOrder'] as List),
      submittedIds = List<String>.unmodifiable(value['submittedIds'] as List),
      scores = List.unmodifiable(
        (value['scores'] as List).map(
          (s) => ToleranceScore(s as Map<String, dynamic>),
        ),
      ),
      result = value['result'] as Map<String, dynamic>?,
      winners = List<String>.unmodifiable(value['winners'] as List);
  final String sessionId, phase, heroId, targetId;
  final int roundIndex;
  final List<ToleranceCard> cards;
  final List<String> visibleOrder, submittedIds, winners;
  final List<ToleranceScore> scores;
  final Map<String, dynamic>? result;
  String text(String id) => cards.firstWhere((c) => c.id == id).text;
}

final class ToleranceCard {
  ToleranceCard(Map<String, dynamic> value)
    : id = value['id'] as String,
      text = value['text'] as String;
  final String id, text;
}

final class ToleranceScore {
  ToleranceScore(Map<String, dynamic> value)
    : playerId = value['playerId'] as String,
      score = value['score'] as int;
  final String playerId;
  final int score;
}

final class TolerancePrivate {
  TolerancePrivate(Map<String, dynamic> value)
    : order = value['order'] == null
          ? null
          : List<String>.unmodifiable(value['order'] as List),
      guess = value['guess'] as int?;
  final List<String>? order;
  final int? guess;
  @override
  String toString() => 'TolerancePrivate(<redacted>)';
}
