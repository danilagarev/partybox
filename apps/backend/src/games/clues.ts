/** Pure game rules: content and deck order are supplied explicitly. */
export interface CluesQuestion {
  id: string;
  answer: string;
  aliases: string[];
  clues: string[];
}
export interface CluesAttempt {
  playerId: string;
  answer: string;
  clueIndex: number;
  correct: boolean;
  points: number;
}
export interface CluesState {
  players: string[];
  questions: CluesQuestion[];
  phase: 'playing' | 'reveal' | 'finished';
  roundIndex: number;
  clueIndex: number;
  attempts: CluesAttempt[];
  scores: { playerId: string; score: number }[];
}
export class CluesRuleError extends Error {
  constructor(readonly code: 'FORBIDDEN' | 'INVALID_PHASE' | 'INVALID_REQUEST') {
    super(code);
  }
}
const invalid = (code: CluesRuleError['code']): never => {
  throw new CluesRuleError(code);
};
export const normalizeCluesAnswer = (value: string) =>
  value
    .toLowerCase()
    .replaceAll('ё', 'е')
    .replace(/[^\p{L}\p{N}\s]/gu, ' ')
    .trim()
    .replace(/\s+/gu, ' ');
export function createClues(players: string[], questions: CluesQuestion[]): CluesState {
  if (
    players.length < 1 ||
    players.length > 12 ||
    new Set(players).size !== players.length ||
    questions.length !== 5 ||
    new Set(questions.map((q) => q.id)).size !== questions.length ||
    questions.some(
      (q) =>
        q.clues.length !== 4 || q.clues.some((c) => !c.trim()) || !normalizeCluesAnswer(q.answer),
    )
  )
    invalid('INVALID_REQUEST');
  return {
    players: [...players],
    questions: questions.map((q) => ({ ...q, aliases: [...q.aliases], clues: [...q.clues] })),
    phase: 'playing',
    roundIndex: 0,
    clueIndex: 0,
    attempts: [],
    scores: players.map((playerId) => ({ playerId, score: 0 })),
  };
}
export function answerClues(
  state: CluesState,
  actorId: string,
  answer: string,
  clueIndex: number,
): CluesState {
  if (!state.players.includes(actorId)) invalid('FORBIDDEN');
  if (state.phase !== 'playing') invalid('INVALID_PHASE');
  if (clueIndex !== state.clueIndex || [...answer].length > 120 || !normalizeCluesAnswer(answer))
    invalid('INVALID_REQUEST');
  if (
    state.attempts.some((a) => a.playerId === actorId && (a.correct || a.clueIndex === clueIndex))
  )
    invalid('INVALID_PHASE');
  const question = state.questions[state.roundIndex]!;
  const correct = [question.answer, ...question.aliases].some(
    (a) => normalizeCluesAnswer(a) === normalizeCluesAnswer(answer),
  );
  const points = correct ? 4 - clueIndex : 0;
  const attempts = [
    ...state.attempts,
    { playerId: actorId, answer: answer.trim(), clueIndex, correct, points },
  ];
  const done = state.players.every((id) =>
    attempts.some(
      (a) => a.playerId === id && (a.correct || (clueIndex === 3 && a.clueIndex === 3)),
    ),
  );
  return {
    ...state,
    attempts,
    phase: done ? 'reveal' : 'playing',
    scores: state.scores.map((s) => ({
      ...s,
      score: s.score + (s.playerId === actorId ? points : 0),
    })),
  };
}
export function hintClues(state: CluesState): CluesState {
  if (state.phase !== 'playing') invalid('INVALID_PHASE');
  return state.clueIndex === 3
    ? { ...state, phase: 'reveal' }
    : { ...state, clueIndex: state.clueIndex + 1 };
}
export function nextClues(state: CluesState): CluesState {
  if (state.phase !== 'reveal') invalid('INVALID_PHASE');
  return state.roundIndex === 4
    ? { ...state, phase: 'finished' }
    : { ...state, roundIndex: state.roundIndex + 1, clueIndex: 0, attempts: [], phase: 'playing' };
}
export function cluesPublic(state: CluesState, sessionId: string) {
  const revealed = state.phase !== 'playing';
  const question = state.questions[state.roundIndex]!;
  return {
    sessionId,
    phase: state.phase,
    roundIndex: state.roundIndex,
    roundCount: 5 as const,
    clueIndex: state.clueIndex,
    clues: question.clues.slice(0, state.clueIndex + 1),
    solvedIds: state.players.filter((id) =>
      state.attempts.some((a) => a.playerId === id && a.correct),
    ),
    attemptedIds: state.players.filter((id) =>
      state.attempts.some((a) => a.playerId === id && a.clueIndex === state.clueIndex),
    ),
    scores: state.scores.map((s) => ({ ...s })),
    result: revealed
      ? {
          answer: question.answer,
          answers: state.players.map((playerId) => {
            const a = state.attempts.filter((a) => a.playerId === playerId).at(-1);
            return {
              playerId,
              answer: a?.answer ?? null,
              correct: a?.correct ?? false,
              points: a?.points ?? 0,
            };
          }),
        }
      : null,
    winners:
      state.phase === 'finished'
        ? state.scores
            .filter((s) => s.score === Math.max(...state.scores.map((s) => s.score)))
            .map((s) => s.playerId)
        : [],
  };
}
export function cluesPrivate(state: CluesState, playerId: string) {
  if (!state.players.includes(playerId)) invalid('FORBIDDEN');
  if (state.phase !== 'playing') return null;
  const attempt = state.attempts.filter((a) => a.playerId === playerId).at(-1);
  return {
    answer: attempt?.answer ?? null,
    clueIndex: attempt?.clueIndex ?? null,
    correct: attempt?.correct ?? false,
    points: attempt?.points ?? 0,
  };
}
