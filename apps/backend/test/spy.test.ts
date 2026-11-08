import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import {
  createSpy,
  acknowledgeSpy,
  advanceSpy,
  voteSpy,
  accuseSpy,
  spyPublic,
  spyCard,
  type SpyState,
} from '../src/games/spy.js';
const vectors = JSON.parse(
  readFileSync(
    new URL('../../../../packages/game-contracts/vectors/spy-v1.json', import.meta.url),
    'utf8',
  ),
);
test('shared Spy vectors match Dart phases, deadline and both outcomes', () => {
  for (const vector of vectors.cases) {
    const c = vector.initial;
    let state = createSpy(c.players, c.location, c.spyIndex, c.durationMs);
    assert.equal(spyCard(state, 'p1').location, null);
    for (const step of vector.steps) {
      const action = () => {
        switch (step.type) {
          case 'ack':
            return acknowledgeSpy(state, step.playerId, step.at);
          case 'time':
            return advanceSpy(state, step.at);
          case 'vote':
            return voteSpy(state);
          default:
            return accuseSpy(state, step.playerId);
        }
      };
      if (step.error) {
        assert.throws(action);
        continue;
      }
      const original = JSON.stringify(state);
      const before: SpyState = state;
      state = action();
      assert.equal(JSON.stringify(before), original);
      assert.equal(state.phase, step.phase);
      const pub = spyPublic(state);
      if (step.winner) assert.equal(pub.result!.winner, step.winner);
      if (state.phase !== 'results') {
        assert.equal(JSON.stringify(pub).includes(c.location), false);
        assert.equal('result' in pub, false);
      }
    }
  }
});
test('server rules reject invalid configurations and unknown personal views', () => {
  const players = Array.from({ length: 4 }, (_, i) => ({ id: `p${i}`, name: `${i}` }));
  for (const duration of [179999, 900001, NaN])
    assert.throws(() => createSpy(players, 'Тест', 0, duration));
  for (const index of [-1, 4, 0.5]) assert.throws(() => createSpy(players, 'Тест', index, 180000));
  assert.throws(() => createSpy(players.slice(0, 3), 'Тест', 0, 180000));
  assert.throws(() => spyCard(createSpy(players, 'Тест', 0, 180000), 'outsider'));
});
