'use strict';
// ── db.js ─────────────────────────────────────────────────────────────────────
const { Pool } = require('pg');
const logger = require('./logger');

const pool = new Pool({
  host: process.env.DB_HOST,
  port: parseInt(process.env.DB_PORT || '5432'),
  database: process.env.DB_NAME,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  max: parseInt(process.env.DB_POOL_MAX || '10'),
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 5_000,
  ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: true } : false,
});

pool.on('error', (err) => logger.error({ err }, 'Idle DB client error'));

async function connectDB(retries = 5, delay = 2000) {
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      const client = await pool.connect();
      await client.query('SELECT 1');
      client.release();
      logger.info('Database connection established');
      return;
    } catch (err) {
      logger.warn({ attempt, err: err.message }, 'DB connection attempt failed');
      if (attempt === retries) throw err;
      await new Promise((r) => setTimeout(r, delay * attempt));
    }
  }
}

async function query(text, params) {
  const start = Date.now();
  const result = await pool.query(text, params);
  logger.debug({ query: text, duration: Date.now() - start, rows: result.rowCount }, 'Query');
  return result;
}

async function withTransaction(fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

module.exports = { pool, connectDB, query, withTransaction };
