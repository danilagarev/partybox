import assert from 'node:assert/strict';
import { randomUUID, randomBytes } from 'node:crypto';
import { test } from 'node:test';
import pg from 'pg';
import type { GameCommand } from '@partybox/game-contracts/rooms-v2';
import { RoomService } from '../src/rooms/room-service.js';
import { RoomError } from '../src/rooms/room-error.js';
import { migrate } from '../src/rooms/migrate.js';
import { spyPacks } from '../src/games/spy-content.js';

test(
  'room pack selection, cancellation, retries and restart preserve private rotation',
  { skip: !process.env.TEST_DATABASE_URL },
  async () => {
    const admin = new pg.Pool({ connectionString: process.env.TEST_DATABASE_URL });
    const schema = `pb_content_${randomUUID().replaceAll('-', '')}`;
    await admin.query(`CREATE SCHEMA ${schema}`);
    const url = new URL(process.env.TEST_DATABASE_URL!);
    url.searchParams.set('options', `-c search_path=${schema}`);
    let pool = new pg.Pool({ connectionString: url.toString() });
    const secret = 'ab'.repeat(32);
    let service = new RoomService(pool, secret);
    try {
      await migrate(pool);
      const enroll = () => ({
        protocolVersion: 1 as const,
        requestId: randomUUID(),
        retryKey: randomBytes(32).toString('base64url'),
        name: 'Игрок',
      });
      const host = await service.enroll(enroll());
      const id = host.snapshot.roomId;
      const members = [host];
      for (let i = 0; i < 3; i++)
        members.push(await service.enroll(enroll(), host.snapshot.publicState.pin));
      for (const member of members) await service.snapshotGame(id, member.guestToken);
      const command = async (type: GameCommand['type'], payload: object = {}) => {
        const view = await service.snapshotGame(id, host.guestToken);
        return {
          protocolVersion: 2,
          commandId: randomUUID(),
          expectedVersion: view.version,
          sessionId: view.publicState.game?.sessionId ?? null,
          type,
          payload,
        } as GameCommand;
      };
      const before = await service.snapshotGame(id, host.guestToken);
      await assert.rejects(
        service.commandGame(
          id,
          host.guestToken,
          await command('spy.start', { packId: 'missing-pack', discussionMinutes: 5 }),
        ),
        (e: unknown) => e instanceof RoomError && e.code === 'INVALID_REQUEST',
      );
      assert.equal((await service.snapshotGame(id, host.guestToken)).version, before.version);
      const seen = new Map([...spyPacks.keys()].map((key) => [key, new Set<string>()]));
      for (let i = 0; i < 25; i++) {
        for (const pack of spyPacks.values()) {
          const start = await command('spy.start', { packId: pack.id, discussionMinutes: 5 });
          const ack = await service.commandGame(id, host.guestToken, start);
          assert.deepEqual(await service.commandGame(id, host.guestToken, start), ack);
          const views = await Promise.all(
            members.map((m) => service.snapshotGame(id, m.guestToken)),
          );
          const location = views.find((v) => v.privateState?.role === 'civilian')!.privateState!
            .location!;
          assert.ok(pack.items.some((item) => item.label === location));
          if (i < pack.items.length) assert.ok(!seen.get(pack.id)!.has(location));
          seen.get(pack.id)!.add(location);
          for (const view of views) {
            assert.equal(view.publicState.game!.packId, pack.id);
            assert.equal(view.publicState.game!.packVersion, pack.version);
            assert.equal(JSON.stringify(view).includes('spyHistory'), false);
            assert.equal(JSON.stringify(view.publicState).includes(location), false);
          }
          const state = (await pool.query('SELECT state FROM pb_rooms WHERE id=$1', [id])).rows[0]
            .state;
          const key = `${pack.id}:${pack.version}`;
          assert.equal(state.spyHistory[key].length, (i % pack.items.length) + 1);
          await service.commandGame(id, host.guestToken, await command('spy.cancel'));
        }
        if (i === 5) {
          await pool.end();
          pool = new pg.Pool({ connectionString: url.toString() });
          service = new RoomService(pool, secret);
        }
      }
      for (const pack of spyPacks.values())
        assert.equal(seen.get(pack.id)!.size, pack.items.length);
    } finally {
      await pool.end();
      await admin.query(`DROP SCHEMA ${schema} CASCADE`);
      await admin.end();
    }
  },
);
