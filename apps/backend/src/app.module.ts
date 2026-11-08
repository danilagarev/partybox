import { GameRoomController } from './rooms/game-room-controller.js';
import { RoomRuntime } from './rooms/room-runtime.js';
import { RoomController } from './rooms/room-controller.js';
import { Controller, Get, Module } from '@nestjs/common';

@Controller('health')
class HealthController {
  @Get()
  health(): { status: 'ok' } {
    return { status: 'ok' };
  }
}

@Module({})
export class AppModule {
  static register(runtime: RoomRuntime) {
    return {
      module: AppModule,
      controllers: [HealthController, RoomController, GameRoomController],
      providers: [{ provide: RoomRuntime, useValue: runtime }],
    };
  }
}
