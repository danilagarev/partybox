import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readFile, readdir, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { webBuildArtifacts } from '../play-assets.mjs';

const stageScript = fileURLToPath(new URL('../stage-web.mjs', import.meta.url));
const verifyScript = fileURLToPath(new URL('../verify-web.mjs', import.meta.url));
// Deliberately explicit fixture: a complete local-engine Flutter bundle must
// include both CanvasKit variants, not just main.dart.js and application assets.
const publicFiles = [
  'index.html',
  'flutter_bootstrap.js',
  'main.dart.js',
  'manifest.json',
  'icons/Icon-192.png',
  'icons/Icon-512.png',
  'canvaskit/canvaskit.js',
  'canvaskit/canvaskit.wasm',
  'canvaskit/chromium/canvaskit.js',
  'canvaskit/chromium/canvaskit.wasm',
  'assets/AssetManifest.bin',
  'assets/FontManifest.json',
  'assets/vendor/zxing-reader-3.1.6.min.js',
  'assets/vendor/zxing_reader.wasm',
  'assets/vendor/zxing-LICENSE.txt',
  'assets/fonts/MaterialIcons-Regular.otf',
  'assets/assets/fonts/Manrope-Regular.ttf',
  'assets/assets/fonts/Manrope-Bold.ttf',
  'assets/assets/fonts/Manrope-ExtraBold.ttf',
  'assets/packages/partybox_game_content/spy-catalog.json',
  'assets/packages/partybox_game_content/packs/spy-ru-base.json',
  'assets/packages/partybox_game_content/packs/spy-ru-travel.json',
  'assets/packages/partybox_game_content/packs/spy-ru-unusual.json',
  'assets/packages/partybox_game_content/packs/clues-ru-base.json',
  'assets/packages/partybox_game_content/packs/truth-ru-base.json',
  'assets/extra-texture.png',
];
const fixtureContent = (name) => `synthetic public content: ${name}`;
async function fixture() {
  const directory = await mkdtemp(join(tmpdir(), 'partybox-web-delivery-'));
  const source = join(directory, 'source');
  for (const name of publicFiles) {
    await mkdir(dirname(join(source, name)), { recursive: true });
    await writeFile(join(source, name), fixtureContent(name));
  }
  return { directory, source, target: join(directory, 'deploy/web') };
}
function run(script, args, cwd) {
  const result = spawnSync(process.execPath, [script, ...args], {
    cwd,
    encoding: 'utf8',
  });
  if (result.error) throw result.error;
  return result;
}
const sha256 = (value) => createHash('sha256').update(value).digest('hex');

