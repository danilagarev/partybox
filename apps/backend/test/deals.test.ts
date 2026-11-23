import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { DealsItem, DealsRevealedSale } from '@partybox/game-contracts/rooms-v7';
import { dealsPack, sellingGoalRules } from '../src/games/deals-content.js';
import {
  advanceDeals,
  createDeals,
  dealsPrivate,
  dealsPublic,
  playDeals,
  type DealsAction,
} from '../src/games/deals.js';

const choose = (length: number) => length - 1;
const move = (type: DealsAction['type'], payload: DealsAction['payload'] = {}) =>
  ({ type, payload }) as DealsAction;

test('duel supports a bluff, inspection, competing price and round transition', () => {
  let state = createDeals(['seller', 'buyer'], choose);
  const play = (player: string, command: DealsAction, now = 5000) => {
    state = playDeals(state, player, command, now);
  };
  for (const id of ['seller', 'buyer']) {
    const view = dealsPrivate(state, id);
    assert.deepEqual(
      view.inventory.map((item) => item.value),
      [2, 5, 8],
    );
    assert.equal(view.goalOptions.length, 2);
    play(id, move('deals.choose', { goalId: view.goalOptions[0]!.id }));
  }
  const hidden = dealsPrivate(state, 'seller').inventory[0]!;
  const listing = { itemId: hidden.id, category: 'art', value: 8, price: 10 } as const;
  play('seller', move('deals.list', listing));
  assert.deepEqual(dealsPublic(state, 'duel').lots, []);
  assert.equal(dealsPrivate(state, 'seller').ownLotItem?.id, hidden.id);
  assert.equal(dealsPrivate(state, 'buyer').ownLotItem, null);
  const pass = { itemId: null, category: null, value: null, price: null };
  play('buyer', move('deals.list', pass));
  assert.equal(state.phase, 'trading');
  assert.equal(state.deadline, 185000);
  assert.equal(advanceDeals(state, 184999), state);
  assert.throws(() => play('seller', move('deals.buy', { sellerId: 'seller', insured: false })));
  play('buyer', move('deals.inspect', { sellerId: 'seller', mode: 'category' }));
  assert.equal(dealsPrivate(state, 'buyer').inspection?.category, hidden.category);
  assert.equal(dealsPrivate(state, 'buyer').inspection?.value, null);
  assert.equal(dealsPrivate(state, 'seller').inspection, null);
  assert.throws(() => play('buyer', move('deals.inspect', { sellerId: 'seller', mode: 'value' })));
  play('buyer', move('deals.offer', { sellerId: 'seller', price: 6, insured: true }));
  assert.equal(dealsPrivate(state, 'seller').incomingOffers[0]!.price, 6);
  play('seller', move('deals.done'));
  play('seller', move('deals.accept', { buyerId: 'buyer' }));
  assert.equal(dealsPrivate(state, 'seller').balance, 46);
  const buyer = dealsPrivate(state, 'buyer');
  assert.equal(buyer.balance, 34);
  assert.equal(buyer.insuranceAvailable, false);
  assert.equal(buyer.purchases[0]!.item.id, hidden.id);
  assert.equal(buyer.purchases[0]!.inspection, 'category');
  const publicState = dealsPublic(state, 'duel');
  assert.equal(publicState.sales[0]!.value, 8);
  assert.equal(publicState.revealedSales, null);
  assert.ok(!JSON.stringify(publicState).includes(hidden.id));
  assert.throws(() => play('buyer', move('deals.done'), 185000));
  const timedOut = advanceDeals(state, 185000);
  assert.equal(timedOut.phase, 'market');
  assert.deepEqual(dealsPublic(timedOut, 'duel').readyIds, ['buyer']);
});

test('all players passing listing opens the market immediately', () => {
  const ids = ['a', 'b'];
  let state = createDeals(ids, choose);
  for (const id of ids) {
    state = playDeals(
      state,
      id,
      move('deals.choose', { goalId: dealsPrivate(state, id).goalOptions[0]!.id }),
      5000,
    );
  }
  const pass = move('deals.list', { itemId: null, category: null, value: null, price: null });
  const waiting = playDeals(state, 'a', pass, 5000);
  assert.equal(waiting.phase, 'listing');
  assert.deepEqual(dealsPublic(waiting, 'duel').readyIds, ['a']);

  const market = playDeals(waiting, 'b', pass, 5000);
  const view = dealsPublic(market, 'duel');
  assert.equal(view.phase, 'market');
  assert.equal(view.deadline, null);
  assert.deepEqual(view.readyIds, []);
  assert.deepEqual(view.lots, []);
  assert.deepEqual(market.market, waiting.market);
  assert.equal(waiting.phase, 'listing');

  const itemId = view.market[0]!.item.id;
  const picked = playDeals(market, 'a', move('deals.market', { itemId }), 5000);
  const recap = playDeals(picked, 'b', move('deals.market', { itemId: null }), 5000);
  assert.equal(recap.phase, 'recap');
  assert.equal(dealsPrivate(recap, 'a').purchases[0]!.item.id, itemId);
});

