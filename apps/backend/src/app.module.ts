import { BallotRoomController } from './rooms/ballot-room-controller.js';
import { CluesRoomController } from './rooms/clues-room-controller.js';
import { ToleranceRoomController } from './rooms/tolerance-room-controller.js';
import { GameRoomController } from './rooms/game-room-controller.js';
import { RoomRuntime } from './rooms/room-runtime.js';
import { RoomController } from './rooms/room-controller.js';
import { Controller, Get, Module, Inject, HttpException } from '@nestjs/common';

@Controller('health')
class HealthController {
  @Get()
  health(): { status: 'ok' } {
    return { status: 'ok' };
  }
}

@Controller('ready')
class ReadinessController {
  constructor(@Inject(RoomRuntime) private readonly runtime: RoomRuntime) {}
  @Get() async ready() {
    try {
      await this.runtime.requireService().ready();
      return { status: 'ready' };
    } catch {
      throw new HttpException({ status: 'unavailable' }, 503);
    }
  }
}

@Module({})
export class AppModule {
  static register(runtime: RoomRuntime) {
    return {
      module: AppModule,
      controllers: [
        HealthController,
        ReadinessController,
        RoomController,
        GameRoomController,
        ToleranceRoomController,
        CluesRoomController,
        BallotRoomController,
      ],
      providers: [{ provide: RoomRuntime, useValue: runtime }],
    };
  }
}
