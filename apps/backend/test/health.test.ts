import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createApp } from '../src/bootstrap.js';

test('HTTP health responds and unknown routes return 404', async () => {
  const app = await createApp({});
  try {
    await app.listen(0, '127.0.0.1');
    const origin = await app.getUrl();
    const health = await fetch(`${origin}/health`);
    assert.equal(health.status, 200);
    assert.deepEqual(await health.json(), { status: 'ok' });
    assert.equal((await fetch(`${origin}/unknown`)).status, 404);
    const ready = await fetch(`${origin}/ready`);
    assert.equal(ready.status, 503);
    assert.deepEqual(await ready.json(), { status: 'unavailable' });
    const rooms = await fetch(`${origin}/rooms`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '{}',
    });
    assert.equal(rooms.status, 503);
    assert.deepEqual(await rooms.json(), { protocolVersion: 1, code: 'SERVICE_UNAVAILABLE' });
  } finally {
    await app.close();
  }
});
