import type {
  DealsEvent,
  DealsGoal,
  DealsInspection,
  DealsInspectionMode,
  DealsItem,
  DealsLot,
  DealsOffer,
  DealsPrivate,
  DealsPublic,
  DealsPurchase,
  DealsResult,
  DealsRevealedSale,
  V7Command,
} from '@partybox/game-contracts/rooms-v7';
import {
  dealsCategories,
  dealsPack,
  dealsValues,
  sellingGoalRules,
  type DealsEventCard,
  type DealsGoalCard,
} from './deals-content.js';

export type DealsAction = Exclude<
  Extract<V7Command, { type: `deals.${string}` }>,
  { type: 'deals.start' | 'deals.cancel' }
>;

interface ListedLot extends DealsLot {
  item: DealsItem;
}
interface DealsPlayer {
  id: string;
  balance: number;
  inventory: DealsItem[];
  goalOptions: DealsGoalCard[];
  goal: DealsGoalCard | null;
  lot: ListedLot | null;
  offer: DealsOffer | null;
  inspection: DealsInspection | null;
  insuranceAvailable: boolean;
  ready: boolean;
  marketPick: string | null;
}
export interface DealsState {
  packVersion: number;
  players: DealsPlayer[];
  deck: DealsItem[];
  events: DealsEventCard[];
  event: DealsEventCard | null;
  market: DealsPublic['market'];
  marketPriority: number;
  phase: DealsPublic['phase'];
  round: number;
  deadline: number | null;
  sales: DealsRevealedSale[];
}

export class DealsRuleError extends Error {
  constructor(readonly code: 'INVALID_PHASE' | 'INVALID_REQUEST' | 'FORBIDDEN') {
    super(code);
  }
}
const invalid = (code: DealsRuleError['code']): never => {
  throw new DealsRuleError(code);
};
const rounds = 5;
const tradingMs = 180_000;

function pickIndex(length: number, choose: (length: number) => number) {
  const index = choose(length);
  if (!Number.isInteger(index) || index < 0 || index >= length) invalid('INVALID_REQUEST');
  return index;
}
function shuffle<T>(cards: T[], choose: (length: number) => number) {
  const result = [...cards];
  for (let i = result.length - 1; i > 0; i--) {
    const j = pickIndex(i + 1, choose);
    [result[i], result[j]] = [result[j]!, result[i]!];
  }
  return result;
}

function draftGoals(goals: DealsGoalCard[], playerCount: number): DealsGoalCard[][] {
  if (playerCount === 2) {
    // A selling goal needs no specific category in the rival's hand.
    const selling = goals.filter((goal) => sellingGoalRules.some((rule) => goal.rule === rule));
    const alternatives = goals.filter(
      (goal) => !selling.includes(goal) && goal.rule !== 'cheapAndRare',
    );
    return selling.slice(0, playerCount).map((goal, index) => [goal, alternatives[index]!]);
  }
  return Array.from({ length: playerCount }, (_, index) => goals.slice(index * 2, index * 2 + 2));
}

export function createDeals(playerIds: string[], choose: (length: number) => number): DealsState {
  if (playerIds.length < 2 || playerIds.length > 6 || new Set(playerIds).size !== playerIds.length)
    invalid('INVALID_REQUEST');

  const itemStacks = dealsValues.map((value) =>
    shuffle(
      dealsPack.items.filter((item) => item.value === value).map((item) => ({ ...item })),
      choose,
    ),
  );
  const goals = shuffle(
    dealsPack.goals.map((goal) => ({ ...goal, categories: [...goal.categories] })),
    choose,
  );
  const goalDraft = draftGoals(goals, playerIds.length);
  return {
    packVersion: dealsPack.version,
    players: playerIds.map((id, index) => ({
      id,
      balance: 40,
      inventory: itemStacks.map((stack) => stack[index]!),
      goalOptions: goalDraft[index]!,
      goal: null,
      lot: null,
      offer: null,
      inspection: null,
      insuranceAvailable: true,
      ready: false,
      marketPick: null,
    })),
    deck: shuffle(
      itemStacks.flatMap((stack) => stack.slice(playerIds.length)),
      choose,
    ),
    events: shuffle(
      dealsPack.events.map((event) => ({ ...event })),
      choose,
    ).slice(0, 2),
    event: null,
    market: [],
    marketPriority: pickIndex(playerIds.length, choose),
    phase: 'goals',
    round: 1,
    deadline: null,
    sales: [],
  };
}

