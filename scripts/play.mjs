#!/usr/bin/env node
import { spawn, fork } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { webBuildArtifacts } from './play-assets.mjs';
import { access, mkdir, readFile, writeFile } from 'node:fs/promises';
import { constants } from 'node:fs';
import { networkInterfaces } from 'node:os';
import { delimiter, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const help = `Запуск «Вечеро» для телефонов (Node 24, Docker, Flutter):
  node scripts/play.mjs lan|internet [параметры]
  --port 8720          порт страницы
  --host IP            адрес привязки (lan: 0.0.0.0; internet: 127.0.0.1)
  --advertise-host IP  адрес в ссылке для друзей в одной Wi-Fi сети
  --skip-build         использовать проверенную сборку этого режима
  --help              эта справка

lan: браузерное превью в одной Wi-Fi сети; адрес сервера подбирается локально.
internet: release-сборка и публичный временный HTTPS-туннель Cloudflare.
Нужен cloudflared в PATH либо CLOUDFLARED_BIN. Публикуется только по явному internet.
Остановка Ctrl+C удаляет только временную БД этого запуска. Партии будут потеряны.`;

function parse(args) {
  if (args.includes('--help')) return null;
  const mode = args.shift();
  if (!['lan', 'internet'].includes(mode)) throw new Error(help);
  const result = {
    mode,
    port: 8720,
    host: mode === 'lan' ? '0.0.0.0' : '127.0.0.1',
    skipBuild: false,
  };
  while (args.length) {
    const key = args.shift();
    if (key === '--skip-build') {
      result.skipBuild = true;
      continue;
    }
    if (!['--port', '--host', '--advertise-host'].includes(key) || !args.length)
      throw new Error(`Неизвестный или неполный параметр: ${key}. См. --help.`);
    const value = args.shift();
    if (key === '--port') {
      if (!/^\d+$/.test(value) || Number(value) < 1 || Number(value) > 65535)
        throw new Error('--port: требуется число от 1 до 65535.');
      result.port = Number(value);
    } else {
      if (!/^[a-zA-Z0-9.:-]+$/.test(value)) throw new Error(`${key}: требуется IP или имя хоста.`);
      result[key === '--host' ? 'host' : 'advertiseHost'] = value;
    }
  }
  if (mode === 'internet' && !['127.0.0.1', '::1', 'localhost'].includes(result.host))
    throw new Error('internet: --host должен быть loopback (127.0.0.1, ::1 или localhost).');
  return result;
}

async function executable(name) {
  const paths = name.includes('/')
    ? [name]
    : (process.env.PATH ?? '').split(delimiter).map((dir) => resolve(dir, name));
  for (const path of paths) {
    try {
      await access(path, constants.X_OK);
      return path;
    } catch {
      /* Try next PATH entry. */
    }
  }
  return null;
}

function lanAddress() {
  try {
    const addresses = Object.entries(networkInterfaces())
      .filter(([name]) => !/docker|veth|br-|virbr|cni|podman|tailscale|tun|^wg/i.test(name))
      .flatMap(([, values]) => values ?? [])
      .filter((entry) => !entry.internal && entry.family === 'IPv4')
      .map((entry) => entry.address);
    // A 172.x WSL/Docker bridge commonly cannot be reached by phones.
    return (
      addresses.find((ip) => ip.startsWith('192.168.')) ??
      addresses.find((ip) => ip.startsWith('10.'))
    );
  } catch {
    console.log(
      'Не удалось прочитать сетевые интерфейсы. Укажите --advertise-host IP вашего Wi-Fi компьютера.',
    );
    return null;
  }
}

async function main() {
  const config = parse(process.argv.slice(2));
  if (!config) {
    console.log(help);
    return;
  }
  const cloudflared =
    config.mode === 'internet' &&
    (process.env.CLOUDFLARED_BIN
      ? await executable(process.env.CLOUDFLARED_BIN)
      : (await executable(resolve(root, '.tools/cloudflared'))) ||
        (await executable('cloudflared')));
  if (config.mode === 'internet' && !cloudflared)
    throw new Error(
      'Для internet нужен cloudflared. Установите его отдельно и добавьте в PATH либо задайте CLOUDFLARED_BIN=/путь/cloudflared. Сборка и БД ещё не запускались.',
    );
  const docker = await executable('docker');
  if (!docker) throw new Error('Нужен Docker CLI и работающий Docker daemon.');
  const flutter =
    !config.skipBuild &&
    (await executable(process.env.FLUTTER_BIN || resolve(root, '.fvm/flutter_sdk/bin/flutter')));
  if (!config.skipBuild && !flutter)
    throw new Error('Не найден Flutter. Настройте .fvm/flutter_sdk либо FLUTTER_BIN.');

  const children = new Set();
  const controller = new AbortController();
  const container = `partybox-play-${process.pid}-${randomBytes(6).toString('hex')}`;
  let databaseStarted = false,
    server,
    tunnel;
  let stopping = false,
    cleaned = false;
  const stop = () => {
    stopping = true;
    controller.abort();
  };
  process.once('SIGINT', stop);
  process.once('SIGTERM', stop);

  function run(
    command,
    args,
    { timeout = 60000, env = process.env, visible = false, allowStopping = false, cwd = root } = {},
  ) {
    if (stopping && !allowStopping) return Promise.reject(new Error('Остановка.'));
    return new Promise((done, fail) => {
      const child = spawn(command, args, {
        cwd,
        env,
        stdio: visible ? 'inherit' : ['ignore', 'pipe', 'pipe'],
        detached: process.platform !== 'win32',
      });
      children.add(child);
      const kill = (signal) => {
        try {
          if (process.platform !== 'win32' && child.pid) process.kill(-child.pid, signal);
          else child.kill(signal);
        } catch {
          /* Child has already exited. */
        }
      };
      let output = '';
      child.stdout?.on('data', (chunk) => {
        if (output.length < 65536) output += chunk.toString();
      });
      child.stderr?.resume(); // Never print Docker, tunnel or backend diagnostics with runtime secrets.
      let timedOut = false;
      let abortTimer;
      const timer = setTimeout(() => {
        timedOut = true;
        kill('SIGKILL');
      }, timeout);
      const abort = () => {
        kill('SIGTERM');
        abortTimer = setTimeout(() => kill('SIGKILL'), 5000);
      };
      if (!allowStopping) controller.signal.addEventListener('abort', abort, { once: true });
      child.once('error', () => finish(false));
      child.once('close', (code) => finish(code === 0));
      let finished = false;
      function finish(ok) {
        if (finished) return;
        finished = true;
        clearTimeout(timer);
        clearTimeout(abortTimer);
        controller.signal.removeEventListener('abort', abort);
        children.delete(child);
        if (ok) done(output.trim());
        else
          fail(
            new Error(
              stopping
                ? 'Остановка.'
                : `${command.split('/').at(-1)}: ${timedOut ? 'превышено время ожидания' : 'команда завершилась с ошибкой'}.`,
            ),
          );
      }
    });
  }

  async function killChild(child, graceful = false) {
    if (!child || child.exitCode !== null || child.signalCode !== null) return;
    await new Promise((done) => {
      const timer = setTimeout(() => child.kill('SIGKILL'), 5000);
      child.once('close', () => {
        clearTimeout(timer);
        done();
      });
      if (graceful && child.connected) child.send('stop');
      else child.kill('SIGTERM');
    });
  }

  async function cleanup() {
    if (cleaned) return;
    cleaned = true;
    await killChild(tunnel);
    await killChild(server, true);
    await Promise.all([...children].map((child) => killChild(child)));
    if (databaseStarted) {
      try {
        await run(docker, ['rm', '--force', '--volumes', container], {
          timeout: 15000,
          allowStopping: true,
        });
      } catch {
        let removed = false;
        try {
          removed = !(await run(
            docker,
            ['ps', '-a', '--filter', `name=^/${container}$`, '--format', '{{.Names}}'],
            { timeout: 10000, allowStopping: true },
          ));
        } catch {
          /* Docker may no longer be available. */
        }
        if (!removed)
          console.error(
            `Не удалось подтвердить удаление временной БД. Проверьте: docker rm --force --volumes ${container}`,
          );
      }
    }
    process.removeListener('SIGINT', stop);
    process.removeListener('SIGTERM', stop);
  }

  const output = resolve(root, `output/play-${config.mode}`);
  const webRoot = resolve(output, 'web');
  const manifestPath = resolve(output, 'play-build.json');
  const manifest = {
    version: 1,
    mode: config.mode,
    buildMode: config.mode === 'lan' ? 'profile' : 'release',
    serverOrigin: 'same-origin',
    browserRooms: true,
    resourcesCdn: false,
    pwa: false,
  };
  async function artifacts() {
    return webBuildArtifacts(webRoot);
  }
  try {
    if (config.skipBuild) {
      let previous;
      try {
        previous = JSON.parse(await readFile(manifestPath, 'utf8'));
      } catch {
        /* Invalid build below. */
      }
      if (Object.entries(manifest).some(([key, value]) => previous?.[key] !== value))
        throw new Error(
          `--skip-build: нет подтверждённой ${manifest.buildMode}-сборки режима ${config.mode}. Запустите без --skip-build.`,
        );
      for (const file of ['index.html', 'flutter_bootstrap.js', 'main.dart.js']) {
        try {
          await access(resolve(webRoot, file));
        } catch {
          throw new Error('--skip-build: сборка неполна. Запустите без --skip-build.');
        }
      }
      if (JSON.stringify(previous.artifacts) !== JSON.stringify(await artifacts()))
        throw new Error(
          '--skip-build: файлы не совпадают с подтверждённой сборкой. Пересоберите без --skip-build.',
        );
    } else {
      console.log(`Собираем сервер и Flutter web (${manifest.buildMode})…`);
      await run('npm', ['run', 'build', '--workspace', '@partybox/backend'], {
        timeout: 180000,
        visible: true,
      });
      await run(
        flutter,
        [
          'build',
          'web',
          `--${manifest.buildMode}`,
          '--no-web-resources-cdn',
          '--pwa-strategy=none',
          '--dart-define=ROOM_SERVER_URL=same-origin',
          '--dart-define=BROWSER_ROOMS=true',
          '-o',
          webRoot,
        ],
        {
          timeout: 900000,
          visible: true,
          cwd: resolve(root, 'apps/mobile'),
          env: { ...process.env, CI: 'true' },
        },
      );
      await mkdir(output, { recursive: true });
      await writeFile(manifestPath, JSON.stringify({ ...manifest, artifacts: await artifacts() }));
    }
    if (stopping) return;
    await run(docker, ['info', '--format', '{{.ServerVersion}}'], { timeout: 15000 });
    console.log('Поднимаем отдельную временную БД…');
    const password = randomBytes(32).toString('hex');
    databaseStarted = true;
    await run(
      docker,
      [
        'run',
        '--detach',
        '--rm',
        '--name',
        container,
        '--publish',
        '127.0.0.1::5432',
        '--env',
        'POSTGRES_PASSWORD',
        '--env',
        'POSTGRES_USER=partybox',
        '--env',
        'POSTGRES_DB=partybox_play',
        'postgres:16.15-bookworm',
      ],
      { timeout: 180000, env: { ...process.env, POSTGRES_PASSWORD: password } },
    );
    const port = (await run(docker, ['port', container, '5432/tcp'])).match(
      /^127\.0\.0\.1:(\d+)$/,
    )?.[1];
    if (!port) throw new Error('Docker не сообщил локальный порт временной БД.');
    const end = Date.now() + 45000;
    while (true) {
      try {
        await run(
          docker,
          ['exec', container, 'pg_isready', '-U', 'partybox', '-d', 'partybox_play'],
          { timeout: 5000 },
        );
        break;
      } catch {
        if (stopping || Date.now() >= end)
          throw new Error('Временная PostgreSQL не стала доступна за 45 секунд.');
      }
      await new Promise((done) => setTimeout(done, 300));
    }
    await new Promise((done, fail) => {
      server = fork(fileURLToPath(new URL('./play-server.mjs', import.meta.url)), [], {
        cwd: root,
        stdio: ['ignore', 'ignore', 'ignore', 'ipc'],
        env: {
          ...process.env,
          PLAY_DATABASE_URL: `postgresql://partybox:${password}@127.0.0.1:${port}/partybox_play`,
          PLAY_TOKEN_SECRET: randomBytes(32).toString('hex'),
          PLAY_WEB_ROOT: webRoot,
          PLAY_TRUST_CLOUDFLARE: config.mode === 'internet' ? 'true' : 'false',
          PLAY_HOST: config.host,
          PLAY_PORT: String(config.port),
        },
      });
      const timer = setTimeout(() => fail(new Error('Сервер не стал готов за 45 секунд.')), 45000);
      const abort = () => {
        clearTimeout(timer);
        fail(new Error('Остановка.'));
      };
      controller.signal.addEventListener('abort', abort, { once: true });
      server.once('error', () => {
        clearTimeout(timer);
        fail(new Error('Не удалось запустить сервер.'));
      });
      server.once('exit', () => {
        clearTimeout(timer);
        fail(new Error('Сервер завершился до готовности. Проверьте свободный --port.'));
      });
      server.on('message', (message) => {
        if (message?.ready) {
          clearTimeout(timer);
          controller.signal.removeEventListener('abort', abort);
          done();
        } else if (message?.error) {
          clearTimeout(timer);
          fail(new Error('Не удалось запустить сервер. Проверьте сборку и свободный --port.'));
        }
      });
    });
    const originHost = ['0.0.0.0', '::'].includes(config.host) ? '127.0.0.1' : config.host;
    const origin = `http://${originHost.includes(':') ? `[${originHost}]` : originHost}:${config.port}`;
    console.log(`Локальная страница готова: ${origin}`);
    if (config.mode === 'internet') {
      const publicUrl = await new Promise((done, fail) => {
        tunnel = spawn(cloudflared, ['tunnel', '--url', origin, '--no-autoupdate'], {
          stdio: ['ignore', 'pipe', 'pipe'],
        });
        let buffer = '';
        let publicAddress;
        const timer = setTimeout(
          () =>
            fail(new Error('Cloudflare не выдал адрес за 60 секунд. Проверьте доступ в интернет.')),
          60000,
        );
        const read = (chunk) => {
          buffer = (buffer + chunk.toString()).slice(-16000);
          const url = buffer.match(/https:\/\/[a-z0-9-]+\.trycloudflare\.com(?=[\s/]|$)/)?.[0];
          if (url) publicAddress = url;
          if (publicAddress && /Registered tunnel connection/i.test(buffer)) {
            clearTimeout(timer);
            done(publicAddress);
          }
        };
        tunnel.stdout.on('data', read);
        tunnel.stderr.on('data', read);
        tunnel.once('error', () => {
          clearTimeout(timer);
          fail(new Error('Не удалось запустить cloudflared.'));
        });
        tunnel.once('exit', () => {
          clearTimeout(timer);
          fail(new Error('Туннель Cloudflare завершился до выдачи адреса.'));
        });
        controller.signal.addEventListener(
          'abort',
          () => {
            clearTimeout(timer);
            fail(new Error('Остановка.'));
          },
          { once: true },
        );
      });
      console.log(`Ссылка для друзей: ${publicUrl}`);
    } else {
      const advertised =
        config.advertiseHost ??
        (config.host !== '0.0.0.0' && config.host !== '127.0.0.1' ? config.host : lanAddress());
      if (advertised)
        console.log(
          `Телефоны в той же Wi-Fi сети: http://${advertised.includes(':') ? `[${advertised}]` : advertised}:${config.port}`,
        );
      else
        console.log(
          'Адрес Wi-Fi не определён. Перезапустите с --advertise-host IP компьютера в вашей сети.',
        );
    }
    console.log('Создайте комнату, назовите друзьям код. Для остановки нажмите Ctrl+C.');
    await new Promise((done, fail) => {
      if (controller.signal.aborted) return done();
      if (
        server.exitCode !== null ||
        server.signalCode !== null ||
        (tunnel && (tunnel.exitCode !== null || tunnel.signalCode !== null))
      )
        return fail(new Error('Сервер или туннель уже остановился.'));
      controller.signal.addEventListener('abort', done, { once: true });
      server.once('exit', () => fail(new Error('Сервер неожиданно остановился.')));
      tunnel?.once('exit', () => fail(new Error('Публичный туннель остановился.')));
    });
  } finally {
    await cleanup();
  }
}

main().catch((error) => {
  if (error.message !== 'Остановка.') {
    console.error(error.message);
    process.exitCode = 1;
  }
});
