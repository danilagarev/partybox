import { selectTruthCards } from '../src/games/truth-content.js';
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  createTruth,
  initialTruth,
  discussTruth,
  betTruth,
  nextTruth,
  truthPrivate,
  truthPublic,
  type TruthCard,
} from '../src/games/truth.js';
const cards: TruthCard[] = Array.from({ length: 10 }, (_, i) => ({
  id: `internal-${i}`,
  truth: i % 2 === 0,
  topic: 'science',
  statement: `Statement ${i}`,
  explanation: `Evidence ${i}`,
  sources: [{ title: 'Source', url: `https://example.org/${i}` }],
}));
for (const count of [2, 12]) {
  test(`truth is private through discussion and betting, scores once, finishes after ten rounds with ${count} players`, () => {
    const players = Array.from({ length: count }, (_, i) => `p${i}`);
    let state = createTruth(players, cards);
    for (let round = 0; round < 10; round++) {
      const card = cards[round]!;
      const before = structuredClone(state.scores);
      for (const player of players) {
        assert.deepEqual(truthPrivate(state, player), {
          initialAnswer: null,
          answer: null,
          stake: null,
        });
        state = initialTruth(state, player, false);
        assert.equal(truthPrivate(state, player)?.initialAnswer, false);
        assert.throws(() => initialTruth(state, player, true), /INVALID_PHASE/);
      }
      assert.equal(state.phase, 'discussion');
      assert.throws(() => nextTruth(state), /INVALID_PHASE/);
      state = discussTruth(state);
      for (const [i, player] of players.entries()) {
        const pub = truthPublic(state, 'session');
        assert.deepEqual(pub.scores, before);
        assert.deepEqual(pub.result, null);
        assert.equal(Object.hasOwn(pub, 'id'), false);
        const wire = JSON.stringify(pub);
        for (const secret of [
          card.id,
          'Evidence',
          'Source',
          'example.org',
          '"answer"',
          '"truth"',
          '"stake"',
        ])
          assert.equal(wire.includes(secret), false);
        assert.deepEqual(truthPrivate(state, player), {
          initialAnswer: false,
          answer: null,
          stake: null,
        });
        state = betTruth(state, player, i === 0 ? !card.truth : card.truth, 3);
        if (state.phase === 'betting') assert.equal(truthPrivate(state, player)?.stake, 3);
        assert.throws(() => betTruth(state, player, true, 3), /INVALID_PHASE/);
      }
      const pub = truthPublic(state, 'session');
      assert.equal(pub.phase, 'reveal');
      assert.equal(truthPrivate(state, players[0]!), null);
      assert.equal(pub.result?.truth, card.truth);
      assert.deepEqual(pub.result?.sources, card.sources);
      assert.equal(pub.result?.answers[0]?.points, -3);
      assert.equal(pub.scores[0]?.score, -3 * (round + 1));
      assert.equal(pub.scores[1]?.score, 3 * (round + 1));
      state = nextTruth(state);
    }
    const pub = truthPublic(state, 'session');
    assert.equal(pub.phase, 'finished');
    assert.deepEqual(pub.winners, players.slice(1));
    assert.throws(() => nextTruth(state), /INVALID_PHASE/);
  });
}
test('truth rejects invalid rosters, repeated cards, unknown actors, early commands and invalid stakes', () => {
  for (const roster of [['a'], ['a', 'a'], Array.from({ length: 13 }, (_, i) => String(i))])
    assert.throws(() => createTruth(roster, cards), /INVALID_REQUEST/);
  assert.throws(() => createTruth(['a', 'b'], Array(10).fill(cards[0])), /INVALID_REQUEST/);
  let state = createTruth(['a', 'b'], cards);
  assert.throws(() => initialTruth(state, 'c', false), /FORBIDDEN/);
  assert.throws(() => truthPrivate(state, 'c'), /FORBIDDEN/);
  assert.throws(() => discussTruth(state), /INVALID_PHASE/);
  assert.throws(() => betTruth(state, 'a', true, 2), /INVALID_PHASE/);
  state = discussTruth(initialTruth(initialTruth(state, 'a', false), 'b', true));
  for (const stake of [-1, 0, 1.5, 4])
    assert.throws(() => betTruth(state, 'a', false, stake), /INVALID_REQUEST/);
});

test('truth decks cover every selected topic once per cycle without repeating cards', () => {
  for (const topics of [[], ['food'], ['human', 'science', 'everyday']] as const) {
    const deck = selectTruthCards(topics, (n) => n - 1);
    const count = topics.length || 6;
    assert.equal(new Set(deck.map((card) => card.id)).size, 10);
    for (let i = 0; i < 10; i += count) {
      const slice = deck.slice(i, i + count);
      assert.equal(new Set(slice.map((card) => card.topic)).size, slice.length);
    }
    if (topics.length) assert.deepEqual(new Set(deck.map((card) => card.topic)), new Set(topics));
  }
});
