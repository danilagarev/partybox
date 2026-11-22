import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:partybox_game_core/partybox_game_core.dart';

class CluesPack {
  CluesPack({
    required this.id,
    required this.version,
    required List<CluesQuestion> questions,
  }) : questions = List.unmodifiable(questions) {
    if (questions.length < 5 ||
        questions.map((question) => question.id).toSet().length !=
            questions.length) {
      throw const FormatException('Clue pack requires distinct questions');
    }
  }

  final String id;
  final int version;
  final List<CluesQuestion> questions;

  static Future<CluesPack> load() async {
    final data =
        jsonDecode(
              await rootBundle.loadString(
                'packages/partybox_game_content/packs/clues-ru-base.json',
                cache: false,
              ),
            )
            as Map<String, dynamic>;
    if (data['schemaVersion'] != 1 ||
        data['gameId'] != 'clues' ||
        data['locale'] != 'ru' ||
        data['version'] is! int) {
      throw const FormatException('Unsupported clue pack');
    }
    return CluesPack(
      id: data['id'] as String,
      version: data['version'] as int,
      questions: (data['items'] as List)
          .map(
            (item) => CluesQuestion(
              id: item['id'] as String,
              answer: item['answer'] as String,
              aliases: (item['aliases'] as List).cast<String>(),
              clues: (item['clues'] as List).cast<String>(),
            ),
          )
          .toList(),
    );
  }
}

/// Draws without replacement. Replays keep the local deck until this screen is
/// closed; randomness belongs to this adapter, never to the game rules.
class CluesDeck {
  CluesDeck(this.pack, {Random? random}) : _random = random ?? Random();
  final CluesPack pack;
  final Random _random;
  final List<CluesQuestion> _remaining = [];

  CluesSession start() {
    final selected = <CluesQuestion>[];
    while (selected.length < 5) {
      if (_remaining.isEmpty) {
        _remaining.addAll(
          pack.questions.where(
            (question) => !selected.any((chosen) => chosen.id == question.id),
          ),
        );
        _remaining.shuffle(_random);
      }
      selected.add(_remaining.removeLast());
    }
    return CluesSession.start(selected);
  }
}
