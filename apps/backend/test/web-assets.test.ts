import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { createApp } from '../src/bootstrap.js';
test('optional web root serves only public Flutter assets and never masks API or secrets', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'pb-web-assets-'));
  const root = join(directory, 'public');
  await mkdir(join(root, 'assets'), { recursive: true });
  await writeFile(join(root, 'index.html'), '<html>PartyBox</html>');
  await writeFile(join(root, 'assets', 'icon.svg'), '<svg/>');
  await writeFile(join(root, '.env'), 'PRIVATE');
  await writeFile(join(directory, 'private.txt'), 'PRIVATE');
  await symlink(join(directory, 'private.txt'), join(root, 'assets', 'outside.txt'));
  const app = await createApp({ webRoot: root });
  try {
    await app.listen(0, '127.0.0.1');
    const origin = await app.getUrl();
    const page = await fetch(origin);
    assert.equal(page.status, 200);
    assert.match(await page.text(), /PartyBox/);
    assert.equal(page.headers.get('cache-control'), 'no-store');
    const asset = await fetch(origin + '/assets/icon.svg');
    assert.equal(asset.status, 200);
    assert.equal(asset.headers.get('cache-control'), 'no-cache');
    assert.match(asset.headers.get('content-type')!, /image\/svg/);
    const unchanged = await fetch(origin + '/assets/icon.svg', {
      headers: { 'If-None-Match': asset.headers.get('etag')! },
    });
    assert.equal(unchanged.status, 304);
    assert.equal(await unchanged.text(), '');
    for (const path of [
      '/.env',
      '/%2eenv',
      '/assets/outside.txt',
      '/assets/%2e%2e%2f%2eenv',
      '/unknown',
    ]) {
      const response = await fetch(origin + path);
      assert.equal(response.status, 404, path);
      assert.doesNotMatch(await response.text(), /PRIVATE|<html>PartyBox/);
    }
    assert.deepEqual(await (await fetch(origin + '/health')).json(), { status: 'ok' });
    const room = await fetch(origin + '/v4/rooms', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '{}',
    });
    assert.equal(room.status, 503);
    assert.equal(((await room.json()) as { protocolVersion: number }).protocolVersion, 4);
  } finally {
    await app.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test('Flutter app bundles revalidate while release entrypoints stay uncached', async () => {
  const root = await mkdtemp(join(tmpdir(), 'pb-web-bundles-'));
  const bundles = ['main.dart.js', 'main.dart.mjs', 'main.dart.wasm'];
  const entrypoints = ['index.html', 'flutter_bootstrap.js', 'version.json'];
  const original = 'release one';
  const replacement = 'updated release';
  for (const filename of [...bundles, ...entrypoints]) {
    await writeFile(join(root, filename), original);
  }
  const app = await createApp({ webRoot: root });
  try {
    await app.listen(0, '127.0.0.1');
    const origin = await app.getUrl();
    for (const filename of bundles) {
      const url = `${origin}/${filename}`;
      const initial = await fetch(url);
      const etag = initial.headers.get('etag');
      assert.equal(initial.status, 200);
      assert.equal(initial.headers.get('cache-control'), 'no-cache');
      assert.ok(etag);
      assert.equal(await initial.text(), original);

      const headers = { 'If-None-Match': etag };
      const unchanged = await fetch(url, { headers });
      assert.equal(unchanged.status, 304);
      assert.equal(unchanged.headers.get('etag'), etag);
      assert.equal(await unchanged.text(), '');

      await writeFile(join(root, filename), replacement);
      const updated = await fetch(url, { headers });
      assert.equal(updated.status, 200);
      assert.notEqual(updated.headers.get('etag'), etag);
      assert.equal(await updated.text(), replacement);
    }
    for (const filename of entrypoints) {
      const response = await fetch(`${origin}/${filename}`);
      assert.equal(response.status, 200);
      assert.equal(response.headers.get('cache-control'), 'no-store');
      await response.text();
    }
  } finally {
    await app.close();
    await rm(root, { recursive: true, force: true });
  }
});
