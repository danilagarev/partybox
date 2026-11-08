import { readFile } from 'node:fs/promises';
import pg from 'pg';

export async function migrate(pool: pg.Pool) {
  // The numbered SQL file is idempotent. A transaction protects partial application.
  const sql = await readFile(new URL('../../../migrations/001_rooms.sql', import.meta.url), 'utf8');
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SELECT pg_advisory_xact_lock(hashtext('partybox-migrations'))");
    await client.query(sql);
    await client.query('COMMIT');
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}
