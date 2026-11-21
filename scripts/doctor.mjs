#!/usr/bin/env node
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { delimiter, dirname, resolve } from 'node:path';
import { validateGraph } from './project-context.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const args = process.argv.slice(2);
if (args.some((arg) => !['--mobile', '--database'].includes(arg))) {
  console.error('Использование: node scripts/doctor.mjs [--mobile] [--database]');
  process.exit(1);
}
let failures = 0;
function report(label, ok, detail, required = true) {
  console.log(`${ok ? 'OK' : required ? 'FAIL' : 'INFO'} ${label}: ${detail}`);
  if (!ok && required) failures++;
}
function read(path) {
  try {
    return readFileSync(path, 'utf8').trim();
  } catch {
    return null;
  }
}
function binary(name) {
  return (process.env.PATH ?? '')
    .split(delimiter)
    .map((path) => resolve(path, name))
    .find(existsSync);
}
const nodePin = read(resolve(root, '.nvmrc'));
report('Node', process.versions.node === nodePin, `${process.versions.node}; ожидается ${nodePin}`);
const npmBinary = binary('npm');
const npmManifest = npmBinary && read(resolve(dirname(realpathSync(npmBinary)), '../package.json'));
const npmVersion = npmManifest && JSON.parse(npmManifest).version;
report('npm', /^11\./.test(npmVersion ?? ''), npmVersion ?? 'не найден; нужен npm 11');
report('Git', !!binary('git'), binary('git') ? 'найден в PATH' : 'не найден');
report(
  'JS-зависимости',
  existsSync(resolve(root, 'node_modules/.bin/tsc')),
  'проверено наличие TypeScript; актуальность lockfile обеспечивает npm ci',
);
const localFlutter = resolve(root, '.fvm/flutter_sdk/bin/flutter');
const flutter =
  process.env.FLUTTER_BIN || (existsSync(localFlutter) ? localFlutter : null) || binary('flutter');
const sdk = flutter && existsSync(flutter) ? resolve(dirname(realpathSync(flutter)), '..') : null;
const dart = process.env.DART_BIN || (sdk && resolve(sdk, 'bin/dart')) || binary('dart');
const flutterPin = JSON.parse(read(resolve(root, '.fvmrc'))).flutter;
const flutterCache = sdk && read(resolve(sdk, 'bin/cache/flutter.version.json'));
const flutterVersion = flutterCache
  ? JSON.parse(flutterCache).flutterVersion
  : sdk && read(resolve(sdk, 'version'));
report(
  'Flutter',
  flutterVersion === flutterPin,
  flutterVersion ?? `не найден или SDK не инициализирован; нужен ${flutterPin}`,
  args.includes('--mobile'),
);
report(
  'Dart',
  !!dart && existsSync(dart),
  dart && existsSync(dart) ? 'найден; runtime проверит make check-mobile' : 'не найден',
  args.includes('--mobile'),
);
report(
  'Docker CLI',
  !!binary('docker'),
  binary('docker') ? 'найден; daemon/smoke проверяются отдельно' : 'не найден',
  false,
);
report(
  'PostgreSQL-интеграции',
  !!process.env.TEST_DATABASE_URL,
  process.env.TEST_DATABASE_URL
    ? 'TEST_DATABASE_URL задан; доступность БД проверяют тесты'
    : 'TEST_DATABASE_URL не задан; интеграции будут пропущены',
  args.includes('--database'),
);
const graph = validateGraph();
report(
  'Карта проекта',
  !graph.errors.length,
  graph.errors.join('; ') || `${graph.modules} модулей, ${graph.edges} связей; пути существуют`,
);
console.log('Диагностика читает файлы; не запускает SDK и не заменяет проверки приложения.');
process.exitCode = failures ? 1 : 0;
