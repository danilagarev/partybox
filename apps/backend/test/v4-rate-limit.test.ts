import assert from 'node:assert/strict';
import { createHmac, randomBytes, randomUUID } from 'node:crypto';
import { test } from 'node:test';
import type { V4EnrollmentResult } from '@partybox/game-contracts/rooms-v4';
import pg from 'pg';
import { createApp } from '../src/bootstrap.js';
import { migrate } from '../src/rooms/migrate.js';

const databaseUrl = process.env.TEST_DATABASE_URL;

test(
  'v4 snapshots share an IP budget and cap each guest without storing tokens',
  { skip: !databaseUrl },
  async () => {
    const admin = new pg.Pool({ connectionString: databaseUrl });
    const namespace = `pb_v4_rate_${randomUUID().replaceAll('-', '')}`;
    try {
      await admin.query(`CREATE SCHEMA ${namespace}`);
      const url = new URL(databaseUrl!);
      url.searchParams.set('options', `-c search_path=${namespace}`);
      const pool = new pg.Pool({ connectionString: url.toString() });
      try {
        await migrate(pool);
        const secret = 'ce'.repeat(32);
        const app = await createApp({ databaseUrl: url.toString(), tokenSecret: secret });
        try {
          await app.listen(0, '127.0.0.1');
          const origin = await app.getUrl();
          const enroll = async (index: number, pin?: string) => {
            const path = pin === undefined ? '/v4/rooms' : `/v4/rooms/join/${pin}`;
            const response = await fetch(origin + path, {
              method: 'POST',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({
                protocolVersion: 4,
                requestId: randomUUID(),
                retryKey: randomBytes(32).toString('base64url'),
                name: `Игрок ${index}`,
              }),
            });
            assert.equal(response.status, 201);
            return (await response.json()) as V4EnrollmentResult;
          };
          const host = await enroll(1);
          const members = [host];
          for (let index = 2; index <= 12; index++) {
            members.push(await enroll(index, host.snapshot.publicState.pin));
          }

          const snapshot = async (member: V4EnrollmentResult, status = 200) => {
            const response = await fetch(`${origin}/v4/rooms/${host.snapshot.roomId}`, {
              headers: { Authorization: `Bearer ${member.guestToken}` },
            });
            assert.equal(response.status, status);
            const body = await response.json();
            if (status === 200) {
              assert.equal(body.selfId, member.snapshot.selfId);
              assert.equal(body.publicState.players.length, 12);
            } else {
              assert.deepEqual(body, { protocolVersion: 4, code: 'RATE_LIMITED' });
            }
          };
          for (let attempt = 0; attempt < 11; attempt++) {
            for (const member of members) await snapshot(member);
          }
          for (let attempt = 11; attempt < 120; attempt++) await snapshot(host);
          await snapshot(host, 429);
          await snapshot(members[1]!);

          const stored = await pool.query<{ bucket: string; attempts: number }>(
            'SELECT bucket, attempts FROM pb_rate_limits',
          );
          assert.ok(stored.rows.every(({ bucket }) => /^[0-9a-f]{64}$/.test(bucket)));
          for (const [index, member] of members.entries()) {
            const hash = createHmac('sha256', secret)
              .update(`snapshot-member-v4:${member.guestToken}`)
              .digest('hex');
            const bucket = stored.rows.find(({ bucket }) => bucket === hash);
            assert.equal(bucket?.attempts, index === 0 ? 121 : index === 1 ? 12 : 11);
            assert.ok(stored.rows.every(({ bucket }) => !bucket.includes(member.guestToken)));
          }
        } finally {
          await app.close();
        }
      } finally {
        await pool.end();
        await admin.query(`DROP SCHEMA ${namespace} CASCADE`);
      }
    } finally {
      await admin.end();
    }
  },
);
