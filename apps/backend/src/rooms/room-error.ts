import type { GameError as ProtocolError } from '@partybox/game-contracts/rooms-v2';
export class RoomError extends Error {
  constructor(
    readonly code: ProtocolError['code'],
    readonly status: number,
  ) {
    super(code);
  }
}
