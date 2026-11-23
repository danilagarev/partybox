import { readFileSync } from 'node:fs';
import { Ajv } from 'ajv';
import type { TruthTopic } from '@partybox/game-contracts/rooms-v6';
import { TruthRuleError, type TruthCard } from './truth.js';

const packages = new URL('../../../../../packages/', import.meta.url);
const pack = JSON.parse(
  readFileSync(new URL('game-content/packs/truth-ru-base.json', packages), 'utf8'),
);
const schema = JSON.parse(
  readFileSync(new URL('game-contracts/schemas/truth-pack.schema.json', packages), 'utf8'),
);
if (!new Ajv({ strict: true }).compile<{ version: number; items: TruthCard[] }>(schema)(pack))
  throw new Error('Invalid bundled Truth pack');
const cards: readonly TruthCard[] = pack.items;
export const truthPackVersion: number = pack.version;

function shuffle<T>(values: T[], choose: (length: number) => number) {
  for (let i = values.length - 1; i > 0; i--) {
    const j = choose(i + 1);
    [values[i], values[j]] = [values[j]!, values[i]!];
  }
  return values;
}

export function selectTruthCards(
  topics: readonly TruthTopic[],
  choose: (length: number) => number,
): TruthCard[] {
  const selected = topics.length ? topics : [...new Set(cards.map((card) => card.topic))];
  const queues = selected.map((topic) =>
    shuffle(
      cards.filter((card) => card.topic === topic),
      choose,
    ),
  );
  const deck: TruthCard[] = [];
  while (deck.length < 10) {
    const available = queues.filter((queue) => queue.length);
    if (!available.length) throw new TruthRuleError('INVALID_REQUEST');
    for (const queue of shuffle(available, choose)) {
      deck.push(queue.pop()!);
      if (deck.length === 10) break;
    }
  }
  return deck;
}
