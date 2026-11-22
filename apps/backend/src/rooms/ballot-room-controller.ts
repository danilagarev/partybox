import {
  Body,
  Controller,
  Get,
  Headers,
  HttpException,
  Inject,
  Param,
  Post,
  Req,
} from '@nestjs/common';
import { RoomRuntime } from './room-runtime.js';
import { RoomError } from './room-error.js';
import { bearer, parseRoomId } from './contracts.js';
import { parseV5Command, parseV5Enrollment } from './ballot-contracts.js';
type Request = { socket: { remoteAddress?: string }; headers?: Record<string, unknown> };
@Controller('v5/rooms')
export class BallotRoomController {
  constructor(@Inject(RoomRuntime) private readonly runtime: RoomRuntime) {}
  private async execute<T>(
    request: Request,
    operation: string,
    limit: number,
    action: () => Promise<T>,
  ) {
    try {
      await this.runtime
        .requireService()
        .rateLimit(this.runtime.clientAddress(request), operation, limit);
      return await action();
    } catch (error) {
      const failure =
        error instanceof RoomError ? error : new RoomError('SERVICE_UNAVAILABLE', 503);
      throw new HttpException({ protocolVersion: 5, code: failure.code }, failure.status);
    }
  }
  @Post() create(@Req() req: Request, @Body() body: unknown) {
    return this.execute(req, 'create', 10, async () => {
      const enrolled = await this.runtime.requireService().enroll(parseV5Enrollment(body));
      return {
        guestToken: enrolled.guestToken,
        snapshot: await this.runtime
          .requireService()
          .snapshotV5(enrolled.snapshot.roomId, enrolled.guestToken),
      };
    });
  }
  @Post('join/:pin') join(@Req() req: Request, @Param('pin') pin: string, @Body() body: unknown) {
    return this.execute(req, 'join', 30, async () => {
      if (!/^\d{6}$/.test(pin)) throw new RoomError('INVALID_REQUEST', 400);
      const enrolled = await this.runtime.requireService().enroll(parseV5Enrollment(body), pin);
      const snapshot = await this.runtime
        .requireService()
        .snapshotV5(enrolled.snapshot.roomId, enrolled.guestToken);
      await this.runtime.publish(snapshot.roomId);
      return { guestToken: enrolled.guestToken, snapshot };
    });
  }
  @Get(':roomId') snapshot(
    @Req() req: Request,
    @Param('roomId') roomId: string,
    @Headers('authorization') token?: string,
  ) {
    return this.execute(req, 'snapshot-v5', 720, async () => {
      const identity = bearer(token);
      await this.runtime.requireService().rateLimit(identity, 'snapshot-member-v5', 120);
      return this.runtime.requireService().snapshotV5(parseRoomId(roomId), identity);
    });
  }
  @Post(':roomId/commands') command(
    @Req() req: Request,
    @Param('roomId') roomId: string,
    @Body() body: unknown,
    @Headers('authorization') token?: string,
  ) {
    return this.execute(req, 'command-v5', 720, async () => {
      const identity = bearer(token);
      await this.runtime.requireService().rateLimit(identity, 'command-member-v5', 120);
      const ack = await this.runtime
        .requireService()
        .commandV5(parseRoomId(roomId), identity, parseV5Command(body));
      await this.runtime.publish(roomId);
      return ack;
    });
  }
}
