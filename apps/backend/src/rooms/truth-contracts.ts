import { readFileSync } from 'node:fs';
import { Ajv } from 'ajv';
import type { V6Command, V6Enrollment } from '@partybox/game-contracts/rooms-v6';
import { RoomError } from './room-error.js';
const schema = JSON.parse(
  readFileSync(
    new URL(import.meta.resolve('@partybox/game-contracts/rooms-v6.schema.json')),
    'utf8',
  ),
);
const ajv = new Ajv({ strict: true });
ajv.addSchema(schema);
const command = ajv.compile<V6Command>({ $ref: `${schema.$id}#/$defs/V6Command` });
const enrollment = ajv.compile<V6Enrollment>({ $ref: `${schema.$id}#/$defs/V6Enrollment` });
export function parseV6Command(value: unknown) {
  if (!command(value)) throw new RoomError('INVALID_REQUEST', 400);
  return value;
}
export function parseV6Enrollment(value: unknown) {
  if (!enrollment(value)) throw new RoomError('INVALID_REQUEST', 400);
  return { ...value, protocolVersion: 1 as const };
}
