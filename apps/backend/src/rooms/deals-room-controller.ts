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
import { parseV7Command, parseV7Enrollment } from './deals-contracts.js';
type Request = { socket: { remoteAddress?: string }; headers?: Record<string, unknown> };
@Controller('v7/rooms')
export class DealsRoomController {
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
      throw new HttpException({ protocolVersion: 7, code: failure.code }, failure.status);
    }
  }
  @Post() create(@Req() req: Request, @Body() body: unknown) {
    return this.execute(req, 'create', 10, async () => {
      const enrolled = await this.runtime.requireService().enroll(parseV7Enrollment(body));
      return {
        guestToken: enrolled.guestToken,
        snapshot: await this.runtime
          .requireService()
          .snapshotV7(enrolled.snapshot.roomId, enrolled.guestToken),
      };
    });
  }
  @Post('join/:pin') join(@Req() req: Request, @Param('pin') pin: string, @Body() body: unknown) {
    return this.execute(req, 'join', 30, async () => {
      if (!/^\d{6}$/.test(pin)) throw new RoomError('INVALID_REQUEST', 400);
      const enrolled = await this.runtime.requireService().enroll(parseV7Enrollment(body), pin);
      const snapshot = await this.runtime
        .requireService()
        .snapshotV7(enrolled.snapshot.roomId, enrolled.guestToken);
      await this.runtime.publish(snapshot.roomId);
      return { guestToken: enrolled.guestToken, snapshot };
    });
  }
  @Get(':roomId') snapshot(
    @Req() req: Request,
    @Param('roomId') roomId: string,
    @Headers('authorization') token?: string,
  ) {
    return this.execute(req, 'snapshot-v7', 720, async () => {
      const identity = bearer(token);
      await this.runtime.requireService().rateLimit(identity, 'snapshot-member-v7', 120);
      return this.runtime.requireService().snapshotV7(parseRoomId(roomId), identity);
    });
  }
  @Post(':roomId/commands') command(
    @Req() req: Request,
    @Param('roomId') roomId: string,
    @Body() body: unknown,
    @Headers('authorization') token?: string,
  ) {
    return this.execute(req, 'command-v7', 720, async () => {
      const identity = bearer(token);
      await this.runtime.requireService().rateLimit(identity, 'command-member-v7', 120);
      const ack = await this.runtime
        .requireService()
        .commandV7(parseRoomId(roomId), identity, parseV7Command(body));
      await this.runtime.publish(roomId);
      return ack;
    });
  }
}
