import { readFileSync } from 'node:fs';
import { Ajv } from 'ajv';
import type { V4Command, V4Enrollment } from '@partybox/game-contracts/rooms-v4';
import { RoomError } from './room-error.js';
const schema = JSON.parse(
  readFileSync(
    new URL(import.meta.resolve('@partybox/game-contracts/rooms-v4.schema.json')),
    'utf8',
  ),
);
const ajv = new Ajv({ strict: true });
ajv.addSchema(schema);
const command = ajv.compile<V4Command>({ $ref: `${schema.$id}#/$defs/V4Command` });
const enrollment = ajv.compile<V4Enrollment>({ $ref: `${schema.$id}#/$defs/V4Enrollment` });
export function parseV4Command(value: unknown) {
  if (!command(value)) throw new RoomError('INVALID_REQUEST', 400);
  return value;
}
export function parseV4Enrollment(value: unknown) {
  if (!enrollment(value)) throw new RoomError('INVALID_REQUEST', 400);
  return { ...value, protocolVersion: 1 as const };
}
