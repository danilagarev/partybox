import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import { once } from 'node:events';
import { mkdtemp, mkdir, writeFile, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { createPlayServer } from '../play-server.mjs';

async function fixture(t, handle = (_req, res) => res.end('backend'), options = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'partybox-proxy-test-'));
  const webRoot = join(directory, 'web');
  await mkdir(join(webRoot, 'assets'), { recursive: true });
  await writeFile(join(webRoot, 'index.html'), '<main>game</main>');
  await writeFile(join(webRoot, 'assets', 'pack.json'), '{"public":true}');
  await writeFile(join(directory, 'secret.json'), 'private');
  await symlink(join(directory, 'secret.json'), join(webRoot, 'assets', 'outside.json'));
  const backend = http.createServer(handle);
  const backendSockets = new Set();
  backend.on('connection', (socket) => {
    backendSockets.add(socket);
    socket.on('close', () => backendSockets.delete(socket));
  });
  backend.listen(0, '127.0.0.1');
  await once(backend, 'listening');
  const proxy = createPlayServer({ webRoot, backendPort: backend.address().port, ...options });
  proxy.listen(0, '127.0.0.1');
  await once(proxy, 'listening');
  t.after(async () => {
    proxy.closeClients();
    await new Promise((done) => proxy.close(done));
    backend.closeAllConnections();
    for (const socket of backendSockets) socket.destroy();
    await new Promise((done) => backend.close(done));
    await rm(directory, { recursive: true, force: true });
  });
  return { proxy, backend, port: proxy.address().port };
}

function request(port, path, { method = 'GET', body, headers = {} } = {}) {
  return new Promise((done, fail) => {
    const req = http.request({ hostname: '127.0.0.1', port, path, method, headers }, (res) => {
      let data = '';
      res.setEncoding('utf8').on('data', (chunk) => {
        data += chunk;
      });
      res.on('end', () => done({ status: res.statusCode, headers: res.headers, body: data }));
    });
    req.on('error', fail);
    req.end(body);
  });
}

test('only Flutter public assets are served; traversal, dotfiles and outside symlinks are denied', async (t) => {
  const { port } = await fixture(t);
  const index = await request(port, '/');
  assert.equal(index.status, 200);
  assert.equal(index.body, '<main>game</main>');
  assert.equal(index.headers['cache-control'], 'no-store');
  assert.equal((await request(port, '/assets/pack.json')).status, 200);
  for (const path of [
    '/.env',
    '/assets/.env',
    '/assets/../secret.json',
    '/assets/%2e%2e/%2e%2e/secret.json',
    '/assets/%2f..%2fsecret.json',
    '/assets/..%5csecret.json',
    '/assets/%00pack.json',
    '/assets/outside.json',
    '/package.json',
    '/flutter_service_worker.js',
    '/%ZZ',
  ]) {
    const response = await request(port, path);
    assert.equal(response.status, 404, path);
    assert.equal(response.body.includes('private'), false, path);
  }
  assert.equal((await request(port, '/', { method: 'POST', body: 'x' })).status, 405);
  const head = await request(port, '/', { method: 'HEAD' });
  assert.equal(head.status, 200);
  assert.equal(head.body, '');
  assert.equal(Number(head.headers['content-length']), index.body.length);
});

test('API commands preserve methods, query, bearer header, body and backend status', async (t) => {
  const received = [];
  const { port } = await fixture(t, async (req, res) => {
    let body = '';
    for await (const chunk of req) body += chunk;
    received.push({ method: req.method, url: req.url, token: req.headers.authorization, body });
    res.writeHead(409, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    res.end('{"code":"VERSION_CONFLICT"}');
  });
  for (const path of [
    '/rooms',
    '/v2/rooms/a/commands',
    '/v3/rooms/a/commands',
    '/v4/rooms/a/commands',
    '/v5/rooms/a/commands',
    '/v6/rooms/a/commands',
    '/v7/rooms/a/commands',
    '/socket.io/?EIO=4',
    '/health',
    '/ready',
  ]) {
    const response = await request(port, path, {
      method: 'POST',
      headers: { Authorization: 'Bearer test-only-token', 'Content-Type': 'application/json' },
      body: '{"type":"spy.ready"}',
    });
    assert.equal(response.status, 409);
    assert.equal(response.body, '{"code":"VERSION_CONFLICT"}');
    assert.deepEqual(received.at(-1), {
      method: 'POST',
      url: path,
      token: 'Bearer test-only-token',
      body: '{"type":"spy.ready"}',
    });
  }
  assert.equal((await request(port, '/v3/rooms-evil')).status, 404);
});

test('LAN ignores forged forwarded headers; Cloudflare trust accepts only one valid IP when explicitly enabled', async (t) => {
  for (const trustCloudflare of [false, true]) {
    const { port } = await fixture(t, (req, res) => res.end(req.headers['x-forwarded-for']), {
      trustCloudflare,
    });
    for (const cloudflare of [
      '198.51.100.17',
      '2001:db8::17',
      '198.51.100.17, 203.0.113.2',
      'invalid',
    ]) {
      const response = await request(port, '/ready', {
        headers: {
          'X-Forwarded-For': '203.0.113.99',
          'CF-Connecting-IP': cloudflare,
        },
      });
      const expected = trustCloudflare && net.isIP(cloudflare) ? cloudflare : '127.0.0.1';
      assert.equal(response.body, expected);
    }
  }
});

test(
  'Socket.IO upgrade forwards handshake, early bytes and bidirectional data; teardown closes upgraded clients',
  { timeout: 5000 },
  async (t) => {
    const { port, backend, proxy } = await fixture(t);
    let upgraded;
    backend.on('upgrade', (req, socket, head) => {
      upgraded = {
        url: req.url,
        auth: req.headers.authorization,
        forwarded: req.headers['x-forwarded-for'],
      };
      socket.write(
        'HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\nfrom-backend',
      );
      if (head.length) socket.write(head);
      socket.on('data', (data) => socket.write(data));
      socket.on('error', () => {});
    });
    const socket = net.connect(port, '127.0.0.1');
    t.after(() => socket.destroy());
    await once(socket, 'connect');
    let response = '';
    const until = (value) =>
      new Promise((done) => {
        if (response.includes(value)) return done();
        const read = (data) => {
          response += data.toString();
          if (response.includes(value)) {
            socket.removeListener('data', read);
            done();
          }
        };
        socket.on('data', read);
      });
    const initial = until('early-bytes');
    socket.write(
      'GET /socket.io/?EIO=4&transport=websocket HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nAuthorization: Bearer test-only-token\r\nX-Forwarded-For: 203.0.113.99\r\nCF-Connecting-IP: 198.51.100.17\r\n\r\nearly-bytes',
    );
    await initial;
    assert.match(response, /101 Switching Protocols/);
    assert.match(response, /from-backend/);
    assert.deepEqual(upgraded, {
      url: '/socket.io/?EIO=4&transport=websocket',
      auth: 'Bearer test-only-token',
      forwarded: '127.0.0.1',
    });
    const echoed = until('later-bytes');
    socket.write('later-bytes');
    await echoed;
    const closed = once(socket, 'close');
    proxy.closeClients();
    await closed;
  },
);
