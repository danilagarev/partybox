import assert from 'node:assert/strict';
import { test } from 'node:test';
import { nextSpyLocation, spyPacks } from '../src/games/spy-content.js';

test('each pack rotates without repetition and avoids repeating at cycle boundaries', () => {
  for (const pack of spyPacks.values()) {
    let history: string[] = [];
    let last: string | undefined;
    for (let cycle = 0; cycle < 3; cycle++) {
      const seen = new Set<string>();
      for (let i = 0; i < pack.items.length; i++) {
        const selection = nextSpyLocation(pack, history, () => 0);
        assert.ok(!seen.has(selection.location));
        assert.notEqual(selection.location, last);
        seen.add(selection.location);
        last = selection.location;
        history = selection.history;
        assert.ok(history.length <= pack.items.length);
      }
      assert.equal(seen.size, pack.items.length);
    }
  }
});

test('single-location pack remains playable after exhaustion', () => {
  const pack = { id: 'test', version: 1, title: 'Test', items: [{ id: 'only', label: 'Only' }] };
  assert.deepEqual(
    nextSpyLocation(pack, ['only'], () => 0),
    { location: 'Only', history: ['only'] },
  );
});
