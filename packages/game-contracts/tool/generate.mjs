import { readFile, writeFile } from 'node:fs/promises';
import { compile } from 'json-schema-to-typescript';
const schema = JSON.parse(
  await readFile(new URL('../schemas/rooms-v1.schema.json', import.meta.url), 'utf8'),
);
const output = await compile(schema, 'RoomsV1', {
  unreachableDefinitions: true,
  ignoreMinAndMaxItems: true,
  style: { singleQuote: true, trailingComma: 'all', printWidth: 100 },
});
await writeFile(new URL('../generated/rooms-v1.d.ts', import.meta.url), output);
