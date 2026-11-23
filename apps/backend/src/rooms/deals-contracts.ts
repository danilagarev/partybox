import { readFileSync } from 'node:fs';
import { Ajv } from 'ajv';
import type { V7Command, V7Enrollment } from '@partybox/game-contracts/rooms-v7';
import { RoomError } from './room-error.js';
const schema = JSON.parse(
  readFileSync(
    new URL(import.meta.resolve('@partybox/game-contracts/rooms-v7.schema.json')),
    'utf8',
  ),
);
const ajv = new Ajv({ strict: true });
ajv.addSchema(schema);
const command = ajv.compile<V7Command>({ $ref: `${schema.$id}#/$defs/V7Command` });
const enrollment = ajv.compile<V7Enrollment>({ $ref: `${schema.$id}#/$defs/V7Enrollment` });
export function parseV7Command(value: unknown) {
  if (!command(value)) throw new RoomError('INVALID_REQUEST', 400);
  return value;
}
export function parseV7Enrollment(value: unknown) {
  if (!enrollment(value)) throw new RoomError('INVALID_REQUEST', 400);
  return { ...value, protocolVersion: 1 as const };
}
