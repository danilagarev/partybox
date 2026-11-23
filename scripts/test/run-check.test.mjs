import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { runCheck, sourceFingerprint } from '../run-check.mjs';

test('check receipts retain failures and logs, and detect source changes including untracked files', async () => {
  const cwd = await mkdtemp(join(tmpdir(), 'partybox-check-'));
  const git = (...args) => execFileSync('git', args, { cwd, stdio: 'ignore' });
  try {
    git('init');
    await writeFile(join(cwd, '.gitignore'), 'output/\n');
    git('add', '.gitignore');
    git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-m', 'fixture');
    const initial = await sourceFingerprint(cwd);
    const failed = await runCheck({
      name: 'failure',
      cwd,
      command: [process.execPath, '-e', 'console.log("diagnostic"); process.exit(7)'],
    });
    assert.equal(failed.exitCode, 7);
    assert.equal(failed.sourceStable, true);
    assert.match(await readFile(failed.logPath, 'utf8'), /diagnostic/);
    assert.equal(JSON.parse(await readFile(failed.receiptPath, 'utf8')).exitCode, 7);
    assert.equal(await sourceFingerprint(cwd), initial);
    const changed = await runCheck({
      name: 'mutation',
      cwd,
      command: [process.execPath, '-e', 'require("fs").writeFileSync("new-source", "changed")'],
    });
    assert.equal(changed.exitCode, 0);
    assert.equal(changed.sourceStable, false);
    assert.notEqual(await sourceFingerprint(cwd), initial);
    const missing = await runCheck({ name: 'missing', cwd, command: ['partybox-missing-command'] });
    assert.equal(missing.exitCode, 1);
    assert.match(missing.error, /ENOENT/);
  } finally {
    await rm(cwd, { recursive: true, force: true });
  }
});
