import { spyPacks, nextSpyLocation } from '../games/spy-content.js';
import type { GameCommand, GameAck, GameSnapshot } from '@partybox/game-contracts/rooms-v2';
import {
  createSpy,
  acknowledgeSpy,
  advanceSpy,
  voteSpy,
  accuseSpy,
  spyCard,
  spyPublic,
  SpyRuleError,
  type SpyState,
} from '../games/spy.js';
import { createHash, createHmac, randomInt, randomUUID } from 'node:crypto';
import pg from 'pg';
import type {
  Enrollment,
  EnrollmentResult,
  LeaveRoom,
  Ack,
  Snapshot,
} from '@partybox/game-contracts/rooms-v1';
import { RoomError } from './room-error.js';

interface Member {
  id: string;
  name: string;
  tokenHash: string;
  left: boolean;
  gameClient?: boolean;
}
interface Room {
  id: string;
  pin: string;
  version: number;
  expiresAt: string;
  hostId: string;
  closed: boolean;
  members: Member[];
  game?: { id: string; packId: string; packVersion: number; state: SpyState; readyIds: string[] };
  spyHistory?: Record<string, string[]>;
}
const hash = (value: string) => createHash('sha256').update(value).digest('hex');
const ttl = 24 * 60 * 60 * 1000;

export class RoomService {
  constructor(
    readonly pool: pg.Pool,
    private readonly secret: string,
    private readonly now = () => new Date(),
    private readonly onChanged?: (id: string) => void,
  ) {
    if (!/^[a-f0-9]{64}$/.test(secret))
      throw new Error('ROOM_TOKEN_SECRET must be 32 random bytes encoded as hex');
  }

  private token(request: Enrollment) {
    return createHmac('sha256', this.secret)
      .update(`${request.requestId}:${request.retryKey}`)
      .digest('base64url');
  }

  async ready() {
    await this.pool.query(
      'SELECT 1 FROM pb_rooms, pb_enrollments, pb_room_commands, pb_rate_limits LIMIT 0',
    );
  }
  async cleanupExpired() {
    return this.transaction(async (client) => {
      const now = this.now();
      const rooms = await client.query<{ id: string }>(
        'DELETE FROM pb_rooms WHERE expires_at<=$1 RETURNING id',
        [now],
      );
      const limits = await client.query('DELETE FROM pb_rate_limits WHERE reset_at<=$1', [now]);
      return { roomIds: rooms.rows.map((r) => r.id), rateLimits: limits.rowCount ?? 0 };
    });
  }
  async rateLimit(ip: string, operation: string, limit: number) {
    const now = this.now();
    // Stable keyed IP digest avoids storing raw addresses or trusting proxy headers.
    const key = createHmac('sha256', this.secret).update(`${operation}:${ip}`).digest('hex');
    const result = await this.pool.query<{ attempts: number }>(
      `INSERT INTO pb_rate_limits(bucket, attempts, reset_at) VALUES($1, 1, $2)
       ON CONFLICT(bucket) DO UPDATE SET
       attempts = CASE WHEN pb_rate_limits.reset_at <= $3 THEN 1 ELSE pb_rate_limits.attempts + 1 END,
       reset_at = CASE WHEN pb_rate_limits.reset_at <= $3 THEN $2 ELSE pb_rate_limits.reset_at END
       RETURNING attempts`,
      [key, new Date(now.getTime() + 60_000), now],
    );
    if (result.rows[0]!.attempts > limit) throw new RoomError('RATE_LIMITED', 429);
  }

  private async transaction<T>(action: (client: pg.PoolClient) => Promise<T>) {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      const result = await action(client);
      await client.query('COMMIT');
      return result;
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  }

  private async read(client: pg.PoolClient, roomId: string) {
    const result = await client.query<{ state: Room }>(
      'SELECT state FROM pb_rooms WHERE id=$1 FOR UPDATE',
      [roomId],
    );
    if (!result.rows[0]) throw new RoomError('ROOM_UNAVAILABLE', 404);
    return result.rows[0].state;
  }

  private active(room: Room) {
    if (this.now().getTime() >= Date.parse(room.expiresAt))
      throw new RoomError('ROOM_EXPIRED', 410);
    if (room.closed) throw new RoomError('ROOM_CLOSED', 410);
  }

  private member(room: Room, token: string, allowLeft = false) {
    const member = room.members.find((m) => m.tokenHash === hash(token));
    if (!member || (member.left && !allowLeft)) throw new RoomError('UNAUTHORIZED', 401);
    return member;
  }

