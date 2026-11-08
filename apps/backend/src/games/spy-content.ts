import { readFileSync } from 'node:fs';
import { Ajv } from 'ajv';

interface Pack {
  id: string;
  version: number;
  title: string;
  items: { id: string; label: string }[];
}
const read = (url: URL) => JSON.parse(readFileSync(url, 'utf8'));
const content = new URL('../../../../../packages/game-content/', import.meta.url);
const contracts = new URL('../../../../../packages/game-contracts/schemas/', import.meta.url);
const ajv = new Ajv({ strict: true });
const catalog = read(new URL('spy-catalog.json', content));
const validateCatalog = ajv.compile<{ packs: { id: string; version: number }[] }>(
  read(new URL('spy-catalog.schema.json', contracts)),
);
if (!validateCatalog(catalog)) throw new Error('Invalid bundled Spy catalog');
const validatePack = ajv.compile<Pack & { locale: string }>(
  read(new URL('content-pack.schema.json', contracts)),
);
export const spyPacks = new Map<string, Pack>();
for (const entry of catalog.packs) {
  const pack = read(new URL(`packs/${entry.id}.json`, content));
  if (
    !validatePack(pack) ||
    pack.id !== entry.id ||
    pack.version !== entry.version ||
    pack.locale !== 'ru' ||
    spyPacks.has(pack.id) ||
    new Set(pack.items.map((item: { id: string }) => item.id)).size !== pack.items.length
  )
    throw new Error('Invalid bundled Spy pack');
  spyPacks.set(pack.id, pack);
}

/** Private, bounded history for a single pack version. Randomness is explicit. */
export function nextSpyLocation(
  pack: Pack,
  previous: readonly string[],
  choose: (length: number) => number,
) {
  let history = previous.filter((id) => pack.items.some((item) => item.id === id));
  let candidates = pack.items.filter((item) => !history.includes(item.id));
  if (!candidates.length) {
    candidates = pack.items.filter((item) => item.id !== history.at(-1));
    if (!candidates.length) candidates = pack.items;
    history = [];
  }
  const item = candidates[choose(candidates.length)]!;
  return { location: item.label, history: [...history, item.id] };
}
