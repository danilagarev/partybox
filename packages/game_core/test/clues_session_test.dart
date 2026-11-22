import 'dart:convert';
import 'dart:io';

import 'package:partybox_game_core/partybox_game_core.dart';
import 'package:test/test.dart';

List<CluesQuestion> questions() => List.generate(
  5,
  (index) => CluesQuestion(
    id: 'q-$index',
    answer: 'Ёлка',
    aliases: ['Новогоднее дерево'],
    clues: ['Первый намёк', 'Второй намёк', 'Третий намёк', 'Последний намёк'],
  ),
);

void main() {
  test('shared server normalization vectors match Dart rules', () {
    final vectors =
        jsonDecode(
              File(
                '../game-contracts/examples/clues-normalization.json',
              ).readAsStringSync(),
            )
            as List;
    for (final vector in vectors) {
      expect(
        normalizeCluesAnswer(vector['input'] as String),
        vector['expected'],
      );
    }
  });

  test('normalization accepts only declared exact answers and aliases', () {
    final question = questions().first;
    expect(
      normalizeCluesAnswer('  НОВОГОДНЕЕ—дерево!!! '),
      'новогоднее дерево',
    );
    expect(question.matches('елка!'), true);
    expect(question.matches('НОВОГОДНЕЕ   дерево'), true);
    expect(question.matches('ёлочка'), false);
    expect(question.matches('я думаю что это елка'), false);
  });

  test('one attempt per clue and exact decreasing score', () {
    for (var hint = 0; hint < 4; hint++) {
      var game = CluesSession.start(questions());
      for (var level = 0; level < hint; level++) {
        game = game.answer('Неверно');
        expect(game.canAnswer, false);
        expect(() => game.answer('Ёлка'), throwsStateError);
        game = game.nextHint();
      }
      expect(game.visibleClues, hasLength(hint + 1));
      expect(game.revealedAnswer, null);
      final result = game.answer('ЁЛКА');
      expect(result.score, 4 - hint);
      expect(result.roundPoints, 4 - hint);
      expect(result.phase, CluesPhase.reveal);
      expect(result.revealedAnswer, 'Ёлка');
      expect(() => result.answer('Ёлка'), throwsStateError);
      expect(() => result.nextHint(), throwsStateError);
    }
  });

  test('last wrong answer or explicit reveal produces zero points', () {
    var game = CluesSession.start(questions());
    for (var i = 0; i < 3; i++) {
      game = game.nextHint();
    }
    expect(game.answer('неправильно').phase, CluesPhase.reveal);
    expect(game.answer('неправильно').score, 0);
    expect(game.nextHint().phase, CluesPhase.reveal);
    expect(game.nextHint().roundPoints, 0);
  });

  test('five rounds finish once and keep previous immutable states', () {
    var game = CluesSession.start(questions());
    final initial = game;
    expect(() => game.nextRound(), throwsStateError);
    expect(() => game.answer('!!!'), throwsArgumentError);
    expect(() => game.answer('а' * 121), throwsArgumentError);
    for (var round = 0; round < 5; round++) {
      game = game.answer('елка');
      expect(game.score, (round + 1) * 4);
      game = game.nextRound();
    }
    expect(game.phase, CluesPhase.finished);
    expect(game.score, 20);
    expect(() => game.nextRound(), throwsStateError);
    expect(() => game.answer('елка'), throwsStateError);
    expect(initial.score, 0);
    expect(initial.visibleClues, ['Первый намёк']);
    expect(() => initial.visibleClues.add('hidden'), throwsUnsupportedError);
  });

  test('invalid content cannot form a session', () {
    expect(
      () => CluesSession.start(questions().take(4).toList()),
      throwsArgumentError,
    );
    final duplicate = questions();
    duplicate[4] = duplicate.first;
    expect(() => CluesSession.start(duplicate), throwsArgumentError);
    expect(
      () => CluesQuestion(id: 'q', answer: '!', clues: ['a', 'b', 'c', 'd']),
      throwsArgumentError,
    );
    expect(
      () => CluesQuestion(id: 'q', answer: 'a', clues: ['a']),
      throwsArgumentError,
    );
  });
}
