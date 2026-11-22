import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { webBuildArtifacts } from '../play-assets.mjs';

test('a Flutter output with entrypoints and empty asset directories is not a playable build', async () => {
  const root = await mkdtemp(join(tmpdir(), 'partybox-assets-'));
  try {
    for (const file of ['index.html', 'flutter_bootstrap.js', 'main.dart.js']) {
      await writeFile(join(root, file), 'synthetic entrypoint');
    }
    await mkdir(join(root, 'assets/fonts'), { recursive: true });
    await assert.rejects(webBuildArtifacts(root), /Сборка неполна: отсутствует /);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('a web bundle rejects symlinks and unexpected root files before publication', async () => {
  for (const kind of ['symlink', 'private']) {
    const root = await mkdtemp(join(tmpdir(), 'partybox-inventory-'));
    try {
      if (kind === 'symlink') await symlink('/etc/passwd', join(root, 'main.dart.js'));
      else await writeFile(join(root, 'credentials.txt'), 'synthetic private file');
      await assert.rejects(webBuildArtifacts(root), /symlinks|Unexpected web asset/);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  }
});
