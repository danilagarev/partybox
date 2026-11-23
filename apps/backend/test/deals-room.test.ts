import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { Ajv } from 'ajv';
import pg from 'pg';
import { io } from 'socket.io-client';
import type { V7EnrollmentResult, V7Snapshot } from '@partybox/game-contracts/rooms-v7';
import { createApp } from '../src/bootstrap.js';
import { migrate } from '../src/rooms/migrate.js';

const schema = JSON.parse(
  readFileSync(
    new URL(import.meta.resolve('@partybox/game-contracts/rooms-v7.schema.json')),
    'utf8',
  ),
);
const ajv = new Ajv({ strict: true }).addSchema(schema);
const validate = ajv.compile<V7Snapshot>({ $ref: `${schema.$id}#/$defs/V7Snapshot` });

test(
  'v7 deals: six clients complete five rounds with atomic sales and private restoration',
  { skip: !process.env.TEST_DATABASE_URL },
  async () => {
    const admin = new pg.Pool({ connectionString: process.env.TEST_DATABASE_URL });
    const namespace = `pb_deals_${randomUUID().replaceAll('-', '')}`;
    await admin.query(`CREATE SCHEMA ${namespace}`);
    const url = new URL(process.env.TEST_DATABASE_URL!);
    url.searchParams.set('options', `-c search_path=${namespace}`);
    const databaseUrl = url.toString();
    const pool = new pg.Pool({ connectionString: databaseUrl });
    let time = Date.now();
    const config = { databaseUrl, tokenSecret: 'ab'.repeat(32), now: () => new Date(time) };
    let app: Awaited<ReturnType<typeof createApp>> | undefined;
    let origin = '';
    const post = (path: string, body: unknown, token?: string) =>
      fetch(origin + path, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
        },
        body: JSON.stringify(body),
      });
    const enroll = async (name: string, pin?: string, protocolVersion = 7) => {
      const response = await post(`/v${protocolVersion}/rooms${pin ? `/join/${pin}` : ''}`, {
        protocolVersion,
        name,
        requestId: randomUUID(),
        retryKey: randomBytes(32).toString('base64url'),
      });
      const body = await response.json();
      assert.equal(response.status, 201, JSON.stringify(body));
      if (protocolVersion === 7)
        assert.ok(validate(body.snapshot), ajv.errorsText(validate.errors));
      return body as V7EnrollmentResult;
    };
    const read = (player: V7EnrollmentResult, version = 7) =>
      fetch(`${origin}/v${version}/rooms/${player.snapshot.roomId}`, {
        headers: { Authorization: `Bearer ${player.guestToken}` },
      });
    const snapshot = async (player: V7EnrollmentResult) => {
      const result = await read(player);
      assert.equal(result.status, 200);
      const value: unknown = await result.json();
      assert.ok(validate(value), ajv.errorsText(validate.errors));
      return value;
    };
    const at = (view: V7Snapshot, type: string, payload: unknown = {}) => ({
      protocolVersion: 7,
      commandId: randomUUID(),
      expectedVersion: view.version,
      sessionId: view.publicState.deals?.sessionId ?? null,
      type,
      payload,
    });
    const send = (player: V7EnrollmentResult, command: unknown) =>
      post(`/v7/rooms/${player.snapshot.roomId}/commands`, command, player.guestToken);
    const accepted = async (response: Response) => {
      const body = await response.json();
      assert.equal(response.status, 201, JSON.stringify(body));
      return body;
    };
    const play = async (player: V7EnrollmentResult, type: string, payload?: unknown) =>
      accepted(await send(player, at(await snapshot(player), type, payload)));
    const restart = async () => {
      await app?.close();
      app = await createApp(config);
      await app.listen(0, '127.0.0.1');
      origin = await app.getUrl();
    };
    try {
      await migrate(pool);
      await restart();
      const host = await enroll('Игрок 1');
      const pin = host.snapshot.publicState.pin;
      const first = await enroll('Игрок 2', pin, 6);
      assert.equal(
        (await (await send(host, at(await snapshot(host), 'deals.start'))).json()).code,
        'CLIENT_UPGRADE_REQUIRED',
      );
      await snapshot(first);
      const members = [host, first];
      while (members.length < 6) members.push(await enroll(`Игрок ${members.length + 1}`, pin));
      const extra = await enroll('Лишний', pin);
      assert.equal(
        (await (await send(host, at(await snapshot(host), 'deals.start'))).json()).code,
        'INVALID_PHASE',
      );
      await play(extra, 'room.leave');
      await play(host, 'deals.start');
      const views = await Promise.all(members.map(snapshot));
      const goalIds = views.flatMap((view) =>
        view.privateDeals!.goalOptions.map((goal) => goal.id),
      );
      assert.equal(new Set(goalIds).size, 12);
      const legacy = await (await read(first, 6)).json();
      assert.equal(legacy.publicState.deals, undefined);
      assert.equal(legacy.privateDeals, undefined);
      assert.equal(legacy.publicState.truth, null);
      await Promise.all(
        members.map(async (player, index) => {
          const view = views[index]!;
          await accepted(
            await send(
              player,
              at(view, 'deals.choose', {
                goalId: view.privateDeals!.goalOptions[0]!.id,
              }),
            ),
          );
        }),
      );
      const sellerId = host.snapshot.selfId;
      const cheap = views[0]!.privateDeals!.inventory.find((item) => item.value === 2)!;
      const sellerListing = async () =>
        play(host, 'deals.list', { itemId: cheap.id, category: 'art', value: 8, price: 6 });
      const pass = { itemId: null, category: null, value: null, price: null };
      await sellerListing();
      const beforeListing = await snapshot(first);
      assert.deepEqual(beforeListing.publicState.deals!.lots, []);
      assert.ok(!JSON.stringify(beforeListing).includes(cheap.id));
      await Promise.all(
        members
          .slice(1)
          .map(async (player) =>
            accepted(await send(player, at(beforeListing, 'deals.list', pass))),
          ),
      );
      await play(first, 'deals.inspect', { sellerId, mode: 'value' });
      const inspected = await snapshot(first);
      assert.equal(inspected.privateDeals!.inspection!.value, 2);
      assert.equal((await snapshot(members[2]!)).privateDeals!.inspection, null);
      assert.equal(inspected.publicState.deals!.lots[0]!.value, 8);
      const buyers = [first, members[2]!];
      const orders = buyers.map(() => at(inspected, 'deals.buy', { sellerId, insured: true }));
      const races = await Promise.all(buyers.map((player, index) => send(player, orders[index])));
      assert.deepEqual(races.map((response) => response.status).sort(), [201, 409]);
      const winnerIndex = races.findIndex((response) => response.status === 201);
      const ack = await accepted(races[winnerIndex]!);
      const winner = buyers[winnerIndex]!;
      const loser = buyers[1 - winnerIndex]!;
      const retried = await accepted(
        await send(winner, {
          ...orders[winnerIndex],
          payload: { insured: true, sellerId },
        }),
      );
      assert.deepEqual(retried, ack);
      const after = await snapshot(loser);
      assert.equal(
        (await send(loser, at(after, 'deals.buy', { sellerId, insured: false }))).status,
        400,
      );
      assert.ok(!JSON.stringify(after).includes(cheap.id));
      assert.equal(after.publicState.deals!.sales.length, 1);
      assert.equal(after.publicState.deals!.revealedSales, null);
      await restart();
      const socket = io(origin, {
        transports: ['websocket'],
        auth: { protocolVersion: 7, roomId: host.snapshot.roomId, guestToken: winner.guestToken },
      });
      try {
        const restored = await new Promise<V7Snapshot>((resolve, reject) => {
          const timer = setTimeout(() => reject(new Error('v7 snapshot timeout')), 5000);
          socket.once('room.snapshot', (wire: V7Snapshot) => {
            clearTimeout(timer);
            resolve(wire);
          });
          socket.once('connect_error', (error) => {
            clearTimeout(timer);
            reject(error);
          });
        });
        assert.ok(validate(restored), ajv.errorsText(validate.errors));
        assert.equal(restored.privateDeals!.purchases[0]!.item.id, cheap.id);
        assert.equal(restored.privateDeals!.balance, winnerIndex === 0 ? 34 : 36);
        assert.equal(restored.privateDeals!.insuranceAvailable, false);
      } finally {
        socket.close();
      }
      for (let round = 1; round <= 5; round++) {
        if (round > 1) {
          const listing = await snapshot(host);
          assert.equal(listing.publicState.deals!.round, round);
          await Promise.all(
            members.map(async (player) =>
              accepted(await send(player, at(listing, 'deals.list', pass))),
            ),
          );
        } else {
          time += 180_001;
        }
        const market = await snapshot(host);
        assert.equal(market.publicState.deals!.phase, 'market');
        const ready = new Set(market.publicState.deals!.readyIds);
        const priority = market.publicState.deals!.marketPriorityId;
        const open = market.publicState.deals!.market[0]!;
        const marketPlayers = members.filter((player) => !ready.has(player.snapshot.selfId));
        await Promise.all(
          marketPlayers.map(async (player) =>
            accepted(await send(player, at(market, 'deals.market', { itemId: open.item.id }))),
          ),
        );
        const recap = await snapshot(host);
        assert.equal(recap.publicState.deals!.phase, 'recap');
        const marketSales = recap.publicState.deals!.sales.filter((sale) => sale.sellerId === null);
        assert.equal(marketSales.length, 1);
        if (!ready.has(priority)) assert.equal(marketSales[0]!.buyerId, priority);
        await Promise.all(
          members.map(async (player) => accepted(await send(player, at(recap, 'deals.next')))),
        );
      }
      const final = (await snapshot(host)).publicState.deals!;
      assert.equal(final.phase, 'finished');
      assert.equal(final.results!.length, 6);
      assert.equal(final.revealedSales!.length, 6);
      assert.equal(final.revealedSales![0]!.purchase.item.id, cheap.id);
      assert.ok(
        final.results!.every(
          (result) => result.total === result.balance + result.goodsValue + result.bonus,
        ),
      );
      await play(host, 'deals.start');
      assert.notEqual((await snapshot(host)).publicState.deals!.sessionId, final.sessionId);
      await play(first, 'room.leave');
      assert.equal((await snapshot(host)).publicState.deals, null);
    } finally {
      await app?.close();
      await pool.end();
      await admin.query(`DROP SCHEMA ${namespace} CASCADE`);
      await admin.end();
    }
  },
);
