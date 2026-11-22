/// The same exact-match normalization is used by the authoritative server.
String normalizeCluesAnswer(String value) => value
    .toLowerCase()
    .replaceAll('ё', 'е')
    .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

class CluesQuestion {
  CluesQuestion({
    required this.id,
    required this.answer,
    required List<String> clues,
    List<String> aliases = const [],
  }) : clues = List.unmodifiable(clues),
       aliases = List.unmodifiable(aliases) {
    if (id.isEmpty ||
        normalizeCluesAnswer(answer).isEmpty ||
        answer.length > 120 ||
        clues.length != 4 ||
        clues.any((clue) => clue.trim().isEmpty) ||
        aliases.any(
          (alias) => normalizeCluesAnswer(alias).isEmpty || alias.length > 120,
        )) {
      throw ArgumentError('Invalid clue question');
    }
  }

  final String id, answer;
  final List<String> clues, aliases;
  bool matches(String value) {
    final normalized = normalizeCluesAnswer(value);
    return normalized == normalizeCluesAnswer(answer) ||
        aliases.any((alias) => normalizeCluesAnswer(alias) == normalized);
  }
}

enum CluesPhase { guessing, reveal, finished }

/// A deterministic five-question solo game. Content is selected by the adapter,
/// clocks and randomness are deliberately absent from these rules.
class CluesSession {
  CluesSession._({
    required List<CluesQuestion> questions,
    this.roundIndex = 0,
    this.clueIndex = 0,
    this.score = 0,
    this.phase = CluesPhase.guessing,
    this.attempt,
    this.roundPoints = 0,
  }) : _questions = List.unmodifiable(questions);

  factory CluesSession.start(List<CluesQuestion> questions) {
    if (questions.length != 5 ||
        questions.map((question) => question.id).toSet().length != 5) {
      throw ArgumentError('Five distinct questions are required');
    }
    return CluesSession._(questions: questions);
  }

  final List<CluesQuestion> _questions;
  final int roundIndex, clueIndex, score, roundPoints;
  final CluesPhase phase;
  final String? attempt;
  int get roundCount => _questions.length;
  int get availablePoints => 4 - clueIndex;
  bool get canAnswer => phase == CluesPhase.guessing && attempt == null;
  List<String> get visibleClues =>
      List.unmodifiable(_questions[roundIndex].clues.take(clueIndex + 1));
  String? get revealedAnswer =>
      phase == CluesPhase.guessing ? null : _questions[roundIndex].answer;

  CluesSession answer(String value) {
    if (!canAnswer) throw StateError('No answer is allowed at this clue');
    if (value.runes.length > 120 || normalizeCluesAnswer(value).isEmpty) {
      throw ArgumentError('Answer must contain 1–120 characters');
    }
    final correct = _questions[roundIndex].matches(value);
    final points = correct ? availablePoints : 0;
    return CluesSession._(
      questions: _questions,
      roundIndex: roundIndex,
      clueIndex: clueIndex,
      score: score + points,
      phase: correct || clueIndex == 3
          ? CluesPhase.reveal
          : CluesPhase.guessing,
      attempt: value.trim(),
      roundPoints: points,
    );
  }

  CluesSession nextHint() {
    if (phase != CluesPhase.guessing) {
      throw StateError('Hints are only available while guessing');
    }
    return CluesSession._(
      questions: _questions,
      roundIndex: roundIndex,
      clueIndex: clueIndex == 3 ? clueIndex : clueIndex + 1,
      score: score,
      phase: clueIndex == 3 ? CluesPhase.reveal : CluesPhase.guessing,
    );
  }

  CluesSession nextRound() {
    if (phase != CluesPhase.reveal) {
      throw StateError('Reveal the answer before advancing');
    }
    return CluesSession._(
      questions: _questions,
      roundIndex: roundIndex == 4 ? 4 : roundIndex + 1,
      score: score,
      phase: roundIndex == 4 ? CluesPhase.finished : CluesPhase.guessing,
    );
  }
}
