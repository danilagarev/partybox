import { readFileSync } from 'node:fs';
import { Ajv } from 'ajv';
import type {
  DealsCategory,
  DealsEvent,
  DealsGoal,
  DealsItem,
  DealsValue,
} from '@partybox/game-contracts/rooms-v7';

export const dealsCategories: readonly DealsCategory[] = [
  'tech',
  'art',
  'jewelry',
  'antiques',
  'toys',
  'music',
];
export const dealsValues: readonly DealsValue[] = [2, 5, 8];
const pairedRules = ['collection', 'cheapAndRare', 'bargain'] as const;
export const sellingGoalRules = [
  'bothSides',
  'bluffSale',
  'honestSale',
  'markupSale',
  'counterofferSale',
  'resale',
] as const;
const otherRules = [
  'twoInspections',
  'twoRare',
  'threeCategories',
  'falseCategory',
  'twoHonest',
  'priceRange',
  ...sellingGoalRules,
] as const;
const effects = [
  'marketDiscount',
  'marketSurcharge',
  'cheapInspection',
  'expensiveInspection',
  'matchInspection',
  'bothInspection',
  'freeInsurance',
  'extraInsurance',
  'directBonus',
  'offerBonus',
  'firstSale',
  'doubleMarket',
] as const;

export interface DealsGoalCard extends DealsGoal {
  rule: (typeof pairedRules)[number] | (typeof otherRules)[number];
  categories: DealsCategory[];
}
export interface DealsEventCard extends DealsEvent {
  effect: (typeof effects)[number];
}
interface DealsPack {
  version: number;
  items: DealsItem[];
  goals: DealsGoalCard[];
  events: DealsEventCard[];
}

const packages = new URL('../../../../../packages/', import.meta.url);
const schema = JSON.parse(
  readFileSync(new URL('game-contracts/schemas/deals-pack.schema.json', packages), 'utf8'),
);
const validate = new Ajv({ strict: true }).compile<DealsPack>(schema);
const pack: unknown = JSON.parse(
  readFileSync(new URL('game-content/packs/deals-ru-base.json', packages), 'utf8'),
);

function uniqueIds(cards: { id: string }[]) {
  return new Set(cards.map((entry) => entry.id)).size === cards.length;
}
if (
  !validate(pack) ||
  !uniqueIds(pack.items) ||
  !uniqueIds(pack.goals) ||
  !uniqueIds(pack.events) ||
  dealsCategories.some((category) =>
    dealsValues.some(
      (value) =>
        pack.items.filter((item) => item.category === category && item.value === value).length < 4,
    ),
  ) ||
  pack.goals.some(
    (goal) =>
      (goal.categories.length === 2) !== pairedRules.some((rule) => rule === goal.rule) ||
      goal.categories.length === 1,
  ) ||
  pairedRules.some(
    (rule) =>
      pack.goals.filter((goal) => goal.rule === rule && goal.categories.length === 2).length < 6,
  ) ||
  otherRules.some(
    (rule) =>
      pack.goals.filter((goal) => goal.rule === rule && goal.categories.length === 0).length < 1,
  ) ||
  effects.some((effect) => pack.events.filter((event) => event.effect === effect).length < 1)
)
  throw new Error('Invalid bundled Deals pack');

export const dealsPack: DealsPack = pack;
