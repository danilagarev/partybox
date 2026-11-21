/** Pure rules: all content and random choices arrive explicitly. */
export interface ToleranceCard {
  id: string;
  text: string;
}
export interface ToleranceState {
  players: string[];
  rounds: { cards: ToleranceCard[]; targetId: string }[];
  phase: 'ranking' | 'guessing' | 'reveal' | 'finished';
  roundIndex: number;
  order: string[] | null;
  guesses: { playerId: string; position: number }[];
  scores: { playerId: string; score: number }[];
}
export class ToleranceRuleError extends Error {
  constructor(readonly code: 'FORBIDDEN' | 'INVALID_PHASE' | 'INVALID_REQUEST') {
    super(code);
  }
}
const invalid = (code: ToleranceRuleError['code']): never => {
  throw new ToleranceRuleError(code);
};
export function createTolerance(
  players: string[],
  cards: ToleranceCard[],
  targets: number[],
): ToleranceState {
  if (
    players.length < 4 ||
    players.length > 12 ||
    new Set(players).size !== players.length ||
    cards.length !== players.length * 4 ||
    new Set(cards.map((c) => c.id)).size !== cards.length ||
    targets.length !== players.length ||
    targets.some((n) => !Number.isInteger(n) || n < 0 || n > 3)
  )
    invalid('INVALID_REQUEST');
  return {
    players: [...players],
    rounds: players.map((_, i) => {
      const selected = cards.slice(i * 4, i * 4 + 4).map((c) => ({ ...c }));
      return { cards: selected, targetId: selected[targets[i]!]!.id };
    }),
    phase: 'ranking',
    roundIndex: 0,
    order: null,
    guesses: [],
    scores: players.map((playerId) => ({ playerId, score: 0 })),
  };
}
export function rankTolerance(
  state: ToleranceState,
  actorId: string,
  order: string[],
): ToleranceState {
  if (actorId !== state.players[state.roundIndex]) invalid('FORBIDDEN');
  if (state.phase !== 'ranking') invalid('INVALID_PHASE');
  const ids = state.rounds[state.roundIndex]!.cards.map((c) => c.id);
  if (order.length !== 4 || new Set(order).size !== 4 || order.some((id) => !ids.includes(id)))
    invalid('INVALID_REQUEST');
  return { ...state, order: [...order], phase: 'guessing' };
}
export function guessTolerance(
  state: ToleranceState,
  actorId: string,
  position: number,
): ToleranceState {
  if (!state.players.includes(actorId) || actorId === state.players[state.roundIndex])
    invalid('FORBIDDEN');
  if (state.phase !== 'guessing' || state.guesses.some((g) => g.playerId === actorId))
    invalid('INVALID_PHASE');
  if (!Number.isInteger(position) || position < 0 || position > 3) invalid('INVALID_REQUEST');
  const guesses = [...state.guesses, { playerId: actorId, position }];
  if (guesses.length !== state.players.length - 1) return { ...state, guesses };
  const correct = state.order!.indexOf(state.rounds[state.roundIndex]!.targetId);
  return {
    ...state,
    guesses,
    phase: 'reveal',
    scores: state.scores.map((s) => ({
      ...s,
      score:
        s.score +
        (guesses.some((g) => g.playerId === s.playerId && g.position === correct) ? 1 : 0),
    })),
  };
}
export function nextTolerance(state: ToleranceState): ToleranceState {
  if (state.phase !== 'reveal') invalid('INVALID_PHASE');
  if (state.roundIndex === state.players.length - 1) return { ...state, phase: 'finished' };
  return { ...state, phase: 'ranking', roundIndex: state.roundIndex + 1, order: null, guesses: [] };
}
export function tolerancePublic(state: ToleranceState, sessionId: string) {
  const round = state.rounds[state.roundIndex]!;
  const revealed = state.phase === 'reveal' || state.phase === 'finished';
  const correctPosition = state.order?.indexOf(round.targetId);
  const best = Math.max(...state.scores.map((s) => s.score));
  return {
    sessionId,
    phase: state.phase,
    roundIndex: state.roundIndex,
    heroId: state.players[state.roundIndex]!,
    cards: round.cards.map((c) => ({ ...c })),
    visibleOrder: state.order?.filter((id) => id !== round.targetId) ?? [],
    targetId: round.targetId,
    submittedIds: state.guesses.map((g) => g.playerId),
    scores: state.scores.map((s) => ({ ...s })),
    result: revealed
      ? {
          order: [...state.order!],
          guesses: state.guesses.map((g) => ({ ...g, correct: g.position === correctPosition })),
        }
      : null,
    winners:
      state.phase === 'finished'
        ? state.scores.filter((s) => s.score === best).map((s) => s.playerId)
        : [],
  };
}
export function tolerancePrivate(state: ToleranceState, actorId: string) {
  if (!state.players.includes(actorId)) invalid('FORBIDDEN');
  return {
    order: actorId === state.players[state.roundIndex] && state.order ? [...state.order] : null,
    guess: state.guesses.find((g) => g.playerId === actorId)?.position ?? null,
  };
}
