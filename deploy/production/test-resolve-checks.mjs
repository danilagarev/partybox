import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

const repo = 'example/partybox';
const checkedSha = 'a'.repeat(40);
const otherSha = 'b'.repeat(40);
const run = {
  id: 1234,
  run_attempt: 2,
  head_sha: checkedSha,
  head_branch: 'main',
  head_repository: { full_name: repo },
  event: 'push',
  status: 'completed',
  conclusion: 'success',
};
const releaseArtifact = `partybox-release-web-${checkedSha}-2`;

function resolveChecks(
  t,
  {
    event = 'workflow_run',
    upstream = run,
    workflow = '.github/workflows/ci.yml',
    currentMain = checkedSha,
    dispatchSha = otherSha,
    inputSha = '',
    branch = 'refs/heads/main',
    listedRuns = [run],
    availableArtifact = releaseArtifact,
  } = {},
) {
  const directory = mkdtempSync(join(tmpdir(), 'partybox-checks-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const eventPath = join(directory, 'event.json');
  const output = join(directory, 'output');
  const trace = join(directory, 'trace');
  writeFileSync(
    eventPath,
    JSON.stringify({ action: 'completed', workflow: { path: workflow }, workflow_run: upstream }),
  );
  writeFileSync(output, '');
  writeFileSync(trace, '');
  writeFileSync(
    join(directory, 'gh'),
    `#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TRACE"
case "$*" in
  *git/ref/heads/main*) printf '%s\n' "$CURRENT_MAIN" ;;
  *actions/workflows/ci.yml/runs*) printf '%s\n' "$LISTED_RUNS" ;;
  *actions/runs/1234/artifacts*) printf '%s\n' "$AVAILABLE_ARTIFACT" ;;
  *) exit 1 ;;
esac
`,
    { mode: 0o700 },
  );
  const result = spawnSync('bash', ['deploy/production/resolve-checks.sh'], {
    encoding: 'utf8',
    env: {
      ...process.env,
      PATH: `${directory}:${process.env.PATH}`,
      TRACE: trace,
      CURRENT_MAIN: currentMain,
      LISTED_RUNS: JSON.stringify({ workflow_runs: listedRuns }),
      AVAILABLE_ARTIFACT: availableArtifact,
      GITHUB_REPOSITORY: repo,
      GITHUB_EVENT_NAME: event,
      GITHUB_EVENT_PATH: eventPath,
      GITHUB_OUTPUT: output,
      GITHUB_SHA: dispatchSha,
      GITHUB_REF: branch,
      INPUT_SHA: inputSha,
    },
  });
  return { ...result, output: readFileSync(output, 'utf8'), trace: readFileSync(trace, 'utf8') };
}

test('automatic release selects the exact triggering Checks commit, run and attempt', (t) => {
  const result = resolveChecks(t);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.output, `sha=${checkedSha}\nrun_id=1234\nartifact=${releaseArtifact}\n`);
  assert.match(result.trace, /git\/ref\/heads\/main/);
  assert.doesNotMatch(result.trace, /actions\/workflows/);
});

test('automatic release skips a completed run superseded by a newer main push', (t) => {
  const result = resolveChecks(t, { currentMain: otherSha });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.output, '');
  assert.match(result.stdout, /superseded/);
});

test('automatic release rejects unsuccessful or unrelated runs', (t) => {
  for (const update of [
    { event: 'pull_request' },
    { event: 'workflow_dispatch' },
    { head_branch: 'feature' },
    { head_repository: { full_name: 'fork/partybox' } },
    { conclusion: 'failure' },
    { status: 'in_progress' },
  ]) {
    const result = resolveChecks(t, { upstream: { ...run, ...update } });
    assert.notEqual(result.status, 0, JSON.stringify(update));
    assert.equal(result.output, '');
    assert.equal(result.trace, '');
  }
  const result = resolveChecks(t, { workflow: '.github/workflows/another.yml' });
  assert.notEqual(result.status, 0);
  assert.equal(result.output, '');
});

test('manual release uses its requested Checks SHA even after main advances', (t) => {
  const result = resolveChecks(t, {
    event: 'workflow_dispatch',
    inputSha: checkedSha,
    listedRuns: [{ ...run, head_sha: otherSha }, { ...run, event: 'pull_request' }, run],
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.output, `sha=${checkedSha}\nrun_id=1234\nartifact=${releaseArtifact}\n`);
  assert.ok(result.trace.includes(`head_sha=${checkedSha} -f branch=main -f event=push`));
});

test('manual release defaults to the dispatch commit and accepts the legacy bundle', (t) => {
  const result = resolveChecks(t, {
    event: 'workflow_dispatch',
    dispatchSha: checkedSha,
    availableArtifact: '',
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(
    result.output,
    `sha=${checkedSha}\nrun_id=1234\nartifact=partybox-web-${checkedSha}\n`,
  );
});

test('manual release requires a full SHA with a successful push from main', (t) => {
  for (const update of [
    { inputSha: 'main' },
    { branch: 'refs/heads/feature' },
    { listedRuns: [] },
  ]) {
    const result = resolveChecks(t, {
      event: 'workflow_dispatch',
      inputSha: checkedSha,
      ...update,
    });
    assert.notEqual(result.status, 0, JSON.stringify(update));
    assert.equal(result.output, '');
  }
});
