import assert from 'node:assert/strict';
import { randomUUID, randomBytes } from 'node:crypto';
import { test } from 'node:test';
import pg from 'pg';
import { io, type Socket } from 'socket.io-client';
import type {
  GameSnapshot,
  GameEnrollmentResult,
  GameCommand,
} from '@partybox/game-contracts/rooms-v2';
import { createApp } from '../src/bootstrap.js';
import { migrate } from '../src/rooms/migrate.js';
const enrollment = () => ({
  protocolVersion: 2,
  requestId: randomUUID(),
  retryKey: randomBytes(32).toString('base64url'),
  name: 'Тестовый игрок',
});
const secret = 'cd'.repeat(32);
test(
  'v2 network round: twelve-player Wi-Fi, privacy, ready, deadline, result, retry, host leave',
  { skip: !process.env.TEST_DATABASE_URL },
  async () => {
    const admin = new pg.Pool({ connectionString: process.env.TEST_DATABASE_URL });
    const schema = `pb_game_${randomUUID().replaceAll('-', '')}`;
    await admin.query(`CREATE SCHEMA ${schema}`);
    const url = new URL(process.env.TEST_DATABASE_URL!);
    url.searchParams.set('options', `-c search_path=${schema}`);
    const pool = new pg.Pool({ connectionString: url.toString() });
    let now = new Date();
    await migrate(pool);
    let app = await createApp({ databaseUrl: url.toString(), tokenSecret: secret, now: () => now });
    const sockets: Socket[] = [];
    try {
      await app.listen(0, '127.0.0.1');
      let origin = await app.getUrl();
      const post = (path: string, body: unknown, token?: string) =>
        fetch(`${origin}${path}`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            ...(token ? { Authorization: `Bearer ${token}` } : {}),
          },
          body: JSON.stringify(body),
        });
      const create = await post('/v2/rooms', enrollment());
      assert.equal(create.status, 201);
      const host = (await create.json()) as GameEnrollmentResult;
      const id = host.snapshot.roomId;
      const pin = host.snapshot.publicState.pin;
      const members = [host];
      for (let i = 0; i < 11; i++) {
        const r = await post(`/v2/rooms/join/${pin}`, enrollment());
        assert.equal(r.status, 201);
        members.push((await r.json()) as GameEnrollmentResult);
      }
      const latest = new Map<string, GameSnapshot>();
      await Promise.all(
        members.map(
          (member) =>
            new Promise<void>((resolve, reject) => {
              const socket = io(origin, {
                auth: { roomId: id, guestToken: member.guestToken, protocolVersion: 2 },
                reconnection: false,
              });
              sockets.push(socket);
              socket.on('room.snapshot', (snapshot: GameSnapshot) => {
                latest.set(snapshot.selfId, snapshot);
                resolve();
              });
              socket.on('connect_error', reject);
            }),
        ),
      );
      const snapshot = async (member: GameEnrollmentResult) =>
        (await (
          await fetch(`${origin}/v2/rooms/${id}`, {
            headers: { Authorization: `Bearer ${member.guestToken}` },
          })
        ).json()) as GameSnapshot;
      const command = async (member: GameEnrollmentResult, type: string, payload: unknown = {}) => {
        const state = await snapshot(member);
        return {
          protocolVersion: 2,
          commandId: randomUUID(),
          expectedVersion: state.version,
          sessionId: state.publicState.game?.sessionId ?? null,
          type,
          payload,
        } as GameCommand;
      };
      const send = async (member: GameEnrollmentResult, type: string, payload: unknown = {}) =>
        post(`/v2/rooms/${id}/commands`, await command(member, type, payload), member.guestToken);
      assert.equal(
        (await send(members[1]!, 'spy.start', { discussionMinutes: 3, packId: 'spy-ru-base' }))
          .status,
        403,
      );
      assert.equal(
        (await send(host, 'spy.start', { discussionMinutes: 3, packId: 'spy-ru-base' })).status,
        201,
      );
      const views = await Promise.all(members.map(snapshot));
      assert.equal(views.filter((v) => v.privateState?.role === 'spy').length, 1);
      const location = views.find((v) => v.privateState?.role === 'civilian')!.privateState!
        .location!;
      for (const view of views) {
        assert.equal(JSON.stringify(view.publicState).includes(location), false);
        assert.equal(view.publicState.game!.result, null);
        if (view.privateState!.role === 'spy') assert.equal(view.privateState!.location, null);
      }
      // Concurrent confirmations cannot silently overwrite one another.
      const a = await command(members[10]!, 'spy.ready');
      const b = await command(members[11]!, 'spy.ready');
      const race = await Promise.all([
        post(`/v2/rooms/${id}/commands`, a, members[10]!.guestToken),
        post(`/v2/rooms/${id}/commands`, b, members[11]!.guestToken),
      ]);
      assert.deepEqual(race.map((r) => r.status).sort(), [201, 409]);
      for (const member of [...members].reverse()) {
        const state = await snapshot(member);
        if (!state.publicState.game!.readyIds.includes(state.selfId))
          assert.equal((await send(member, 'spy.ready')).status, 201);
      }
      const discussion = await snapshot(host);
      assert.equal(discussion.publicState.game!.phase, 'discussion');
      now = new Date(Date.parse(discussion.publicState.game!.deadline!));
      await snapshot(host);
      const end = Date.now() + 3000;
      while ([...latest.values()].some((v) => v.publicState.game?.phase !== 'voting')) {
        if (Date.now() > end) throw new Error('Deadline was not broadcast');
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      for (const socket of sockets) socket.disconnect();
      await app.close();
      app = await createApp({ databaseUrl: url.toString(), tokenSecret: secret, now: () => now });
      await app.listen(0, '127.0.0.1');
      origin = await app.getUrl();
      now = new Date(Date.parse(discussion.publicState.game!.deadline!));
      const voting = await snapshot(host);
      assert.equal(voting.publicState.game!.phase, 'voting');
      const spy = views.find((v) => v.privateState?.role === 'spy')!.selfId;
      const accusation = await command(host, 'spy.accuse', { suspectId: spy });
      const first = await post(`/v2/rooms/${id}/commands`, accusation, host.guestToken);
      assert.equal(first.status, 201);
      const ack = await first.json();
      assert.deepEqual(
        await (await post(`/v2/rooms/${id}/commands`, accusation, host.guestToken)).json(),
        ack,
      );
      assert.equal(
        (
          await post(
            `/v2/rooms/${id}/commands`,
            { ...accusation, payload: { suspectId: views.find((v) => v.selfId !== spy)!.selfId } },
            host.guestToken,
          )
        ).status,
        409,
      );
      const result = await snapshot(host);
      assert.equal(result.publicState.game!.result!.winner, 'civilians');
      assert.equal(result.privateState, null);
      assert.equal(
        (await send(host, 'spy.start', { discussionMinutes: 3, packId: 'spy-ru-base' })).status,
        201,
      );
      assert.equal((await send(host, 'room.leave')).status, 201);
      const remaining = await snapshot(members[1]!);
      assert.equal(remaining.publicState.game, null);
      assert.equal(remaining.publicState.hostId, members[1]!.snapshot.selfId);
      assert.equal(
        (
          await fetch(`${origin}/v2/rooms/${id}`, {
            headers: { Authorization: `Bearer ${host.guestToken}` },
          })
        ).status,
        401,
      );
    } finally {
      for (const socket of sockets) socket.disconnect();
      await app.close();
      await pool.end();
      await admin.query(`DROP SCHEMA ${schema} CASCADE`);
      await admin.end();
    }
  },
);