test('room game supports every size from two to six and shuffles balanced inventory', () => {
  for (let count = 2; count <= 6; count++) {
    const players = Array.from({ length: count }, (_, i) => String(i));
    const state = createDeals(players, choose);
    const items = players.flatMap((id) => dealsPrivate(state, id).inventory);
    const goals = players.flatMap((id) => dealsPrivate(state, id).goalOptions);
    assert.equal(new Set(items.map((item) => item.id)).size, count * 3);
    assert.equal(new Set(goals.map((goal) => goal.id)).size, count * 2);
    assert.equal(state.deck.length, 108 - count * 3);
    assert.notEqual(state.events[0]!.id, state.events[1]!.id);
  }
  for (const ids of [['a'], ['a', 'a'], ['a', 'b', 'c', 'd', 'e', 'f', 'g']]) {
    assert.throws(() => createDeals(ids, choose));
  }
});

test('each side of a duel can choose a goal about selling with any category', () => {
  for (let seed = 0; seed < 200; seed++) {
    let random = seed;
    const state = createDeals(['a', 'b'], (length) => {
      random = (Math.imul(random, 1664525) + 1013904223) >>> 0;
      return Math.floor((random * length) / 2 ** 32);
    });
    const allOptions = state.players.flatMap((player) => player.goalOptions);
    assert.equal(new Set(allOptions.map((option) => option.id)).size, 4);
    for (const player of state.players) {
      const [selling, alternative] = player.goalOptions;
      assert.ok(sellingGoalRules.some((rule) => selling?.rule === rule));
      assert.deepEqual(selling?.categories, []);
      assert.notEqual(alternative?.rule, 'cheapAndRare');
    }
  }
});

const rareItems = dealsPack.items.filter(({ value }) => value === 8);
const firstRare = rareItems[0]!;
const secondRare = rareItems[1]!;

function mockSale(
  item: DealsItem,
  round: number,
  sellerId: string | null,
  buyerId: string,
  changes: Partial<DealsRevealedSale['purchase']> = {},
): DealsRevealedSale {
  return {
    buyerId,
    purchase: {
      item,
      round,
      sellerId,
      value: item.value,
      category: item.category,
      price: item.value,
      offered: false,
      inspection: null,
      insured: false,
      ...changes,
    },
  };
}

function goalBonus(goalId: string, sales: DealsRevealedSale[]) {
  const state = createDeals(['a', 'b'], choose);
  const goal = dealsPack.goals.find((option) => option.id === goalId)!;
  return dealsPublic(
    {
      ...state,
      phase: 'finished',
      round: 5,
      sales,
      players: state.players.map((player) => ({ ...player, goal })),
    },
    'duel',
  ).results![0]!.bonus;
}

test('a resale and buyback never count one item as two distinct purchases', () => {
  const fromMarket = mockSale(firstRare, 1, null, 'a');
  const categoryChecked = mockSale(firstRare, 1, 'b', 'a', { inspection: 'category' });
  const sold = mockSale(firstRare, 2, 'a', 'b');
  const rebought = mockSale(firstRare, 3, 'b', 'a');
  const reboughtChecked = mockSale(firstRare, 3, 'b', 'a', { inspection: 'value' });
  assert.equal(goalBonus('goal-19', [categoryChecked, sold, reboughtChecked]), 0);
  assert.equal(goalBonus('goal-20', [fromMarket, sold, rebought]), 0);
  assert.equal(goalBonus('goal-23', [rebought, sold, rebought]), 0);
  assert.equal(
    goalBonus('goal-19', [
      categoryChecked,
      mockSale(secondRare, 2, 'b', 'a', { inspection: 'value' }),
    ]),
    8,
  );
  assert.equal(goalBonus('goal-20', [fromMarket, mockSale(secondRare, 2, 'b', 'a')]), 8);
  assert.equal(goalBonus('goal-23', [rebought, mockSale(secondRare, 5, 'b', 'a')]), 7);
});

test('selling goals require one opponent purchase and score the agreed sale terms', () => {
  const buy = mockSale(firstRare, 1, 'b', 'a');
  const trick = mockSale(firstRare, 2, 'a', 'b', { offered: true, price: 10, value: 2 });
  const honest = mockSale(secondRare, 3, 'a', 'b');
  for (const [goalId, bonus] of [
    ['goal-25', 7],
    ['goal-26', 8],
    ['goal-27', 7],
    ['goal-28', 8],
    ['goal-29', 8],
    ['goal-30', 9],
  ] as const) {
    assert.equal(goalBonus(goalId, [trick, honest]), 0);
    assert.equal(goalBonus(goalId, [buy, trick, honest]), bonus);
  }
  assert.equal(goalBonus('goal-28', [buy, mockSale(firstRare, 2, 'a', 'b', { price: 9 })]), 0);
  assert.equal(goalBonus('goal-30', [mockSale(firstRare, 1, 'a', 'b'), buy]), 0);
});
