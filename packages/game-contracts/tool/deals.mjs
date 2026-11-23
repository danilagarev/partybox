import { readFile, writeFile } from 'node:fs/promises';
import { compile } from 'json-schema-to-typescript';
import { format } from 'prettier';

const file = (path) => new URL(path, import.meta.url);
const read = (path) => readFile(file(path), 'utf8');
const writeJson = async (path, value) =>
  writeFile(file(path), await format(JSON.stringify(value), { parser: 'json', printWidth: 100 }));
const schema = JSON.parse(
  (await read('../schemas/rooms-v6.schema.json'))
    .replaceAll('rooms-v6', 'rooms-v7')
    .replaceAll('V6', 'V7')
    .replaceAll(/("const":\s*)6\b/g, '$1' + '7'),
);

const defs = schema.$defs;
const ref = (name) => ({ $ref: `#/$defs/${name}` });
const nullable = (value) => ({ oneOf: [value, { type: 'null' }] });
const array = (items, maxItems) => ({ type: 'array', items, maxItems });
const obj = (properties) => ({
  type: 'object',
  additionalProperties: false,
  properties,
  required: Object.keys(properties),
});
const int = (minimum, maximum) => ({ type: 'integer', minimum, maximum });
const text = (maxLength) => ({ type: 'string', minLength: 1, maxLength });
const uid = defs.V7Snapshot.properties.selfId;
const id = { type: 'string', pattern: '^[a-z0-9-]{1,40}$' };
const bool = { type: 'boolean' };
const category = ref('DealsCategory');
const value = ref('DealsValue');
const mode = ref('DealsInspectionMode');
const price = int(1, 15);
const round = int(1, 5);
const balance = int(0, 150);
const bonus = int(0, 9);

Object.assign(defs, {
  DealsCategory: { type: 'string', enum: ['tech', 'art', 'jewelry', 'antiques', 'toys', 'music'] },
  DealsValue: { type: 'integer', enum: [2, 5, 8] },
  DealsInspectionMode: { type: 'string', enum: ['category', 'value', 'match', 'both'] },
  DealsItem: obj({ id, name: text(100), category, value }),
  DealsGoal: obj({ id, title: text(100), text: text(350), bonus }),
  DealsEvent: obj({ id, title: text(100), text: text(350) }),
  DealsLot: obj({ sellerId: uid, category, value, price, sold: bool }),
  DealsOffer: obj({ sellerId: uid, buyerId: uid, price, insured: bool }),
  DealsInspection: obj({
    sellerId: uid,
    mode,
    category: nullable(category),
    value: nullable(value),
    matches: nullable(bool),
  }),
  DealsSale: obj({ sellerId: nullable(uid), buyerId: uid, round, price, category, value }),
  DealsPurchase: obj({
    item: ref('DealsItem'),
    round,
    price,
    sellerId: nullable(uid),
    category,
    value,
    offered: bool,
    inspection: nullable(mode),
    insured: bool,
  }),
  DealsResult: obj({
    playerId: uid,
    balance,
    goodsValue: int(0, 80),
    bonus,
    total: int(0, 239),
    goal: ref('DealsGoal'),
    inventory: array(ref('DealsItem'), 10),
  }),
  DealsRevealedSale: obj({ buyerId: uid, purchase: ref('DealsPurchase') }),
  DealsPublic: obj({
    sessionId: uid,
    packVersion: int(1, 1000),
    phase: { type: 'string', enum: ['goals', 'listing', 'trading', 'market', 'recap', 'finished'] },
    round,
    deadline: nullable({ type: 'string' }),
    readyIds: array(uid, 6),
    lots: array(ref('DealsLot'), 6),
    market: array(obj({ item: ref('DealsItem'), price }), 2),
    event: nullable(ref('DealsEvent')),
    marketPriorityId: uid,
    sales: array(ref('DealsSale'), 30),
    results: nullable(array(ref('DealsResult'), 6)),
    revealedSales: nullable(array(ref('DealsRevealedSale'), 30)),
  }),
  DealsPrivate: obj({
    balance,
    inventory: array(ref('DealsItem'), 10),
    goalOptions: array(ref('DealsGoal'), 2),
    ownLotItem: nullable(ref('DealsItem')),
    goal: nullable(ref('DealsGoal')),
    outgoingOffer: nullable(ref('DealsOffer')),
    incomingOffers: array(ref('DealsOffer'), 5),
    inspection: nullable(ref('DealsInspection')),
    insuranceAvailable: bool,
    purchased: bool,
    purchases: array(ref('DealsPurchase'), 5),
  }),
});
const snapshot = defs.V7Snapshot;
snapshot.properties.publicState.properties.deals = nullable(ref('DealsPublic'));
snapshot.properties.publicState.required.push('deals');
snapshot.properties.privateDeals = nullable(ref('DealsPrivate'));
snapshot.required.push('privateDeals');

const commandPayloads = {
  start: {},
  cancel: {},
  choose: { goalId: id },
  list: {
    itemId: nullable(id),
    category: nullable(category),
    value: nullable(value),
    price: nullable(price),
  },
  offer: { sellerId: nullable(uid), price: nullable(price), insured: bool },
  accept: { buyerId: uid },
  buy: { sellerId: uid, insured: bool },
  inspect: { sellerId: uid, mode },
  done: {},
  market: { itemId: nullable(id) },
  next: {},
};
const { protocolVersion, commandId, expectedVersion, sessionId } =
  defs.V7Command.oneOf[0].properties;
for (const [action, payload] of Object.entries(commandPayloads)) {
  defs.V7Command.oneOf.push(
    obj({
      protocolVersion,
      commandId,
      expectedVersion,
      sessionId,
      type: { const: `deals.${action}` },
      payload: obj(payload),
    }),
  );
}

await writeJson('../schemas/rooms-v7.schema.json', schema);
await writeFile(
  file('../generated/rooms-v7.d.ts'),
  await compile(schema, 'RoomsV7', {
    unreachableDefinitions: true,
    ignoreMinAndMaxItems: true,
    style: { singleQuote: true, trailingComma: 'all', printWidth: 100 },
  }),
);
await writeFile(
  file('../../../apps/mobile/lib/src/rooms/generated/room_deals_schema.dart'),
  `// GENERATED by packages/game-contracts/tool/deals.mjs. Do not edit.\nconst roomDealsSchemaJson = r'''\n${JSON.stringify(schema, null, 2)}\n''';\n`,
);
const openapi = JSON.parse(
  (await read('../openapi-rooms-v6.json'))
    .replaceAll('/v6/', '/v7/')
    .replaceAll('V6', 'V7')
    .replaceAll('6.0.0', '7.0.0'),
);
openapi.components.schemas = JSON.parse(
  JSON.stringify(defs).replaceAll('#/$defs/', '#/components/schemas/'),
);
await writeJson('../openapi-rooms-v7.json', openapi);