function member(state: DealsState, id: string) {
  return state.players.find((player) => player.id === id) ?? invalid('FORBIDDEN');
}
function updatePlayer(state: DealsState, player: DealsPlayer): DealsState {
  return {
    ...state,
    players: state.players.map((entry) => (entry.id === player.id ? player : entry)),
  };
}
function everyoneReady(state: DealsState) {
  return state.players.every((player) => player.ready);
}
function bought(state: DealsState, id: string) {
  return state.sales.some(
    ({ buyerId, purchase }) => buyerId === id && purchase.round === state.round,
  );
}

function openRound(state: DealsState, round: number): DealsState {
  const draw = round === 2 || round === 4;
  const event = draw ? state.events[round / 2 - 1]! : null;
  const drawCount = draw ? state.players.length : 0;
  const marketSize = event?.effect === 'doubleMarket' ? 2 : 1;
  const markup =
    event?.effect === 'marketDiscount' ? 1 : event?.effect === 'marketSurcharge' ? 3 : 2;
  return {
    ...state,
    phase: 'listing',
    round,
    deadline: null,
    event,
    marketPriority: (state.marketPriority + Number(round > 1)) % state.players.length,
    players: state.players.map((player, index) => ({
      ...player,
      inventory: draw ? [...player.inventory, state.deck[index]!] : player.inventory,
      lot: null,
      offer: null,
      inspection: null,
      ready: false,
      marketPick: null,
    })),
    market: state.deck
      .slice(drawCount, drawCount + marketSize)
      .map((item) => ({ item, price: item.value + markup })),
    deck: state.deck.slice(drawCount + marketSize),
  };
}

function openLot(state: DealsState, buyerId: string, sellerId: string) {
  if (buyerId === sellerId) invalid('FORBIDDEN');
  const seller = member(state, sellerId);
  const lot = seller.lot;
  if (!lot || lot.sold) return invalid('INVALID_REQUEST');
  return { seller, lot };
}
function requireBuyer(state: DealsState, player: DealsPlayer) {
  if (player.ready || bought(state, player.id)) invalid('INVALID_PHASE');
}
function priceAllowed(price: number) {
  return Number.isInteger(price) && price >= 1 && price <= 15;
}
function premium(state: DealsState) {
  return state.event?.effect === 'freeInsurance' ? 0 : 1;
}
function requireFunds(state: DealsState, buyer: DealsPlayer, price: number, insured: boolean) {
  if (
    (insured && !buyer.insuranceAvailable) ||
    price + (insured ? premium(state) : 0) > buyer.balance
  )
    invalid('INVALID_REQUEST');
}

function settlePeer(
  state: DealsState,
  buyer: DealsPlayer,
  seller: DealsPlayer,
  lot: ListedLot,
  price: number,
  insured: boolean,
  offered: boolean,
): DealsState {
  requireBuyer(state, buyer);
  requireFunds(state, buyer, price, insured);
  const item = lot.item;
  const effect = state.event?.effect;
  const buyerBonus = offered && effect === 'offerBonus' ? 1 : 0;
  const firstPeerSale = !state.sales.some(
    ({ purchase }) => purchase.round === state.round && purchase.sellerId !== null,
  );
  const sellerBonus =
    effect === 'firstSale' && firstPeerSale ? 2 : effect === 'directBonus' && !offered ? 1 : 0;
  const insurancePayout = insured && item.value === 2 ? (effect === 'extraInsurance' ? 4 : 3) : 0;
  const purchase: DealsPurchase = {
    item,
    round: state.round,
    sellerId: seller.id,
    price,
    category: lot.category,
    value: lot.value,
    offered,
    inspection: buyer.inspection?.sellerId === seller.id ? buyer.inspection.mode : null,
    insured,
  };
  return {
    ...state,
    sales: [...state.sales, { buyerId: buyer.id, purchase }],
    players: state.players.map((player) => {
      if (player.id === buyer.id)
        return {
          ...player,
          balance:
            player.balance - price - (insured ? premium(state) : 0) + insurancePayout + buyerBonus,
          inventory: [...player.inventory, item],
          insuranceAvailable: player.insuranceAvailable && !insured,
          offer: null,
        };
      const offer = player.offer?.sellerId === seller.id ? null : player.offer;
      if (player.id === seller.id)
        return {
          ...player,
          balance: player.balance + price + sellerBonus,
          inventory: player.inventory.filter((entry) => entry.id !== item.id),
          lot: { ...lot, sold: true },
          offer,
        };
      return offer === player.offer ? player : { ...player, offer };
    }),
  };
}

