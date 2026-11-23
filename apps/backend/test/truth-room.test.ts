import assert from 'node:assert/strict';
import { randomUUID, randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import pg from 'pg';
import { Ajv } from 'ajv';
import { io, type Socket } from 'socket.io-client';
import type { V6EnrollmentResult, V6Snapshot } from '@partybox/game-contracts/rooms-v6';
import { createApp } from '../src/bootstrap.js';
import { migrate } from '../src/rooms/migrate.js';
const schema = JSON.parse(
  readFileSync(
    new URL(import.meta.resolve('@partybox/game-contracts/rooms-v6.schema.json')),
    'utf8',
  ),
);
const ajv = new Ajv({ strict: true });
ajv.addSchema(schema);
const valid = ajv.compile<V6Snapshot>({ $ref: `${schema.$id}#/$defs/V6Snapshot` });
const enrollment = (name: string, protocolVersion = 6) => ({
  protocolVersion,
  name,
  requestId: randomUUID(),
  retryKey: randomBytes(32).toString('base64url'),
});
test(
  'v6 HTTP/WebSocket: truth concurrent rounds, private restore, durable scoring, stale requests and capability checks',
  { skip: !process.env.TEST_DATABASE_URL },
  async () => {
    const admin = new pg.Pool({ connectionString: process.env.TEST_DATABASE_URL });
    const namespace = `pb_truth_${randomUUID().replaceAll('-', '')}`;
    await admin.query(`CREATE SCHEMA ${namespace}`);
    const url = new URL(process.env.TEST_DATABASE_URL!);
    url.searchParams.set('options', `-c search_path=${namespace}`);
    const pool = new pg.Pool({ connectionString: url.toString() });
    await migrate(pool);
    const secret = 'ad'.repeat(32);
    let app = await createApp({ databaseUrl: url.toString(), tokenSecret: secret });
    let origin = '';
    let socket: Socket | undefined;
    const post = async (path: string, body: unknown, token?: string) =>
      fetch(origin + path, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
        },
        body: JSON.stringify(body),
      });
    const snapshot = async (m: V6EnrollmentResult) => {
      const r = await fetch(`${origin}/v6/rooms/${m.snapshot.roomId}`, {
        headers: { Authorization: `Bearer ${m.guestToken}` },
      });
      assert.equal(r.status, 200);
      const v = await r.json();
      assert.ok(valid(v), ajv.errorsText(valid.errors));
      return v;
    };
    const make = async (m: V6EnrollmentResult, type: string, payload: unknown = {}) => {
      const v = await snapshot(m);
      return {
        protocolVersion: 6,
        commandId: randomUUID(),
        expectedVersion: v.version,
        sessionId: v.publicState.truth?.sessionId ?? null,
        type,
        payload,
      };
    };
    const raw = async (m: V6EnrollmentResult, cmd: unknown, version = 6) => {
      const response = await post(
        `/v${version}/rooms/${m.snapshot.roomId}/commands`,
        cmd,
        m.guestToken,
      );
      if (response.status >= 400)
        assert.equal((await response.clone().json()).protocolVersion, version);
      return response;
    };
    const send = async (m: V6EnrollmentResult, type: string, payload: unknown = {}) =>
      raw(m, await make(m, type, payload));
    const okay = async (m: V6EnrollmentResult, type: string, payload: unknown = {}) => {
      const r = await send(m, type, payload);
      assert.equal(r.status, 201, JSON.stringify(await r.json()));
    };
    try {
      await app.listen(0, '127.0.0.1');
      origin = await app.getUrl();
      const host = (await (
        await post('/v6/rooms', enrollment('Ведущий'))
      ).json()) as V6EnrollmentResult;
      assert.ok(valid(host.snapshot));
      assert.equal((await send(host, 'truth.start', { topics: [] })).status, 409);
      const pin = host.snapshot.publicState.pin;
      const guest = (await (
        await post(`/v5/rooms/join/${pin}`, enrollment('Гость', 5))
      ).json()) as V6EnrollmentResult;
      const blocked = await send(host, 'truth.start', { topics: [] });
      assert.equal((await blocked.json()).code, 'CLIENT_UPGRADE_REQUIRED');
      await snapshot(guest);
      assert.equal((await send(guest, 'truth.start', { topics: [] })).status, 403);
      assert.equal((await send(host, 'truth.start', { topics: ['human', 'human'] })).status, 400);
      await okay(host, 'truth.start', { topics: ['animals'] });
      const legacy = await fetch(`${origin}/v5/rooms/${host.snapshot.roomId}`, {
        headers: { Authorization: `Bearer ${guest.guestToken}` },
      });
      assert.equal(legacy.status, 200);
      const legacyLobby = await legacy.json();
      assert.equal(legacyLobby.protocolVersion, 5);
      assert.equal(legacyLobby.publicState.game, null);
      assert.equal(legacyLobby.privateState, null);
      assert.equal('truth' in legacyLobby.publicState, false);
      assert.equal('privateTruth' in legacyLobby, false);
      const oldStart = await post(
        `/v5/rooms/${host.snapshot.roomId}/commands`,
        {
          protocolVersion: 5,
          commandId: randomUUID(),
          expectedVersion: legacyLobby.version,
          sessionId: null,
          type: 'clues.start',
          payload: {},
        },
        host.guestToken,
      );
      assert.equal((await oldStart.json()).code, 'CLIENT_UPGRADE_REQUIRED');
      assert.equal((await post(`/v6/rooms/join/${pin}`, enrollment('Опоздал'))).status, 409);
      assert.equal((await send(host, 'clues.start')).status, 409);
      assert.equal((await send(guest, 'truth.cancel')).status, 403);
      const v = await snapshot(host);
      const commandAt = (view: V6Snapshot, type: string, payload: unknown = {}) => ({
        protocolVersion: 6,
        commandId: randomUUID(),
        expectedVersion: view.version,
        sessionId: view.publicState.truth!.sessionId,
        type,
        payload,
      });
      const delayed = commandAt(v, 'truth.initial', { answer: true });
      assert.equal((await raw(host, { ...delayed, sessionId: randomUUID() })).status, 409);
      const statements = new Set<string>();
      let current = v;
      for (let round = 0; round < 10; round++) {
        const game = current.publicState.truth!;
        assert.equal(game.roundIndex, round);
        assert.equal(game.phase, 'initial');
        assert.equal(game.topic, 'animals');
        assert.equal(game.result, null);
        statements.add(game.statement);
        if (round === 1) {
          const stale = await raw(host, delayed);
          assert.equal((await stale.json()).code, 'VERSION_CONFLICT');
        }
        const initialResponses = await Promise.all([
          raw(host, commandAt(current, 'truth.initial', { answer: false })),
          raw(guest, commandAt(current, 'truth.initial', { answer: true })),
        ]);
        for (const r of initialResponses) assert.equal(r.status, 201);
        const discussion = await snapshot(host);
        assert.equal(discussion.publicState.truth?.phase, 'discussion');
        assert.equal(discussion.publicState.truth?.result, null);
        assert.deepEqual(discussion.privateTruth, {
          initialAnswer: false,
          answer: null,
          stake: null,
        });
        if (round === 0)
          assert.equal((await raw(guest, commandAt(discussion, 'truth.discussed'))).status, 403);
        assert.equal((await raw(host, commandAt(discussion, 'truth.discussed'))).status, 201);
        const betting = await snapshot(guest);
        const hostBet = commandAt(betting, 'truth.bet', { answer: false, stake: 2 });
        const guestBet = commandAt(betting, 'truth.bet', { answer: true, stake: 3 });
        if (round === 0) {
          assert.equal(
            (await raw(host, { ...hostBet, payload: { answer: true, stake: 4 } })).status,
            400,
          );
          assert.equal((await raw(host, hostBet)).status, 201);
          const other = await snapshot(guest);
          assert.deepEqual(other.privateTruth, { initialAnswer: true, answer: null, stake: null });
          assert.deepEqual(other.publicState.truth?.betIds, [host.snapshot.selfId]);
          assert.equal(other.publicState.truth?.result, null);
          assert.deepEqual(other.publicState.truth?.scores, game.scores);
          assert.equal((await raw(host, { ...hostBet, commandId: randomUUID() })).status, 409);
          await app.close();
          app = await createApp({ databaseUrl: url.toString(), tokenSecret: secret });
          await app.listen(0, '127.0.0.1');
          origin = await app.getUrl();
          const restored = await new Promise<V6Snapshot>((resolve, reject) => {
            const timer = setTimeout(() => reject(new Error('v6 snapshot timeout')), 5000);
            socket = io(origin, {
              transports: ['websocket'],
              auth: {
                protocolVersion: 6,
                roomId: host.snapshot.roomId,
                guestToken: host.guestToken,
              },
              forceNew: true,
            });
            socket.once('room.snapshot', (wire) => {
              clearTimeout(timer);
              resolve(wire);
            });
            socket.once('connect_error', reject);
          });
          assert.ok(valid(restored));
          assert.deepEqual(restored.privateTruth, {
            initialAnswer: false,
            answer: false,
            stake: 2,
          });
          assert.deepEqual(restored.publicState, other.publicState);
          socket!.close();
          socket = undefined;
          const last = await raw(guest, guestBet);
          assert.equal(last.status, 201);
          const retry = await raw(guest, { ...guestBet, payload: { stake: 3, answer: true } });
          assert.deepEqual(await retry.json(), await last.json());
          assert.equal(
            (await raw(guest, { ...guestBet, payload: { stake: 2, answer: true } })).status,
            409,
          );
        } else {
          const responses = await Promise.all([raw(host, hostBet), raw(guest, guestBet)]);
          for (const r of responses) assert.equal(r.status, 201);
        }
        const revealed = await snapshot(host);
        assert.equal(revealed.privateTruth, null);
        const result = revealed.publicState.truth!.result!;
        assert.ok(result.sources.length > 0 && result.explanation.length > 0);
        assert.deepEqual(
          result.answers.map((a) => a.initialAnswer),
          [false, true],
        );
        assert.deepEqual(
          result.answers.map((a) => a.answer),
          [false, true],
        );
        assert.deepEqual(
          revealed.publicState.truth!.scores.map((s) => s.score),
          game.scores.map((s, i) => s.score + result.answers[i]!.points),
        );
        assert.equal((await raw(host, commandAt(revealed, 'truth.next'))).status, 201);
        current = await snapshot(host);
      }
      assert.equal(statements.size, 10);
      assert.equal(current.publicState.truth?.phase, 'finished');
      assert.ok(current.publicState.truth!.winners.length >= 1);
      await okay(host, 'truth.start', { topics: [] });
      await okay(host, 'truth.cancel');
      assert.equal((await snapshot(guest)).publicState.truth, null);
      await okay(host, 'truth.start', { topics: ['food', 'science'] });
      await okay(host, 'room.leave');
      const lobby = await snapshot(guest);
      assert.equal(lobby.publicState.hostId, guest.snapshot.selfId);
      assert.equal(lobby.publicState.truth, null);
      assert.equal(lobby.privateTruth, null);
      const newcomer = (await (
        await post(`/v6/rooms/join/${pin}`, enrollment('Новый'))
      ).json()) as V6EnrollmentResult;
      await okay(guest, 'truth.start', { topics: [] });
      const currentGame = await snapshot(newcomer);
      const leaveV1 = {
        protocolVersion: 1,
        commandId: randomUUID(),
        expectedVersion: currentGame.version,
        type: 'room.leave',
        payload: {},
      };
      const left = await post(
        `/rooms/${newcomer.snapshot.roomId}/commands`,
        leaveV1,
        newcomer.guestToken,
      );
      assert.equal(left.status, 201);
      assert.equal((await snapshot(guest)).publicState.truth, null);
      const finalMember = (await (
        await post(`/v6/rooms/join/${pin}`, enrollment('Ещё игрок'))
      ).json()) as V6EnrollmentResult;
      await okay(guest, 'truth.start', { topics: [] });
      const v6Game = await snapshot(finalMember);
      const leftV5 = await post(
        `/v5/rooms/${finalMember.snapshot.roomId}/commands`,
        {
          ...leaveV1,
          protocolVersion: 5,
          commandId: randomUUID(),
          sessionId: null,
          expectedVersion: v6Game.version,
        },
        finalMember.guestToken,
      );
      assert.equal(leftV5.status, 201);
      assert.equal((await snapshot(guest)).publicState.truth, null);
    } finally {
      socket?.close();
      await app.close();
      await pool.end();
      await admin.query(`DROP SCHEMA ${namespace} CASCADE`);
      await admin.end();
    }
  },
);
