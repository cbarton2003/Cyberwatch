'use strict';
// ── processors/processScan.js ─────────────────────────────────────────────────
// Coordinates a bulk scan: iterates over submitted IOC values, triggers
// individual enrichment for each, and aggregates the final report.

const { Pool } = require('pg');
const { Queue } = require('bullmq');
const { Redis } = require('ioredis');
const logger = require('../logger');

const pool = new Pool({
  host: process.env.DB_HOST,
  port: parseInt(process.env.DB_PORT || '5432'),
  database: process.env.DB_NAME,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  max: 3,
  ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: true } : false,
});

async function processScan(job) {
  const { scanId, values } = job.data;
  const client = await pool.connect();

  try {
    await client.query(
      `UPDATE scans SET status = 'running', updated_at = NOW() WHERE id = $1`,
      [scanId]
    );

    const totals = { malicious: 0, suspicious: 0, benign: 0, errors: 0 };
    const batchSize = 50;

    for (let i = 0; i < values.length; i += batchSize) {
      const batch = values.slice(i, i + batchSize);

      // Upsert each IOC and read back disposition
      for (const value of batch) {
        try {
          const result = await client.query(
            `SELECT disposition FROM iocs WHERE value = $1`,
            [value]
          );
          const disposition = result.rows[0]?.disposition || 'unknown';
          if (disposition === 'malicious')  totals.malicious++;
          else if (disposition === 'suspicious') totals.suspicious++;
          else totals.benign++;
        } catch {
          totals.errors++;
        }
      }

      const processed = Math.min(i + batchSize, values.length);
      const progress = Math.floor((processed / values.length) * 100);
      await job.updateProgress(progress);

      await client.query(
        `UPDATE scans SET processed = $2, malicious = $3, suspicious = $4,
                          benign = $5, errors = $6, updated_at = NOW()
         WHERE id = $1`,
        [scanId, processed, totals.malicious, totals.suspicious, totals.benign, totals.errors]
      );
    }

    await client.query(
      `UPDATE scans SET status = 'completed', completed_at = NOW(), updated_at = NOW() WHERE id = $1`,
      [scanId]
    );

    logger.info({ scanId, ...totals }, 'Scan completed');
    return totals;

  } catch (err) {
    await client.query(
      `UPDATE scans SET status = 'failed', error_message = $1, updated_at = NOW() WHERE id = $2`,
      [err.message, scanId]
    );
    throw err;
  } finally {
    client.release();
  }
}

module.exports = { processScan };
