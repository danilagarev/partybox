import assert from 'node:assert/strict';
import {
  mkdtempSync,
  mkdirSync,
  copyFileSync,
  readFileSync,
  writeFileSync,
  statSync,
  rmSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const source = resolve('deploy/production');
const oldImage = `ghcr.io/example/backend@sha256:${'a'.repeat(64)}`;
const newImage = `ghcr.io/example/backend@sha256:${'b'.repeat(64)}`;
function fixture() {
  const root = mkdtempSync(join(tmpdir(), 'partybox-release-test-'));
  const bundle = join(root, 'releases', 'test');
  const bin = join(root, 'bin');
  mkdirSync(bundle, { recursive: true });
  mkdirSync(bin);
  for (const file of ['compose.yaml', 'release.sh'])
    copyFileSync(join(source, file), join(bundle, file));
  writeFileSync(join(root, '.env'), 'PARTYBOX_UID=1000\nPARTYBOX_GID=1000\n');
  writeFileSync(
    join(bin, 'docker'),
    `#!/usr/bin/env bash
printf '%s %s\\n' "$BACKEND_IMAGE" "$*" >> "$TRACE"
printf 'config=%s\\n' "\${DOCKER_CONFIG:-default}" >> "$TRACE"
if [[ $* == *'run --rm --no-deps migrate'* && \${FAIL_MIGRATION:-0} == 1 ]]; then exit 1; fi
if [[ $* == *'up -d --no-deps --wait'* && $BACKEND_IMAGE == "$BAD_IMAGE" ]]; then exit 1; fi
`,
    { mode: 0o700 },
  );
  const trace = join(root, 'trace');
  return {
    root,
    run(image, extra = {}) {
      return spawnSync('bash', [join(bundle, 'release.sh'), image], {
        encoding: 'utf8',
        env: {
          ...process.env,
          PATH: `${bin}:${process.env.PATH}`,
          TRACE: trace,
          BAD_IMAGE: '',
          ...extra,
        },
      });
    },
    trace: () => readFileSync(trace, 'utf8'),
    close: () => rmSync(root, { recursive: true, force: true }),
  };
}

test('initialization preserves secret values and private permissions', () => {
  const root = mkdtempSync(join(tmpdir(), 'partybox-init-test-'));
  try {
    const run = () => spawnSync('bash', [join(source, 'init.sh'), root], { encoding: 'utf8' });
    assert.equal(run().status, 0);
    const before = readFileSync(join(root, 'secrets/room_token_secret'), 'utf8');
    assert.match(before, /^[a-f0-9]{64}\n$/);
    assert.equal(run().status, 0);
    assert.equal(readFileSync(join(root, 'secrets/room_token_secret'), 'utf8'), before);
    assert.equal(statSync(join(root, 'secrets')).mode & 0o777, 0o700);
    assert.equal(statSync(join(root, 'secrets/room_token_secret')).mode & 0o777, 0o600);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
test('migration precedes replacement and success records immutable references', () => {
  const f = fixture();
  try {
    writeFileSync(join(f.root, 'current-image'), oldImage);
    assert.equal(f.run(newImage).status, 0);
    assert.equal(readFileSync(join(f.root, 'current-image'), 'utf8').trim(), newImage);
    assert.equal(readFileSync(join(f.root, 'previous-image'), 'utf8').trim(), oldImage);
    assert.ok(
      f.trace().indexOf('run --rm --no-deps migrate') < f.trace().indexOf('up -d --no-deps --wait'),
    );
  } finally {
    f.close();
  }
});
test('failed readiness restores previous image without changing release record or deleting database', () => {
  const f = fixture();
  try {
    writeFileSync(join(f.root, 'current-image'), oldImage);
    assert.equal(f.run(newImage, { BAD_IMAGE: newImage }).status, 1);
    assert.equal(readFileSync(join(f.root, 'current-image'), 'utf8'), oldImage);
    assert.match(f.trace(), new RegExp(`${oldImage} .*up -d --no-deps --wait`));
    assert.doesNotMatch(f.trace(), /down|volume rm/);
  } finally {
    f.close();
  }
});
test('migration failure leaves old backend untouched', () => {
  const f = fixture();
  try {
    writeFileSync(join(f.root, 'current-image'), oldImage);
    assert.equal(f.run(newImage, { FAIL_MIGRATION: '1' }).status, 1);
    assert.doesNotMatch(f.trace(), /up -d --no-deps/);
    assert.equal(readFileSync(join(f.root, 'current-image'), 'utf8'), oldImage);
  } finally {
    f.close();
  }
});
test('first failed release stops only PartyBox API and accepts no mutable image', () => {
  const f = fixture();
  try {
    assert.equal(f.run('ghcr.io/example/backend:latest').status, 1);
    assert.equal(f.run(newImage, { BAD_IMAGE: newImage }).status, 1);
    assert.match(f.trace(), /stop partybox-api/);
    assert.doesNotMatch(f.trace(), /down|volume rm/);
  } finally {
    f.close();
  }
});

test('private registry credentials are scoped to PartyBox', () => {
  const f = fixture();
  try {
    mkdirSync(join(f.root, 'docker-auth'));
    writeFileSync(join(f.root, 'docker-auth/config.json'), '{}');
    assert.equal(f.run(newImage, { DOCKER_CONFIG: '/unrelated/baza-auth' }).status, 0);
    assert.ok(f.trace().includes(`config=${f.root}/docker-auth`));
    assert.ok(!f.trace().includes('/unrelated/baza-auth'));
  } finally {
    f.close();
  }
});
