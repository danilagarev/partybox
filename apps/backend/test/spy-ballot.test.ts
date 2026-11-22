import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  createSpy,
  acknowledgeSpy,
  voteSpy,
  ballotSpy,
  spyVoting,
  spyBallot,
  accuseSpy,
  spyPublic,
} from '../src/games/spy.js';
const players = ['a', 'b', 'c', 'd'].map((id) => ({ id, name: id }));
function voting() {
  let state = createSpy(players, 'Музей', 1, 180000, true);
  for (const p of players) state = acknowledgeSpy(state, p.id, 1000);
  return voteSpy(state);
}
test('every player including host and spy votes; only personal choice is projected', () => {
  let state = voting();
  assert.throws(() => accuseSpy(state, 'b'));
  state = ballotSpy(state, 'a', 1, 'b');
  assert.equal(state.phase, 'voting');
  assert.deepEqual(spyVoting(state), {
    round: 1,
    candidateIds: ['a', 'b', 'c', 'd'],
    votedIds: ['a'],
  });
  assert.deepEqual(spyBallot(state, 'a'), { round: 1, suspectId: 'b' });
  assert.equal(spyBallot(state, 'b'), undefined);
  assert.equal('result' in spyPublic(state), false);
  assert.throws(() => ballotSpy(state, 'a', 1, 'c'));
  assert.throws(() => ballotSpy(state, 'foreign', 1, 'b'));
  assert.throws(() => ballotSpy(state, 'b', 2, 'b'));
  assert.throws(() => ballotSpy(state, 'b', 1, 'foreign'));
  for (const id of ['b', 'c', 'd']) state = ballotSpy(state, id, 1, 'b');
  assert.equal(state.phase, 'results');
  assert.equal(state.suspectId, 'b');
  assert.equal(spyPublic(state).result?.winner, 'civilians');
  assert.equal(spyVoting(state), undefined);
  assert.equal(spyBallot(state, 'a'), undefined);
  assert.throws(() => ballotSpy(state, 'a', 1, 'b'));
});
test('ties reset ballots and narrow candidates; delayed rounds cannot affect a new round', () => {
  let state = voting();
  for (const [i, id] of ['a', 'b', 'c', 'd'].entries())
    state = ballotSpy(state, id, 1, i < 2 ? 'a' : 'b');
  assert.equal(state.phase, 'voting');
  assert.deepEqual(spyVoting(state), { round: 2, candidateIds: ['a', 'b'], votedIds: [] });
  assert.equal(spyBallot(state, 'a'), undefined);
  assert.throws(() => ballotSpy(state, 'a', 1, 'b'));
  assert.throws(() => ballotSpy(state, 'a', 2, 'c'));
  // Persistence is plain JSON; reconstruction retains the current round.
  state = JSON.parse(JSON.stringify(state));
  for (const id of ['a', 'b', 'c', 'd']) state = ballotSpy(state, id, 2, 'a');
  assert.equal(state.phase, 'results');
  assert.equal(spyPublic(state).result?.winner, 'spy');
});
