import { isIP } from 'node:net';

/** Enable only for a backend reachable exclusively through one trusted reverse proxy. */
export function clientAddress(
  remote: string | undefined,
  forwarded: unknown,
  trustOneProxy: boolean,
) {
  let address = remote ?? 'unknown';
  if (trustOneProxy && typeof forwarded === 'string') {
    const last = forwarded.split(',').at(-1)?.trim();
    if (last && isIP(last)) address = last;
  }
  return address.startsWith('::ffff:') && isIP(address.slice(7)) === 4 ? address.slice(7) : address;
}
