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
  await writeFile(join(root, 'main.dart.js'), 'window.partybox=true');
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
    const script = await fetch(origin + '/main.dart.js');
    assert.equal(script.status, 200);
    assert.equal(script.headers.get('cache-control'), 'no-store');
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
