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
import { RoomError } from './room-error.js';
import { RoomRuntime } from './room-runtime.js';
import { bearer, parseEnrollment, parseLeave, parseRoomId } from './contracts.js';
type Request = { socket: { remoteAddress?: string }; headers?: Record<string, unknown> };

@Controller('rooms')
export class RoomController {
  constructor(@Inject(RoomRuntime) private readonly runtime: RoomRuntime) {}
  private async execute<T>(
    request: Request,
    operation: string,
    limit: number,
    action: () => Promise<T>,
  ): Promise<T> {
    try {
      await this.runtime
        .requireService()
        .rateLimit(this.runtime.clientAddress(request), operation, limit);
      return await action();
    } catch (error) {
      const failure =
        error instanceof RoomError ? error : new RoomError('SERVICE_UNAVAILABLE', 503);
      throw new HttpException({ protocolVersion: 1, code: failure.code }, failure.status);
    }
  }
  @Post()
  create(@Req() request: Request, @Body() body: unknown) {
    return this.execute(request, 'create', 10, async () =>
      this.runtime.requireService().enroll(parseEnrollment(body)),
    );
  }
  @Post('join/:pin')
  join(@Req() request: Request, @Param('pin') pin: string, @Body() body: unknown) {
    return this.execute(request, 'join', 30, async () => {
      if (!/^[0-9]{6}$/.test(pin)) throw new RoomError('INVALID_REQUEST', 400);
      const result = await this.runtime.requireService().enroll(parseEnrollment(body), pin);
      await this.runtime.publish(result.snapshot.roomId);
      return result;
    });
  }
  @Get(':roomId')
  snapshot(
    @Req() request: Request,
    @Param('roomId') roomId: string,
    @Headers('authorization') authorization?: string,
  ) {
    return this.execute(request, 'snapshot', 120, () =>
      this.runtime.requireService().snapshot(parseRoomId(roomId), bearer(authorization)),
    );
  }
  @Post(':roomId/commands')
  command(
    @Req() request: Request,
    @Param('roomId') roomId: string,
    @Body() body: unknown,
    @Headers('authorization') authorization?: string,
  ) {
    return this.execute(request, 'command', 120, async () => {
      const ack = await this.runtime
        .requireService()
        .leave(parseRoomId(roomId), bearer(authorization), parseLeave(body));
      await this.runtime.publish(roomId);
      return ack;
    });
  }
}
