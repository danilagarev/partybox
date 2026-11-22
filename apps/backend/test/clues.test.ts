import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  createClues,
  answerClues,
  hintClues,
  nextClues,
  cluesPublic,
  cluesPrivate,
  normalizeCluesAnswer,
  CluesRuleError,
  type CluesQuestion,
} from '../src/games/clues.js';
const questions: CluesQuestion[] = Array.from({ length: 5 }, (_, i) => ({
  id: `q${i}`,
  answer: `Ёж ${i}`,
  aliases: [`ёжик ${i}`],
  clues: [`Первая ${i}`, `Вторая ${i}`, `Третья ${i}`, `Четвёртая ${i}`],
}));
const bad = (action: () => unknown, code: string) =>
  assert.throws(action, (e: unknown) => e instanceof CluesRuleError && e.code === code);
test('clues solo full game, aliases and deterministic scoring', () => {
  const vectors = JSON.parse(
    readFileSync(
      new URL(
        '../../../../packages/game-contracts/examples/clues-normalization.json',
        import.meta.url,
      ),
      'utf8',
    ),
  ) as { input: string; expected: string }[];
  for (const vector of vectors) assert.equal(normalizeCluesAnswer(vector.input), vector.expected);
  let state = createClues(['a'], questions);
  for (let round = 0; round < 5; round++) {
    state = hintClues(state);
    state = answerClues(state, 'a', ` ЁЖИК ${round}! `, 1);
    assert.equal(state.phase, 'reveal');
    assert.equal(cluesPrivate(state, 'a'), null);
    state = nextClues(state);
  }
  assert.equal(state.phase, 'finished');
  assert.equal(state.scores[0]!.score, 15);
  assert.deepEqual(cluesPublic(state, 's').winners, ['a']);
  bad(() => nextClues(state), 'INVALID_PHASE');
});
test('clues multiplayer locks attempts per clue, hides others and never repeats points', () => {
  let state = createClues(['a', 'b'], questions);
  const initial = JSON.stringify(cluesPublic(state, 'session'));
  assert.doesNotMatch(initial, /Ёж|Вторая|Третья|Четвёртая|aliases|q0/);
  state = answerClues(state, 'a', 'ошибка', 0);
  assert.equal(state.phase, 'playing');
  bad(() => answerClues(state, 'a', 'Ёж 0', 0), 'INVALID_PHASE');
  bad(() => answerClues(state, 'b', 'Ёж 0', 1), 'INVALID_REQUEST');
  assert.equal(cluesPrivate(state, 'a')!.answer, 'ошибка');
  assert.equal(cluesPrivate(state, 'b')!.answer, null);
  assert.doesNotMatch(JSON.stringify(cluesPublic(state, 'session')), /ошибка/);
  state = hintClues(state);
  assert.equal(cluesPrivate(state, 'a')!.answer, 'ошибка');
  state = answerClues(state, 'a', 'Ёж 0', 1);
  assert.equal(state.scores[0]!.score, 3);
  bad(() => answerClues(state, 'a', 'Ёж 0', 1), 'INVALID_PHASE');
  state = hintClues(state);
  bad(() => answerClues(state, 'a', 'Ёж 0', 2), 'INVALID_PHASE');
  state = hintClues(state);
  state = answerClues(state, 'b', 'мимо', 3);
  assert.equal(state.phase, 'reveal');
  assert.equal(cluesPublic(state, 'session').result!.answer, 'Ёж 0');
  assert.equal(state.scores[0]!.score, 3);
  assert.equal(state.scores[1]!.score, 0);
});
test('clues validates bounds, membership, phase and lets host finish stalled final hint', () => {
  bad(() => createClues([], questions), 'INVALID_REQUEST');
  bad(() => createClues(['a', 'a'], questions), 'INVALID_REQUEST');
  bad(
    () =>
      createClues(
        Array.from({ length: 13 }, (_, i) => `${i}`),
        questions,
      ),
    'INVALID_REQUEST',
  );
  bad(() => createClues(['a'], questions.slice(1)), 'INVALID_REQUEST');
  let state = createClues(['a'], questions);
  bad(() => answerClues(state, 'other', 'x', 0), 'FORBIDDEN');
  for (const answer of ['   ', '!!!', 'x'.repeat(121)])
    bad(() => answerClues(state, 'a', answer, 0), 'INVALID_REQUEST');
  bad(() => nextClues(state), 'INVALID_PHASE');
  for (let i = 0; i < 4; i++) state = hintClues(state);
  assert.equal(state.phase, 'reveal');
  assert.equal(state.scores[0]!.score, 0);
  bad(() => answerClues(state, 'a', 'Ёж 0', 3), 'INVALID_PHASE');
});

test('answer limit uses Unicode code points consistently with the schema', () => {
  const state = createClues(['a'], questions);
  const answer = 'а' + '😀'.repeat(119);
  const next = answerClues(state, 'a', answer, 0);
  assert.equal(cluesPrivate(next, 'a')!.answer, answer);
  bad(() => answerClues(state, 'a', answer + '😀', 0), 'INVALID_REQUEST');
});
