import { readFileSync } from 'node:fs';
import { Ajv } from 'ajv';
import type { ToleranceCard } from './tolerance.js';
const base = new URL('../../../../../packages/', import.meta.url);
const pack = JSON.parse(
  readFileSync(new URL('game-content/packs/tolerance-ru-base.json', base), 'utf8'),
);
const schema = JSON.parse(
  readFileSync(new URL('game-contracts/schemas/tolerance-pack.schema.json', base), 'utf8'),
);
const validate = new Ajv({ strict: true }).compile<{ items: ToleranceCard[] }>(schema);
if (
  !validate(pack) ||
  new Set(pack.items.map((c: ToleranceCard) => c.id)).size !== pack.items.length
)
  throw new Error('Invalid bundled Tolerance pack');
export const toleranceCards: readonly ToleranceCard[] = pack.items;
/** Fisher-Yates, bounded by a single deck; no content repeats within a party. */
export function selectToleranceCards(count: number, choose: (length: number) => number) {
  const cards = [...toleranceCards];
  for (let i = cards.length - 1; i > 0; i--) {
    const j = choose(i + 1);
    [cards[i], cards[j]] = [cards[j]!, cards[i]!];
  }
  // Source IDs describe an expanding content pool. Wire v3 IDs remain opaque,
  // session-scoped two-digit handles so already installed clients keep working.
  return cards.slice(0, count * 4).map((card, index) => ({
    id: `tolerance-${String(index + 1).padStart(2, '0')}`,
    text: card.text,
  }));
}
