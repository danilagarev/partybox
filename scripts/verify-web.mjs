import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { webBuildArtifacts } from './play-assets.mjs';

const root = resolve(process.argv[2] ?? 'deploy/web');
const manifest = JSON.parse(await readFile(resolve(root, 'build-manifest.json'), 'utf8'));
if (
  manifest.version !== 1 ||
  JSON.stringify(manifest.artifacts) !== JSON.stringify(await webBuildArtifacts(root))
)
  throw new Error('Web assets do not match the build manifest');
console.log('Web bundle checksums verified');
