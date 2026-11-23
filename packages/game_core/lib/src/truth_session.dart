enum TruthPhase { initial, discussion, betting, reveal, finished }

const truthRoundCount = 10;
const truthTopicIds = [
  'animals',
  'human',
  'food',
  'history',
  'science',
  'everyday',
];

final class TruthCard {
  TruthCard({
    required this.id,
    required this.topic,
    required this.statement,
    required this.truth,
    required this.explanation,
    required List<({String title, String url})> sources,
  }) : sources = List.unmodifiable(sources);

  final String id, topic, statement, explanation;
  final bool truth;
  final List<({String title, String url})> sources;
}

typedef TruthAnswer = ({bool initial, bool answer, int stake, int points});

/// Rules for the shared-phone game. The adapter supplies the shuffled deck.
final class TruthSession {
  TruthSession(List<String> players, List<TruthCard> cards)
    : players = List.unmodifiable(players),
      _cards = List.unmodifiable(cards),
      _scores = List.filled(players.length, 0) {
    if (players.length < 2 ||
        players.length > 12 ||
        players.any((name) => name.trim().isEmpty) ||
        cards.length != truthRoundCount ||
        cards.map((card) => card.id).toSet().length != truthRoundCount) {
      throw ArgumentError('Invalid Truth party');
    }
  }

  final List<String> players;
  final List<TruthCard> _cards;
  final List<int> _scores;
  final List<bool> _initial = [];
  final List<TruthAnswer> _answers = [];
  int _roundIndex = 0;
  TruthPhase _phase = TruthPhase.initial;

  int get roundIndex => _roundIndex;
  TruthPhase get phase => _phase;
  TruthCard get _current => _cards[_roundIndex];
  String get statement => _current.statement;
  String get topic => _current.topic;
  int? get turnIndex => switch (_phase) {
    TruthPhase.initial => _initial.length,
    TruthPhase.betting => _answers.length,
    _ => null,
  };
  bool? get currentInitial =>
      _phase == TruthPhase.betting ? _initial[_answers.length] : null;
  TruthCard? get revealed =>
      _phase == TruthPhase.reveal || _phase == TruthPhase.finished
      ? _current
      : null;
  List<TruthAnswer> get answers =>
      revealed == null ? const [] : List.unmodifiable(_answers);
  List<int> get scores => List.unmodifiable(_scores);
  List<int> get winners => _phase != TruthPhase.finished
      ? const []
      : [
          for (final (i, score) in _scores.indexed)
            if (_scores.every((other) => score >= other)) i,
        ];

  void answerInitial(bool answer) {
    _require(TruthPhase.initial);
    _initial.add(answer);
    if (_initial.length == players.length) _phase = TruthPhase.discussion;
  }

  void finishDiscussion() {
    _require(TruthPhase.discussion);
    _phase = TruthPhase.betting;
  }

  void bet(bool answer, int stake) {
    _require(TruthPhase.betting);
    if (stake < 1 || stake > 3) throw RangeError.range(stake, 1, 3);
    _answers.add((
      initial: _initial[_answers.length],
      answer: answer,
      stake: stake,
      points: answer == _current.truth ? stake : -stake,
    ));
    if (_answers.length == players.length) {
      for (final (i, answer) in _answers.indexed) {
        _scores[i] += answer.points;
      }
      _phase = TruthPhase.reveal;
    }
  }

  void next() {
    _require(TruthPhase.reveal);
    if (_roundIndex == truthRoundCount - 1) {
      _phase = TruthPhase.finished;
      return;
    }
    _roundIndex++;
    _initial.clear();
    _answers.clear();
    _phase = TruthPhase.initial;
  }

  void _require(TruthPhase expected) {
    if (_phase != expected) throw StateError('Invalid Truth phase');
  }
}