function inspect(
  state: DealsState,
  player: DealsPlayer,
  sellerId: string,
  mode: DealsInspectionMode,
): DealsState {
  requireBuyer(state, player);
  if (player.inspection) invalid('INVALID_PHASE');
  const { lot } = openLot(state, player.id, sellerId);
  const effect = state.event?.effect;
  if (
    (mode === 'match' && effect !== 'matchInspection') ||
    (mode === 'both' && effect !== 'bothInspection')
  )
    invalid('INVALID_REQUEST');
  const cost =
    mode === 'match' || effect === 'cheapInspection'
      ? 1
      : mode === 'both' || effect === 'expensiveInspection'
        ? 3
        : 2;
  if (cost > player.balance) invalid('INVALID_REQUEST');
  const balance = player.balance - cost;
  const offer = player.offer;
  return updatePlayer(state, {
    ...player,
    balance,
    offer: offer && offer.price + (offer.insured ? premium(state) : 0) <= balance ? offer : null,
    inspection: {
      sellerId,
      mode,
      category: mode === 'category' || mode === 'both' ? lot.item.category : null,
      value: mode === 'value' || mode === 'both' ? lot.item.value : null,
      matches: mode === 'match' ? lot.item.category === lot.category : null,
    },
  });
}

function settleMarket(state: DealsState): DealsState {
  const purchasedItems = new Set<string>();
  const sales = [...state.sales];
  const players = [...state.players];
  for (let offset = 0; offset < players.length; offset++) {
    const index = (state.marketPriority + offset) % players.length;
    const player = players[index]!;
    const lot = state.market.find(({ item }) => item.id === player.marketPick);
    if (lot && !purchasedItems.has(lot.item.id)) {
      const { item, price } = lot;
      purchasedItems.add(item.id);
      players[index] = {
        ...player,
        balance: player.balance - price,
        inventory: [...player.inventory, item],
      };
      sales.push({
        buyerId: player.id,
        purchase: {
          item,
          round: state.round,
          price,
          sellerId: null,
          category: item.category,
          value: item.value,
          offered: false,
          inspection: null,
          insured: false,
        },
      });
    }
  }
  return {
    ...state,
    phase: 'recap',
    sales,
    players: players.map((player) => ({ ...player, ready: false, marketPick: null })),
  };
}

function endTrading(state: DealsState): DealsState {
  const market: DealsState = {
    ...state,
    phase: 'market',
    deadline: null,
    players: state.players.map((player) => ({
      ...player,
      offer: null,
      ready: bought(state, player.id),
    })),
  };
  return everyoneReady(market) ? settleMarket(market) : market;
}

export function advanceDeals(state: DealsState, nowMs: number): DealsState {
  if (state.phase === 'trading' && state.deadline !== null && nowMs >= state.deadline)
    return endTrading(state);
  return state;
}

