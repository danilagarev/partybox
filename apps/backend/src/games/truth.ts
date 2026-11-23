import type {
  PrivateTruth,
  TruthPublic,
  TruthSource,
  TruthTopic,
  TruthResult,
} from '@partybox/game-contracts/rooms-v6';

export interface TruthCard {
  id: string;
  topic: TruthTopic;
  statement: string;
  truth: boolean;
  explanation: string;
  sources: TruthSource[];
}

export interface TruthState {
  cards: TruthCard[];
  phase: TruthPublic['phase'];
  roundIndex: number;
  scores: TruthPublic['scores'];
  initial: Record<string, boolean>;
  bets: Record<string, { answer: boolean; stake: number }>;
}

export class TruthRuleError extends Error {
  constructor(readonly code: 'INVALID_PHASE' | 'INVALID_REQUEST' | 'FORBIDDEN') {
    super(code);
  }
}

export function createTruth(players: string[], cards: TruthCard[]): TruthState {
  if (
    players.length < 2 ||
    players.length > 12 ||
    new Set(players).size !== players.length ||
    cards.length !== 10 ||
    new Set(cards.map((c) => c.id)).size !== 10
  )
    throw new TruthRuleError('INVALID_REQUEST');
  return {
    cards: structuredClone(cards),
    phase: 'initial',
    roundIndex: 0,
    scores: players.map((playerId) => ({ playerId, score: 0 })),
    initial: {},
    bets: {},
  };
}

function requireMember(state: TruthState, actor: string) {
  if (!state.scores.some((s) => s.playerId === actor)) throw new TruthRuleError('FORBIDDEN');
}

export function initialTruth(state: TruthState, actor: string, answer: boolean): TruthState {
  requireMember(state, actor);
  if (state.phase !== 'initial' || Object.hasOwn(state.initial, actor))
    throw new TruthRuleError('INVALID_PHASE');
  const initial = { ...state.initial, [actor]: answer };
  return {
    ...state,
    initial,
    phase: Object.keys(initial).length === state.scores.length ? 'discussion' : 'initial',
  };
}

export function discussTruth(state: TruthState): TruthState {
  if (state.phase !== 'discussion') throw new TruthRuleError('INVALID_PHASE');
  return { ...state, phase: 'betting' };
}

function pointsFor(bet: { answer: boolean; stake: number }, card: TruthCard) {
  return bet.answer === card.truth ? bet.stake : -bet.stake;
}

export function betTruth(
  state: TruthState,
  actor: string,
  answer: boolean,
  stake: number,
): TruthState {
  requireMember(state, actor);
  if (state.phase !== 'betting' || Object.hasOwn(state.bets, actor))
    throw new TruthRuleError('INVALID_PHASE');
  if (!Number.isInteger(stake) || stake < 1 || stake > 3)
    throw new TruthRuleError('INVALID_REQUEST');
  const bets = { ...state.bets, [actor]: { answer, stake } };
  if (Object.keys(bets).length < state.scores.length) return { ...state, bets };
  const card = state.cards[state.roundIndex]!;
  return {
    ...state,
    phase: 'reveal',
    bets,
    scores: state.scores.map(({ playerId, score }) => ({
      playerId,
      score: score + pointsFor(bets[playerId]!, card),
    })),
  };
}

export function nextTruth(state: TruthState): TruthState {
  if (state.phase !== 'reveal') throw new TruthRuleError('INVALID_PHASE');
  if (state.roundIndex === 9) return { ...state, phase: 'finished' };
  return { ...state, phase: 'initial', roundIndex: state.roundIndex + 1, initial: {}, bets: {} };
}

function resultFor(state: TruthState, card: TruthCard): TruthResult | null {
  if (state.phase !== 'reveal' && state.phase !== 'finished') return null;
  return {
    truth: card.truth,
    explanation: card.explanation,
    sources: card.sources.map(({ title, url }) => ({ title, url })),
    answers: state.scores.map(({ playerId }) => {
      const bet = state.bets[playerId]!;
      return {
        playerId,
        initialAnswer: state.initial[playerId]!,
        answer: bet.answer,
        stake: bet.stake,
        points: pointsFor(bet, card),
      };
    }),
  };
}

export function truthPublic(state: TruthState, sessionId: string): TruthPublic {
  const card = state.cards[state.roundIndex]!;
  const ids = state.scores.map((s) => s.playerId);
  const high = Math.max(...state.scores.map((s) => s.score));
  return {
    sessionId,
    phase: state.phase,
    roundIndex: state.roundIndex,
    roundCount: 10,
    topic: card.topic,
    statement: card.statement,
    initialAnsweredIds: ids.filter((id) => Object.hasOwn(state.initial, id)),
    betIds: ids.filter((id) => Object.hasOwn(state.bets, id)),
    scores: state.scores.map((s) => ({ ...s })),
    result: resultFor(state, card),
    winners:
      state.phase === 'finished'
        ? state.scores.filter((s) => s.score === high).map((s) => s.playerId)
        : [],
  };
}

export function truthPrivate(state: TruthState, actor: string): PrivateTruth | null {
  requireMember(state, actor);
  if (state.phase === 'reveal' || state.phase === 'finished') return null;
  const bet = state.bets[actor];
  return {
    initialAnswer: state.initial[actor] ?? null,
    answer: bet?.answer ?? null,
    stake: bet?.stake ?? null,
  };
}