  private view(room: Room, member: Member): Snapshot {
    return {
      protocolVersion: 1,
      roomId: room.id,
      version: room.version,
      serverTime: this.now().toISOString(),
      selfId: member.id,
      privateState: null,
      publicState: {
        phase: 'lobby',
        pin: room.pin,
        hostId: room.hostId,
        expiresAt: room.expiresAt,
        players: room.members.filter((m) => !m.left).map(({ id, name }) => ({ id, name })),
      },
    };
  }

  async enroll(request: Enrollment, pin?: string): Promise<EnrollmentResult> {
    const fingerprint = hash(
      JSON.stringify({ name: request.name.trim(), pin: pin ?? null, protocolVersion: 1 }),
    );
    return this.transaction(async (client) => {
      await client.query('SELECT pg_advisory_xact_lock(hashtext($1))', [request.requestId]);
      const previous = await client.query<{
        retry_hash: string;
        fingerprint: string;
        room_id: string;
      }>('SELECT * FROM pb_enrollments WHERE request_id=$1', [request.requestId]);
      const old = previous.rows[0];
      if (old) {
        if (old.retry_hash !== hash(request.retryKey) || old.fingerprint !== fingerprint)
          throw new RoomError('COMMAND_CONFLICT', 409);
        const room = await this.read(client, old.room_id);
        const member = this.member(room, this.token(request));
        this.active(room);
        return { guestToken: this.token(request), snapshot: this.view(room, member) };
      }
      const member: Member = {
        id: randomUUID(),
        name: request.name.trim(),
        tokenHash: hash(this.token(request)),
        left: false,
      };
      let room: Room;
      if (pin !== undefined) {
        const result = await client.query<{ state: Room }>(
          'SELECT state FROM pb_rooms WHERE pin=$1 FOR UPDATE',
          [pin],
        );
        if (!result.rows[0]) throw new RoomError('ROOM_UNAVAILABLE', 404);
        room = result.rows[0].state;
        // Joining a PIN never discloses whether an unavailable room existed.
        if (room.closed || this.now().getTime() >= Date.parse(room.expiresAt))
          throw new RoomError('ROOM_UNAVAILABLE', 404);
        if (room.game && room.game.state.phase !== 'results')
          throw new RoomError('ROOM_UNAVAILABLE', 409);
        if (room.members.filter((m) => !m.left).length >= 12) throw new RoomError('ROOM_FULL', 409);
        room.members.push(member);
        room.version++;
      } else {
        room = {
          id: randomUUID(),
          pin: '',
          version: 1,
          expiresAt: new Date(this.now().getTime() + ttl).toISOString(),
          hostId: member.id,
          closed: false,
          members: [member],
        };
        let inserted = false;
        for (let attempt = 0; attempt < 20; attempt++) {
          room.pin = randomInt(0, 1_000_000).toString().padStart(6, '0');
          const result = await client.query(
            'INSERT INTO pb_rooms(id,pin,expires_at,state) VALUES($1,$2,$3,$4) ON CONFLICT(pin) DO NOTHING',
            [room.id, room.pin, room.expiresAt, room],
          );
          if (result.rowCount) {
            inserted = true;
            break;
          }
        }
        if (!inserted) throw new RoomError('SERVICE_UNAVAILABLE', 503);
      }
      await client.query('UPDATE pb_rooms SET state=$2 WHERE id=$1', [room.id, room]);
      await client.query(
        'INSERT INTO pb_enrollments(request_id,retry_hash,fingerprint,room_id,player_id) VALUES($1,$2,$3,$4,$5)',
        [request.requestId, hash(request.retryKey), fingerprint, room.id, member.id],
      );
      return { guestToken: this.token(request), snapshot: this.view(room, member) };
    });
  }

  async snapshot(roomId: string, token: string): Promise<Snapshot> {
    return this.transaction(async (client) => {
      const room = await this.read(client, roomId);
      const member = this.member(room, token);
      this.active(room);
      return this.view(room, member);
    });
  }

