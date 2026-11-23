import 'dart:convert';
import 'dart:math';
import 'generated/room_schema.dart';
import 'generated/room_game_schema.dart';
import 'generated/room_tolerance_schema.dart';
import 'generated/room_clues_schema.dart';
import 'generated/room_ballot_schema.dart';
import 'generated/room_truth_schema.dart';

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
    'SERVER_UPGRADE_REQUIRED' =>
      'На сервере пока старая версия. Обновите сервер комнат.',
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
    (base[r'$defs'] as Map).addAll(
      (jsonDecode(roomCluesSchemaJson) as Map)[r'$defs'] as Map,
    );
    (base[r'$defs'] as Map).addAll(
      (jsonDecode(roomBallotSchemaJson) as Map)[r'$defs'] as Map,
    );
    (base[r'$defs'] as Map).addAll(
      (jsonDecode(roomTruthSchemaJson) as Map)[r'$defs'] as Map,
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
      'uniqueItems',
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
        if (value is List &&
            schema['uniqueItems'] == true &&
            value.toSet().length != value.length) {
          return false;
        }
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
    this.clues,
    this.privateClues,
    this.truth,
    this.privateTruth,
  );
  factory RoomSnapshot.parse(Object? json) {
    RoomContract.require(switch (json is Map ? json['protocolVersion'] : null) {
      6 => 'V6Snapshot',
      5 => 'V5Snapshot',
      4 => 'V4Snapshot',
      3 => 'V3Snapshot',
      2 => 'GameSnapshot',
      _ => 'Snapshot',
    }, json);
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
      final voting = gameValue['voting'] as Map?;
      final ballot = cardValue?['ballot'] as Map?;
      if (voting != null) {
        final candidates = (voting['candidateIds'] as List).cast<String>();
        final voted = (voting['votedIds'] as List).cast<String>();
        if (phase != 'voting' ||
            candidates.any((id) => !ids.contains(id)) ||
            voted.any((id) => !ids.contains(id)) ||
            voted.length >= ids.length ||
            voted.contains(map['selfId']) != (ballot != null) ||
            (ballot != null &&
                (ballot['round'] != voting['round'] ||
                    !candidates.contains(ballot['suspectId'])))) {
          throw const RoomFailure('PROTOCOL');
        }
      } else if (ballot != null) {
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
    final clues = state['clues'] as Map<String, dynamic>?;
    final privateClues = map['privateClues'] as Map<String, dynamic>?;
    _validateClues(
      clues,
      privateClues,
      ids,
      map['selfId'] as String,
      gameValue != null || tolerance != null,
    );
    final truth = state['truth'] as Map<String, dynamic>?;
    final privateTruth = map['privateTruth'] as Map<String, dynamic>?;
    final truthGame = truth == null ? null : TruthGame(truth);
    final truthChoices = privateTruth == null
        ? null
        : TruthPrivate(privateTruth);
    _validateTruth(
      truthGame,
      truthChoices,
      ids,
      map['selfId'] as String,
      gameValue != null || tolerance != null || clues != null,
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
      clues == null ? null : CluesGame(clues),
      privateClues == null ? null : CluesPrivate(privateClues),
      truthGame,
      truthChoices,
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
  final CluesGame? clues;
  final CluesPrivate? privateClues;
  final TruthGame? truth;
  final TruthPrivate? privateTruth;
  String? get sessionId =>
      truth?.sessionId ??
      clues?.sessionId ??
      tolerance?.sessionId ??
      game?.sessionId;

  static void _validateTruth(
    TruthGame? game,
    TruthPrivate? personal,
    Set<String> players,
    String self,
    bool otherGame,
  ) {
    void require(bool condition) {
      if (!condition) throw const RoomFailure('PROTOCOL');
    }

    if (game == null) {
      require(personal == null);
      return;
    }
    require(!otherGame && players.length >= 2);
    final revealed = game.phase == 'reveal' || game.phase == 'finished';
    require(
      revealed == (game.result != null) && revealed == (personal == null),
    );
    for (final ids in [game.initialAnsweredIds, game.betIds, game.winners]) {
      require(ids.toSet().length == ids.length && ids.every(players.contains));
    }
    require(
      (game.phase == 'initial') ==
          (game.initialAnsweredIds.length < players.length),
    );
    require(revealed == (game.betIds.length == players.length));
    if (game.phase == 'initial' || game.phase == 'discussion') {
      require(game.betIds.isEmpty);
    }
    final scoreIds = game.scores.map((score) => score.playerId).toSet();
    require(
      game.scores.length == players.length && scoreIds.containsAll(players),
    );
    if (game.phase == 'finished') {
      final highest = game.scores.map((score) => score.score).reduce(max);
      require(
        game.roundIndex == game.roundCount - 1 &&
            game.winners.toSet().length ==
                game.scores.where((score) => score.score == highest).length &&
            game.scores
                .where((score) => score.score == highest)
                .every((score) => game.winners.contains(score.playerId)),
      );
    } else {
      require(game.winners.isEmpty);
    }
    if (personal != null) {
      require(
        (personal.initialAnswer != null) ==
            game.initialAnsweredIds.contains(self),
      );
      require((personal.answer != null) == game.betIds.contains(self));
      require((personal.answer == null) == (personal.stake == null));
    }
    final result = game.result;
    if (result != null) {
      final answerIds = result.answers.map((answer) => answer.playerId).toSet();
      require(
        result.answers.length == players.length &&
            answerIds.containsAll(players),
      );
      require(
        result.answers.every(
          (choice) =>
              choice.initialAnswer != null &&
              choice.answer != null &&
              choice.stake >= 1 &&
              choice.points ==
                  (choice.answer == result.truth
                      ? choice.stake
                      : -choice.stake),
        ),
      );
    }
  }

  static void _validateClues(
    Map<String, dynamic>? value,
    Map<String, dynamic>? personal,
    Set<String> players,
    String self,
    bool otherGame,
  ) {
    void require(bool condition) {
      if (!condition) throw const RoomFailure('PROTOCOL');
    }

    if (value == null) {
      require(personal == null);
      return;
    }
    require(!otherGame);
    final phase = value['phase'] as String;
    require(phase == 'playing' ? personal != null : personal == null);
    final clueIndex = value['clueIndex'] as int;
    require((value['clues'] as List).length == clueIndex + 1);
    final solved = (value['solvedIds'] as List).cast<String>();
    final attempted = (value['attemptedIds'] as List).cast<String>();
    final winners = (value['winners'] as List).cast<String>();
    for (final ids in [solved, attempted, winners]) {
      require(ids.toSet().length == ids.length && ids.every(players.contains));
    }
    final scores = (value['scores'] as List).cast<Map<String, dynamic>>();
    require(
      scores.length == players.length &&
          scores.map((s) => s['playerId']).toSet().containsAll(players) &&
          scores.map((s) => s['playerId']).toSet().length == players.length,
    );
    require((phase == 'finished') == winners.isNotEmpty);
    if (phase == 'finished') {
      require(value['roundIndex'] == 4);
      final best = scores.map((s) => s['score'] as int).reduce(max);
      require(
        winners.toSet().containsAll(
              scores
                  .where((s) => s['score'] == best)
                  .map((s) => s['playerId'] as String),
            ) &&
            winners.every(
              (id) =>
                  scores.any((s) => s['playerId'] == id && s['score'] == best),
            ),
      );
    }
    final result = value['result'] as Map?;
    require((phase != 'playing') == (result != null));
    if (personal != null) {
      final answer = personal['answer'] as String?;
      final ownClue = personal['clueIndex'] as int?;
      final correct = personal['correct'] as bool;
      final points = personal['points'] as int;
      require((answer == null) == (ownClue == null));
      require(ownClue == null || ownClue <= clueIndex);
      require(correct == solved.contains(self));
      require(correct ? answer != null && points == 4 - ownClue! : points == 0);
      if (ownClue == clueIndex && answer != null) {
        require(attempted.contains(self));
      }
    }
    if (result != null) {
      final answers = (result['answers'] as List).cast<Map<String, dynamic>>();
      require(
        answers.length == players.length &&
            answers.map((a) => a['playerId']).toSet().length ==
                players.length &&
            answers.every(
              (a) =>
                  players.contains(a['playerId']) &&
                  a['correct'] == solved.contains(a['playerId']) &&
                  (a['correct'] == true
                      ? a['answer'] != null && (a['points'] as int) > 0
                      : a['points'] == 0),
            ),
      );
    }
  }

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
      result = value['result'] as Map<String, dynamic>?,
      votingRound = (value['voting'] as Map?)?['round'] as int?,
      candidateIds = List<String>.unmodifiable(
        ((value['voting'] as Map?)?['candidateIds'] as List?)?.cast<String>() ??
            const <String>[],
      ),
      votedIds = List<String>.unmodifiable(
        ((value['voting'] as Map?)?['votedIds'] as List?)?.cast<String>() ??
            const <String>[],
      );
  final String sessionId, phase, packId;
  final int? votingRound;
  final List<String> candidateIds, votedIds;
  final List<String> readyIds;
  final DateTime? deadline;
  final Map<String, dynamic>? result;
}

final class RoomCard {
  RoomCard(Map<String, dynamic> value)
    : role = value['role'] as String,
      location = value['location'] as String?,
      ballotRound = (value['ballot'] as Map?)?['round'] as int?,
      ballotSuspectId = (value['ballot'] as Map?)?['suspectId'] as String?;
  final String role;
  final String? location;
  final int? ballotRound;
  final String? ballotSuspectId;
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
          (s) => RoomScore(s as Map<String, dynamic>),
        ),
      ),
      result = value['result'] as Map<String, dynamic>?,
      winners = List<String>.unmodifiable(value['winners'] as List);
  final String sessionId, phase, heroId, targetId;
  final int roundIndex;
  final List<ToleranceCard> cards;
  final List<String> visibleOrder, submittedIds, winners;
  final List<RoomScore> scores;
  final Map<String, dynamic>? result;
  String text(String id) => cards.firstWhere((c) => c.id == id).text;
}

