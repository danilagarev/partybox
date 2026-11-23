#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { spawn, execFileSync } from 'node:child_process';
import { mkdir, open, readFile, writeFile, lstat, readlink } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
export const checks = {
  node: ['npm', 'run', 'check'],
  mobile: ['make', 'check-mobile'],
  release: [
    'node',
    '--test',
    'deploy/production/test-release.mjs',
    'deploy/production/test-resolve-checks.mjs',
  ],
  context: ['node', 'scripts/project-context.mjs', '--check'],
};

// Include unstaged, staged and untracked sources, but never ignored artifacts/secrets.
export async function sourceFingerprint(cwd) {
  const hash = createHash('sha256');
  const files = execFileSync(
    'git',
    ['ls-files', '-z', '--cached', '--others', '--exclude-standard'],
    {
      cwd,
      encoding: 'utf8',
    },
  );
  for (const path of [...new Set(files.split('\0').filter(Boolean))].sort()) {
    hash.update(`${path}\0`);
    try {
      const info = await lstat(join(cwd, path));
      hash.update(`${info.mode}\0`);
      if (info.isSymbolicLink()) hash.update(await readlink(join(cwd, path)));
      else if (info.isFile()) hash.update(await readFile(join(cwd, path)));
      else hash.update('non-file');
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      hash.update('deleted');
    }
    hash.update('\0');
  }
  return hash.digest('hex');
}

export async function runCheck({ name, command, cwd = root, output = join(cwd, 'output/checks') }) {
  await mkdir(output, { recursive: true });
  const startedAt = new Date().toISOString();
  const id = `${startedAt.replaceAll(/[:.]/g, '-')}-${name}-${process.pid}`;
  const logPath = join(output, `${id}.log`);
  const receiptPath = join(output, `${id}.json`);
  const before = await sourceFingerprint(cwd);
  const log = await open(logPath, 'wx', 0o600);
  let result;
  try {
    result = await new Promise((done) => {
      const child = spawn(command[0], command.slice(1), {
        cwd,
        env: process.env,
        stdio: ['ignore', log.fd, log.fd],
      });
      child.once('error', (error) => done({ exitCode: 1, error: error.message }));
      child.once('close', (code, signal) => done({ exitCode: code ?? 1, signal }));
    });
  } finally {
    await log.close();
  }
  const after = await sourceFingerprint(cwd);
  const receipt = {
    name,
    command,
    startedAt,
    finishedAt: new Date().toISOString(),
    durationMs: Date.now() - Date.parse(startedAt),
    node: process.version,
    commit: execFileSync('git', ['rev-parse', 'HEAD'], { cwd, encoding: 'utf8' }).trim(),
    sourceBefore: before,
    sourceAfter: after,
    sourceStable: before === after,
    ...result,
    logPath,
  };
  await writeFile(receiptPath, `${JSON.stringify(receipt, null, 2)}\n`, { mode: 0o600 });
  return { ...receipt, receiptPath };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [name, ...extra] = process.argv.slice(2);
  if (!checks[name] || extra.length) {
    console.error(`Использование: node scripts/run-check.mjs <${Object.keys(checks).join('|')}>`);
    process.exitCode = 1;
  } else {
    console.log(`Проверка ${name}: ${checks[name].join(' ')}; полный вывод — output/checks/`);
    const result = await runCheck({ name, command: checks[name] });
    if (result.exitCode !== 0) {
      const log = await readFile(result.logPath, 'utf8');
      console.error(log.slice(-4000).split('\n').slice(-30).join('\n'));
      if (result.error) console.error(result.error);
    }
    console.log(
      `${result.exitCode === 0 ? 'PASS' : 'FAIL'} ${name}; ${result.durationMs} ms; sourceStable=${result.sourceStable}\nКвитанция: ${result.receiptPath}\nЛог: ${result.logPath}`,
    );
    process.exitCode = result.exitCode;
  }
}
