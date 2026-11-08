import assert from 'node:assert/strict';
import { test } from 'node:test';
import { clientAddress } from '../src/rooms/client-address.js';
test('forwarded identity is ignored unless exactly one trusted proxy is configured', () => {
  assert.equal(clientAddress('10.0.0.2', '203.0.113.7', false), '10.0.0.2');
  assert.equal(clientAddress('10.0.0.2', '198.51.100.99, 203.0.113.7', true), '203.0.113.7');
  assert.equal(clientAddress('10.0.0.2', 'not-an-ip', true), '10.0.0.2');
  assert.equal(clientAddress('::ffff:127.0.0.1', undefined, false), '127.0.0.1');
});
