import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';

// Entrypoints alone can exist after Flutter removes a previous output bundle.
const required = [
  'index.html',
  'flutter_bootstrap.js',
  'main.dart.js',
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
];

export async function webBuildArtifacts(webRoot) {
  const entries = await Promise.all(
    required.map(async (name) => {
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
