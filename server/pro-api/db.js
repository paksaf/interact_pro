// Postgres pool for Interact Pro's pro-api server.
//
// Single-pool-for-life pattern — Express handlers use `query(sql, args)`
// directly, the pool handles connection acquisition. We don't expose
// transactions yet (no endpoint needs them today); when one does, add
// a `withTransaction(async (client) => { ... })` helper.

import pg from 'pg';

const { Pool } = pg;

const DATABASE_URL = process.env.DATABASE_URL;
if (!DATABASE_URL) {
  console.error('FATAL: DATABASE_URL env var required.');
  process.exit(1);
}

export const pool = new Pool({
  connectionString: DATABASE_URL,
  max: Number.parseInt(process.env.PG_POOL_MAX ?? '10', 10),
  idleTimeoutMillis: 30_000,
  // Silently log slow queries — useful for op review without changing
  // application code.
  statement_timeout: 10_000,
});

pool.on('error', (err) => {
  // A pool client died unexpectedly. The pool will recreate it; we
  // just log so we know it happened.
  console.error('pg pool client error:', err.message);
});

/**
 * Run a parameterised SQL query. Always use $1 / $2 placeholders — the
 * pg driver escapes them for you. NEVER concatenate user input into the
 * SQL string.
 */
export async function query(text, params = []) {
  const start = Date.now();
  try {
    const result = await pool.query(text, params);
    const elapsed = Date.now() - start;
    if (elapsed > 500) {
      console.warn(`slow query (${elapsed}ms): ${text.slice(0, 100)}`);
    }
    return result;
  } catch (err) {
    console.error(`query failed: ${text.slice(0, 100)} → ${err.message}`);
    throw err;
  }
}

/**
 * Convenience: returns a single row or null. Throws if multiple rows
 * came back (defensive — catches "I forgot a WHERE clause" bugs).
 */
export async function queryOne(text, params = []) {
  const { rows } = await query(text, params);
  if (rows.length > 1) {
    throw new Error(`queryOne expected ≤1 row, got ${rows.length}`);
  }
  return rows[0] ?? null;
}

/**
 * Smoke-test the connection on boot so we crash early if Postgres
 * isn't reachable, instead of failing the first user request.
 */
export async function ping() {
  await query('SELECT 1');
  console.log('postgres: connected');
}

/**
 * Shut the pool down on SIGTERM so systemd's stop is clean.
 */
export async function shutdown() {
  await pool.end();
}
