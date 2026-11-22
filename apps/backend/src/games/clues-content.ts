import { readFileSync } from 'node:fs';
import { Ajv } from 'ajv';
import type { CluesQuestion } from './clues.js';
const base = new URL('../../../../../packages/', import.meta.url);
const pack = JSON.parse(
  readFileSync(new URL('game-content/packs/clues-ru-base.json', base), 'utf8'),
);
const schema = JSON.parse(
  readFileSync(new URL('game-contracts/schemas/clues-pack.schema.json', base), 'utf8'),
);
if (!new Ajv({ strict: true }).compile<{ version: number; items: CluesQuestion[] }>(schema)(pack))
  throw new Error('Invalid bundled Clues pack');
export const cluesPackVersion: number = pack.version;
export const cluesQuestions: readonly CluesQuestion[] = pack.items;
export function selectCluesQuestions(choose: (length: number) => number): CluesQuestion[] {
  const questions = [...cluesQuestions];
  for (let i = questions.length - 1; i > 0; i--) {
    const j = choose(i + 1);
    [questions[i], questions[j]] = [questions[j]!, questions[i]!];
  }
  return questions.slice(0, 5).map((question, index) => ({
    ...question,
    id: `question-${index + 1}`,
    aliases: [...question.aliases],
    clues: [...question.clues],
  }));
}
