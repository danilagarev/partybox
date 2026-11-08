import pg from 'pg';
import { migrate } from './migrate.js';
if (!process.env.DATABASE_URL) throw new Error('DATABASE_URL is required');
const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
try {
  await migrate(pool);
} finally {
  await pool.end();
}
