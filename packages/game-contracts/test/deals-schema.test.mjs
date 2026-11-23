import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import Ajv from 'ajv';
import { compile } from 'json-schema-to-typescript';

const read = (name) => readFile(new URL(name, import.meta.url), 'utf8');
const schema = JSON.parse(await read('../schemas/rooms-v7.schema.json'));
const examples = JSON.parse(await read('../examples/rooms-v7.json'));
const ajv = new Ajv({ strict: true }).addSchema(schema);
const validator = (name) => ajv.compile({ $ref: `${schema.$id}#/$defs/${name}` });

test('v7 examples preserve v6 mechanics and validate the deals wire format', () => {
  for (const [name, example] of Object.entries(examples)) {
    const validate = validator(name);
    assert.ok(validate(example), `${name}: ${ajv.errorsText(validate.errors)}`);
  }
  const command = examples.V7Command;
  const validate = validator('V7Command');
  assert.ok(validate({ ...command, type: 'truth.bet', payload: { answer: false, stake: 2 } }));
  assert.equal(validate({ ...command, protocolVersion: 6 }), false);
  for (const payload of [
    { ...command.payload, price: 16 },
    { ...command.payload, price: 2.5 },
    { ...command.payload, sellerId: 'x' },
    { ...command.payload, buyerId: command.payload.sellerId },
  ]) {
    assert.equal(validate({ ...command, payload }), false);
  }
  const validateSnapshot = validator('V7Snapshot');
  const snapshot = structuredClone(examples.V7Snapshot);
  snapshot.publicState.deals.lots[0].item = snapshot.publicState.deals.market[0].item;
  assert.equal(validateSnapshot(snapshot), false, 'closed lot cannot carry its item');
});

test('v7 generated TypeScript, Dart and OpenAPI match the schema', async () => {
  assert.equal(
    await read('../generated/rooms-v7.d.ts'),
    await compile(schema, 'RoomsV7', {
      unreachableDefinitions: true,
      ignoreMinAndMaxItems: true,
      style: { singleQuote: true, trailingComma: 'all', printWidth: 100 },
    }),
  );
  const dart = await read('../../../apps/mobile/lib/src/rooms/generated/room_deals_schema.dart');
  assert.ok(dart.includes(JSON.stringify(schema, null, 2)));
  const api = JSON.parse(await read('../openapi-rooms-v7.json'));
  assert.deepEqual(
    api.components.schemas,
    JSON.parse(JSON.stringify(schema.$defs).replaceAll('#/$defs/', '#/components/schemas/')),
  );
});
