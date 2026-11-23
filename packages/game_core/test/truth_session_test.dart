import 'package:partybox_game_core/partybox_game_core.dart';
import 'package:test/test.dart';

List<TruthCard> _deck() => [
  for (var index = 0; index < truthRoundCount; index++)
    TruthCard(
      id: 'card-$index',
      topic: 'science',
      statement: 'Утверждение $index',
      truth: true,
      explanation: 'Объяснение',
      sources: [(title: 'Источник', url: 'https://example.org/fact')],
    ),
];

void main() {
  test('two players can change answers and earn or lose their stakes', () {
    final game = TruthSession(['Аня', 'Борис'], _deck());
    expect(game.revealed, isNull);
    expect(() => game.bet(true, 2), throwsStateError);
    game.answerInitial(false);
    expect(game.turnIndex, 1);
    expect(game.currentInitial, isNull);
    expect(game.finishDiscussion, throwsStateError);
    game.answerInitial(true);
    expect(game.phase, TruthPhase.discussion);
    game.finishDiscussion();
    expect(game.currentInitial, false);
    expect(() => game.bet(true, 4), throwsRangeError);
    game.bet(true, 3);
    expect(game.revealed, isNull);
    expect(game.answers, isEmpty);
    expect(game.scores, [0, 0]);
    expect(game.currentInitial, true);
    game.bet(false, 2);
    expect(game.phase, TruthPhase.reveal);
    expect(game.revealed!.truth, isTrue);
    expect(game.answers.first, (
      initial: false,
      answer: true,
      stake: 3,
      points: 3,
    ));
    expect(game.scores, [3, -2]);
    expect(() => game.bet(true, 3), throwsStateError);
    game.next();
    expect(game.phase, TruthPhase.initial);
    expect(game.turnIndex, 0);
    expect(game.answers, isEmpty);
    expect(game.scores, [3, -2]);
  });

  test('twelve players complete ten rounds and share first place on a tie', () {
    final game = TruthSession(
      List.generate(12, (index) => 'Игрок ${index + 1}'),
      _deck(),
    );
    for (var round = 0; round < truthRoundCount; round++) {
      expect(game.roundIndex, round);
      for (var player = 0; player < 12; player++) {
        game.answerInitial(true);
      }
      game.finishDiscussion();
      for (var player = 0; player < 12; player++) {
        game.bet(true, 1);
      }
      game.next();
    }
    expect(game.phase, TruthPhase.finished);
    expect(game.scores, everyElement(10));
    expect(game.winners, List.generate(12, (index) => index));
    expect(game.next, throwsStateError);
  });

  test('rejects invalid player count and duplicate cards', () {
    expect(() => TruthSession(['Аня'], _deck()), throwsArgumentError);
    final deck = _deck();
    deck[1] = deck[0];
    expect(() => TruthSession(['Аня', 'Борис'], deck), throwsArgumentError);
  });
}