export function playDeals(
  state: DealsState,
  playerId: string,
  command: DealsAction,
  nowMs: number,
): DealsState {
  const player = member(state, playerId);
  if (state.deadline !== null && nowMs >= state.deadline) invalid('INVALID_PHASE');
  switch (command.type) {
    case 'deals.choose': {
      if (state.phase !== 'goals' || player.ready) invalid('INVALID_PHASE');
      const goal = player.goalOptions.find((option) => option.id === command.payload.goalId);
      if (!goal) return invalid('INVALID_REQUEST');
      const next = updatePlayer(state, { ...player, goal, goalOptions: [], ready: true });
      return everyoneReady(next) ? openRound(next, 1) : next;
    }
    case 'deals.list': {
      if (state.phase !== 'listing' || player.ready) invalid('INVALID_PHASE');
      const { itemId, category, value, price } = command.payload;
      let lot: ListedLot | null = null;
      if (itemId === null) {
        if (category !== null || value !== null || price !== null) invalid('INVALID_REQUEST');
      } else {
        const item = player.inventory.find((entry) => entry.id === itemId);
        if (
          !item ||
          category === null ||
          !dealsCategories.includes(category) ||
          value === null ||
          !dealsValues.includes(value) ||
          price === null ||
          !priceAllowed(price)
        )
          return invalid('INVALID_REQUEST');
        lot = { sellerId: playerId, item, category, value, price, sold: false };
      }
      const next = updatePlayer(state, { ...player, lot, ready: true });
      if (!everyoneReady(next)) return next;
      return {
        ...next,
        phase: 'trading',
        deadline: nowMs + tradingMs,
        players: next.players.map((entry) => ({ ...entry, ready: false })),
      };
    }
    case 'deals.offer': {
      if (state.phase !== 'trading') invalid('INVALID_PHASE');
      requireBuyer(state, player);
      const { sellerId, price, insured } = command.payload;
      if (sellerId === null && price === null && !insured)
        return updatePlayer(state, { ...player, offer: null });
      if (sellerId === null || price === null || !priceAllowed(price))
        return invalid('INVALID_REQUEST');
      openLot(state, playerId, sellerId);
      requireFunds(state, player, price, insured);
      return updatePlayer(state, {
        ...player,
        offer: { sellerId, buyerId: playerId, price, insured },
      });
    }
    case 'deals.accept': {
      if (state.phase !== 'trading') invalid('INVALID_PHASE');
      const { buyerId } = command.payload;
      const { lot } = openLot(state, buyerId, playerId);
      const buyer = member(state, buyerId);
      const offer = buyer.offer;
      if (!offer || offer.sellerId !== playerId) return invalid('INVALID_REQUEST');
      return settlePeer(state, buyer, player, lot, offer.price, offer.insured, true);
    }
    case 'deals.buy': {
      if (state.phase !== 'trading') invalid('INVALID_PHASE');
      const { sellerId, insured } = command.payload;
      const { seller, lot } = openLot(state, playerId, sellerId);
      return settlePeer(state, player, seller, lot, lot.price, insured, false);
    }
    case 'deals.inspect':
      if (state.phase !== 'trading') invalid('INVALID_PHASE');
      return inspect(state, player, command.payload.sellerId, command.payload.mode);
    case 'deals.done': {
      if (state.phase !== 'trading' || player.ready) invalid('INVALID_PHASE');
      const next = updatePlayer(state, { ...player, ready: true, offer: null });
      return everyoneReady(next) ? endTrading(next) : next;
    }
    case 'deals.market': {
      if (state.phase !== 'market' || player.ready) invalid('INVALID_PHASE');
      const { itemId } = command.payload;
      if (itemId !== null) {
        const lot = state.market.find(({ item }) => item.id === itemId);
        if (!lot || lot.price > player.balance) invalid('INVALID_REQUEST');
      }
      const next = updatePlayer(state, { ...player, ready: true, marketPick: itemId });
      return everyoneReady(next) ? settleMarket(next) : next;
    }
    case 'deals.next': {
      if (state.phase !== 'recap' || player.ready) invalid('INVALID_PHASE');
      const next = updatePlayer(state, { ...player, ready: true });
      if (!everyoneReady(next)) return next;
      if (state.round < rounds) return openRound(next, state.round + 1);
      return {
        ...next,
        phase: 'finished',
        players: next.players.map((entry) => ({ ...entry, ready: false })),
      };
    }
  }
}

function goalCard({ id, title, text, bonus }: DealsGoalCard): DealsGoal {
  return { id, title, text, bonus };
}
function eventCard({ id, title, text }: DealsEventCard): DealsEvent {
  return { id, title, text };
}
function purchaseCard(purchase: DealsPurchase): DealsPurchase {
  return { ...purchase, item: { ...purchase.item } };
}

function isHonest({ item, category, value }: DealsPurchase) {
  return item.category === category && item.value === value;
}

function metGoal(
  goal: DealsGoalCard,
  inventory: DealsItem[],
  purchases: DealsPurchase[],
  sales: DealsPurchase[],
): boolean {
  const peer = purchases.filter((purchase) => purchase.sellerId !== null);
  const market = purchases.filter((purchase) => purchase.sellerId === null);
  const peerIds = new Set(peer.map(({ item }) => item.id));
  const [first, second] = goal.categories;
  switch (goal.rule) {
    case 'collection':
      return (
        goal.categories.every((category) => inventory.some((item) => item.category === category)) &&
        inventory.some((item) => goal.categories.includes(item.category) && peerIds.has(item.id))
      );
    case 'cheapAndRare':
      return peer.some(
        ({ item }) =>
          item.category === first &&
          (item.value === 2 || item.value === 8) &&
          peer.some(
            (other) =>
              other.item.category === second &&
              (other.item.value === 2 || other.item.value === 8) &&
              other.item.value !== item.value,
          ),
      );
    case 'bargain':
      return peer.some(
        ({ item, price, offered }) =>
          offered && price <= item.value && goal.categories.includes(item.category),
      );
    case 'twoInspections':
      return peer.some(
        (purchase) =>
          (purchase.inspection === 'category' || purchase.inspection === 'both') &&
          peer.some(
            (other) =>
              purchase.item.id !== other.item.id &&
              (other.inspection === 'value' || other.inspection === 'both'),
          ),
      );
    case 'twoRare':
      return peer.some(
        ({ item }) =>
          item.value === 8 &&
          market.some((other) => other.item.value === 8 && other.item.id !== item.id),
      );
    case 'threeCategories':
      return peer.some(({ item }) => {
        const otherCategories = new Set(market.map((purchase) => purchase.item.category));
        otherCategories.delete(item.category);
        return otherCategories.size >= 2;
      });
    case 'falseCategory':
      return peer.some(
        ({ item, category, inspection }) =>
          (inspection === 'category' || inspection === 'both') && category !== item.category,
      );
    case 'twoHonest':
      return (
        new Set(
          peer
            .filter((purchase) => purchase.inspection === null && isHonest(purchase))
            .map(({ item }) => item.id),
        ).size >= 2
      );
    case 'priceRange':
      return (
        dealsValues.every((value) => inventory.some((item) => item.value === value)) &&
        inventory.some((item) => peerIds.has(item.id))
      );
    case 'bothSides':
      return peer.length > 0 && sales.length > 0;
    case 'bluffSale':
      return peer.length > 0 && sales.some((sale) => !isHonest(sale));
    case 'honestSale':
      return peer.length > 0 && sales.some(isHonest);
    case 'markupSale':
      return peer.length > 0 && sales.some((sale) => sale.price >= sale.item.value + 2);
    case 'counterofferSale':
      return peer.length > 0 && sales.some((sale) => sale.offered);
    case 'resale':
      return (
        peer.length > 0 &&
        sales.some((sale) =>
          purchases.some(
            (purchase) => purchase.item.id === sale.item.id && purchase.round < sale.round,
          ),
        )
      );
  }
}

