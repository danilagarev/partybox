import { cp, mkdir, readdir, realpath, rm, writeFile } from 'node:fs/promises';
import { resolve, sep } from 'node:path';
import { webBuildArtifacts } from './play-assets.mjs';

const [sourceArg, targetArg] = process.argv.slice(2);
if (!sourceArg || !targetArg) throw new Error('Usage: stage-web.mjs SOURCE TARGET');
const source = resolve(sourceArg),
  target = resolve(targetArg);
if (source === target || source.startsWith(target + sep) || target !== resolve('deploy/web'))
  throw new Error('Target must be the repository deploy/web directory');
const artifacts = await webBuildArtifacts(source);
await mkdir(target, { recursive: true });
if ((await realpath(target)) !== target) throw new Error('Web target must not be a symlink');
for (const name of await readdir(target)) {
  if (name !== '.gitkeep') await rm(resolve(target, name), { recursive: true, force: true });
}
for (const name of Object.keys(artifacts)) {
  await mkdir(resolve(target, name, '..'), { recursive: true });
  await cp(resolve(source, name), resolve(target, name));
}
await writeFile(
  resolve(target, 'build-manifest.json'),
  JSON.stringify({ version: 1, artifacts }, null, 2) + '\n',
);
console.log('Verified web assets staged in deploy/web');
