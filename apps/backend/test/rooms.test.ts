import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { test } from 'node:test';
import pg from 'pg';
import { io, type Socket } from 'socket.io-client';
import { Ajv } from 'ajv';
import { readFileSync } from 'node:fs';
import type {
  Enrollment,
  EnrollmentResult,
  Snapshot,
  LeaveRoom,
} from '@partybox/game-contracts/rooms-v1';
import { createApp } from '../src/bootstrap.js';
import { migrate } from '../src/rooms/migrate.js';
import { RoomService } from '../src/rooms/room-service.js';
import { RoomError } from '../src/rooms/room-error.js';

const enrollmentKey = () => randomBytes(32).toString('base64url');
const secret = 'ab'.repeat(32); // Synthetic test key, never a deployed credential.
const enrollment = (name = 'Игрок'): Enrollment => ({
  protocolVersion: 1,
  requestId: randomUUID(),
  retryKey: enrollmentKey(),
  name,
});
const leave = (expectedVersion: number): LeaveRoom => ({
  protocolVersion: 1,
  commandId: randomUUID(),
  expectedVersion,
  type: 'room.leave',
  payload: {},
});
const code = (expected: string) => (error: unknown) =>
  error instanceof RoomError && error.code === expected;
const schema = JSON.parse(
  readFileSync(
    new URL(import.meta.resolve('@partybox/game-contracts/rooms-v1.schema.json')),
    'utf8',
  ),
);
const ajv = new Ajv({ strict: true });
ajv.addSchema(schema);
const validSnapshot = ajv.compile({ $ref: `${schema.$id}#/$defs/Snapshot` });

function snapshotEvent(socket: Socket, minimumVersion = 1): Promise<Snapshot> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error('Snapshot timeout'));
    }, 5000);
    const receive = (snapshot: Snapshot) => {
      if (snapshot.version < minimumVersion) return;
      cleanup();
      resolve(snapshot);
    };
    const failed = (error: Error) => {
      cleanup();
      reject(error);
    };
    function cleanup() {
      clearTimeout(timer);
      socket.off('room.snapshot', receive);
      socket.off('connect_error', failed);
    }
    socket.on('room.snapshot', receive);
    socket.on('connect_error', failed);
  });
}

