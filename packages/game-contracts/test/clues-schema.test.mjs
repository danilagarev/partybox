import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import Ajv from 'ajv';
import { compile } from 'json-schema-to-typescript';
const read = async (name) => JSON.parse(await readFile(new URL(name, import.meta.url), 'utf8'));
const schema = await read('../schemas/rooms-v4.schema.json');
const examples = await read('../examples/rooms-v4.json');
const ajv = new Ajv({ strict: true });
ajv.addSchema(schema);
test('v4 examples and private commands enforce protocol, actors and bounds', () => {
  for (const [name, example] of Object.entries(examples)) {
    const validate = ajv.compile({ $ref: `${schema.$id}#/$defs/${name}` });
    assert.ok(validate(example), `${name}: ${ajv.errorsText(validate.errors)}`);
    assert.equal(validate({ ...example, actorId: 'foreign' }), false);
    assert.equal(validate({ ...example, protocolVersion: 2 }), false);
  }
  const validate = ajv.compile({ $ref: `${schema.$id}#/$defs/V4Command` });
  const base = examples.V4Command;
  assert.ok(
    validate({ ...base, type: 'clues.answer', payload: { answer: 'Музей', clueIndex: 0 } }),
  );
  for (const clueIndex of [-1, 4, 0.5, '1'])
    assert.equal(
      validate({ ...base, type: 'clues.answer', payload: { answer: 'Музей', clueIndex } }),
      false,
    );
  for (const answer of ['', ' '.repeat(3), 'x'.repeat(121)])
    assert.equal(
      validate({ ...base, type: 'clues.answer', payload: { answer, clueIndex: 0 } }),
      false,
    );
});
test('v4 generated TS, Dart and OpenAPI match their schema', async () => {
  const expected = await compile(schema, 'RoomsV4', {
    unreachableDefinitions: true,
    ignoreMinAndMaxItems: true,
    style: { singleQuote: true, trailingComma: 'all', printWidth: 100 },
  });
  assert.equal(
    await readFile(new URL('../generated/rooms-v4.d.ts', import.meta.url), 'utf8'),
    expected,
  );
  const dart = await readFile(
    new URL('../../../apps/mobile/lib/src/rooms/generated/room_clues_schema.dart', import.meta.url),
    'utf8',
  );
  assert.ok(dart.includes(JSON.stringify(schema, null, 2)));
  const api = await read('../openapi-rooms-v4.json');
  assert.deepEqual(
    api.components.schemas,
    JSON.parse(JSON.stringify(schema.$defs).replaceAll('#/$defs/', '#/components/schemas/')),
  );
});
