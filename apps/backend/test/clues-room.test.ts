import assert from 'node:assert/strict';
import { randomUUID, randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import pg from 'pg';
import { Ajv } from 'ajv';
import { io, type Socket } from 'socket.io-client';
import type { V4Command, V4Snapshot, V4EnrollmentResult } from '@partybox/game-contracts/rooms-v4';
import { createApp } from '../src/bootstrap.js';
import { migrate } from '../src/rooms/migrate.js';
const schema = JSON.parse(
  readFileSync(
    new URL(import.meta.resolve('@partybox/game-contracts/rooms-v4.schema.json')),
    'utf8',
  ),
);
const ajv = new Ajv({ strict: true });
ajv.addSchema(schema);
const valid = ajv.compile<V4Snapshot>({ $ref: `${schema.$id}#/$defs/V4Snapshot` });
const enrollment = (protocolVersion = 4) => ({
  protocolVersion,
  requestId: randomUUID(),
  retryKey: randomBytes(32).toString('base64url'),
  name: 'Тестовый игрок',
});
test(
  'v4 HTTP and WebSocket: hidden clues, complete party, concurrency, retry, restart and old-client leave',
  { skip: !process.env.TEST_DATABASE_URL },
  async () => {
    const admin = new pg.Pool({ connectionString: process.env.TEST_DATABASE_URL });
    const namespace = `pb_clues_${randomUUID().replaceAll('-', '')}`;
    await admin.query(`CREATE SCHEMA ${namespace}`);
    const url = new URL(process.env.TEST_DATABASE_URL!);
    url.searchParams.set('options', `-c search_path=${namespace}`);
    const pool = new pg.Pool({ connectionString: url.toString() });
    await migrate(pool);
    const secret = 'ce'.repeat(32);
    let app = await createApp({ databaseUrl: url.toString(), tokenSecret: secret });
    let origin = '';
    let socket: Socket | undefined;
    const post = (path: string, body: unknown, token?: string) =>
      fetch(origin + path, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
        },
        body: JSON.stringify(body),
      });
    const snapshot = async (member: V4EnrollmentResult) => {
      const r = await fetch(`${origin}/v4/rooms/${member.snapshot.roomId}`, {
        headers: { Authorization: `Bearer ${member.guestToken}` },
      });
      assert.equal(r.status, 200);
      const v = await r.json();
      assert.ok(valid(v), ajv.errorsText(valid.errors));
      return v;
    };
    const command = async (member: V4EnrollmentResult, type: string, payload: unknown = {}) => {
      const v = await snapshot(member);
      return {
        protocolVersion: 4,
        commandId: randomUUID(),
        expectedVersion: v.version,
        sessionId:
          v.publicState.clues?.sessionId ??
          v.publicState.tolerance?.sessionId ??
          v.publicState.game?.sessionId ??
          null,
        type,
        payload,
      } as V4Command;
    };
    const raw = (member: V4EnrollmentResult, cmd: V4Command) =>
      post(`/v4/rooms/${member.snapshot.roomId}/commands`, cmd, member.guestToken);
    const send = async (member: V4EnrollmentResult, type: string, payload: unknown = {}) =>
      raw(member, await command(member, type, payload));
    const okay = async (member: V4EnrollmentResult, type: string, payload: unknown = {}) => {
      const r = await send(member, type, payload);
      assert.equal(r.status, 201, JSON.stringify(await r.json()));
    };
    try {
      await app.listen(0, '127.0.0.1');
      origin = await app.getUrl();
      const hostRequest = enrollment();
      const host = (await (await post('/v4/rooms', hostRequest)).json()) as V4EnrollmentResult;
      assert.ok(valid(host.snapshot));
      assert.equal(
        ((await (await post('/v4/rooms', hostRequest)).json()) as V4EnrollmentResult).guestToken,
        host.guestToken,
      );
      const id = host.snapshot.roomId,
        pin = host.snapshot.publicState.pin;
      const members = [host];
      for (let i = 0; i < 3; i++)
        members.push(
          (await (await post(`/v4/rooms/join/${pin}`, enrollment())).json()) as V4EnrollmentResult,
        );
      assert.equal((await send(members[1]!, 'clues.start')).status, 403);
      const old = (await (
        await post(`/v3/rooms/join/${pin}`, enrollment(3))
      ).json()) as V4EnrollmentResult;
      assert.equal((await send(host, 'clues.start')).status, 409);
      await snapshot(old);
      members.push(old);
      await okay(host, 'clues.start');
      const initial = await snapshot(host);
      const sessionId = initial.publicState.clues!.sessionId;
      assert.equal(initial.publicState.clues!.clues.length, 1);
      assert.equal(initial.publicState.clues!.result, null);
      assert.equal(initial.privateClues!.answer, null);
      assert.equal((await post(`/v4/rooms/join/${pin}`, enrollment())).status, 409);
      const internal = async () => {
        const r = await pool.query('SELECT state FROM pb_rooms WHERE id=$1', [id]);
        return r.rows[0].state.clues.state as {
          roundIndex: number;
          questions: { answer: string; aliases: string[]; clues: string[] }[];
        };
      };
      const firstQuestion = (await internal()).questions[0]!;
      const serialized = JSON.stringify(initial);
      assert.ok(!serialized.includes(JSON.stringify(firstQuestion.answer)));
      assert.ok(!serialized.includes(JSON.stringify(firstQuestion.clues[1])));
      await new Promise<void>((resolve, reject) => {
        socket = io(origin, {
          transports: ['websocket'],
          auth: { protocolVersion: 4, roomId: id, guestToken: host.guestToken },
        });
        const timeout = setTimeout(() => reject(new Error('v4 socket timeout')), 3000);
        socket.once('room.snapshot', (v) => {
          try {
            assert.ok(valid(v));
            assert.equal(v.publicState.clues!.sessionId, sessionId);
            assert.equal(v.publicState.clues!.result, null);
            clearTimeout(timeout);
            resolve();
          } catch (e) {
            reject(e);
          }
        });
        socket.once('connect_error', reject);
      });
      socket!.disconnect();
      socket = undefined;
      // A stale simultaneous answer cannot silently receive different clue points.
      const wrong = await command(host, 'clues.answer', {
        answer: 'НЕВЕРНЫЙ_ТЕСТОВЫЙ_ОТВЕТ',
        clueIndex: 0,
      });
      const other = await command(members[1]!, 'clues.answer', {
        answer: firstQuestion.answer,
        clueIndex: 0,
      });
      assert.equal((await raw(host, wrong)).status, 201);
      assert.equal((await raw(members[1]!, other)).status, 409);
      const ack = await (await raw(host, wrong)).json();
      assert.deepEqual(await (await raw(host, wrong)).json(), ack);
      assert.equal(
        (await raw(host, { ...wrong, payload: { answer: 'changed', clueIndex: 0 } } as V4Command))
          .status,
        409,
      );
      assert.equal(
        (await send(host, 'clues.answer', { answer: firstQuestion.answer, clueIndex: 0 })).status,
        409,
      );
      const outsiderView = await snapshot(members[1]!);
      assert.equal(outsiderView.privateClues!.answer, null);
      assert.ok(!JSON.stringify(outsiderView).includes('НЕВЕРНЫЙ_ТЕСТОВЫЙ_ОТВЕТ'));
      await okay(host, 'clues.hint');
      assert.equal((await snapshot(host)).privateClues!.answer, 'НЕВЕРНЫЙ_ТЕСТОВЫЙ_ОТВЕТ');
      assert.equal(
        (await send(host, 'clues.answer', { answer: firstQuestion.answer, clueIndex: 0 })).status,
        400,
      );
      // Persisted questions and attempts survive process/pool replacement.
      await app.close();
      app = await createApp({ databaseUrl: url.toString(), tokenSecret: secret });
      await app.listen(0, '127.0.0.1');
      origin = await app.getUrl();
      assert.equal((await snapshot(host)).publicState.clues!.clueIndex, 1);
      assert.equal((await snapshot(host)).publicState.clues!.sessionId, sessionId);
      for (let round = 0; round < 5; round++) {
        const state = await snapshot(host);
        const game = state.publicState.clues!;
        const question = (await internal()).questions[round]!;
        assert.equal(game.roundIndex, round);
        for (const member of members) {
          const current = await snapshot(member);
          assert.equal(current.privateClues!.correct, false);
          const cmd = await command(member, 'clues.answer', {
            answer: question.answer,
            clueIndex: game.clueIndex,
          });
          const response = await raw(member, cmd);
          assert.equal(response.status, 201);
          if (member === members[0])
            assert.deepEqual(await (await raw(member, cmd)).json(), await response.json());
        }
        const revealed = await snapshot(host);
        assert.equal(revealed.publicState.clues!.phase, 'reveal');
        assert.equal(revealed.publicState.clues!.result!.answer, question.answer);
        assert.equal(revealed.privateClues, null);
        await okay(host, 'clues.next');
      }
      const finished = await snapshot(host);
      assert.equal(finished.publicState.clues!.phase, 'finished');
      assert.equal(finished.publicState.clues!.winners.length, 5);
      assert.ok(finished.publicState.clues!.scores.every((s) => s.score === 19));
      const newcomer = (await (
        await post(`/v3/rooms/join/${pin}`, enrollment(3))
      ).json()) as V4EnrollmentResult;
      assert.equal((await snapshot(host)).publicState.clues, null);
      await snapshot(newcomer);
      await okay(host, 'clues.start');
      const leaveView = await fetch(`${origin}/rooms/${id}`, {
        headers: { Authorization: `Bearer ${newcomer.guestToken}` },
      });
      const oldView = (await leaveView.json()) as { version: number };
      const leave = await post(
        `/rooms/${id}/commands`,
        {
          protocolVersion: 1,
          commandId: randomUUID(),
          expectedVersion: oldView.version,
          type: 'room.leave',
          payload: {},
        },
        newcomer.guestToken,
      );
      assert.equal(leave.status, 201);
      assert.equal((await snapshot(host)).publicState.clues, null);
      // A fresh one-person room is a valid online solo party.
      const solo = (await (await post('/v4/rooms', enrollment())).json()) as V4EnrollmentResult;
      await okay(solo, 'clues.start');
      assert.equal((await snapshot(solo)).publicState.clues!.scores.length, 1);
    } finally {
      socket?.disconnect();
      await app.close();
      await pool.end();
      await admin.query(`DROP SCHEMA ${namespace} CASCADE`);
      await admin.end();
    }
  },
);
