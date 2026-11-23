import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import { machine, cpus } from 'node:os';
import { dirname } from 'node:path';
import { performance } from 'node:perf_hooks';
import { parseArgs } from 'node:util';
import {
  acknowledgeSpy,
  ballotSpy,
  createSpy,
  spyBallot,
  spyCard,
  spyPublic,
  spyVoting,
  voteSpy,
} from '../apps/backend/src/games/spy.ts';

const fixedNow = 1_800_000_000_000;
const scenarios = [
  { name: '4-players-result', players: 4, outcome: 'result' },
  { name: '12-players-pending', players: 12, outcome: 'pending' },
  { name: '12-players-tie', players: 12, outcome: 'tie' },
  { name: '12-players-result', players: 12, outcome: 'result' },
];

function scenarioWorkload({ players: playerCount, outcome }) {
  const players = Array.from({ length: playerCount }, (_, index) => ({
    id: `player-${index + 1}`,
    name: `Игрок ${index + 1}`,
  }));
  let prepared = createSpy(players, 'Станция', 0, 180_000, true);
  for (const player of players) prepared = acknowledgeSpy(prepared, player.id, fixedNow);
  prepared = voteSpy(prepared);

  const votesBeforeSample = playerCount - (outcome === 'pending' ? 2 : 1);
  const suspectFor = (index) => players[outcome === 'tie' ? index % 2 : 0].id;
  for (let index = 0; index < votesBeforeSample; index++) {
    prepared = ballotSpy(prepared, players[index].id, 1, suspectFor(index));
  }
  const voter = players[votesBeforeSample].id;
  const suspect = suspectFor(votesBeforeSample);
  function submitVote() {
    return ballotSpy(prepared, voter, 1, suspect);
  }

  const afterVote = submitVote();
  assert.equal(afterVote.phase, outcome === 'result' ? 'results' : 'voting');
  assert.equal(afterVote.ballots.round, outcome === 'tie' ? 2 : 1);
  assert.equal(afterVote.ballots.votes.length, outcome === 'tie' ? 0 : votesBeforeSample + 1);

  return () => {
    const state = submitVote();
    return players.map(({ id }) => ({
      publicGame: spyPublic(state),
      voting: spyVoting(state),
      card: state.phase === 'results' ? null : spyCard(state, id),
      ballot: spyBallot(state, id),
    }));
  };
}

function measure(scenario, iterations, warmup) {
  const operation = scenarioWorkload(scenario);
  let projections;
  for (let index = 0; index < warmup; index++) projections = operation();

  const samples = new Float64Array(iterations);
  const startedAt = performance.now();
  for (let index = 0; index < iterations; index++) {
    const sampleStartedAt = performance.now();
    projections = operation();
    samples[index] = performance.now() - sampleStartedAt;
  }
  const elapsedMs = performance.now() - startedAt;
  assert.equal(projections.length, scenario.players);
  samples.sort();
  return {
    ...scenario,
    p50Ms: samples[Math.ceil(iterations * 0.5) - 1],
    p95Ms: samples[Math.ceil(iterations * 0.95) - 1],
    throughputOpsPerSec: (iterations * 1_000) / elapsedMs,
  };
}

export function evaluateBudget(scenarios, maxP95Ms) {
  if (maxP95Ms === null) return null;
  const exceededScenarios = scenarios
    .filter((scenario) => scenario.p95Ms > maxP95Ms)
    .map(({ name }) => name);
  return { maxP95Ms, passed: exceededScenarios.length === 0, exceededScenarios };
}

function iterationCount(value, option, minimum) {
  const count = Number(value);
  if (!/^\d+$/.test(value) || !Number.isInteger(count) || count < minimum || count > 1_000_000) {
    throw new Error(`${option} ожидает целое число от ${minimum} до 1000000`);
  }
  return count;
}

export async function main(args, write = (text) => process.stdout.write(text)) {
  const { values } = parseArgs({
    args,
    options: {
      help: { type: 'boolean', short: 'h' },
      iterations: { type: 'string', default: '10000' },
      warmup: { type: 'string', default: '2000' },
      output: { type: 'string' },
      'max-p95-ms': { type: 'string' },
    },
  });
  if (values.help) {
    write(
      'node scripts/benchmark-spy.mjs [--iterations 10000] [--warmup 2000] [--output <файл.json>] [--max-p95-ms <мс>]\n',
    );
    return 0;
  }

  const iterations = iterationCount(values.iterations, '--iterations', 1);
  const warmup = iterationCount(values.warmup, '--warmup', 0);
  const maxP95Ms = values['max-p95-ms'] === undefined ? null : Number(values['max-p95-ms']);
  if (maxP95Ms !== null && (!Number.isFinite(maxP95Ms) || maxP95Ms <= 0)) {
    throw new Error('--max-p95-ms ожидает положительное конечное число');
  }

  const timestamp = new Date().toISOString();
  const results = scenarios.map((scenario) => measure(scenario, iterations, warmup));
  const budget = evaluateBudget(results, maxP95Ms);
  const report = {
    schemaVersion: 1,
    benchmark: 'spy-ballot-projections',
    timestamp,
    environment: {
      node: process.version,
      platform: process.platform,
      architecture: machine(),
      cpuModel: cpus()[0]?.model ?? null,
    },
    iterations,
    warmup,
    scenarios: results,
    budget,
  };
  const json = `${JSON.stringify(report, null, 2)}\n`;
  if (values.output !== undefined) {
    await mkdir(dirname(values.output), { recursive: true });
    await writeFile(values.output, json);
  }
  write(json);
  return budget?.passed === false ? 1 : 0;
}

if (import.meta.main) {
  try {
    process.exitCode = await main(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
