import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import Ajv from 'ajv';
import { compile } from 'json-schema-to-typescript';
const read = async (name) => JSON.parse(await readFile(new URL(name, import.meta.url), 'utf8'));
const schema = await read('../schemas/rooms-v6.schema.json');
const examples = await read('../examples/rooms-v6.json');
const ajv = new Ajv({ strict: true });
ajv.addSchema(schema);
test('v6 examples and private commands enforce protocol, actors and bounds', () => {
  for (const [name, example] of Object.entries(examples)) {
    const validate = ajv.compile({ $ref: `${schema.$id}#/$defs/${name}` });
    assert.ok(validate(example), `${name}: ${ajv.errorsText(validate.errors)}`);
    assert.equal(validate({ ...example, actorId: 'foreign' }), false);
    assert.equal(validate({ ...example, protocolVersion: 5 }), false);
  }
  const validate = ajv.compile({ $ref: `${schema.$id}#/$defs/V6Command` });
  const base = examples.V6Command;
  for (const payload of [
    { answer: 1, stake: 2 },
    { answer: false },
    { answer: true, stake: 4 },
    { answer: true, stake: 1.5 },
    { answer: true, stake: 3, actorId: 'foreign' },
  ]) {
    assert.equal(validate({ ...base, payload }), false);
  }
  for (const topics of [[], ['human'], ['animals', 'everyday']]) {
    assert.ok(validate({ ...base, type: 'truth.start', payload: { topics } }));
  }
  for (const topics of [['human', 'human'], ['invented']]) {
    assert.equal(validate({ ...base, type: 'truth.start', payload: { topics } }), false);
  }
  const snapshot = examples.V6Snapshot;
  const validateSnapshot = ajv.compile({ $ref: `${schema.$id}#/$defs/V6Snapshot` });
  const { privateTruth, ...withoutPrivate } = snapshot;
  assert.equal(validateSnapshot(withoutPrivate), false);
  for (const field of ['cardId', 'explanation', 'answer', 'truth', 'sources']) {
    assert.equal(
      validateSnapshot({
        ...snapshot,
        publicState: {
          ...snapshot.publicState,
          truth: { ...snapshot.publicState.truth, [field]: 'leak' },
        },
      }),
      false,
    );
  }
});
test('v6 generated TS, Dart and OpenAPI match their schema', async () => {
  const expected = await compile(schema, 'RoomsV6', {
    unreachableDefinitions: true,
    ignoreMinAndMaxItems: true,
    style: { singleQuote: true, trailingComma: 'all', printWidth: 100 },
  });
  assert.equal(
    await readFile(new URL('../generated/rooms-v6.d.ts', import.meta.url), 'utf8'),
    expected,
  );
  const dart = await readFile(
    new URL('../../../apps/mobile/lib/src/rooms/generated/room_truth_schema.dart', import.meta.url),
    'utf8',
  );
  assert.ok(dart.includes(JSON.stringify(schema, null, 2)));
  const api = await read('../openapi-rooms-v6.json');
  assert.deepEqual(
    api.components.schemas,
    JSON.parse(JSON.stringify(schema.$defs).replaceAll('#/$defs/', '#/components/schemas/')),
  );
});
