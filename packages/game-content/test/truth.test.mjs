import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import Ajv from 'ajv';

const pack = JSON.parse(await readFile(new URL('../packs/truth-ru-base.json', import.meta.url)));
const schema = JSON.parse(
  await readFile(new URL('../../game-contracts/schemas/truth-pack.schema.json', import.meta.url)),
);
const validate = new Ajv({ allErrors: true, strict: true }).compile(schema);
const topicIds = ['animals', 'human', 'food', 'history', 'science', 'everyday'];
const normalize = (value) =>
  value
    .toLocaleLowerCase('ru')
    .replaceAll('ё', 'е')
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .trim();

test('truth release pack has 30 unique cards in each of its six supported topics', () => {
  assert.ok(validate(pack), JSON.stringify(validate.errors));
  assert.deepEqual(pack.topics.map((topic) => topic.id).sort(), [...topicIds].sort());
  assert.equal(pack.items.length, 180);
  assert.equal(new Set(pack.items.map((item) => item.id)).size, pack.items.length);
  assert.equal(
    new Set(pack.items.map((item) => normalize(item.statement))).size,
    pack.items.length,
  );

  for (const topic of topicIds) {
    const items = pack.items.filter((item) => item.topic === topic);
    assert.equal(items.length, 30, topic);
    assert.equal(items.filter((item) => item.truth).length, 15, topic);
  }
});

test('truth cards have usable source links, explanations, and calendar dates', () => {
  for (const item of pack.items) {
    const checkedAt = new Date(item.checkedAt);
    assert.equal(checkedAt.toISOString().slice(0, 10), item.checkedAt, item.id);
    assert.ok(normalize(item.statement), item.id);
    assert.ok(normalize(item.explanation), item.id);
    assert.notEqual(normalize(item.explanation), normalize(item.statement), item.id);
    assert.equal(
      new Set(item.sources.map((source) => source.url)).size,
      item.sources.length,
      item.id,
    );
    for (const source of item.sources) {
      assert.ok(source.title.trim(), item.id);
      const url = new URL(source.url);
      assert.equal(url.protocol, 'https:', item.id);
      assert.ok(url.hostname.includes('.'), item.id);
      assert.equal(url.username, '', item.id);
      assert.equal(url.password, '', item.id);
    }
  }
});

test('truth schema rejects unknown games or topics and malformed cards or citations', () => {
  const first = pack.items[0];
  const check = (changes) =>
    validate({ ...pack, items: [{ ...first, ...changes }, ...pack.items.slice(1)] });
  assert.equal(validate({ ...pack, schemaVersion: 2 }), false);
  assert.equal(validate({ ...pack, gameId: 'spy' }), false);
  assert.equal(check({ topic: 'water' }), false);
  assert.equal(check({ truth: 'true' }), false);
  assert.equal(check({ sources: [] }), false);
  assert.equal(check({ sources: [{ title: 'Источник', url: 'http://example.org/' }] }), false);
  assert.equal(check({ checkedAt: '2026-23-11' }), false);
});
