import { readFileSync } from 'node:fs';
import { Ajv } from 'ajv';
import type { Enrollment, LeaveRoom } from '@partybox/game-contracts/rooms-v1';
import { RoomError } from './room-error.js';
const schema = JSON.parse(
  readFileSync(
    new URL(import.meta.resolve('@partybox/game-contracts/rooms-v1.schema.json')),
    'utf8',
  ),
);
const ajv = new Ajv({ strict: true });
ajv.addSchema(schema);
const enrollment = ajv.compile<Enrollment>({ $ref: `${schema.$id}#/$defs/Enrollment` });
const leave = ajv.compile<LeaveRoom>({ $ref: `${schema.$id}#/$defs/LeaveRoom` });
export function parseEnrollment(value: unknown): Enrollment {
  if (!enrollment(value)) throw new RoomError('INVALID_REQUEST', 400);
  return value;
}
export function parseLeave(value: unknown): LeaveRoom {
  if (!leave(value)) throw new RoomError('INVALID_REQUEST', 400);
  return value;
}
export function parseRoomId(value: string) {
  if (!/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(value))
    throw new RoomError('INVALID_REQUEST', 400);
  return value;
}
export function parseToken(value: unknown): string {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(value))
    throw new RoomError('UNAUTHORIZED', 401);
  return value;
}
export function bearer(value: string | undefined) {
  return parseToken(value?.startsWith('Bearer ') ? value.slice(7) : undefined);
}