test(
  'PostgreSQL rooms: transactions, tokens, TTL, HTTP and Socket.IO',
  { skip: !process.env.TEST_DATABASE_URL },
  async (t) => {
    const admin = new pg.Pool({ connectionString: process.env.TEST_DATABASE_URL });
    const namespace = `pb_test_${randomUUID().replaceAll('-', '')}`;
    await admin.query(`CREATE SCHEMA ${namespace}`);
    const url = new URL(process.env.TEST_DATABASE_URL!);
    url.searchParams.set('options', `-c search_path=${namespace}`);
    const databaseUrl = url.toString();
    const pool = new pg.Pool({ connectionString: databaseUrl, max: 10 });
    try {
      await assert.rejects(new RoomService(pool, secret).ready());
      await migrate(pool);
      await migrate(pool);
      const instant = new Date();
      const service = new RoomService(pool, secret, () => instant);
      await t.test(
        'readiness requires migration; TTL cleanup preserves active rooms and cascades receipts',
        async () => {
          await service.ready();
          let now = new Date();
          const timed = new RoomService(pool, secret, () => now);
          const old = await timed.enroll(enrollment());
          await timed.rateLimit('cleanup-case', 'join', 10);
          now = new Date(Date.parse(old.snapshot.publicState.expiresAt));
          const fresh = await timed.enroll(enrollment());
          const cleaned = await timed.cleanupExpired();
          assert.ok(cleaned.roomIds.includes(old.snapshot.roomId));
          assert.ok(!cleaned.roomIds.includes(fresh.snapshot.roomId));
          const receipts = await pool.query(
            'SELECT count(*)::int AS count FROM pb_enrollments WHERE room_id=$1',
            [old.snapshot.roomId],
          );
          assert.equal(receipts.rows[0].count, 0);
          await assert.rejects(
            timed.snapshot(old.snapshot.roomId, old.guestToken),
            code('ROOM_UNAVAILABLE'),
          );
          assert.equal(
            (await timed.snapshot(fresh.snapshot.roomId, fresh.guestToken)).publicState.players
              .length,
            1,
          );
          assert.ok(cleaned.rateLimits >= 1);
        },
      );
      await t.test(
        'enrollment retries survive a new service and only return the owning token',
        async () => {
          const request = enrollment('  Игрок 1  ');
          const first = await service.enroll(request);
          const again = await new RoomService(pool, secret, () => instant).enroll(request);
          assert.equal(again.guestToken, first.guestToken);
          assert.equal(again.snapshot.version, 1);
          assert.equal(again.snapshot.publicState.players[0]!.name, 'Игрок 1');
          assert.equal(
            Date.parse(first.snapshot.publicState.expiresAt) -
              Date.parse(first.snapshot.serverTime),
            86_400_000,
          );
          await assert.rejects(
            service.enroll({ ...request, retryKey: enrollmentKey() }),
            code('COMMAND_CONFLICT'),
          );
          await assert.rejects(
            service.enroll({ ...request, name: 'Другой' }),
            code('COMMAND_CONFLICT'),
          );
          await assert.rejects(
            service.snapshot(first.snapshot.roomId, enrollmentKey()),
            code('UNAUTHORIZED'),
          );
          const raw = await pool.query('SELECT state FROM pb_rooms WHERE id=$1', [
            first.snapshot.roomId,
          ]);
          assert.ok(!JSON.stringify(raw.rows).includes(first.guestToken));
          assert.ok(!JSON.stringify(raw.rows).includes(request.retryKey));
          assert.ok(validSnapshot(first.snapshot));
          assert.deepEqual(
            Object.keys(first.snapshot).sort(),
            [
              'protocolVersion',
              'roomId',
              'version',
              'serverTime',
              'publicState',
              'privateState',
              'selfId',
            ].sort(),
          );
        },
      );
      await t.test(
        'four members, host transfer, stale command, replay after later changes, token revocation',
        async () => {
          const host = await service.enroll(enrollment());
          const roomId = host.snapshot.roomId;
          const pin = host.snapshot.publicState.pin;
          const members = [host];
          for (let i = 0; i < 3; i++) members.push(await service.enroll(enrollment(), pin));
          const command = leave(4);
          const ack = await service.leave(roomId, host.guestToken, command);
          assert.equal(ack.version, 5);
          const next = await service.snapshot(roomId, members[1]!.guestToken);
          assert.equal(next.publicState.hostId, members[1]!.snapshot.selfId);
          assert.equal(next.publicState.players.length, 3);
          await assert.rejects(service.snapshot(roomId, host.guestToken), code('UNAUTHORIZED'));
          await assert.rejects(
            service.leave(roomId, members[1]!.guestToken, leave(4)),
            code('VERSION_CONFLICT'),
          );
          await service.leave(roomId, members[3]!.guestToken, leave(5));
          assert.deepEqual(await service.leave(roomId, host.guestToken, command), ack);
          await assert.rejects(
            service.leave(roomId, host.guestToken, { ...command, expectedVersion: 99 }),
            code('COMMAND_CONFLICT'),
          );
          await service.leave(roomId, members[1]!.guestToken, leave(6));
          const lastCommand = leave(7);
          const last = await service.leave(roomId, members[2]!.guestToken, lastCommand);
          assert.deepEqual(await service.leave(roomId, members[2]!.guestToken, lastCommand), last);
          await assert.rejects(service.enroll(enrollment(), pin), code('ROOM_UNAVAILABLE'));
        },
      );
      await t.test('concurrent enrollment and commands serialize at room version', async () => {
        const host = await service.enroll(enrollment());
        const pin = host.snapshot.publicState.pin;
        const request = enrollment();
        const retries = await Promise.all([
          service.enroll(request, pin),
          service.enroll(request, pin),
        ]);
        assert.equal(retries[0]!.snapshot.selfId, retries[1]!.snapshot.selfId);
        for (let i = 0; i < 9; i++) await service.enroll(enrollment(), pin);
        const race = await Promise.allSettled([
          service.enroll(enrollment(), pin),
          service.enroll(enrollment(), pin),
        ]);
        assert.equal(race.filter((r) => r.status === 'fulfilled').length, 1);
        const failure = race.find((r) => r.status === 'rejected');
        assert.equal(failure?.status === 'rejected' && failure.reason.code, 'ROOM_FULL');
        const snapshot = await service.snapshot(host.snapshot.roomId, host.guestToken);
        assert.equal(snapshot.publicState.players.length, 12);
        assert.equal(snapshot.version, 12);
        const commands = await Promise.allSettled([
          service.leave(snapshot.roomId, host.guestToken, leave(12)),
          service.leave(snapshot.roomId, retries[0]!.guestToken, leave(12)),
        ]);
        assert.equal(commands.filter((r) => r.status === 'fulfilled').length, 1);
        const conflict = commands.find((r) => r.status === 'rejected');
        assert.equal(conflict?.status === 'rejected' && conflict.reason.code, 'VERSION_CONFLICT');
      });
      await t.test('TTL boundary, expired tokens and persistent rate limits', async () => {
        let now = new Date();
        const clocked = new RoomService(pool, secret, () => now);
        const room = await clocked.enroll(enrollment());
        now = new Date(Date.parse(room.snapshot.publicState.expiresAt) - 1);
        await clocked.snapshot(room.snapshot.roomId, room.guestToken);
        now = new Date(now.getTime() + 1);
        await assert.rejects(
          clocked.snapshot(room.snapshot.roomId, room.guestToken),
          code('ROOM_EXPIRED'),
        );
        await assert.rejects(
          clocked.enroll(enrollment(), room.snapshot.publicState.pin),
          code('ROOM_UNAVAILABLE'),
        );
        await assert.rejects(
          clocked.leave(room.snapshot.roomId, room.guestToken, leave(1)),
          code('ROOM_EXPIRED'),
        );
        await clocked.rateLimit('test-address', 'join', 2);
        await clocked.rateLimit('test-address', 'join', 2);
        await assert.rejects(
          new RoomService(pool, secret, () => now).rateLimit('test-address', 'join', 2),
          code('RATE_LIMITED'),
        );
        now = new Date(now.getTime() + 60_000);
        await clocked.rateLimit('test-address', 'join', 2);
      });
      await t.test(
        'HTTP clients and authorized realtime snapshots restore across application restart',
        async () => {
          let app = await createApp({ databaseUrl, tokenSecret: secret });
          const sockets: Socket[] = [];
          try {
            await app.listen(0, '127.0.0.1');
            let origin = await app.getUrl();
            const post = async (path: string, body: unknown, token?: string) =>
              fetch(`${origin}${path}`, {
                method: 'POST',
                headers: {
                  'Content-Type': 'application/json',
                  ...(token ? { Authorization: `Bearer ${token}` } : {}),
                },
                body: JSON.stringify(body),
              });
            const hostRequest = enrollment('Ведущий');
            const response = await post('/rooms', hostRequest);
            assert.equal(response.status, 201);
            assert.equal(response.headers.get('cache-control'), 'no-store');
            const host = (await response.json()) as EnrollmentResult;
            const roomId = host.snapshot.roomId;
            const pin = host.snapshot.publicState.pin;
            const members = [host];
            const connect = (member: EnrollmentResult) => {
              const socket = io(origin, {
                auth: { roomId, guestToken: member.guestToken },
                autoConnect: false,
                reconnection: false,
              });
              sockets.push(socket);
              return socket;
            };
            const hostSocket = connect(host);
            const initial = snapshotEvent(hostSocket);
            hostSocket.connect();
            assert.equal((await initial).selfId, host.snapshot.selfId);
            for (let i = 0; i < 3; i++) {
              const update = snapshotEvent(hostSocket, i + 2);
              const joined = await post(`/rooms/join/${pin}`, enrollment());
              assert.equal(joined.status, 201);
              members.push((await joined.json()) as EnrollmentResult);
              assert.equal((await update).publicState.players.length, i + 2);
            }
            for (const member of members.slice(1)) {
              const socket = connect(member);
              const event = snapshotEvent(socket);
              socket.connect();
              const view = await event;
              assert.ok(validSnapshot(view));
              assert.equal(view.selfId, member.snapshot.selfId);
              assert.equal(view.privateState, null);
              assert.equal(view.version, 4);
              assert.ok(!JSON.stringify(view).includes(host.guestToken));
            }
            const wrong = io(origin, {
              auth: { roomId, guestToken: enrollmentKey() },
              autoConnect: false,
              reconnection: false,
            });
            sockets.push(wrong);
            const denied = new Promise<string>((resolve) =>
              wrong.once('connect_error', (error) => resolve(error.message)),
            );
            wrong.connect();
            assert.equal(await denied, 'UNAUTHORIZED');
            const invalid = await post('/rooms', {
              ...enrollment(),
              playerId: host.snapshot.selfId,
            });
            assert.equal(invalid.status, 400);
            assert.equal(
              (await post('/rooms', { ...enrollment(), name: '\u0000name' })).status,
              400,
            );
            assert.equal((await post('/rooms', { ...enrollment(), name: '\ud800' })).status, 400);
            assert.equal(
              (await post('/rooms', { ...enrollment(), name: 'x'.repeat(9000) })).status,
              413,
            );
            assert.equal((await fetch(`${origin}/rooms/${roomId}`)).status, 401);
            assert.equal(
              (
                await fetch(`${origin}/rooms/${roomId}`, {
                  headers: { Authorization: `Bearer ${enrollmentKey()}` },
                })
              ).status,
              401,
            );
            // Disconnect does not alter host or membership.
            hostSocket.disconnect();
            hostSocket.connect();
            const afterReconnect = await snapshotEvent(hostSocket);
            assert.equal(afterReconnect.version, 4);
            assert.equal(afterReconnect.publicState.hostId, host.snapshot.selfId);
            const nextSocket = sockets[1]!;
            const changed = snapshotEvent(nextSocket, 5);
            const cmd = leave(4);
            const result = await post(`/rooms/${roomId}/commands`, cmd, host.guestToken);
            assert.equal(result.status, 201);
            const ack = await result.json();
            assert.equal((await changed).publicState.hostId, members[1]!.snapshot.selfId);
            assert.deepEqual(
              await (await post(`/rooms/${roomId}/commands`, cmd, host.guestToken)).json(),
              ack,
            );
            assert.equal(
              (
                await fetch(`${origin}/rooms/${roomId}`, {
                  headers: { Authorization: `Bearer ${host.guestToken}` },
                })
              ).status,
              401,
            );
            await app.close();
            app = await createApp({ databaseUrl, tokenSecret: secret });
            await app.listen(0, '127.0.0.1');
            origin = await app.getUrl();
            const restored = await fetch(`${origin}/rooms/${roomId}`, {
              headers: { Authorization: `Bearer ${members[1]!.guestToken}` },
            });
            assert.equal(restored.status, 200);
            assert.equal(((await restored.json()) as Snapshot).version, 5);
            const rejoined = connect(members[1]!);
            const event = snapshotEvent(rejoined);
            rejoined.connect();
            assert.equal((await event).version, 5);
            for (let attempt = 0; attempt < 27; attempt++)
              await post('/rooms/join/000000', enrollment());
            const limited = await post('/rooms/join/000000', enrollment());
            assert.equal(limited.status, 429);
            assert.deepEqual(await limited.json(), { protocolVersion: 1, code: 'RATE_LIMITED' });
          } finally {
            for (const socket of sockets) socket.disconnect();
            await app.close();
          }
        },
      );
    } finally {
      await pool.end();
      await admin.query(`DROP SCHEMA ${namespace} CASCADE`);
      await admin.end();
    }
  },
);
