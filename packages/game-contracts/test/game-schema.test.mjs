import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import Ajv from 'ajv';
import { compile } from 'json-schema-to-typescript';
const schema = JSON.parse(
  await readFile(new URL('../schemas/rooms-v2.schema.json', import.meta.url), 'utf8'),
);
const examples = JSON.parse(
  await readFile(new URL('../examples/rooms-v2.json', import.meta.url), 'utf8'),
);
const ajv = new Ajv({ strict: true });
ajv.addSchema(schema);
test('game v2 contracts enforce own actor, phases of payloads and bounds', () => {
  for (const [name, example] of Object.entries(examples)) {
    const validate = ajv.compile({ $ref: `${schema.$id}#/$defs/${name}` });
    assert.ok(validate(example), ajv.errorsText(validate.errors));
    assert.equal(validate({ ...example, protocolVersion: 1 }), false);
    assert.equal(validate({ ...example, playerId: 'foreign' }), false);
  }
  const validate = ajv.compile({ $ref: `${schema.$id}#/$defs/GameCommand` });
  for (const minutes of [2, 16, 3.5])
    assert.equal(
      validate({
        ...examples.GameCommand,
        type: 'spy.start',
        payload: { packId: 'spy-ru-base', discussionMinutes: minutes },
      }),
      false,
    );
});
test('v2 generated TS, Dart and OpenAPI stay aligned', async () => {
  const expected = await compile(schema, 'RoomsV2', {
    unreachableDefinitions: true,
    ignoreMinAndMaxItems: true,
    style: { singleQuote: true, trailingComma: 'all', printWidth: 100 },
  });
  assert.equal(
    await readFile(new URL('../generated/rooms-v2.d.ts', import.meta.url), 'utf8'),
    expected,
  );
  const dart = await readFile(
    new URL('../../../apps/mobile/lib/src/rooms/generated/room_game_schema.dart', import.meta.url),
    'utf8',
  );
  assert.ok(dart.includes(JSON.stringify(schema, null, 2)));
  const api = JSON.parse(
    await readFile(new URL('../openapi-rooms-v2.json', import.meta.url), 'utf8'),
  );
  assert.deepEqual(
    api.components.schemas,
    JSON.parse(JSON.stringify(schema.$defs).replaceAll('#/$defs/', '#/components/schemas/')),
  );
});
