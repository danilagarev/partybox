import 'dart:convert';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:partybox_game_core/partybox_game_core.dart';

Future<List<TruthCard>> loadTruthCards() async {
  final data =
      jsonDecode(
            await rootBundle.loadString(
              'packages/partybox_game_content/packs/truth-ru-base.json',
            ),
          )
          as Map<String, dynamic>;
  if (data['schemaVersion'] != 1 ||
      data['gameId'] != 'truth' ||
      data['locale'] != 'ru') {
    throw const FormatException('Unsupported Truth pack');
  }
  return [
    for (final item in (data['items'] as List).cast<Map<String, dynamic>>())
      TruthCard(
        id: item['id'] as String,
        topic: item['topic'] as String,
        statement: item['statement'] as String,
        truth: item['truth'] as bool,
        explanation: item['explanation'] as String,
        sources: [
          for (final source
              in (item['sources'] as List).cast<Map<String, dynamic>>())
            (title: source['title'] as String, url: source['url'] as String),
        ],
      ),
  ];
}

/// Draw one card per selected topic before repeating a topic where possible.
List<TruthCard> drawTruthCards(
  List<TruthCard> cards,
  Set<String> topics,
  Random random,
) {
  final queues = {
    for (final topic in truthTopicIds)
      if (topics.isEmpty || topics.contains(topic))
        topic: cards.where((card) => card.topic == topic).toList()
          ..shuffle(random),
  };
  final drawn = <TruthCard>[];
  while (drawn.length < truthRoundCount && queues.isNotEmpty) {
    final order = queues.keys.toList()..shuffle(random);
    for (final topic in order) {
      final queue = queues[topic]!;
      if (queue.isNotEmpty) drawn.add(queue.removeLast());
      if (queue.isEmpty) queues.remove(topic);
      if (drawn.length == truthRoundCount) break;
    }
  }
  return drawn;
}