final class ToleranceCard {
  ToleranceCard(Map<String, dynamic> value)
    : id = value['id'] as String,
      text = value['text'] as String;
  final String id, text;
}

final class RoomScore {
  RoomScore(Map<String, dynamic> value)
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

final class CluesGame {
  CluesGame(Map<String, dynamic> value)
    : sessionId = value['sessionId'] as String,
      phase = value['phase'] as String,
      roundIndex = value['roundIndex'] as int,
      roundCount = value['roundCount'] as int,
      clueIndex = value['clueIndex'] as int,
      clues = List<String>.unmodifiable(value['clues'] as List),
      solvedIds = List<String>.unmodifiable(value['solvedIds'] as List),
      attemptedIds = List<String>.unmodifiable(value['attemptedIds'] as List),
      scores = List<RoomScore>.unmodifiable(
        (value['scores'] as List).map(
          (s) => RoomScore(s as Map<String, dynamic>),
        ),
      ),
      result = value['result'] as Map<String, dynamic>?,
      winners = List<String>.unmodifiable(value['winners'] as List);
  final String sessionId, phase;
  final int roundIndex, roundCount, clueIndex;
  final List<String> clues, solvedIds, attemptedIds, winners;
  final List<RoomScore> scores;
  final Map<String, dynamic>? result;
}

final class CluesPrivate {
  CluesPrivate(Map<String, dynamic> value)
    : answer = value['answer'] as String?,
      clueIndex = value['clueIndex'] as int?,
      correct = value['correct'] as bool,
      points = value['points'] as int;
  final String? answer;
  final int? clueIndex;
  final bool correct;
  final int points;
  @override
  String toString() => 'CluesPrivate(<redacted>)';
}

final class TruthGame {
  TruthGame(Map<String, dynamic> value)
    : sessionId = value['sessionId'] as String,
      phase = value['phase'] as String,
      topic = value['topic'] as String,
      statement = value['statement'] as String,
      roundIndex = value['roundIndex'] as int,
      roundCount = value['roundCount'] as int,
      initialAnsweredIds = List<String>.unmodifiable(
        value['initialAnsweredIds'] as List,
      ),
      betIds = List<String>.unmodifiable(value['betIds'] as List),
      scores = List<RoomScore>.unmodifiable(
        (value['scores'] as List).map(
          (score) => RoomScore(score as Map<String, dynamic>),
        ),
      ),
      result = value['result'] == null
          ? null
          : TruthReveal(value['result'] as Map<String, dynamic>),
      winners = List<String>.unmodifiable(value['winners'] as List);
  final String sessionId, phase, topic, statement;
  final int roundIndex, roundCount;
  final List<String> initialAnsweredIds, betIds, winners;
  final List<RoomScore> scores;
  final TruthReveal? result;
}

final class TruthPrivate {
  TruthPrivate(Map<String, dynamic> value)
    : initialAnswer = value['initialAnswer'] as bool?,
      answer = value['answer'] as bool?,
      stake = value['stake'] as int?;
  final bool? initialAnswer, answer;
  final int? stake;
  @override
  String toString() => 'TruthPrivate(<redacted>)';
}

final class TruthReveal {
  TruthReveal(Map<String, dynamic> value)
    : truth = value['truth'] as bool,
      explanation = value['explanation'] as String,
      sources = List<({String title, String url})>.unmodifiable(
        (value['sources'] as List).cast<Map<String, dynamic>>().map(
          (source) =>
              (title: source['title'] as String, url: source['url'] as String),
        ),
      ),
      answers = List<TruthRevealedAnswer>.unmodifiable(
        (value['answers'] as List).cast<Map<String, dynamic>>().map(
          TruthRevealedAnswer.new,
        ),
      );
  final bool truth;
  final String explanation;
  final List<({String title, String url})> sources;
  final List<TruthRevealedAnswer> answers;
}

final class TruthRevealedAnswer {
  TruthRevealedAnswer(Map<String, dynamic> value)
    : playerId = value['playerId'] as String,
      initialAnswer = value['initialAnswer'] as bool?,
      answer = value['answer'] as bool?,
      stake = value['stake'] as int,
      points = value['points'] as int;
  final String playerId;
  final bool? initialAnswer, answer;
  final int stake, points;
}
