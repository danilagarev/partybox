import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  createTolerance,
  rankTolerance,
  guessTolerance,
  nextTolerance,
  tolerancePublic,
  tolerancePrivate,
  ToleranceRuleError,
} from '../src/games/tolerance.js';
import { selectToleranceCards, toleranceCards } from '../src/games/tolerance-content.js';
const players = ['a', 'b', 'c', 'd'];
const cards = Array.from({ length: 16 }, (_, i) => ({ id: `card-${i}`, text: `Ситуация ${i}` }));
const initial = () => createTolerance(players, cards, [2, 0, 1, 3]);
const rejects = (fn: () => unknown, code: string) =>
  assert.throws(fn, (e) => e instanceof ToleranceRuleError && e.code === code);

test('large content pool uses unique v3-compatible handles without losing source text', () => {
  let turn = 0;
  const deck = selectToleranceCards(12, (length) => (++turn * 73) % length);
  const texts = new Set(deck.map((card) => card.text));
  assert.equal(texts.size, 48);
  assert.ok(deck.every((card) => /^tolerance-[0-9]{2}$/.test(card.id)));
  assert.equal(new Set(deck.map((card) => card.id)).size, 48);
  assert.ok(toleranceCards.some((card) => /[0-9]{3}$/.test(card.id) && texts.has(card.text)));
  assert.ok(deck.every((card) => toleranceCards.some((source) => source.text === card.text)));
});

test('tolerance secret ordering and simultaneous guesses stay private until every listener answered', () => {
  const first = initial();
  const ranked = rankTolerance(first, 'a', ['card-2', 'card-0', 'card-3', 'card-1']);
  assert.equal(first.phase, 'ranking');
  assert.equal(first.order, null);
  assert.deepEqual(tolerancePublic(first, 'id').visibleOrder, []);
  assert.deepEqual(tolerancePublic(ranked, 'id').visibleOrder, ['card-0', 'card-3', 'card-1']);
  let state = guessTolerance(ranked, 'b', 0);
  state = guessTolerance(state, 'c', 1);
  const publicView = tolerancePublic(state, 'id');
  assert.equal(publicView.result, null);
  assert.deepEqual(publicView.submittedIds, ['b', 'c']);
  assert.ok(!('order' in publicView));
  assert.ok(!('guesses' in publicView));
  assert.deepEqual(tolerancePrivate(state, 'd'), { order: null, guess: null });
  assert.deepEqual(tolerancePrivate(state, 'b'), { order: null, guess: 0 });
  assert.deepEqual(tolerancePrivate(state, 'a'), { order: ranked.order, guess: null });
  state = guessTolerance(state, 'd', 0);
  assert.equal(state.phase, 'reveal');
  assert.deepEqual(tolerancePublic(state, 'id').result, {
    order: ranked.order,
    guesses: [
      { playerId: 'b', position: 0, correct: true },
      { playerId: 'c', position: 1, correct: false },
      { playerId: 'd', position: 0, correct: true },
    ],
  });
  assert.deepEqual(
    state.scores.map((s) => s.score),
    [0, 1, 0, 1],
  );
  rejects(() => guessTolerance(state, 'b', 0), 'INVALID_PHASE');
});

test('tolerance validates actor, phase, permutation and numeric bounds', () => {
  const first = initial();
  rejects(
    () => createTolerance(players.slice(0, 3), cards.slice(0, 12), [0, 0, 0]),
    'INVALID_REQUEST',
  );
  rejects(() => createTolerance(['a', 'a', 'c', 'd'], cards, [0, 0, 0, 0]), 'INVALID_REQUEST');
  rejects(() => createTolerance(players, cards, [0, 0, 0, 4]), 'INVALID_REQUEST');
  rejects(
    () =>
      rankTolerance(
        first,
        'b',
        cards.slice(0, 4).map((c) => c.id),
      ),
    'FORBIDDEN',
  );
  for (const order of [
    ['card-0'],
    ['card-0', 'card-0', 'card-1', 'card-2'],
    ['card-0', 'card-1', 'card-2', 'foreign'],
  ])
    rejects(() => rankTolerance(first, 'a', order), 'INVALID_REQUEST');
  rejects(() => nextTolerance(first), 'INVALID_PHASE');
  rejects(() => guessTolerance(first, 'b', 0), 'INVALID_PHASE');
  const ranked = rankTolerance(
    first,
    'a',
    cards.slice(0, 4).map((c) => c.id),
  );
  rejects(() => guessTolerance(ranked, 'a', 0), 'FORBIDDEN');
  rejects(() => guessTolerance(ranked, 'foreign', 0), 'FORBIDDEN');
  for (const pos of [-1, 4, 0.5, NaN])
    rejects(() => guessTolerance(ranked, 'b', pos), 'INVALID_REQUEST');
  const guessed = guessTolerance(ranked, 'b', 0);
  rejects(() => guessTolerance(guessed, 'b', 1), 'INVALID_PHASE');
  rejects(
    () =>
      rankTolerance(
        ranked,
        'a',
        cards.slice(0, 4).map((c) => c.id),
      ),
    'INVALID_PHASE',
  );
});

test('every participant becomes hero once, scores persist, all tied winners are returned', () => {
  let state = initial();
  for (let round = 0; round < players.length; round++) {
    assert.equal(state.roundIndex, round);
    assert.equal(state.phase, 'ranking');
    const hero = players[round]!;
    const current = state.rounds[round]!;
    state = rankTolerance(
      state,
      hero,
      current.cards.map((c) => c.id),
    );
    for (const actor of players.filter((p) => p !== hero))
      state = guessTolerance(state, actor, state.order!.indexOf(current.targetId));
    assert.equal(state.phase, 'reveal');
    state = nextTolerance(state);
  }
  assert.equal(state.phase, 'finished');
  assert.deepEqual(
    state.scores.map((s) => s.score),
    [3, 3, 3, 3],
  );
  assert.deepEqual(tolerancePublic(state, 'id').winners, players);
  rejects(() => nextTolerance(state), 'INVALID_PHASE');
  // Serialized state is sufficient to restore a party, without RNG or system time.
  assert.deepEqual(
    tolerancePublic(JSON.parse(JSON.stringify(state)), 'id'),
    tolerancePublic(state, 'id'),
  );
});

test('content sampling is explicit and supplies distinct situations for twelve players', () => {
  const deck = selectToleranceCards(12, () => 0);
  assert.equal(deck.length, 48);
  assert.equal(new Set(deck.map((c) => c.id)).size, 48);
  assert.deepEqual(
    selectToleranceCards(12, () => 0),
    deck,
  );
});
