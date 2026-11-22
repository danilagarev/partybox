import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:partybox_mobile/src/rooms/room_models.dart';
import 'package:partybox_mobile/src/rooms/room_vault.dart';

import 'support.dart';

Map<String, dynamic> cluesFixture({
  int version = 1,
  int clueIndex = 0,
  String phase = 'playing',
  int round = 0,
  String? ownAnswer,
  bool correct = false,
  int? ownClue,
  bool guest = false,
}) {
  final examples =
      jsonDecode(
            File(
              '../../packages/game-contracts/examples/rooms-v4.json',
            ).readAsStringSync(),
          )
          as Map;
  final data = examples['V4Snapshot'] as Map<String, dynamic>;
  final state = data['publicState'] as Map<String, dynamic>;
  final game = state['clues'] as Map<String, dynamic>;
  final players = (state['players'] as List).cast<Map<String, dynamic>>();
  if (guest) state['hostId'] = players[1]['id'];
  final revealed = phase != 'playing';
  final answer = revealed ? ownAnswer ?? 'Учебный ответ' : ownAnswer;
  final solved = revealed || correct;
  final level = answer == null ? null : ownClue ?? clueIndex;
  final points = solved ? 4 - level! : 0;
  data['version'] = version;
  game.addAll({
    'phase': phase,
    'roundIndex': phase == 'finished' ? 4 : round,
    'clueIndex': clueIndex,
    'clues': [
      for (var i = 0; i <= clueIndex; i++) 'Учебная подсказка ${i + 1}',
    ],
    'solvedIds': solved ? [selfId] : <String>[],
    'attemptedIds': answer != null && level == clueIndex
        ? [selfId]
        : <String>[],
    'scores': [
      for (final player in players)
        {
          'playerId': player['id'],
          'score': player['id'] == selfId ? points : 0,
        },
    ],
    'result': revealed
        ? {
            'answer': 'Учебный ответ',
            'answers': [
              for (final player in players)
                {
                  'playerId': player['id'],
                  'answer': player['id'] == selfId ? answer : null,
                  'correct': player['id'] == selfId,
                  'points': player['id'] == selfId ? points : 0,
                },
            ],
          }
        : null,
    'winners': phase == 'finished' ? [selfId] : <String>[],
  });
  data['privateClues'] = revealed
      ? null
      : {
          'answer': answer,
          'clueIndex': level,
          'correct': solved,
          'points': points,
        };
  return data;
}

class CluesApi extends FakeRoomApi {
  final responses = <Map<String, dynamic>>[];
  final errors = <RoomFailure?>[];
  Completer<void>? commandGate;

  @override
  Future<void> command(RoomAccess access) async {
    final index = leaves.length;
    leaves.add(access);
    if (commandGate != null) await commandGate!.future;
    if (index < responses.length) {
      current = RoomSnapshot.parse(responses[index]);
    }
    if (index < errors.length && errors[index] != null) throw errors[index]!;
  }
}
