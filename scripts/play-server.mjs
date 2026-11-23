import http from 'node:http';
import net from 'node:net';
import { createReadStream } from 'node:fs';
import { realpath, stat } from 'node:fs/promises';
import { extname, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import { pipeline } from 'node:stream';

const types = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json',
  '.css': 'text/css',
  '.wasm': 'application/wasm',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.bin': 'application/octet-stream',
  '.frag': 'application/octet-stream',
};
const apiPath = (path) =>
  /^\/(?:v[234567]\/rooms|rooms|socket\.io|health|ready)(?:\/|\?|$)/.test(path);

/** One origin for Flutter, HTTP commands and Socket.IO; never serves repository files. */
export function createPlayServer({ webRoot, backendPort, trustCloudflare = false }) {
  const headersFor = (req) => {
    const cloudflareIp = req.headers['cf-connecting-ip'];
    const address =
      trustCloudflare && typeof cloudflareIp === 'string' && net.isIP(cloudflareIp)
        ? cloudflareIp
        : req.socket.remoteAddress;
    return {
      ...req.headers,
      host: `127.0.0.1:${backendPort}`,
      'x-forwarded-for': address ?? '127.0.0.1',
    };
  };
  const sockets = new Set();
  const track = (socket) => {
    sockets.add(socket);
    socket.once('close', () => sockets.delete(socket));
  };
  const server = http.createServer(async (req, res) => {
    if (apiPath(req.url ?? '')) {
      const upstream = http.request(
        {
          hostname: '127.0.0.1',
          port: backendPort,
          method: req.method,
          path: req.url,
          headers: headersFor(req),
        },
        (reply) => {
          res.writeHead(reply.statusCode ?? 502, reply.headers);
          pipeline(reply, res, () => {});
        },
      );
      upstream.on('error', () => {
        if (!res.headersSent) res.writeHead(502);
        res.end();
      });
      req.once('aborted', () => upstream.destroy());
      res.once('close', () => {
        if (!res.writableFinished) upstream.destroy();
      });
      pipeline(req, upstream, () => {});
      return;
    }
    if (!['GET', 'HEAD'].includes(req.method)) {
      res.writeHead(405, { Allow: 'GET, HEAD' }).end();
      return;
    }
    try {
      const path = decodeURIComponent((req.url ?? '/').split('?')[0]);
      if (
        !path.startsWith('/') ||
        /[\\\0]/.test(path) ||
        path.split('/').some((part) => part.startsWith('.') || part === '..')
      ) {
        res.writeHead(404).end();
        return;
      }
      const relative = path === '/' ? 'index.html' : path.slice(1);
      // Only the Flutter entry points and known public asset directories are exposed.
      if (
        !/^(?:index\.html|flutter(?:_bootstrap)?\.js|main\.dart\.(?:js|wasm|mjs)|manifest\.json|version\.json|favicon\.png|(?:assets|canvaskit|icons)\/[^?]+)$/.test(
          relative,
        )
      ) {
        res.writeHead(404).end();
        return;
      }
      const contentType =
        types[extname(relative)] ??
        (relative.startsWith('assets/') && !extname(relative) ? 'application/octet-stream' : null);
      if (!contentType) {
        res.writeHead(404).end();
        return;
      }
      const root = await realpath(webRoot);
      const file = await realpath(resolve(root, relative));
      if (!file.startsWith(root + sep)) {
        res.writeHead(404).end();
        return;
      }
      const info = await stat(file);
      if (!info.isFile()) {
        res.writeHead(404).end();
        return;
      }
      res.writeHead(200, {
        'Content-Type': contentType,
        'Content-Length': info.size,
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
      });
      if (req.method === 'HEAD') res.end();
      else pipeline(createReadStream(file), res, () => {});
    } catch {
      if (!res.headersSent) res.writeHead(404);
      res.end();
    }
  });
  server.on('connection', track);
  server.on('upgrade', (req, socket, head) => {
    if (!/^\/socket\.io(?:\/|\?|$)/.test(req.url ?? '')) {
      socket.end('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
      return;
    }
    const upstream = net.connect(backendPort, '127.0.0.1');
    track(upstream);
    upstream.on('connect', () => {
      const headers = headersFor(req);
      upstream.write(
        `${req.method} ${req.url} HTTP/1.1\r\n${Object.entries(headers)
          .map(([key, value]) => `${key}: ${Array.isArray(value) ? value.join(', ') : value}`)
          .join('\r\n')}\r\n\r\n`,
      );
      if (head.length) upstream.write(head);
      socket.pipe(upstream).pipe(socket);
    });
    upstream.on('error', () => socket.destroy());
    socket.on('error', () => upstream.destroy());
    socket.on('close', () => upstream.destroy());
    upstream.on('close', () => socket.destroy());
  });
  // server.close does not close upgraded sockets on its own.
  server.closeClients = () => {
    for (const socket of sockets) socket.destroy();
  };
  return server;
}

async function runtime() {
  let app, proxy;
  let closing = false;
  const close = async () => {
    if (closing) return;
    closing = true;
    proxy?.closeClients();
    if (proxy?.listening) await new Promise((done) => proxy.close(done));
    await app?.close();
    if (process.connected) process.disconnect();
  };
  process.on('message', (message) => {
    if (message === 'stop') void close();
  });
  process.on('disconnect', () => {
    void close();
  });
  try {
    const [{ createApp }, { migrate }, { default: pg }] = await Promise.all([
      import('../apps/backend/dist/src/bootstrap.js'),
      import('../apps/backend/dist/src/rooms/migrate.js'),
      import('pg'),
    ]);
    const pool = new pg.Pool({
      connectionString: process.env.PLAY_DATABASE_URL,
      connectionTimeoutMillis: 3000,
      statement_timeout: 10000,
    });
    try {
      await migrate(pool);
    } finally {
      await pool.end();
    }
    app = await createApp({
      databaseUrl: process.env.PLAY_DATABASE_URL,
      tokenSecret: process.env.PLAY_TOKEN_SECRET,
      trustOneProxy: true,
    });
    await app.listen(0, '127.0.0.1');
    const backendPort = app.getHttpServer().address().port;
    const ready = await fetch(`http://127.0.0.1:${backendPort}/ready`, {
      signal: AbortSignal.timeout(5000),
    });
    if (!ready.ok) throw new Error('Backend readiness failed');
    proxy = createPlayServer({
      webRoot: process.env.PLAY_WEB_ROOT,
      backendPort,
      trustCloudflare: process.env.PLAY_TRUST_CLOUDFLARE === 'true',
    });
    await new Promise((done, fail) => {
      proxy.once('error', fail);
      proxy.listen(Number(process.env.PLAY_PORT), process.env.PLAY_HOST, done);
    });
    process.send?.({ ready: true, port: proxy.address().port });
  } catch {
    process.send?.({ error: true });
    await close();
    process.exitCode = 1;
  }
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  // IPC-only child; importing this module in tests never starts the backend.
  if (!process.send) {
    console.error('Запускайте node scripts/play.mjs lan или internet.');
    process.exitCode = 1;
  } else {
    void runtime();
  }
}
