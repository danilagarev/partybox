import type { V5Command, V5Snapshot, V5Ack } from '@partybox/game-contracts/rooms-v5';
import type { V4Command, V4Snapshot, V4Ack } from '@partybox/game-contracts/rooms-v4';
import {
  createClues,
  answerClues,
  hintClues,
  nextClues,
  cluesPublic,
  cluesPrivate,
  CluesRuleError,
  type CluesState,
} from '../games/clues.js';
import { selectCluesQuestions, cluesPackVersion } from '../games/clues-content.js';
import type { V3Command, V3Snapshot, V3Ack } from '@partybox/game-contracts/rooms-v3';
import {
  createTolerance,
  rankTolerance,
  guessTolerance,
  nextTolerance,
  tolerancePublic,
  tolerancePrivate,
  ToleranceRuleError,
  type ToleranceState,
} from '../games/tolerance.js';
import { selectToleranceCards } from '../games/tolerance-content.js';
import { spyPacks, nextSpyLocation } from '../games/spy-content.js';
import type { GameCommand, GameAck, GameSnapshot } from '@partybox/game-contracts/rooms-v2';
import {
  createSpy,
  acknowledgeSpy,
  advanceSpy,
  voteSpy,
  accuseSpy,
  ballotSpy,
  spyVoting,
  spyBallot,
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
  toleranceClient?: boolean;
  cluesClient?: boolean;
  ballotClient?: boolean;
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
  tolerance?: { id: string; state: ToleranceState };
  clues?: { id: string; packVersion: number; state: CluesState };
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
    // Stable keyed identity digest avoids storing raw addresses or guest tokens.
    // IP buckets cap aggregate traffic; v4 additionally caps each guest identity.
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
        if (
          (room.game && room.game.state.phase !== 'results') ||
          (room.tolerance && room.tolerance.state.phase !== 'finished') ||
          (room.clues && room.clues.state.phase !== 'finished')
        )
          throw new RoomError('ROOM_UNAVAILABLE', 409);
        if (room.members.filter((m) => !m.left).length >= 12) throw new RoomError('ROOM_FULL', 409);
        // A completed party belongs to its frozen roster; a newcomer starts a fresh lobby.
        delete room.tolerance;
        delete room.clues;
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
      delete room.tolerance;
      delete room.clues;
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
    return this.snapshotBoth(roomId, token, 2) as Promise<GameSnapshot>;
  }
  async snapshotV3(roomId: string, token: string): Promise<V3Snapshot> {
    return this.snapshotBoth(roomId, token, 3) as Promise<V3Snapshot>;
  }
  async snapshotV4(roomId: string, token: string): Promise<V4Snapshot> {
    return this.snapshotBoth(roomId, token, 4) as Promise<V4Snapshot>;
  }
  async snapshotV5(roomId: string, token: string): Promise<V5Snapshot> {
    return this.snapshotBoth(roomId, token, 5) as Promise<V5Snapshot>;
  }
  private async snapshotBoth(
    roomId: string,
    token: string,
    protocol: 2 | 3 | 4 | 5,
  ): Promise<GameSnapshot | V3Snapshot | V4Snapshot | V5Snapshot> {
    let changed = false;
    const snapshot = await this.transaction(async (client) => {
      const room = await this.read(client, roomId);
      const member = this.member(room, token);
      this.active(room);
      if (protocol < 5 && room.game?.state.ballots)
        throw new RoomError('CLIENT_UPGRADE_REQUIRED', 409);
      const advanced = this.advanceGame(room);
      changed = advanced;
      if (
        !member.gameClient ||
        (protocol >= 3 && !member.toleranceClient) ||
        (protocol >= 4 && !member.cluesClient) ||
        (protocol === 5 && !member.ballotClient) ||
        advanced
      ) {
        member.gameClient = true;
        if (protocol >= 3) member.toleranceClient = true;
        if (protocol >= 4) member.cluesClient = true;
        if (protocol === 5) member.ballotClient = true;
        await client.query('UPDATE pb_rooms SET state=$2 WHERE id=$1', [roomId, room]);
      }
      const view = this.gameView(room, member);
      if (protocol === 2) return view;
      const v3 = {
        ...view,
        protocolVersion: 3 as const,
        publicState: {
          ...view.publicState,
          tolerance: room.tolerance
            ? tolerancePublic(room.tolerance.state, room.tolerance.id)
            : null,
        },
        privateTolerance: room.tolerance ? tolerancePrivate(room.tolerance.state, member.id) : null,
      };
      if (protocol === 3) return v3;
      const v4 = {
        ...v3,
        protocolVersion: 4 as const,
        publicState: {
          ...v3.publicState,
          clues: room.clues ? cluesPublic(room.clues.state, room.clues.id) : null,
        },
        privateClues: room.clues ? cluesPrivate(room.clues.state, member.id) : null,
      };
      if (protocol === 4) return v4;
      const voting = room.game ? spyVoting(room.game.state) : undefined;
      const ballot = room.game ? spyBallot(room.game.state, member.id) : undefined;
      return {
        ...v4,
        protocolVersion: 5 as const,
        publicState: {
          ...v4.publicState,
          game: v4.publicState.game
            ? {
                ...v4.publicState.game,
                ...(voting ? { voting } : {}),
              }
            : null,
        },
        privateState: v4.privateState
          ? { ...v4.privateState, ...(ballot ? { ballot } : {}) }
          : null,
      };
    });
    if (changed) this.onChanged?.(roomId);
    return snapshot;
  }
  async commandGame(roomId: string, token: string, command: GameCommand): Promise<GameAck> {
    return this.commandBoth(roomId, token, command) as Promise<GameAck>;
  }
  async commandV3(roomId: string, token: string, command: V3Command): Promise<V3Ack> {
    return this.commandBoth(roomId, token, command) as Promise<V3Ack>;
  }
  async commandV4(roomId: string, token: string, command: V4Command): Promise<V4Ack> {
    return this.commandBoth(roomId, token, command) as Promise<V4Ack>;
  }
  async commandV5(roomId: string, token: string, command: V5Command): Promise<V5Ack> {
    return this.commandBoth(roomId, token, command) as Promise<V5Ack>;
  }
  private async commandBoth(
    roomId: string,
    token: string,
    command: GameCommand | V3Command | V4Command | V5Command,
  ): Promise<GameAck | V3Ack | V4Ack | V5Ack> {
    return this.transaction(async (client) => {
      const room = await this.read(client, roomId);
      const member = this.member(room, token, true);
      if (this.now().getTime() >= Date.parse(room.expiresAt))
        throw new RoomError('ROOM_EXPIRED', 410);
      const fingerprint = hash(
        JSON.stringify({
          protocolVersion: command.protocolVersion,
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
      const previous = await client.query<{
        fingerprint: string;
        ack: GameAck | V3Ack | V4Ack | V5Ack;
      }>(
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
      // Other players' independent ballots may commit before this one.
      const independentBallot =
        command.type === 'spy.ballot' &&
        command.expectedVersion <= room.version &&
        room.game?.state.phase === 'voting' &&
        room.game.state.ballots?.round === command.payload.round;
      if (command.expectedVersion !== room.version && !independentBallot)
        throw new RoomError('VERSION_CONFLICT', 409);
      const expectedSession =
        command.protocolVersion === 2 && command.type === 'room.leave'
          ? (room.game?.id ?? null)
          : command.protocolVersion >= 4
            ? (room.clues?.id ?? room.tolerance?.id ?? room.game?.id ?? null)
            : (room.tolerance?.id ?? room.game?.id ?? null);
      if (command.sessionId !== expectedSession) throw new RoomError('SESSION_CONFLICT', 409);
      try {
        if (command.type === 'room.leave') {
          member.left = true;
          delete room.game;
          delete room.tolerance;
          delete room.clues;
          const remaining = room.members.filter((m) => !m.left);
          if (!remaining.length) room.closed = true;
          else if (room.hostId === member.id) room.hostId = remaining[0]!.id;
        } else if (command.type === 'clues.start') {
          if (room.hostId !== member.id) throw new RoomError('FORBIDDEN', 403);
          if (
            (room.game && room.game.state.phase !== 'results') ||
            (room.tolerance && room.tolerance.state.phase !== 'finished') ||
            (room.clues && room.clues.state.phase !== 'finished')
          )
            throw new RoomError('INVALID_PHASE', 409);
          const players = room.members.filter((m) => !m.left);
          if (players.some((m) => !m.cluesClient))
            throw new RoomError('CLIENT_UPGRADE_REQUIRED', 409);
          room.clues = {
            id: randomUUID(),
            packVersion: cluesPackVersion,
            state: createClues(
              players.map((p) => p.id),
              selectCluesQuestions(randomInt),
            ),
          };
          delete room.game;
          delete room.tolerance;
        } else if (
          command.type === 'clues.answer' ||
          command.type === 'clues.hint' ||
          command.type === 'clues.next' ||
          command.type === 'clues.cancel'
        ) {
          const game = room.clues;
          if (!game) throw new RoomError('INVALID_PHASE', 409);
          if (command.type === 'clues.answer')
            game.state = answerClues(
              game.state,
              member.id,
              command.payload.answer,
              command.payload.clueIndex,
            );
          else {
            if (room.hostId !== member.id) throw new RoomError('FORBIDDEN', 403);
            if (command.type === 'clues.hint') game.state = hintClues(game.state);
            else if (command.type === 'clues.next') game.state = nextClues(game.state);
            else delete room.clues;
          }
        } else if (command.type === 'tolerance.start') {
          if (room.hostId !== member.id) throw new RoomError('FORBIDDEN', 403);
          if (
            (room.game && room.game.state.phase !== 'results') ||
            (room.tolerance && room.tolerance.state.phase !== 'finished') ||
            (room.clues && room.clues.state.phase !== 'finished')
          )
            throw new RoomError('INVALID_PHASE', 409);
          const players = room.members.filter((m) => !m.left);
          if (players.length < 4) throw new RoomError('INVALID_PHASE', 409);
          if (players.some((m) => !m.toleranceClient))
            throw new RoomError('CLIENT_UPGRADE_REQUIRED', 409);
          room.tolerance = {
            id: randomUUID(),
            state: createTolerance(
              players.map((p) => p.id),
              selectToleranceCards(players.length, randomInt),
              players.map(() => randomInt(4)),
            ),
          };
          delete room.game;
          delete room.clues;
        } else if (
          command.type === 'tolerance.rank' ||
          command.type === 'tolerance.guess' ||
          command.type === 'tolerance.next' ||
          command.type === 'tolerance.cancel'
        ) {
          const game = room.tolerance;
          if (!game) throw new RoomError('INVALID_PHASE', 409);
          if (command.type === 'tolerance.rank')
            game.state = rankTolerance(game.state, member.id, command.payload.order);
          else if (command.type === 'tolerance.guess')
            game.state = guessTolerance(game.state, member.id, command.payload.position);
          else {
            if (room.hostId !== member.id) throw new RoomError('FORBIDDEN', 403);
            if (command.type === 'tolerance.next') game.state = nextTolerance(game.state);
            else delete room.tolerance;
          }
        } else if (command.type === 'spy.ballot') {
          if (room.tolerance || room.clues || !room.game) throw new RoomError('INVALID_PHASE', 409);
          room.game.state = ballotSpy(
            room.game.state,
            member.id,
            command.payload.round,
            command.payload.suspectId,
          );
        } else if (command.type === 'spy.ready') {
          if (room.tolerance || room.clues) throw new RoomError('INVALID_PHASE', 409);
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
          if (command.type !== 'spy.start' && (room.tolerance || room.clues))
            throw new RoomError('INVALID_PHASE', 409);
          if (command.type === 'spy.start') {
            if (
              (room.tolerance && room.tolerance.state.phase !== 'finished') ||
              (room.clues && room.clues.state.phase !== 'finished')
            )
              throw new RoomError('INVALID_PHASE', 409);
            const pack = spyPacks.get(command.payload.packId);
            if (!pack) throw new RoomError('INVALID_REQUEST', 400);
            if (room.game && room.game.state.phase !== 'results')
              throw new RoomError('INVALID_PHASE', 409);
            const players = room.members.filter((m) => !m.left);
            if (players.length < 4) throw new RoomError('INVALID_PHASE', 409);
            if (command.protocolVersion === 5 && players.some((m) => !m.ballotClient))
              throw new RoomError('CLIENT_UPGRADE_REQUIRED', 409);
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
            delete room.tolerance;
            delete room.clues;
            room.game = {
              id: randomUUID(),
              packId: pack.id,
              packVersion: pack.version,
              state: createSpy(
                players.map(({ id, name }) => ({ id, name })),
                selection.location,
                randomInt(players.length),
                command.payload.discussionMinutes * 60000,
                command.protocolVersion === 5,
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
        if (error instanceof CluesRuleError)
          throw new RoomError(
            error.code,
            error.code === 'FORBIDDEN' ? 403 : error.code === 'INVALID_REQUEST' ? 400 : 409,
          );
        if (error instanceof ToleranceRuleError)
          throw new RoomError(
            error.code,
            error.code === 'FORBIDDEN' ? 403 : error.code === 'INVALID_REQUEST' ? 400 : 409,
          );
        if (error instanceof SpyRuleError) throw new RoomError('INVALID_PHASE', 409);
        throw error;
      }
      room.version++;
      const ack: GameAck | V3Ack | V4Ack | V5Ack = {
        protocolVersion: command.protocolVersion,
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
