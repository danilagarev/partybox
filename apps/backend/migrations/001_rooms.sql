CREATE TABLE IF NOT EXISTS pb_rooms (
  id uuid PRIMARY KEY,
  pin char(6) NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  state jsonb NOT NULL
);
CREATE TABLE IF NOT EXISTS pb_enrollments (
  request_id uuid PRIMARY KEY,
  retry_hash text NOT NULL,
  fingerprint text NOT NULL,
  room_id uuid NOT NULL REFERENCES pb_rooms(id) ON DELETE CASCADE,
  player_id uuid NOT NULL
);
CREATE TABLE IF NOT EXISTS pb_room_commands (
  room_id uuid NOT NULL REFERENCES pb_rooms(id) ON DELETE CASCADE,
  player_id uuid NOT NULL,
  command_id uuid NOT NULL,
  fingerprint text NOT NULL,
  ack jsonb NOT NULL,
  PRIMARY KEY(room_id, player_id, command_id)
);
CREATE TABLE IF NOT EXISTS pb_rate_limits (
  bucket text PRIMARY KEY,
  attempts integer NOT NULL,
  reset_at timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS pb_rooms_expiry ON pb_rooms(expires_at);
