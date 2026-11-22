import { readFileSync } from 'node:fs';
import { Ajv } from 'ajv';
import type { V5Command, V5Enrollment } from '@partybox/game-contracts/rooms-v5';
import { RoomError } from './room-error.js';
const schema = JSON.parse(
  readFileSync(
    new URL(import.meta.resolve('@partybox/game-contracts/rooms-v5.schema.json')),
    'utf8',
  ),
);
const ajv = new Ajv({ strict: true });
ajv.addSchema(schema);
const command = ajv.compile<V5Command>({ $ref: `${schema.$id}#/$defs/V5Command` });
const enrollment = ajv.compile<V5Enrollment>({ $ref: `${schema.$id}#/$defs/V5Enrollment` });
export function parseV5Command(value: unknown) {
  if (!command(value)) throw new RoomError('INVALID_REQUEST', 400);
  return value;
}
export function parseV5Enrollment(value: unknown) {
  if (!enrollment(value)) throw new RoomError('INVALID_REQUEST', 400);
  return { ...value, protocolVersion: 1 as const };
}
