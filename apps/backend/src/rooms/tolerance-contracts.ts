import { readFileSync } from 'node:fs';
import { Ajv } from 'ajv';
import type { V3Command, V3Enrollment } from '@partybox/game-contracts/rooms-v3';
import { RoomError } from './room-error.js';
const schema = JSON.parse(
  readFileSync(
    new URL(import.meta.resolve('@partybox/game-contracts/rooms-v3.schema.json')),
    'utf8',
  ),
);
const ajv = new Ajv({ strict: true });
ajv.addSchema(schema);
const command = ajv.compile<V3Command>({ $ref: `${schema.$id}#/$defs/V3Command` });
const enrollment = ajv.compile<V3Enrollment>({ $ref: `${schema.$id}#/$defs/V3Enrollment` });
export function parseV3Command(value: unknown) {
  if (!command(value)) throw new RoomError('INVALID_REQUEST', 400);
  return value;
}
export function parseV3Enrollment(value: unknown) {
  if (!enrollment(value)) throw new RoomError('INVALID_REQUEST', 400);
  return { ...value, protocolVersion: 1 as const };
}
