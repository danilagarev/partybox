#!/usr/bin/env node
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, relative, isAbsolute } from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const source = readFileSync(resolve(root, 'docs/PROJECT_GRAPH.md'), 'utf8');
const quoted = (value) => [...value.matchAll(/`([^`]+)`/g)].map((m) => m[1]);
const modules = new Map(
  [...source.matchAll(/^\|\s*([a-z]+)\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|$/gm)].map((m) => [
    m[1],
    { paths: quoted(m[2]), checks: quoted(m[3]) },
  ]),
);
const edges = [...source.matchAll(/^  ([a-z]+) --> ([a-z]+)$/gm)].map((m) => m.slice(1));
export function validateGraph() {
  const errors = [];
  if (!modules.size || !edges.length) errors.push('Карта пуста или формат изменён.');
  for (const [name, module] of modules) {
    if (!module.paths.length || !module.checks.length)
      errors.push(`${name}: отсутствуют пути или проверки`);
    for (const path of module.paths) {
      const target = resolve(root, path);
      if (!existsSync(target)) errors.push(`${name}: нет ${path}`);
      else {
        const within = relative(realpathSync(root), realpathSync(target));
        if (within === '..' || within.startsWith('../') || isAbsolute(within))
          errors.push(`${name}: путь вне репозитория ${path}`);
      }
    }
  }
  for (const edge of edges)
    for (const name of edge) if (!modules.has(name)) errors.push(`Неизвестный узел: ${name}`);
  return { errors, modules: modules.size, edges: edges.length };
}
const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
const args = process.argv.slice(2);
if (isMain && args.length === 1 && args[0] === '--check') {
  const { errors } = validateGraph();
  if (errors.length) {
    console.error(errors.join('\n'));
    process.exitCode = 1;
  } else console.log(`Карта: ${modules.size} модулей, ${edges.length} связей; пути существуют.`);
} else if (isMain && args.length === 1 && modules.has(args[0])) {
  const name = args[0];
  const module = modules.get(name);
  console.log(`${name}\nЧитать точечно:\n${module.paths.join('\n')}`);
  console.log(`Проверить:\n${module.checks.join('\n')}`);
  console.log(
    `Связи:\n${edges
      .filter((edge) => edge.includes(name))
      .map((edge) => edge.join(' → '))
      .join('\n')}`,
  );
} else if (isMain) {
  console.log(
    `Использование: node scripts/project-context.mjs <${[...modules.keys()].join('|')}> или --check`,
  );
  if (args.length) process.exitCode = 1;
}