test('inventory hashes every public asset and requires both complete CanvasKit variants', async () => {
  const { directory, source } = await fixture();
  try {
    const initial = await webBuildArtifacts(source);
    assert.deepEqual(Object.keys(initial), [...publicFiles].sort());
    assert.equal(
      initial['assets/extra-texture.png'],
      sha256(fixtureContent('assets/extra-texture.png')),
    );
    await writeFile(join(source, 'assets/extra-texture.png'), 'changed public asset');
    const changed = await webBuildArtifacts(source);
    assert.notEqual(changed['assets/extra-texture.png'], initial['assets/extra-texture.png']);
    for (const engine of [
      'canvaskit/canvaskit.js',
      'canvaskit/canvaskit.wasm',
      'canvaskit/chromium/canvaskit.js',
      'canvaskit/chromium/canvaskit.wasm',
    ]) {
      await rm(join(source, engine));
      await assert.rejects(webBuildArtifacts(source), /Сборка неполна: отсутствует/);
      await writeFile(join(source, engine), '');
      await assert.rejects(webBuildArtifacts(source), /Сборка неполна: пустой/);
      await writeFile(join(source, engine), fixtureContent(engine));
    }
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test('staging copies only inventoried public files and verification detects engine tampering or extra assets', async () => {
  const { directory, source, target } = await fixture();
  try {
    const ignored = [
      '.last_build_id',
      '.gitkeep',
      'flutter_service_worker.js',
      'main.dart.js.symbols',
      'canvaskit/chromium/canvaskit.js.symbols',
      'build-manifest.json',
    ];
    for (const name of ignored) await writeFile(join(source, name), 'synthetic build metadata');
    await mkdir(target, { recursive: true });
    await writeFile(join(target, '.gitkeep'), '');
    await writeFile(join(target, 'stale.txt'), 'previous staged file');
    const staged = run(stageScript, [source, target], directory);
    assert.equal(staged.status, 0, staged.stderr);
    assert.ok(!(await readdir(target)).includes('stale.txt'));
    assert.ok((await readdir(target)).includes('.gitkeep'));
    const manifest = JSON.parse(await readFile(join(target, 'build-manifest.json'), 'utf8'));
    assert.equal(manifest.version, 1);
    assert.deepEqual(Object.keys(manifest.artifacts), [...publicFiles].sort());
    for (const name of ignored.filter(
      (name) => !['.gitkeep', 'build-manifest.json'].includes(name),
    )) {
      await assert.rejects(readFile(join(target, name)), { code: 'ENOENT' });
    }
    assert.equal(run(verifyScript, [target], directory).status, 0);
    const engine = 'canvaskit/chromium/canvaskit.wasm';
    await writeFile(join(target, engine), 'corrupted engine');
    assert.notEqual(run(verifyScript, [target], directory).status, 0);
    await writeFile(join(target, engine), fixtureContent(engine));
    assert.equal(run(verifyScript, [target], directory).status, 0);
    await rm(join(target, engine));
    assert.notEqual(run(verifyScript, [target], directory).status, 0);
    await writeFile(join(target, engine), fixtureContent(engine));
    await writeFile(join(target, 'assets/unknown-extra.json'), '{}');
    assert.notEqual(run(verifyScript, [target], directory).status, 0);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test('hidden files, unknown root files/directories and symlinks are rejected before staging mutates its destination', async () => {
  for (const forbidden of ['.env', 'credentials.txt', 'private/secrets.json', 'assets/.private']) {
    const { directory, source, target } = await fixture();
    try {
      await mkdir(target, { recursive: true });
      await writeFile(join(target, 'preserve.txt'), 'previous stage');
      await mkdir(dirname(join(source, forbidden)), { recursive: true });
      await writeFile(join(source, forbidden), 'synthetic non-public content');
      await assert.rejects(webBuildArtifacts(source), /Unexpected/);
      assert.notEqual(run(stageScript, [source, target], directory).status, 0);
      assert.equal(await readFile(join(target, 'preserve.txt'), 'utf8'), 'previous stage');
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  }
  for (const name of ['assets/outside.txt', '.last_build_id']) {
    const { directory, source } = await fixture();
    try {
      const outside = join(directory, 'outside.txt');
      await writeFile(outside, 'synthetic outside content');
      await symlink(outside, join(source, name));
      await assert.rejects(webBuildArtifacts(source), /symlinks/);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  }
});

test('stage rejects unsafe destinations and verification rejects an unsupported manifest version', async () => {
  const { directory, source, target } = await fixture();
  try {
    assert.notEqual(run(stageScript, [source, source], directory).status, 0);
    assert.notEqual(run(stageScript, [source, join(directory, 'unrelated')], directory).status, 0);
    await mkdir(dirname(target), { recursive: true });
    const outside = join(directory, 'outside');
    await mkdir(outside);
    await writeFile(join(outside, 'preserve.txt'), 'outside target');
    await symlink(outside, target);
    assert.notEqual(run(stageScript, [source, target], directory).status, 0);
    assert.equal(await readFile(join(outside, 'preserve.txt'), 'utf8'), 'outside target');
    await rm(target);
    assert.equal(run(stageScript, [source, target], directory).status, 0);
    const manifest = JSON.parse(await readFile(join(target, 'build-manifest.json'), 'utf8'));
    await writeFile(
      join(target, 'build-manifest.json'),
      JSON.stringify({ ...manifest, version: 2 }),
    );
    assert.notEqual(run(verifyScript, [target], directory).status, 0);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
