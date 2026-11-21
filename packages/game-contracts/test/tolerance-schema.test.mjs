import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import Ajv from 'ajv';
import { compile } from 'json-schema-to-typescript';
const read = async (name) => JSON.parse(await readFile(new URL(name, import.meta.url), 'utf8'));
const schema = await read('../schemas/rooms-v3.schema.json');
const examples = await read('../examples/rooms-v3.json');
const ajv = new Ajv({ strict: true });
ajv.addSchema(schema);
test('v3 examples and private commands enforce protocol, actors and bounds', () => {
  for (const [name, example] of Object.entries(examples)) {
    const validate = ajv.compile({ $ref: `${schema.$id}#/$defs/${name}` });
    assert.ok(validate(example), `${name}: ${ajv.errorsText(validate.errors)}`);
    assert.equal(validate({ ...example, actorId: 'foreign' }), false);
    assert.equal(validate({ ...example, protocolVersion: 2 }), false);
  }
  const validate = ajv.compile({ $ref: `${schema.$id}#/$defs/V3Command` });
  const base = examples.V3Command;
  assert.ok(
    validate({
      ...base,
      type: 'tolerance.rank',
      payload: { order: ['tolerance-01', 'tolerance-02', 'tolerance-03', 'tolerance-04'] },
    }),
  );
  for (const position of [-1, 4, 0.5, '1'])
    assert.equal(validate({ ...base, type: 'tolerance.guess', payload: { position } }), false);
  for (const position of [0, 1, 2, 3])
    assert.ok(validate({ ...base, type: 'tolerance.guess', payload: { position } }));
  assert.equal(
    validate({ ...base, type: 'tolerance.rank', payload: { order: ['tolerance-01'] } }),
    false,
  );
});
test('v3 generated TS, Dart and OpenAPI match their schema', async () => {
  const expected = await compile(schema, 'RoomsV3', {
    unreachableDefinitions: true,
    ignoreMinAndMaxItems: true,
    style: { singleQuote: true, trailingComma: 'all', printWidth: 100 },
  });
  assert.equal(
    await readFile(new URL('../generated/rooms-v3.d.ts', import.meta.url), 'utf8'),
    expected,
  );
  const dart = await readFile(
    new URL(
      '../../../apps/mobile/lib/src/rooms/generated/room_tolerance_schema.dart',
      import.meta.url,
    ),
    'utf8',
  );
  assert.ok(dart.includes(JSON.stringify(schema, null, 2)));
  const api = await read('../openapi-rooms-v3.json');
  assert.deepEqual(
    api.components.schemas,
    JSON.parse(JSON.stringify(schema.$defs).replaceAll('#/$defs/', '#/components/schemas/')),
  );
});