  async leave(roomId: string, token: string, command: LeaveRoom): Promise<Ack> {
    return this.transaction(async (client) => {
      const room = await this.read(client, roomId);
      const member = this.member(room, token, true);
      // Expiry is terminal even for retries; explicit leave can be retried after closure.
      if (this.now().getTime() >= Date.parse(room.expiresAt))
        throw new RoomError('ROOM_EXPIRED', 410);
      const fingerprint = hash(
        JSON.stringify({
          protocolVersion: command.protocolVersion,
          commandId: command.commandId,
          expectedVersion: command.expectedVersion,
          type: command.type,
          payload: {},
        }),
      );
      const previous = await client.query<{ fingerprint: string; ack: Ack }>(
        'SELECT fingerprint,ack FROM pb_room_commands WHERE room_id=$1 AND player_id=$2 AND command_id=$3',
        [roomId, member.id, command.commandId],
      );
      const old = previous.rows[0];
      if (old) {
        if (old.fingerprint !== fingerprint) throw new RoomError('COMMAND_CONFLICT', 409);
        return old.ack;
      }
      if (member.left) throw new RoomError('UNAUTHORIZED', 401);
      this.active(room);
      if (command.expectedVersion !== room.version) throw new RoomError('VERSION_CONFLICT', 409);
      delete room.game;
      member.left = true;
      const remaining = room.members.filter((m) => !m.left);
      if (!remaining.length) room.closed = true;
      else if (room.hostId === member.id) room.hostId = remaining[0]!.id;
      room.version++;
      const ack: Ack = {
        protocolVersion: 1,
        commandId: command.commandId,
        accepted: true,
        version: room.version,
      };
      await client.query('UPDATE pb_rooms SET state=$2 WHERE id=$1', [roomId, room]);
      await client.query(
        'INSERT INTO pb_room_commands(room_id,player_id,command_id,fingerprint,ack) VALUES($1,$2,$3,$4,$5)',
        [roomId, member.id, command.commandId, fingerprint, ack],
      );
      return ack;
    });
  }
  private advanceGame(room: Room) {
    if (!room.game) return false;
    const next = advanceSpy(room.game.state, this.now().getTime());
    if (next === room.game.state) return false;
    room.game.state = next;
    room.version++;
    return true;
  }
  private gameView(room: Room, member: Member): GameSnapshot {
    const base = this.view(room, member);
    const game = room.game;
    const pub = game ? spyPublic(game.state) : null;
    return {
      ...base,
      protocolVersion: 2,
      publicState: {
        ...base.publicState,
        game: game
          ? {
              sessionId: game.id,
              packId: game.packId,
              packVersion: game.packVersion,
              phase: game.state.phase,
              readyIds: [...game.readyIds],
              deadline: pub!.deadline,
              result: pub && 'result' in pub ? pub.result! : null,
            }
          : null,
      },
      privateState: game && game.state.phase !== 'results' ? spyCard(game.state, member.id) : null,
    };
  }
  async snapshotGame(roomId: string, token: string): Promise<GameSnapshot> {
    let changed = false;
    const snapshot = await this.transaction(async (client) => {
      const room = await this.read(client, roomId);
      const member = this.member(room, token);
      this.active(room);
      const advanced = this.advanceGame(room);
      changed = advanced;
      if (!member.gameClient || advanced) {
        member.gameClient = true;
        await client.query('UPDATE pb_rooms SET state=$2 WHERE id=$1', [roomId, room]);
      }
      return this.gameView(room, member);
    });
    if (changed) this.onChanged?.(roomId);
    return snapshot;
  }
  async commandGame(roomId: string, token: string, command: GameCommand): Promise<GameAck> {
    return this.transaction(async (client) => {
      const room = await this.read(client, roomId);
      const member = this.member(room, token, true);
      if (this.now().getTime() >= Date.parse(room.expiresAt))
        throw new RoomError('ROOM_EXPIRED', 410);
      const fingerprint = hash(
        JSON.stringify({
          protocolVersion: 2,
          commandId: command.commandId,
          expectedVersion: command.expectedVersion,
          sessionId: command.sessionId,
          type: command.type,
          payload:
            command.type === 'spy.start'
              ? {
                  discussionMinutes: command.payload.discussionMinutes,
                  packId: command.payload.packId,
                }
              : command.payload,
        }),
      );
      const previous = await client.query<{ fingerprint: string; ack: GameAck }>(
        'SELECT fingerprint,ack FROM pb_room_commands WHERE room_id=$1 AND player_id=$2 AND command_id=$3',
        [roomId, member.id, command.commandId],
      );
      if (previous.rows[0]) {
        if (previous.rows[0].fingerprint !== fingerprint)
          throw new RoomError('COMMAND_CONFLICT', 409);
        return previous.rows[0].ack;
      }
      if (member.left) throw new RoomError('UNAUTHORIZED', 401);
      this.active(room);
      // Persisted deadlines are advanced by snapshots/background polling before further actions.
      if (command.expectedVersion !== room.version) throw new RoomError('VERSION_CONFLICT', 409);
      if (command.sessionId !== (room.game?.id ?? null))
        throw new RoomError('SESSION_CONFLICT', 409);
      try {
        if (command.type === 'room.leave') {
          member.left = true;
          delete room.game;
          const remaining = room.members.filter((m) => !m.left);
          if (!remaining.length) room.closed = true;
          else if (room.hostId === member.id) room.hostId = remaining[0]!.id;
        } else if (command.type === 'spy.ready') {
          const game = room.game;
          if (!game || game.state.phase !== 'distribution' || game.readyIds.includes(member.id))
            throw new RoomError('INVALID_PHASE', 409);
          game.readyIds.push(member.id);
          while (
            game.state.phase === 'distribution' &&
            game.readyIds.includes(game.state.players[game.state.distributedCount]!.id)
          )
            game.state = acknowledgeSpy(
              game.state,
              game.state.players[game.state.distributedCount]!.id,
              this.now().getTime(),
            );
        } else {
          if (room.hostId !== member.id) throw new RoomError('FORBIDDEN', 403);
          if (command.type === 'spy.start') {
            const pack = spyPacks.get(command.payload.packId);
            if (!pack) throw new RoomError('INVALID_REQUEST', 400);
            if (room.game && room.game.state.phase !== 'results')
              throw new RoomError('INVALID_PHASE', 409);
            const players = room.members.filter((m) => !m.left);
            if (players.length < 4) throw new RoomError('INVALID_PHASE', 409);
            if (players.some((m) => !m.gameClient))
              throw new RoomError('CLIENT_UPGRADE_REQUIRED', 409);
            const key = `${pack.id}:${pack.version}`;
            const selection = nextSpyLocation(pack, room.spyHistory?.[key] ?? [], randomInt);
            room.spyHistory = Object.fromEntries(
              [...spyPacks.values()].map((p) => {
                const k = `${p.id}:${p.version}`;
                return [k, k === key ? selection.history : (room.spyHistory?.[k] ?? [])];
              }),
            );
            room.game = {
              id: randomUUID(),
              packId: pack.id,
              packVersion: pack.version,
              state: createSpy(
                players.map(({ id, name }) => ({ id, name })),
                selection.location,
                randomInt(players.length),
                command.payload.discussionMinutes * 60000,
              ),
              readyIds: [],
            };
          } else if (command.type === 'spy.cancel') {
            if (!room.game) throw new RoomError('INVALID_PHASE', 409);
            delete room.game;
          } else {
            const game = room.game;
            if (!game) throw new RoomError('INVALID_PHASE', 409);
            const before = game.state.phase;
            game.state = advanceSpy(game.state, this.now().getTime());
            if (
              command.type === 'spy.vote' &&
              !(before === 'discussion' && game.state.phase === 'voting')
            )
              game.state = voteSpy(game.state);
            if (command.type === 'spy.accuse')
              game.state = accuseSpy(game.state, command.payload.suspectId);
          }
        }
      } catch (error) {
        if (error instanceof SpyRuleError) throw new RoomError('INVALID_PHASE', 409);
        throw error;
      }
      room.version++;
      const ack: GameAck = {
        protocolVersion: 2,
        commandId: command.commandId,
        accepted: true,
        version: room.version,
      };
      await client.query('UPDATE pb_rooms SET state=$2 WHERE id=$1', [roomId, room]);
      await client.query(
        'INSERT INTO pb_room_commands(room_id,player_id,command_id,fingerprint,ack) VALUES($1,$2,$3,$4,$5)',
        [roomId, member.id, command.commandId, fingerprint, ack],
      );
      return ack;
    });
  }
  async advanceDueGames(): Promise<string[]> {
    const rows = await this.pool.query<{ id: string }>(
      `SELECT id FROM pb_rooms WHERE expires_at>$1 AND state->'game'->'state'->>'phase'='discussion' AND (state->'game'->'state'->>'deadline')::bigint <= $2`,
      [this.now(), this.now().getTime()],
    );
    const changed: string[] = [];
    for (const { id } of rows.rows)
      await this.transaction(async (client) => {
        const room = await this.read(client, id);
        if (this.advanceGame(room)) {
          await client.query('UPDATE pb_rooms SET state=$2 WHERE id=$1', [id, room]);
          changed.push(id);
        }
      });
    return changed;
  }
}
