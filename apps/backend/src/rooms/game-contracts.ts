import { readFileSync } from 'node:fs';
import { Ajv } from 'ajv';
import type { GameCommand, V2Enrollment } from '@partybox/game-contracts/rooms-v2';
import { RoomError } from './room-error.js';
const schema = JSON.parse(
  readFileSync(
    new URL(import.meta.resolve('@partybox/game-contracts/rooms-v2.schema.json')),
    'utf8',
  ),
);
const ajv = new Ajv({ strict: true });
ajv.addSchema(schema);
const command = ajv.compile<GameCommand>({ $ref: `${schema.$id}#/$defs/GameCommand` });
const enrollment = ajv.compile<V2Enrollment>({ $ref: `${schema.$id}#/$defs/V2Enrollment` });
export function parseGameCommand(value: unknown) {
  if (!command(value)) throw new RoomError('INVALID_REQUEST', 400);
  return value;
}
export function parseGameEnrollment(value: unknown) {
  if (!enrollment(value)) throw new RoomError('INVALID_REQUEST', 400);
  return { ...value, protocolVersion: 1 as const };
}
