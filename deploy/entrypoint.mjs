import { readFileSync } from 'node:fs';
function secret(name) {
  const file = process.env[`${name}_FILE`];
  if (!file) throw new Error(`${name}_FILE is required`);
  const value = readFileSync(file, 'utf8').trim();
  if (!value) throw new Error(`${name} is empty`);
  return value;
}
try {
  const token = secret('ROOM_TOKEN_SECRET');
  if (!/^[a-f0-9]{64}$/.test(token)) throw new Error('Invalid room token secret');
  const url = new URL('postgresql://postgres:5432/partybox');
  url.username = 'partybox';
  url.password = secret('DATABASE_PASSWORD');
  process.env.DATABASE_URL = url.toString();
  process.env.ROOM_TOKEN_SECRET = token;
  if (!['0', '1'].includes(process.env.TRUST_PROXY_HOPS ?? '0'))
    throw new Error('TRUST_PROXY_HOPS must be 0 or 1');
  const mode = process.argv[2] ?? 'serve';
  if (mode === 'migrate') await import('../apps/backend/dist/src/rooms/migrate-main.js');
  else if (mode === 'serve') await import('../apps/backend/dist/src/main.js');
  else throw new Error('Unknown entrypoint mode');
} catch {
  console.error(
    'Backend configuration or startup failed; check secret files and database availability.',
  );
  process.exitCode = 1;
}
