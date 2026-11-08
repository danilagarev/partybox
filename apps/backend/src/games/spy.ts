export interface SpyPlayer {
  id: string;
  name: string;
}
export interface SpyState {
  players: SpyPlayer[];
  location: string;
  spyIndex: number;
  durationMs: number;
  phase: 'distribution' | 'discussion' | 'voting' | 'results';
  distributedCount: number;
  deadline: number | null;
  suspectId: string | null;
}
export class SpyRuleError extends Error {}
export function createSpy(
  players: SpyPlayer[],
  location: string,
  spyIndex: number,
  durationMs: number,
): SpyState {
  if (
    players.length < 4 ||
    players.length > 12 ||
    new Set(players.map((p) => p.id)).size !== players.length ||
    players.some((p) => !p.id.trim() || !p.name.trim()) ||
    !location.trim() ||
    !Number.isInteger(spyIndex) ||
    spyIndex < 0 ||
    spyIndex >= players.length ||
    !Number.isInteger(durationMs) ||
    durationMs < 180000 ||
    durationMs > 900000
  )
    throw new SpyRuleError('INVALID_CONFIG');
  return {
    players: players.map((p) => ({ ...p })),
    location: location.trim(),
    spyIndex,
    durationMs,
    phase: 'distribution',
    distributedCount: 0,
    deadline: null,
    suspectId: null,
  };
}
export function acknowledgeSpy(state: SpyState, playerId: string, now: number): SpyState {
  if (state.phase !== 'distribution' || state.players[state.distributedCount]?.id !== playerId)
    throw new SpyRuleError('INVALID_PHASE');
  const count = state.distributedCount + 1;
  const done = count === state.players.length;
  return {
    ...state,
    distributedCount: count,
    phase: done ? 'discussion' : 'distribution',
    deadline: done ? now + state.durationMs : null,
  };
}
export function voteSpy(state: SpyState): SpyState {
  if (state.phase !== 'discussion') throw new SpyRuleError('INVALID_PHASE');
  return { ...state, phase: 'voting' };
}
export function advanceSpy(state: SpyState, now: number): SpyState {
  return state.phase === 'discussion' && now >= state.deadline! ? voteSpy(state) : state;
}
export function accuseSpy(state: SpyState, suspectId: string): SpyState {
  if (state.phase !== 'voting' || !state.players.some((p) => p.id === suspectId))
    throw new SpyRuleError('INVALID_PHASE');
  return { ...state, phase: 'results', suspectId };
}
export function spyCard(state: SpyState, playerId: string) {
  const index = state.players.findIndex((p) => p.id === playerId);
  if (index < 0) throw new SpyRuleError('UNKNOWN_PLAYER');
  return index === state.spyIndex
    ? { role: 'spy' as const, location: null }
    : { role: 'civilian' as const, location: state.location };
}
export function spyPublic(state: SpyState) {
  return {
    gameId: 'spy',
    phase: state.phase,
    players: state.players.map(({ id, name }) => ({ id, name })),
    deadline: state.deadline === null ? null : new Date(state.deadline).toISOString(),
    ...(state.phase === 'results'
      ? {
          result: {
            spyId: state.players[state.spyIndex]!.id,
            location: state.location,
            suspectId: state.suspectId!,
            winner:
              state.suspectId === state.players[state.spyIndex]!.id
                ? ('civilians' as const)
                : ('spy' as const),
          },
        }
      : {}),
  };
}
