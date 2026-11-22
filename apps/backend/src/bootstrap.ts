import { webAssets } from './web-assets.js';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { RoomRuntime } from './rooms/room-runtime.js';
import { AppModule } from './app.module.js';

export async function createApp(
  options: {
    webRoot?: string;
    databaseUrl?: string;
    tokenSecret?: string;
    now?: () => Date;
    trustOneProxy?: boolean;
  } = {
    webRoot: process.env.WEB_ROOT,
    databaseUrl: process.env.DATABASE_URL,
    tokenSecret: process.env.ROOM_TOKEN_SECRET,
    trustOneProxy: process.env.TRUST_PROXY_HOPS === '1',
  },
) {
  const runtime = new RoomRuntime(options);
  const app = await NestFactory.create<NestExpressApplication>(AppModule.register(runtime), {
    logger: ['error', 'warn', 'log'],
    bodyParser: false,
  });
  app.useBodyParser('json', { limit: '8kb' });
  app.use(
    (_req: unknown, res: { setHeader: (key: string, value: string) => void }, next: () => void) => {
      res.setHeader('Cache-Control', 'no-store');
      next();
    },
  );
  if (options.webRoot && existsSync(resolve(options.webRoot, 'index.html')))
    app.use(await webAssets(options.webRoot));
  runtime.attach(app);
  app.enableShutdownHooks();
  return app;
}
