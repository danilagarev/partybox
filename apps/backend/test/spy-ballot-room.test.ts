import assert from 'node:assert/strict';
import { randomUUID, randomBytes, createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import pg from 'pg';
import { Ajv } from 'ajv';
import { io, type Socket } from 'socket.io-client';
import type { V5EnrollmentResult, V5Snapshot } from '@partybox/game-contracts/rooms-v5';
import { createApp } from '../src/bootstrap.js';
import { migrate } from '../src/rooms/migrate.js';
const schema = JSON.parse(
  readFileSync(
    new URL(import.meta.resolve('@partybox/game-contracts/rooms-v5.schema.json')),
    'utf8',
  ),
);
const ajv = new Ajv({ strict: true });
ajv.addSchema(schema);
const valid = ajv.compile<V5Snapshot>({ $ref: `${schema.$id}#/$defs/V5Snapshot` });
const enrollment = (name: string, protocolVersion = 5) => ({
  protocolVersion,
  name,
  requestId: randomUUID(),
  retryKey: randomBytes(32).toString('base64url'),
});
test(
  'v5 HTTP/WebSocket: everyone votes, ties, private reconnect, durable retry and old-client safety',
  { skip: !process.env.TEST_DATABASE_URL },
  async () => {
    const admin = new pg.Pool({ connectionString: process.env.TEST_DATABASE_URL });
    const namespace = `pb_ballot_${randomUUID().replaceAll('-', '')}`;
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
    const snapshot = async (m: V5EnrollmentResult) => {
      const r = await fetch(`${origin}/v5/rooms/${m.snapshot.roomId}`, {
        headers: { Authorization: `Bearer ${m.guestToken}` },
      });
      assert.equal(r.status, 200);
      const v = await r.json();
      assert.ok(valid(v), ajv.errorsText(valid.errors));
      return v;
    };
    const make = async (m: V5EnrollmentResult, type: string, payload: unknown = {}) => {
      const v = await snapshot(m);
      return {
        protocolVersion: 5,
        commandId: randomUUID(),
        expectedVersion: v.version,
        sessionId: v.publicState.game?.sessionId ?? null,
        type,
        payload,
      };
    };
    const raw = async (m: V5EnrollmentResult, cmd: unknown, version = 5) => {
      const response = await post(
        `/v${version}/rooms/${m.snapshot.roomId}/commands`,
        cmd,
        m.guestToken,
      );
      if (response.status >= 400)
        assert.equal((await response.clone().json()).protocolVersion, version);
      return response;
    };
    const send = async (m: V5EnrollmentResult, type: string, payload: unknown = {}) =>
      raw(m, await make(m, type, payload));
    const okay = async (m: V5EnrollmentResult, type: string, payload: unknown = {}) => {
      const r = await send(m, type, payload);
      assert.equal(r.status, 201, JSON.stringify(await r.json()));
    };
    try {
      await app.listen(0, '127.0.0.1');
      origin = await app.getUrl();
      const hostRequest = enrollment('Ведущий');
      const host = (await (await post('/v5/rooms', hostRequest)).json()) as V5EnrollmentResult;
      assert.ok(valid(host.snapshot));
      assert.equal(
        (await (await post('/v5/rooms', hostRequest)).json()).guestToken,
        host.guestToken,
      );
      const pin = host.snapshot.publicState.pin;
      const members = [host];
      for (let i = 1; i < 4; i++)
        members.push(
          (await (
            await post(
              `/v${i === 3 ? 4 : 5}/rooms/join/${pin}`,
              enrollment(`Игрок ${i}`, i === 3 ? 4 : 5),
            )
          ).json()) as V5EnrollmentResult,
        );
      assert.equal(
        (await send(host, 'spy.start', { packId: 'spy-ru-base', discussionMinutes: 3 })).status,
        409,
      );
      // Joining with an old client never silently switches the room to host-only voting.
      await snapshot(members[3]!);
      assert.equal(
        (await send(members[1]!, 'spy.start', { packId: 'spy-ru-base', discussionMinutes: 3 }))
          .status,
        403,
      );
      await okay(host, 'spy.start', { packId: 'spy-ru-base', discussionMinutes: 3 });
      for (const m of members) await okay(m, 'spy.ready');
      await okay(host, 'spy.vote');
      const ids = members.map((m) => m.snapshot.selfId);
      const commands = await Promise.all(
        members.map((m, i) => make(m, 'spy.ballot', { round: 1, suspectId: ids[i < 2 ? 0 : 1] })),
      );
      const first = await raw(host, commands[0]!);
      assert.equal(first.status, 201);
      const firstAck = await first.json();
      const reordered = { ...commands[0]!, payload: { suspectId: ids[0], round: 1 } };
      assert.deepEqual(await (await raw(host, reordered)).json(), firstAck);
      // A durable receipt created by an earlier v5 process may use either order.
      const oldFingerprint = createHash('sha256').update(JSON.stringify(reordered)).digest('hex');
      await pool.query(
        'UPDATE pb_room_commands SET fingerprint=$1 WHERE room_id=$2 AND player_id=$3 AND command_id=$4',
        [oldFingerprint, host.snapshot.roomId, host.snapshot.selfId, commands[0]!.commandId],
      );
      assert.deepEqual(await (await raw(host, commands[0]!)).json(), firstAck);

      assert.equal((await snapshot(host)).publicState.game?.phase, 'voting');
      const own = await snapshot(host);
      assert.equal(own.privateState?.ballot?.suspectId, ids[0]);
      const other = await snapshot(members[1]!);
      assert.equal(other.privateState?.ballot, undefined);
      assert.equal(other.publicState.game?.result, null);
      assert.deepEqual(other.publicState.game?.voting?.votedIds, [ids[0]]);
      assert.equal((await send(host, 'spy.accuse', { suspectId: ids[0] })).status, 409);
      const oldAccuse = {
        ...(await make(host, 'spy.accuse', { suspectId: ids[0] })),
        protocolVersion: 4,
      };
      assert.equal((await raw(host, oldAccuse, 4)).status, 409);
      const mutate = { ...commands[0]!, payload: { round: 1, suspectId: ids[1] } };
      assert.equal((await raw(host, mutate)).status, 409);
      assert.equal((await send(host, 'spy.ballot', { round: 1, suspectId: ids[1] })).status, 409);
      // Restart with persisted individual ballots and replay exactly the original command.
      await app.close();
      app = await createApp({ databaseUrl: url.toString(), tokenSecret: secret });
      await app.listen(0, '127.0.0.1');
      origin = await app.getUrl();
      assert.deepEqual(await (await raw(host, commands[0]!)).json(), firstAck);
      const fromSocket = await new Promise<V5Snapshot>((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('v5 snapshot timeout')), 5000);
        socket = io(origin, {
          transports: ['websocket'],
          auth: { protocolVersion: 5, roomId: host.snapshot.roomId, guestToken: host.guestToken },
          forceNew: true,
        });
        socket.once('room.snapshot', (v) => {
          clearTimeout(timer);
          resolve(v);
        });
        socket.once('connect_error', reject);
      });
      assert.ok(valid(fromSocket));
      assert.equal(fromSocket.privateState?.ballot?.suspectId, ids[0]);
      socket!.close();
      socket = undefined;
      const responses = await Promise.all(members.slice(1).map((m, i) => raw(m, commands[i + 1]!)));
      for (const r of responses) assert.equal(r.status, 201, JSON.stringify(await r.json()));
      const tied = await snapshot(host);
      assert.equal(tied.publicState.game?.phase, 'voting');
      assert.deepEqual(tied.publicState.game?.voting, {
        round: 2,
        candidateIds: [ids[0], ids[1]],
        votedIds: [],
      });
      assert.equal(tied.privateState?.ballot, undefined);
      assert.equal(
        (await send(members[1]!, 'spy.ballot', { round: 1, suspectId: ids[0] })).status,
        409,
      );
      assert.equal(
        (await send(members[1]!, 'spy.ballot', { round: 2, suspectId: ids[2] })).status,
        409,
      );
      const round2 = await Promise.all(
        members.map((m) => make(m, 'spy.ballot', { round: 2, suspectId: ids[1] })),
      );
      const final = await Promise.all(members.map((m, i) => raw(m, round2[i]!)));
      for (const r of final) assert.equal(r.status, 201, JSON.stringify(await r.json()));
      for (const m of members) {
        const v = await snapshot(m);
        assert.equal(v.publicState.game?.phase, 'results');
        assert.equal(v.publicState.game?.result?.suspectId, ids[1]);
        assert.equal(v.privateState, null);
        assert.equal(v.publicState.game?.voting, undefined);
      }
      assert.equal((await send(host, 'spy.ballot', { round: 2, suspectId: ids[1] })).status, 409);
      // A newcomer receives usable access after results, including an older client.
      const newcomerRequest = enrollment('Новый участник', 4);
      const join = await post(`/v4/rooms/join/${pin}`, newcomerRequest);
      assert.equal(join.status, 201, 'old client must receive access after v5 results');
      const newcomer = await join.json();
      assert.equal(newcomer.snapshot.publicState.game, null);
      assert.equal((await snapshot(host)).publicState.players.length, 5);
      const replayJoin = await (await post(`/v4/rooms/join/${pin}`, newcomerRequest)).json();
      assert.equal(replayJoin.guestToken, newcomer.guestToken);
      const left = await post(
        `/v4/rooms/${host.snapshot.roomId}/commands`,
        {
          protocolVersion: 4,
          commandId: randomUUID(),
          expectedVersion: newcomer.snapshot.version,
          sessionId: null,
          type: 'room.leave',
          payload: {},
        },
        newcomer.guestToken,
      );
      assert.equal(left.status, 201);
      assert.equal((await snapshot(host)).publicState.players.length, 4);
      // The single-phone / older protocol behavior remains supported in an older game.
      const legacy = {
        ...(await make(host, 'spy.start', { packId: 'spy-ru-base', discussionMinutes: 3 })),
        protocolVersion: 4,
      };
      assert.equal((await raw(host, legacy, 4)).status, 201);
      for (const m of members) await okay(m, 'spy.ready');
      await okay(host, 'spy.vote');
      assert.equal((await snapshot(host)).publicState.game?.voting, undefined);
      await okay(host, 'spy.accuse', { suspectId: ids[1] });
    } finally {
      socket?.close();
      await app.close();
      await pool.end();
      await admin.query(`DROP SCHEMA ${namespace} CASCADE`);
      await admin.end();
    }
  },
);