function purchasesOf(state: DealsState, playerId: string) {
  return state.sales.filter(({ buyerId }) => buyerId === playerId).map(({ purchase }) => purchase);
}
function resultFor(state: DealsState, player: DealsPlayer): DealsResult {
  const goal = player.goal!;
  const goodsValue = player.inventory.reduce((value, item) => value + item.value, 0);
  const sales = state.sales
    .map(({ purchase }) => purchase)
    .filter((purchase) => purchase.sellerId === player.id);
  const bonus = metGoal(goal, player.inventory, purchasesOf(state, player.id), sales)
    ? goal.bonus
    : 0;
  return {
    playerId: player.id,
    balance: player.balance,
    goodsValue,
    bonus,
    total: player.balance + goodsValue + bonus,
    goal: goalCard(goal),
    inventory: player.inventory.map((item) => ({ ...item })),
  };
}

export function dealsPublic(state: DealsState, sessionId: string): DealsPublic {
  const finished = state.phase === 'finished';
  return {
    sessionId,
    packVersion: state.packVersion,
    phase: state.phase,
    round: state.round,
    deadline: state.deadline === null ? null : new Date(state.deadline).toISOString(),
    readyIds: state.players.filter((player) => player.ready).map((player) => player.id),
    lots:
      state.phase === 'listing'
        ? []
        : state.players.flatMap(({ lot }) =>
            lot
              ? [
                  {
                    sellerId: lot.sellerId,
                    category: lot.category,
                    value: lot.value,
                    price: lot.price,
                    sold: lot.sold,
                  },
                ]
              : [],
          ),
    market: state.market.map(({ item, price }) => ({ item: { ...item }, price })),
    event: state.event ? eventCard(state.event) : null,
    marketPriorityId: state.players[state.marketPriority]!.id,
    sales: state.sales
      .filter(({ purchase }) => purchase.round === state.round)
      .map(({ buyerId, purchase: { sellerId, round, price, category, value } }) => ({
        buyerId,
        sellerId,
        round,
        price,
        category,
        value,
      })),
    results: finished ? state.players.map((player) => resultFor(state, player)) : null,
    revealedSales: finished
      ? state.sales.map(({ buyerId, purchase }) => ({ buyerId, purchase: purchaseCard(purchase) }))
      : null,
  };
}

export function dealsPrivate(state: DealsState, playerId: string): DealsPrivate {
  const player = member(state, playerId);
  return {
    balance: player.balance,
    inventory: player.inventory.map((item) => ({ ...item })),
    goalOptions: player.goalOptions.map(goalCard),
    ownLotItem: player.lot ? { ...player.lot.item } : null,
    goal: player.goal ? goalCard(player.goal) : null,
    outgoingOffer: player.offer ? { ...player.offer } : null,
    incomingOffers: state.players.flatMap(({ offer }) =>
      offer?.sellerId === playerId ? [{ ...offer }] : [],
    ),
    inspection: player.inspection ? { ...player.inspection } : null,
    insuranceAvailable: player.insuranceAvailable,
    purchased: bought(state, playerId),
    purchases: purchasesOf(state, playerId).map(purchaseCard),
  };
}
