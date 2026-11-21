// Isolated PartyBox + Caddy smoke. Never uses the real VPS, Baza or public ACME.
import assert from 'node:assert/strict';
import {
  mkdtempSync,
  mkdirSync,
  copyFileSync,
  rmSync,
  appendFileSync,
  writeFileSync,
  readFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { randomUUID, randomBytes } from 'node:crypto';
import { io } from 'socket.io-client';

const root = mkdtempSync(join(tmpdir(), 'partybox-production-smoke-'));
const bundle = join(root, 'releases/smoke');
const source = resolve('deploy/production');
const project = `partybox_prod_smoke_${process.pid}`;
const image = `partybox-production-smoke:${process.pid}`;
const proxyNetwork = `${project}_proxy`;
const proxyName = `${project}_caddy`;
const env = { ...process.env, BACKEND_IMAGE: image, PARTYBOX_PROXY_NETWORK: proxyNetwork };
let socket;
function run(command, args, capture = false) {
  const result = spawnSync(command, args, {
    env,
    encoding: 'utf8',
    stdio: capture ? 'pipe' : 'inherit',
  });
  if (result.status !== 0)
    throw new Error(`${command} failed: ${capture ? result.stderr : result.status}`);
  return result.stdout;
}
const base = [
  'compose',
  '--project-name',
  project,
  '--env-file',
  join(root, '.env'),
  '-f',
  join(bundle, 'compose.yaml'),
];
const compose = (args, capture) => run('docker', [...base, ...args], capture);
mkdirSync(bundle, { recursive: true });
for (const file of ['compose.yaml']) copyFileSync(join(source, file), join(bundle, file));
try {
  run('bash', [join(source, 'init.sh'), root]);
  appendFileSync(join(root, '.env'), `\nPARTYBOX_PROXY_NETWORK=${proxyNetwork}\n`);
  run('docker', ['network', 'create', proxyNetwork], true);
  // Caddy's test CA stays in this disposable container; no public certificate request.
  const caddyfile = readFileSync(join(source, 'Caddyfile.example'), 'utf8').replace(
    'partybox.sorima.tech {',
    'partybox.sorima.tech {\n    tls internal',
  );
  writeFileSync(join(root, 'Caddyfile'), caddyfile);
  const config = JSON.parse(compose(['config', '--format', 'json'], true));
  assert.equal(config.services['partybox-api'].ports, undefined);
  assert.equal(config.networks.frontend.external, true);
  assert.equal(config.services.postgres.ports, undefined);
  assert.equal(config.networks.database.internal, true);
  assert.equal(config.services['partybox-api'].read_only, true);
  assert.ok(!config.services['partybox-api'].user.startsWith('0:'));
  assert.equal(Number(config.services['partybox-api'].mem_limit), 384 * 1024 ** 2);
  run('docker', ['build', '-f', 'deploy/Dockerfile', '-t', image, '.']);
  // The independent proxy must boot before the application exists.
  run(
    'docker',
    [
      'run',
      '--detach',
      '--name',
      proxyName,
      '--network',
      proxyNetwork,
      '-p',
      '127.0.0.1::443',
      '-v',
      `${root}/Caddyfile:/etc/caddy/Caddyfile:ro`,
      'caddy:2-alpine',
    ],
    true,
  );
  run('docker', [
    'exec',
    proxyName,
    'caddy',
    'validate',
    '--config',
    '/etc/caddy/Caddyfile',
    '--adapter',
    'caddyfile',
  ]);
  const tlsPort = run('docker', ['port', proxyName, '443'], true).trim().split(':').at(-1);
  const proxyId = proxyName;
  run(
    'docker',
    ['cp', `${proxyId}:/data/caddy/pki/authorities/local/root.crt`, join(root, 'root.crt')],
    true,
  );
  function probe(path, extra = []) {
    return run(
      'curl',
      [
        '--fail',
        '--silent',
        '--show-error',
        '--noproxy',
        '*',
        '--cacert',
        join(root, 'root.crt'),
        '--resolve',
        `partybox.sorima.tech:${tlsPort}:127.0.0.1`,
        ...extra,
        `https://partybox.sorima.tech:${tlsPort}/${path}`,
      ],
      true,
    );
  }
  async function ready() {
    for (let i = 0; i < 30; i++) {
      try {
        assert.equal(JSON.parse(probe('ready')).status, 'ready');
        return;
      } catch {
        await new Promise((r) => setTimeout(r, 500));
      }
    }
    throw new Error('Caddy could not reach PartyBox after startup/recreate');
  }
  compose(['up', '-d', '--wait', '--wait-timeout', '120', 'postgres']);
  compose(['run', '--rm', '--no-deps', 'migrate']);
  compose(['up', '-d', '--no-deps', '--wait', '--wait-timeout', '120', 'partybox-api']);
  await ready();
  assert.equal(JSON.parse(probe('health')).status, 'ok');
  const enrollment = JSON.parse(
    probe('v3/rooms', [
      '-H',
      'Content-Type: application/json',
      '--data',
      JSON.stringify({
        protocolVersion: 3,
        requestId: randomUUID(),
        retryKey: randomBytes(32).toString('base64url'),
        name: 'Smoke',
      }),
    ]),
  );
  await new Promise((resolve, reject) => {
    socket = io(`https://127.0.0.1:${tlsPort}`, {
      transports: ['websocket'],
      reconnection: false,
      rejectUnauthorized: false,
      extraHeaders: { Host: 'partybox.sorima.tech' },
      // Only this isolated self-signed WebSocket probe disables certificate validation.
      auth: {
        roomId: enrollment.snapshot.roomId,
        guestToken: enrollment.guestToken,
        protocolVersion: 3,
      },
    });
    const timer = setTimeout(() => reject(new Error('WebSocket upgrade timed out')), 10000);
    socket.once('room.snapshot', (value) => {
      clearTimeout(timer);
      assert.equal(value.selfId, enrollment.snapshot.selfId);
      resolve();
    });
    socket.once('connect_error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
  socket.disconnect();
  compose([
    'exec',
    '-T',
    'postgres',
    'psql',
    '-U',
    'partybox',
    '-d',
    'partybox',
    '-c',
    'CREATE TABLE deployment_smoke (id int); INSERT INTO deployment_smoke VALUES (42);',
  ]);
  compose([
    'up',
    '-d',
    '--no-deps',
    '--force-recreate',
    '--wait',
    '--wait-timeout',
    '120',
    'partybox-api',
  ]);
  await ready();
  assert.equal(
    compose(
      [
        'exec',
        '-T',
        'postgres',
        'psql',
        '-U',
        'partybox',
        '-d',
        'partybox',
        '-Atc',
        'SELECT id FROM deployment_smoke;',
      ],
      true,
    ).trim(),
    '42',
  );
  console.log(
    'PartyBox + Caddy: standalone proxy network, boot without API, trusted local TLS, WebSocket, API recreate, unpublished API and private database and persistence passed.',
  );
} finally {
  socket?.disconnect();
  try {
    run('docker', ['rm', '-f', '-v', proxyName], true);
  } catch {
    /* Only this smoke proxy. */
  }
  try {
    compose(['down', '--volumes', '--remove-orphans']);
  } catch {
    /* Keep the original failure. */
  }
  try {
    run('docker', ['image', 'rm', image]);
  } catch {
    /* Optional cleanup. */
  }
  try {
    run('docker', ['network', 'rm', proxyNetwork], true);
  } catch {
    /* Only this smoke network. */
  }
  rmSync(root, { recursive: true, force: true });
}
