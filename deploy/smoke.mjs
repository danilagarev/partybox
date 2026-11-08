import { mkdtemp, writeFile, readFile, rm, mkdir } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { checkDeployment, waitReady, request } from '../apps/backend/tool/check-deployment.mjs';
const root = fileURLToPath(new URL('../', import.meta.url));
const directory = await mkdtemp(join(tmpdir(), 'partybox-https-'));
const project = `pb-https-${randomBytes(5).toString('hex')}`;
const env = { ...process.env, ROOM_DOMAIN: 'localhost' };
const override = join(directory, 'override.yaml');
const files = ['-p', project, '-f', join(root, 'deploy/compose.yaml'), '-f', override];
function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: root, env, stdio: 'inherit', ...options });
    child.once('error', reject);
    child.once('exit', (code) =>
      code === 0 ? resolve() : reject(new Error(`${command} exited ${code}`)),
    );
  });
}
const compose = (...args) => run('docker', ['compose', ...files, ...args]);
const listener = createServer();
await new Promise((resolve) => listener.listen(0, '127.0.0.1', resolve));
const port = listener.address().port;
await new Promise((resolve) => listener.close(resolve));
const origin = `https://localhost:${port}`;
try {
  await mkdir(join(directory, 'secrets'), { mode: 0o700 });
  for (const name of ['database_password', 'room_token_secret'])
    await writeFile(join(directory, 'secrets', name), randomBytes(32).toString('hex') + '\n', {
      mode: 0o444,
    });
  const caddy = join(directory, 'Caddyfile');
  await writeFile(caddy, 'localhost {\n tls internal\n reverse_proxy backend:3000\n}\n');
  await writeFile(
    override,
    `services:
  proxy:
    ports: !override
      - "127.0.0.1:${port}:443"
    volumes: !override
      - ${JSON.stringify(caddy + ':/etc/caddy/Caddyfile:ro')}
      - caddy_data:/data
      - caddy_config:/config
secrets:
  database_password:
    file: ${JSON.stringify(join(directory, 'secrets/database_password'))}
  room_token_secret:
    file: ${JSON.stringify(join(directory, 'secrets/room_token_secret'))}
`,
  );
  await compose('config', '--quiet');
  await compose('up', '-d', '--build');
  const cert = join(directory, 'root.crt');
  let ca;
  for (let i = 0; i < 30; i++) {
    try {
      await compose('cp', 'proxy:/data/caddy/pki/authorities/local/root.crt', cert);
      ca = await readFile(cert);
      break;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
  }
  if (!ca) throw new Error('Local CA certificate was not created');
  await waitReady(origin, ca);
  let untrustedRejected = false;
  try {
    await request(origin, undefined, '/health');
  } catch (error) {
    untrustedRejected = [
      'UNABLE_TO_VERIFY_LEAF_SIGNATURE',
      'SELF_SIGNED_CERT_IN_CHAIN',
      'DEPTH_ZERO_SELF_SIGNED_CERT',
      'UNABLE_TO_GET_ISSUER_CERT_LOCALLY',
    ].includes(error.code);
  }
  if (!untrustedRejected) throw new Error('Untrusted certificate was not rejected');
  await checkDeployment(origin, ca, async () => {
    await compose('restart', 'backend');
    await waitReady(origin, ca);
    await compose('stop', 'postgres');
    await waitReady(origin, ca, 503);
    if ((await request(origin, ca, '/health')).status !== 200)
      throw new Error('Health should remain available without DB');
    await compose('start', 'postgres');
    await waitReady(origin, ca);
  });
  if (process.env.FLUTTER_BIN)
    await run(
      process.env.FLUTTER_BIN,
      ['test', 'test/rooms/room_server_test.dart', '--reporter', 'expanded'],
      {
        cwd: join(root, 'apps/mobile'),
        env: { ...env, ROOM_TEST_SERVER: origin, ROOM_TEST_CA: cert },
      },
    );
  let limited = false;
  for (let i = 0; i < 70; i++) {
    const response = await request(origin, ca, '/v2/rooms/join/000000', {}, null, {
      'X-Forwarded-For': `198.51.100.${i + 1}`,
    });
    if (response.status === 429) {
      limited = true;
      break;
    }
  }
  if (!limited) throw new Error('Forwarded header spoofing bypassed the IP limit');
  console.log(
    'HTTPS deployment smoke passed: verified TLS, readiness, four clients, restart and database recovery.',
  );
} finally {
  try {
    await compose('down', '--volumes', '--remove-orphans');
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}
