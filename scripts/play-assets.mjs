import { createHash } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import { resolve } from 'node:path';

// Entrypoints alone can exist after Flutter removes a previous output bundle.
const required = [
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
  'assets/fonts/MaterialIcons-Regular.otf',
  'assets/assets/fonts/Manrope-Regular.ttf',
  'assets/assets/fonts/Manrope-Bold.ttf',
  'assets/assets/fonts/Manrope-ExtraBold.ttf',
  'assets/packages/partybox_game_content/spy-catalog.json',
  'assets/packages/partybox_game_content/packs/spy-ru-base.json',
  'assets/packages/partybox_game_content/packs/spy-ru-travel.json',
  'assets/packages/partybox_game_content/packs/spy-ru-unusual.json',
  'assets/packages/partybox_game_content/packs/clues-ru-base.json',
];

export async function webBuildArtifacts(webRoot) {
  const files = [];
  async function inventory(directory = '') {
    for (const entry of await readdir(resolve(webRoot, directory), { withFileTypes: true })) {
      const name = directory ? `${directory}/${entry.name}` : entry.name;
      if (entry.isSymbolicLink()) throw new Error(`Web assets cannot contain symlinks: ${name}`);
      if (
        ['.last_build_id', '.gitkeep', 'flutter_service_worker.js', 'build-manifest.json'].includes(
          name,
        ) ||
        name.endsWith('.symbols')
      )
        continue;
      if (entry.name.startsWith('.')) throw new Error(`Unexpected hidden web asset: ${name}`);
      if (entry.isDirectory()) {
        if (!/^(?:assets|canvaskit|icons)(?:\/|$)/.test(name))
          throw new Error(`Unexpected web directory: ${name}`);
        await inventory(name);
      } else if (
        entry.isFile() &&
        /^(?:index\.html|flutter(?:_bootstrap)?\.js|main\.dart\.(?:js|wasm|mjs)|manifest\.json|version\.json|favicon\.png|(?:assets|canvaskit|icons)\/.+)$/.test(
          name,
        )
      ) {
        files.push(name);
      } else throw new Error(`Unexpected web asset: ${name}`);
    }
  }
  await inventory();
  for (const name of required) {
    if (!files.includes(name))
      throw new Error(`Сборка неполна: отсутствует ${name}. Пересоберите без --skip-build.`);
  }
  const entries = await Promise.all(
    files.sort().map(async (name) => {
      let content;
      try {
        content = await readFile(resolve(webRoot, name));
      } catch {
        throw new Error(`Сборка неполна: отсутствует ${name}. Пересоберите без --skip-build.`);
      }
      if (!content.length) throw new Error(`Сборка неполна: пустой ${name}.`);
      return [name, createHash('sha256').update(content).digest('hex')];
    }),
  );
  return Object.fromEntries(entries);
}
