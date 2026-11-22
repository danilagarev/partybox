import { createReadStream } from 'node:fs';
import { realpath, stat } from 'node:fs/promises';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { extname, resolve, sep } from 'node:path';
import { pipeline } from 'node:stream';
const mime: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json',
  '.wasm': 'application/wasm',
  '.css': 'text/css',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff2': 'font/woff2',
  '.bin': 'application/octet-stream',
  '.frag': 'application/octet-stream',
};
/** Explicit Flutter assets only. API paths and missing assets never become index.html. */
export async function webAssets(directory: string) {
  const root = await realpath(directory);
  if (!(await stat(resolve(root, 'index.html'))).isFile())
    throw new Error('WEB_ROOT needs index.html');
  return async (req: IncomingMessage, res: ServerResponse, next: () => void) => {
    if (!['GET', 'HEAD'].includes(req.method ?? '')) return next();
    try {
      const path = decodeURIComponent((req.url ?? '/').split('?')[0]!);
      if (
        !path.startsWith('/') ||
        /[\\\0]/.test(path) ||
        path.split('/').some((p) => p.startsWith('.') || p === '..')
      )
        return next();
      const relative = path === '/' ? 'index.html' : path.slice(1);
      if (
        !/^(?:index\.html|flutter(?:_bootstrap)?\.js|main\.dart\.(?:js|wasm|mjs)|manifest\.json|version\.json|favicon\.png|(?:assets|canvaskit|icons)\/[^?]+)$/.test(
          relative,
        )
      )
        return next();
      const file = await realpath(resolve(root, relative));
      if (!file.startsWith(root + sep)) return next();
      const info = await stat(file);
      if (!info.isFile()) return next();
      const revalidate =
        relative.startsWith('assets/') ||
        relative.startsWith('canvaskit/') ||
        /^main\.dart\.(?:js|wasm|mjs)$/.test(relative);
      const etag = `W/"${info.size.toString(16)}-${info.mtimeMs.toString(16)}"`;
      const headers = {
        'Content-Type': mime[extname(file)] ?? 'application/octet-stream',
        'Cache-Control': revalidate ? 'no-cache' : 'no-store',
        ETag: etag,
        'X-Content-Type-Options': 'nosniff',
      };
      if (revalidate && req.headers['if-none-match'] === etag) {
        res.writeHead(304, headers).end();
        return;
      }
      res.writeHead(200, { ...headers, 'Content-Length': info.size });
      if (req.method === 'HEAD') {
        res.end();
        return;
      }
      pipeline(createReadStream(file), res, () => {});
    } catch {
      next();
    }
  };
}
