import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import Ajv from 'ajv';

const pack = JSON.parse(await readFile(new URL('../packs/clues-ru-base.json', import.meta.url)));
const schema = JSON.parse(
  await readFile(new URL('../../game-contracts/schemas/clues-pack.schema.json', import.meta.url)),
);
const validate = new Ajv({ allErrors: true, strict: true }).compile(schema);
const normalize = (value) =>
  value
    .toLocaleLowerCase('ru')
    .replaceAll('ё', 'е')
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .trim();

test('clues release pack has sixty unique puzzles conforming to its versioned schema', () => {
  assert.ok(validate(pack), JSON.stringify(validate.errors));
  assert.equal(pack.items.length, 60);
  assert.equal(new Set(pack.items.map((item) => item.id)).size, pack.items.length);
  assert.equal(new Set(pack.items.map((item) => normalize(item.answer))).size, pack.items.length);
  assert.equal(validate({ ...pack, schemaVersion: 2 }), false);
  assert.equal(validate({ ...pack, gameId: 'spy' }), false);
  assert.equal(validate({ ...pack, futureAnswers: [] }), false);
});

test('accepted answers are nonblank and do not overlap between puzzles after normalization', () => {
  const owners = new Map();
  for (const item of pack.items) {
    const accepted = [item.answer, ...item.aliases].map(normalize);
    assert.ok(
      accepted.every((answer) => answer.length > 0),
      item.id,
    );
    assert.equal(new Set(accepted).size, accepted.length, `${item.id}: redundant alias`);
    for (const answer of accepted) {
      assert.ok(!owners.has(answer), `${item.id}: answer belongs to another puzzle`);
      owners.set(answer, item.id);
    }
  }
});

test('four distinct clues do not directly disclose any accepted answer', () => {
  for (const item of pack.items) {
    const hints = item.clues.map(normalize);
    assert.equal(hints.length, 4);
    assert.equal(new Set(hints).size, 4, item.id);
    const answers = [item.answer, ...item.aliases].map(normalize);
    for (const hint of hints) {
      assert.ok(hint.length > 0, item.id);
      for (const answer of answers) {
        assert.ok(!` ${hint} `.includes(` ${answer} `), `${item.id}: literal answer in clue`);
      }
    }
  }
});

test('clues schema rejects malformed hints, source identifiers and oversized answers', () => {
  const checkItem = (changes) =>
    validate({ ...pack, items: [{ ...pack.items[0], ...changes }, ...pack.items.slice(1)] });
  assert.equal(checkItem({ clues: pack.items[0].clues.slice(0, 3) }), false);
  assert.equal(checkItem({ clues: [...pack.items[0].clues, 'Пятая подсказка'] }), false);
  assert.equal(checkItem({ clues: Array(4).fill('Одна и та же подсказка') }), false);
  assert.equal(checkItem({ id: 'clues-1' }), false);
  assert.equal(checkItem({ answer: 'я'.repeat(81) }), false);
  assert.equal(checkItem({ aliases: [''] }), false);
  assert.equal(checkItem({ answer: 'Ответ', unsupported: true }), false);
});
