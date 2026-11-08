import { request as httpsRequest } from 'node:https';
import { randomUUID, randomBytes } from 'node:crypto';
import { io } from 'socket.io-client';
const pause = () => new Promise((resolve) => setTimeout(resolve, 200));
export function request(origin, ca, path, body, token, extraHeaders = {}) {
  return new Promise((resolve, reject) => {
    const req = httpsRequest(
      new URL(path, origin),
      {
        ca,
        method: body ? 'POST' : 'GET',
        headers: {
          'Content-Type': 'application/json',
          ...(token ? { Authorization: `Bearer ${token}` } : {}),
          ...extraHeaders,
        },
        timeout: 5000,
      },
      (res) => {
        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () => {
          try {
            resolve({
              status: res.statusCode,
              value: JSON.parse(Buffer.concat(chunks).toString('utf8')),
            });
          } catch {
            resolve({ status: res.statusCode, value: null });
          }
        });
      },
    );
    req.on('timeout', () => req.destroy(new Error('Request timed out')));
    req.on('error', reject);
    req.end(body ? JSON.stringify(body) : undefined);
  });
}
function ensure(condition, message) {
  if (!condition) throw new Error(message);
}
export async function waitReady(origin, ca, status = 200) {
  const until = Date.now() + 60000;
  while (Date.now() < until) {
    try {
      if ((await request(origin, ca, '/ready')).status === status) return;
    } catch {}
    await pause();
  }
  throw new Error(`Readiness did not reach ${status}`);
}
export async function checkDeployment(origin, ca, restart) {
  const enroll = () => ({
    protocolVersion: 2,
    requestId: randomUUID(),
    retryKey: randomBytes(32).toString('base64url'),
    name: 'Тестовый участник',
  });
  const hostResponse = await request(origin, ca, '/v2/rooms', enroll());
  ensure(hostResponse.status === 201, 'Create failed');
  const host = hostResponse.value;
  const id = host.snapshot.roomId;
  const members = [host];
  const sockets = [];
  const snapshot = async (member) => {
    const res = await request(origin, ca, `/v2/rooms/${id}`, null, member.guestToken);
    ensure(res.status === 200, 'Snapshot failed');
    return res.value;
  };
  const send = async (member, type, payload = {}) => {
    const state = await snapshot(member);
    const cmd = {
      protocolVersion: 2,
      commandId: randomUUID(),
      expectedVersion: state.version,
      sessionId: state.publicState.game?.sessionId ?? null,
      type,
      payload,
    };
    const response = await request(origin, ca, `/v2/rooms/${id}/commands`, cmd, member.guestToken);
    ensure(response.status === 201, `Command ${type} failed`);
    return cmd;
  };
  const connect = (member) =>
    new Promise((resolve, reject) => {
      const socket = io(origin, {
        ca,
        rejectUnauthorized: true,
        transports: ['websocket'],
        reconnection: false,
        auth: { protocolVersion: 2, roomId: id, guestToken: member.guestToken },
      });
      sockets.push(socket);
      const timer = setTimeout(() => reject(new Error('Socket timeout')), 8000);
      socket.once('room.snapshot', (value) => {
        clearTimeout(timer);
        if (value.selfId !== member.snapshot.selfId)
          reject(new Error('Personal snapshot mismatch'));
        else resolve();
      });
      socket.once('connect_error', () => {
        clearTimeout(timer);
        reject(new Error('Verified TLS socket connection failed'));
      });
    });
  try {
    for (let i = 0; i < 3; i++) {
      const response = await request(
        origin,
        ca,
        `/v2/rooms/join/${host.snapshot.publicState.pin}`,
        enroll(),
      );
      ensure(response.status === 201, 'Join failed');
      members.push(response.value);
    }
    await Promise.all(members.map(connect));
    await send(host, 'spy.start', { discussionMinutes: 3, packId: 'spy-ru-base' });
    const views = await Promise.all(members.map(snapshot));
    ensure(
      views.filter((v) => v.privateState?.role === 'spy').length === 1,
      'Spy allocation mismatch',
    );
    for (const member of [...members].reverse()) await send(member, 'spy.ready');
    const before = await snapshot(host);
    ensure(before.publicState.game.phase === 'discussion', 'Discussion did not start');
    for (const socket of sockets) socket.disconnect();
    await restart();
    const after = await snapshot(host);
    ensure(
      after.publicState.game.sessionId === before.publicState.game.sessionId &&
        after.publicState.game.deadline === before.publicState.game.deadline,
      'Persisted session was lost',
    );
    ensure((await request(origin, ca, '/health')).status === 200, 'Liveness failed');
    await Promise.all(members.map(connect));
    await send(host, 'spy.vote');
    const spy = views.find((v) => v.privateState?.role === 'spy').selfId;
    const cmd = await send(host, 'spy.accuse', { suspectId: spy });
    ensure(
      (await request(origin, ca, `/v2/rooms/${id}/commands`, cmd, host.guestToken)).status === 201,
      'Accepted command replay failed',
    );
    const result = await snapshot(host);
    ensure(
      result.publicState.game.result.winner === 'civilians' && result.privateState === null,
      'Result mismatch',
    );
    for (const member of members) await send(member, 'room.leave');
  } finally {
    for (const socket of sockets) socket.disconnect();
  }
}
