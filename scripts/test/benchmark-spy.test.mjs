import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { evaluateBudget, main } from '../benchmark-spy.mjs';

test('Spy benchmark emits matching JSON to stdout and the requested artifact with no default gate', async () => {
  const root = await mkdtemp(join(tmpdir(), 'partybox-benchmark-'));
  try {
    const output = join(root, 'reports', 'benchmark.json');
    let stdout = '';
    const status = await main(
      ['--iterations', '10', '--warmup', '2', '--output', output],
      (json) => (stdout += json),
    );
    assert.equal(status, 0);
    assert.equal(await readFile(output, 'utf8'), stdout);
    const report = JSON.parse(stdout);
    assert.equal(report.iterations, 10);
    assert.equal(report.warmup, 2);
    assert.equal(report.budget, null);
    assert.deepEqual(
      report.scenarios.map(({ players, outcome }) => [players, outcome]),
      [
        [4, 'result'],
        [12, 'pending'],
        [12, 'tie'],
        [12, 'result'],
      ],
    );
    for (const { p50Ms, p95Ms, throughputOpsPerSec } of report.scenarios) {
      assert.ok(Number.isFinite(p50Ms) && p50Ms >= 0);
      assert.ok(Number.isFinite(p95Ms) && p95Ms >= p50Ms);
      assert.ok(Number.isFinite(throughputOpsPerSec) && throughputOpsPerSec > 0);
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('Spy benchmark budget is opt-in and uses the p95 of every scenario', () => {
  const scenarios = [
    { name: 'first', p95Ms: 0.1 },
    { name: 'second', p95Ms: 0.2 },
  ];
  assert.equal(evaluateBudget(scenarios, null), null);
  assert.deepEqual(evaluateBudget(scenarios, 0.2), {
    maxP95Ms: 0.2,
    passed: true,
    exceededScenarios: [],
  });
  assert.deepEqual(evaluateBudget(scenarios, 0.1), {
    maxP95Ms: 0.1,
    passed: false,
    exceededScenarios: ['second'],
  });
});

test('Spy benchmark rejects invalid iteration counts before running', async () => {
  await assert.rejects(main(['--iterations', '0']), /--iterations ожидает целое число/);
});
