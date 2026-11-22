import assert from 'node:assert/strict';
import { readdir, readFile } from 'node:fs/promises';
import { test } from 'node:test';
import Ajv from 'ajv';

const readJson = async (url) => JSON.parse(await readFile(url, 'utf8'));
const schema = await readJson(
  new URL('../../game-contracts/schemas/content-pack.schema.json', import.meta.url),
);
const validate = new Ajv({ allErrors: true, strict: true }).compile(schema);
const toleranceSchema = await readJson(
  new URL('../../game-contracts/schemas/tolerance-pack.schema.json', import.meta.url),
);
const validateTolerance = new Ajv({ allErrors: true, strict: true }).compile(toleranceSchema);
const cluesSchema = await readJson(
  new URL('../../game-contracts/schemas/clues-pack.schema.json', import.meta.url),
);
const validateClues = new Ajv({ allErrors: true, strict: true }).compile(cluesSchema);
const directory = new URL('../packs/', import.meta.url);

test('all bundled packs match the contract and have unique identifiers', async () => {
  const files = (await readdir(directory)).filter((name) => name.endsWith('.json'));
  assert.ok(files.length > 0, 'at least one starter pack is required');
  const packIds = new Set();
  for (const file of files) {
    const pack = await readJson(new URL(file, directory));
    const check =
      pack.gameId === 'clues'
        ? validateClues
        : pack.gameId === 'tolerance'
          ? validateTolerance
          : validate;
    assert.ok(check(pack), `${file}: ${JSON.stringify(check.errors)}`);
    assert.ok(!packIds.has(pack.id), `duplicate pack id: ${pack.id}`);
    packIds.add(pack.id);
    const itemIds = pack.items.map((item) => item.id);
    assert.equal(new Set(itemIds).size, itemIds.length, `${file}: duplicate item ids`);
    assert.ok(
      pack.items.every((item) => (item.label ?? item.text ?? item.answer).trim().length > 0),
    );
  }
});

test('catalog pins every bundled pack and contains no ambiguous locations', async () => {
  const catalog = await readJson(new URL('../spy-catalog.json', import.meta.url));
  const catalogSchema = await readJson(
    new URL('../../game-contracts/schemas/spy-catalog.schema.json', import.meta.url),
  );
  assert.ok(new Ajv({ strict: true }).validate(catalogSchema, catalog));
  const files = (await readdir(directory)).filter(
    (name) => name.startsWith('spy-') && name.endsWith('.json'),
  );
  assert.deepEqual(catalog.packs.map((p) => `${p.id}.json`).sort(), files.sort());
  assert.equal(new Set(catalog.packs.map((p) => p.id)).size, catalog.packs.length);
  const labels = new Set();
  assert.equal(catalog.packs.length, 3);
  for (const entry of catalog.packs) {
    const pack = await readJson(new URL(`${entry.id}.json`, directory));
    assert.equal(pack.id, entry.id);
    assert.equal(pack.version, entry.version);
    assert.equal(pack.locale, catalog.locale);
    assert.equal(pack.items.length, 60, `${entry.id}: release deck needs 60 locations`);
    for (const item of pack.items) {
      const label = item.label.trim().toLocaleLowerCase('ru');
      assert.ok(!labels.has(label), `duplicate location: ${item.id}`);
      labels.add(label);
    }
  }
});

test('tolerance deck supports twelve heroes without repeated or blank situations', async () => {
  const pack = await readJson(new URL('../packs/tolerance-ru-base.json', import.meta.url));
  assert.ok(validateTolerance(pack));
  assert.equal(pack.items.length, 220);
  assert.equal(
    new Set(pack.items.map((item) => item.text.trim().toLocaleLowerCase('ru'))).size,
    pack.items.length,
  );
  assert.equal(validateTolerance({ ...pack, schemaVersion: 2 }), false);
});

test('tolerance source schema accepts larger decks without changing legacy ids', async () => {
  const pack = await readJson(new URL('../packs/tolerance-ru-base.json', import.meta.url));
  const source = (count) => ({
    ...pack,
    items: Array.from({ length: count }, (_, index) => ({
      id: `tolerance-${String(index + 1).padStart(2, '0')}`,
      text: `Ситуация ${index + 1}`,
    })),
  });
  assert.ok(validateTolerance(source(48)), 'legacy minimum deck remains valid');
  assert.ok(validateTolerance(source(240)), 'expanded source deck is valid');
  assert.equal(validateTolerance(source(241)), false);
  assert.equal(validateTolerance(source(47)), false);
  for (const id of ['tolerance-1', 'tolerance-1000', 'tolerance-01x']) {
    const invalid = source(48);
    invalid.items[0].id = id;
    assert.equal(validateTolerance(invalid), false, `invalid source id: ${id}`);
  }
});
