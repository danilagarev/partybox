import { clientAddress } from './client-address.js';
import type { INestApplication } from '@nestjs/common';
import { Server } from 'socket.io';
import pg from 'pg';
import { RoomError } from './room-error.js';
import { RoomService } from './room-service.js';
import { parseRoomId, parseToken } from './contracts.js';

export class RoomRuntime {
  readonly service?: RoomService;
  private io?: Server;
  private readonly pool?: pg.Pool;
  private deadlineTimer?: ReturnType<typeof setInterval>;
  private polling = false;
  private cleanupTimer?: ReturnType<typeof setInterval>;
  private sweeping = false;
  private readonly trustOneProxy: boolean;
  constructor(
    options: {
      databaseUrl?: string;
      tokenSecret?: string;
      now?: () => Date;
      trustOneProxy?: boolean;
    } = {},
  ) {
    this.trustOneProxy = options.trustOneProxy ?? false;
    if (options.databaseUrl) {
      if (!options.tokenSecret) throw new Error('ROOM_TOKEN_SECRET is required with DATABASE_URL');
      this.pool = new pg.Pool({
        connectionString: options.databaseUrl,
        max: 10,
        connectionTimeoutMillis: 3000,
        statement_timeout: 5000,
      });
      this.pool.on('error', () => {
        /* No tokens, queries or connection strings in logs. */
      });
      this.service = new RoomService(this.pool, options.tokenSecret, options.now, (id) => {
        void this.publish(id);
      });
    }
  }
  clientAddress(request: {
    socket: { remoteAddress?: string };
    headers?: Record<string, unknown>;
  }) {
    return clientAddress(
      request.socket.remoteAddress,
      request.headers?.['x-forwarded-for'],
      this.trustOneProxy,
    );
  }
  requireService() {
    if (!this.service) throw new RoomError('SERVICE_UNAVAILABLE', 503);
    return this.service;
  }
  attach(app: INestApplication) {
    if (!this.service) return;
    const io = (this.io = new Server(app.getHttpServer(), {
      maxHttpBufferSize: 8192,
      serveClient: false,
    }));
    io.use(async (socket, next) => {
      try {
        const service = this.requireService();
        await service.rateLimit(
          clientAddress(
            socket.handshake.address,
            socket.handshake.headers['x-forwarded-for'],
            this.trustOneProxy,
          ),
          'socket',
          60,
        );
        const roomId = parseRoomId(socket.handshake.auth.roomId);
        const token = parseToken(socket.handshake.auth.guestToken);
        const protocolVersion = socket.handshake.auth.protocolVersion ?? 1;
        if (protocolVersion !== 1 && protocolVersion !== 2)
          throw new RoomError('INVALID_REQUEST', 400);
        const snapshot =
          protocolVersion === 2
            ? await service.snapshotGame(roomId, token)
            : await service.snapshot(roomId, token);
        socket.data = { roomId, token, protocolVersion, expiresAt: snapshot.publicState.expiresAt };
        next();
      } catch (error) {
        next(new Error(error instanceof RoomError ? error.code : 'SERVICE_UNAVAILABLE'));
      }
    });
    this.deadlineTimer = setInterval(() => {
      void this.pollDeadlines();
    }, 1000);
    this.deadlineTimer.unref();
    this.cleanupTimer = setInterval(() => {
      void this.cleanup();
    }, 60000);
    this.cleanupTimer.unref();
    void this.cleanup();
    io.on('connection', (socket) => {
      const timer = setTimeout(
        () => {
          socket.emit('room.error', {
            protocolVersion: socket.data.protocolVersion,
            code: 'ROOM_EXPIRED',
          });
          socket.disconnect(true);
        },
        Math.max(0, Date.parse(socket.data.expiresAt) - Date.now()),
      );
      timer.unref();
      socket.on('disconnect', () => clearTimeout(timer));
      // Reading after connection avoids missing commits between authentication and subscribe.
      void this.sendSnapshot(socket);
    });
  }
  private async sendSnapshot(socket: import('socket.io').Socket) {
    try {
      const snapshot =
        socket.data.protocolVersion === 2
          ? await this.requireService().snapshotGame(socket.data.roomId, socket.data.token)
          : await this.requireService().snapshot(socket.data.roomId, socket.data.token);
      if (socket.connected) socket.emit('room.snapshot', snapshot);
    } catch (error) {
      socket.emit('room.error', {
        protocolVersion: socket.data.protocolVersion,
        code: error instanceof RoomError ? error.code : 'SERVICE_UNAVAILABLE',
      });
      socket.disconnect(true);
    }
  }
  async publish(roomId: string) {
    // Single backend process for this iteration. Each connection gets its own projection.
    if (!this.io) return;
    await Promise.all(
      [...this.io.sockets.sockets.values()]
        .filter((s) => s.data.roomId === roomId)
        .map((s) => this.sendSnapshot(s)),
    );
  }
  private async pollDeadlines() {
    if (this.polling) return;
    this.polling = true;
    try {
      for (const id of await this.requireService().advanceDueGames()) await this.publish(id);
    } catch {
      /* A failed poll retries next second; no private state in logs. */
    } finally {
      this.polling = false;
    }
  }
  private async cleanup() {
    if (this.sweeping) return;
    this.sweeping = true;
    try {
      const result = await this.requireService().cleanupExpired();
      for (const id of result.roomIds) await this.publish(id);
    } catch {
      /* Retry without logging SQL or private state. */
    } finally {
      this.sweeping = false;
    }
  }
  async beforeApplicationShutdown() {
    clearInterval(this.deadlineTimer);
    clearInterval(this.cleanupTimer);
    if (this.io) await new Promise<void>((resolve) => this.io!.close(() => resolve()));
  }
  async onApplicationShutdown() {
    await this.pool?.end();
  }
}
