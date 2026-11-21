import assert from 'node:assert/strict';
import { randomUUID, randomBytes } from 'node:crypto';
import { test } from 'node:test';
import pg from 'pg';
import { io, type Socket } from 'socket.io-client';
import { Ajv } from 'ajv';
import { readFileSync } from 'node:fs';
import type { V3Snapshot, V3EnrollmentResult, V3Command } from '@partybox/game-contracts/rooms-v3';
import { createApp } from '../src/bootstrap.js';
import { migrate } from '../src/rooms/migrate.js';
const enrollment = (protocolVersion = 3) => ({
  protocolVersion,
  requestId: randomUUID(),
  retryKey: randomBytes(32).toString('base64url'),
  name: 'Участник',
});
const schema = JSON.parse(
  readFileSync(
    new URL(import.meta.resolve('@partybox/game-contracts/rooms-v3.schema.json')),
    'utf8',
  ),
);
const ajv = new Ajv({ strict: true });
ajv.addSchema(schema);
const valid = ajv.compile<V3Snapshot>({ $ref: `${schema.$id}#/$defs/V3Snapshot` });

test(
  'v3 full party: actor privacy, voting race, retry, restart, rotation, compatibility and leave',
  { skip: !process.env.TEST_DATABASE_URL },
  async () => {
    const admin = new pg.Pool({ connectionString: process.env.TEST_DATABASE_URL });
    const namespace = `pb_tolerance_${randomUUID().replaceAll('-', '')}`;
    await admin.query(`CREATE SCHEMA ${namespace}`);
    const url = new URL(process.env.TEST_DATABASE_URL!);
    url.searchParams.set('options', `-c search_path=${namespace}`);
    const pool = new pg.Pool({ connectionString: url.toString() });
    await migrate(pool);
    const secret = 'ef'.repeat(32);
    let app = await createApp({ databaseUrl: url.toString(), tokenSecret: secret });
    let origin = '';
    const sockets: Socket[] = [];
    const post = (path: string, body: unknown, token?: string) =>
      fetch(`${origin}${path}`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
        },
        body: JSON.stringify(body),
      });
    const snapshot = async (member: V3EnrollmentResult) => {
      const response = await fetch(`${origin}/v3/rooms/${member.snapshot.roomId}`, {
        headers: { Authorization: `Bearer ${member.guestToken}` },
      });
      assert.equal(response.status, 200);
      const view = await response.json();
      assert.ok(valid(view), ajv.errorsText(valid.errors));
      return view;
    };
    const command = async (member: V3EnrollmentResult, type: string, payload: unknown = {}) => {
      const state = await snapshot(member);
      return {
        protocolVersion: 3,
        commandId: randomUUID(),
        expectedVersion: state.version,
        sessionId:
          state.publicState.tolerance?.sessionId ?? state.publicState.game?.sessionId ?? null,
        type,
        payload,
      } as V3Command;
    };
    const sendRaw = (member: V3EnrollmentResult, cmd: V3Command) =>
      post(`/v3/rooms/${member.snapshot.roomId}/commands`, cmd, member.guestToken);
    const send = async (member: V3EnrollmentResult, type: string, payload: unknown = {}) =>
      sendRaw(member, await command(member, type, payload));
    const okay = async (member: V3EnrollmentResult, type: string, payload: unknown = {}) => {
      const response = await send(member, type, payload);
      assert.equal(response.status, 201, JSON.stringify(await response.json()));
    };
    try {
      await app.listen(0, '127.0.0.1');
      origin = await app.getUrl();
      const hostRequest = enrollment();
      const host = (await (await post('/v3/rooms', hostRequest)).json()) as V3EnrollmentResult;
      const id = host.snapshot.roomId;
      const pin = host.snapshot.publicState.pin;
      assert.ok(valid(host.snapshot));
      const members = [host];
      for (let i = 0; i < 3; i++)
        members.push(
          (await (await post(`/v3/rooms/join/${pin}`, enrollment())).json()) as V3EnrollmentResult,
        );
      // Every join marks v3 capability; merely opening a v2 snapshot never downgrades it.
      await fetch(`${origin}/v2/rooms/${id}`, {
        headers: { Authorization: `Bearer ${members[1]!.guestToken}` },
      });
      assert.equal((await send(members[1]!, 'tolerance.start')).status, 403);
      await okay(host, 'tolerance.start');
      const first = await snapshot(host);
      assert.equal(first.publicState.tolerance!.heroId, host.snapshot.selfId);
      assert.equal(first.publicState.game, null);
      assert.equal(first.privateState, null);
      const latest = new Map<string, V3Snapshot>();
      await Promise.all(
        members.map(
          (member) =>
            new Promise<void>((resolve, reject) => {
              const socket = io(origin, {
                auth: { roomId: id, guestToken: member.guestToken, protocolVersion: 3 },
                reconnection: false,
              });
              sockets.push(socket);
              socket.on('room.snapshot', (value: V3Snapshot) => {
                assert.ok(valid(value));
                latest.set(value.selfId, value);
                resolve();
              });
              socket.on('connect_error', reject);
            }),
        ),
      );
      assert.equal((await post(`/v3/rooms/join/${pin}`, enrollment())).status, 409);
      const order = first.publicState.tolerance!.cards.map((c) => c.id).reverse();
      assert.equal((await send(members[1]!, 'tolerance.rank', { order })).status, 403);
      assert.equal(
        (await send(host, 'tolerance.rank', { order: [order[0], order[0], order[1], order[2]] }))
          .status,
        400,
      );
      assert.equal(
        (await send(host, 'tolerance.rank', { order: [...order.slice(0, 3), 'tolerance-99'] }))
          .status,
        400,
      );
      const ranking = await command(host, 'tolerance.rank', { order });
      const rankingResponse = await sendRaw(host, ranking);
      assert.equal(rankingResponse.status, 201);
      const rankingAck = await rankingResponse.json();
      assert.deepEqual(await (await sendRaw(host, ranking)).json(), rankingAck);
      assert.equal(
        (
          await sendRaw(host, {
            ...ranking,
            type: 'tolerance.rank',
            payload: { order: [...order].reverse() },
          })
        ).status,
        409,
      );
      const privateHero = await snapshot(host);
      assert.deepEqual(privateHero.privateTolerance!.order, order);
      for (const listener of members.slice(1)) {
        const view = await snapshot(listener);
        assert.equal(view.privateTolerance!.order, null);
        assert.equal(view.publicState.tolerance!.result, null);
        assert.equal(view.publicState.tolerance!.visibleOrder.length, 3);
      }
      assert.equal((await send(host, 'tolerance.guess', { position: 0 })).status, 403);
      assert.equal((await send(host, 'tolerance.next')).status, 409);
      assert.equal((await send(members[1]!, 'tolerance.guess', { position: 4 })).status, 400);
      const correct = order.indexOf(first.publicState.tolerance!.targetId);
      const a = await command(members[1]!, 'tolerance.guess', { position: correct });
      const b = await command(members[2]!, 'tolerance.guess', { position: (correct + 1) % 4 });
      const race = await Promise.all([sendRaw(members[1]!, a), sendRaw(members[2]!, b)]);
      assert.deepEqual(race.map((r) => r.status).sort(), [201, 409]);
      for (const listener of members.slice(1, 3)) {
        const view = await snapshot(listener);
        if (view.privateTolerance!.guess === null)
          await okay(listener, 'tolerance.guess', {
            position: listener === members[1] ? correct : (correct + 1) % 4,
          });
      }
      const hidden = await snapshot(members[3]!);
      assert.equal(hidden.publicState.tolerance!.result, null);
      assert.equal(hidden.privateTolerance!.guess, null);
      assert.equal(hidden.publicState.tolerance!.submittedIds.length, 2);
      // Restore a partial vote across a genuine backend restart.
      for (const socket of sockets) socket.disconnect();
      await app.close();
      app = await createApp({ databaseUrl: url.toString(), tokenSecret: secret });
      await app.listen(0, '127.0.0.1');
      origin = await app.getUrl();
      assert.equal((await snapshot(members[1]!)).privateTolerance!.guess, correct);
      assert.deepEqual((await snapshot(host)).privateTolerance!.order, order);
      assert.equal((await send(members[1]!, 'tolerance.guess', { position: correct })).status, 409);
      await okay(members[3]!, 'tolerance.guess', { position: correct });
      const revealed = await snapshot(host);
      assert.equal(revealed.publicState.tolerance!.phase, 'reveal');
      assert.deepEqual(revealed.publicState.tolerance!.result!.order, order);
      assert.deepEqual(
        revealed.publicState.tolerance!.scores.map((s) => s.score),
        [0, 1, 0, 1],
      );
      // Retrying an accepted command cannot award points twice, even after restart.
      assert.deepEqual(await (await sendRaw(host, ranking)).json(), rankingAck);
      assert.deepEqual(
        (await snapshot(host)).publicState.tolerance!.scores,
        revealed.publicState.tolerance!.scores,
      );
      assert.equal((await send(members[1]!, 'tolerance.next')).status, 403);
      const used = new Set(first.publicState.tolerance!.cards.map((c) => c.id));
      for (let round = 1; round < 4; round++) {
        await okay(host, 'tolerance.next');
        const view = await snapshot(host);
        const game = view.publicState.tolerance!;
        assert.equal(game.roundIndex, round);
        assert.equal(game.heroId, members[round]!.snapshot.selfId);
        const nextOrder = game.cards.map((c) => c.id);
        for (const card of nextOrder) {
          assert.ok(!used.has(card));
          used.add(card);
        }
        await okay(members[round]!, 'tolerance.rank', { order: nextOrder });
        for (const listener of members.filter((m) => m !== members[round]))
          await okay(listener, 'tolerance.guess', { position: nextOrder.indexOf(game.targetId) });
      }
      await okay(host, 'tolerance.next');
      const finished = await snapshot(host);
      assert.equal(finished.publicState.tolerance!.phase, 'finished');
      assert.ok(finished.publicState.tolerance!.winners.length > 0);
      const fifthResponse = await post(`/v3/rooms/join/${pin}`, enrollment());
      assert.equal(fifthResponse.status, 201);
      const fifth = (await fifthResponse.json()) as V3EnrollmentResult;
      assert.ok(valid(fifth.snapshot), ajv.errorsText(valid.errors));
      assert.equal(fifth.snapshot.publicState.tolerance, null);
      assert.equal(fifth.snapshot.publicState.players.length, 5);
      for (const member of [...members, fifth]) {
        const joinedView = await snapshot(member);
        assert.equal(joinedView.publicState.tolerance, null);
        assert.equal(joinedView.publicState.players.length, 5);
      }
      await okay(host, 'tolerance.start');
      assert.equal((await snapshot(fifth)).publicState.tolerance!.scores.length, 5);
      await okay(host, 'tolerance.cancel');

      await okay(host, 'spy.start', { discussionMinutes: 3, packId: 'spy-ru-base' });
      const spy = await snapshot(host);
      assert.equal(spy.publicState.tolerance, null);
      assert.equal(spy.publicState.game!.phase, 'distribution');
      await okay(host, 'spy.cancel');
      await okay(host, 'tolerance.start');
      // A v2 command may leave, and must cancel the v3 party as well.
      const beforeLeave = await snapshot(members[1]!);
      const leave = await post(
        `/v2/rooms/${id}/commands`,
        {
          protocolVersion: 2,
          commandId: randomUUID(),
          expectedVersion: beforeLeave.version,
          sessionId: null,
          type: 'room.leave',
          payload: {},
        },
        members[1]!.guestToken,
      );
      assert.equal(leave.status, 201);
      assert.equal((await snapshot(host)).publicState.tolerance, null);
      // Old guests must open v3 before another tolerance party can start.
      const oldGuest = (await (
        await post(`/v2/rooms/join/${pin}`, enrollment(2))
      ).json()) as V3EnrollmentResult;
      assert.equal((await send(host, 'tolerance.start')).status, 409);
      const oldGuestV3 = await snapshot(oldGuest);
      assert.equal(oldGuestV3.protocolVersion, 3);
      await okay(host, 'tolerance.start');
      await okay(host, 'tolerance.cancel');
      assert.equal((await snapshot(host)).publicState.tolerance, null);
      // Enrollment retries retain identity and never duplicate a member.
      const retried = (await (await post('/v3/rooms', hostRequest)).json()) as V3EnrollmentResult;
      assert.equal(retried.guestToken, host.guestToken);
      assert.equal(retried.snapshot.selfId, host.snapshot.selfId);
      await okay(host, 'tolerance.start');
      const previousSession = (await snapshot(host)).publicState.tolerance!.sessionId;
      const stale = await command(host, 'tolerance.cancel');
      assert.equal((await sendRaw(host, { ...stale, sessionId: randomUUID() })).status, 409);
      assert.equal((await snapshot(host)).publicState.tolerance!.sessionId, previousSession);
      await okay(oldGuest, 'room.leave');
      assert.equal((await snapshot(host)).publicState.tolerance, null);
      const replacement = await post(`/v3/rooms/join/${pin}`, enrollment());
      assert.equal(replacement.status, 201);
      await okay(host, 'tolerance.start');
      const beforeHostLeave = await snapshot(host);
      const v1Leave = await post(
        `/rooms/${id}/commands`,
        {
          protocolVersion: 1,
          commandId: randomUUID(),
          expectedVersion: beforeHostLeave.version,
          type: 'room.leave',
          payload: {},
        },
        host.guestToken,
      );
      assert.equal(v1Leave.status, 201);
      const afterHostLeave = await snapshot(members[2]!);
      assert.equal(afterHostLeave.publicState.tolerance, null);
      assert.equal(afterHostLeave.publicState.hostId, members[2]!.snapshot.selfId);
    } finally {
      for (const socket of sockets) socket.disconnect();
      await app.close();
      await pool.end();
      await admin.query(`DROP SCHEMA ${namespace} CASCADE`);
      await admin.end();
    }
  },
);
