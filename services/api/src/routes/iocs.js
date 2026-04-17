'use strict';
// ── routes/iocs.js ────────────────────────────────────────────────────────────
// Indicators of Compromise: IPs, domains, file hashes, URLs submitted for
// enrichment and threat scoring.

const express = require('express');
const { body, param, query, validationResult } = require('express-validator');
const { v4: uuidv4 } = require('uuid');
const { query: dbQuery, withTransaction } = require('../db');
const { enqueueEnrichment } = require('../queue');
const logger = require('../logger');

const router = express.Router();

const IOC_TYPES = ['ip', 'domain', 'hash_md5', 'hash_sha1', 'hash_sha256', 'url', 'email'];
const SEVERITIES = ['low', 'medium', 'high', 'critical'];
const DISPOSITIONS = ['unknown', 'benign', 'suspicious', 'malicious'];

const validate = (req, res, next) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) return res.status(400).json({ errors: errors.array() });
  next();
};

// ── GET /iocs ─────────────────────────────────────────────────────────────────

router.get('/', [
  query('type').optional().isIn(IOC_TYPES),
  query('disposition').optional().isIn(DISPOSITIONS),
  query('min_score').optional().isFloat({ min: 0, max: 10 }).toFloat(),
  query('severity').optional().isIn(SEVERITIES),
  query('source').optional().trim().isLength({ max: 100 }),
  query('limit').optional().isInt({ min: 1, max: 500 }).toInt(),
  query('offset').optional().isInt({ min: 0 }).toInt(),
], validate, async (req, res, next) => {
  try {
    const { type, disposition, min_score, severity, source, limit = 50, offset = 0 } = req.query;
    const conditions = [];
    const params = [];

    if (type) { params.push(type); conditions.push(`type = $${params.length}`); }
    if (disposition) { params.push(disposition); conditions.push(`disposition = $${params.length}`); }
    if (min_score !== undefined) { params.push(min_score); conditions.push(`threat_score >= $${params.length}`); }
    if (severity) { params.push(severity); conditions.push(`severity = $${params.length}`); }
    if (source) { params.push(`%${source}%`); conditions.push(`source ILIKE $${params.length}`); }

    const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';
    params.push(limit, offset);

    const [result, countResult] = await Promise.all([
      dbQuery(
        `SELECT id, value, type, severity, threat_score, disposition, source, tags,
                enrichment_status, first_seen, last_seen, created_at
         FROM iocs ${where}
         ORDER BY threat_score DESC, created_at DESC
         LIMIT $${params.length - 1} OFFSET $${params.length}`,
        params
      ),
      dbQuery(`SELECT COUNT(*) FROM iocs ${where}`, params.slice(0, -2)),
    ]);

    res.json({
      data: result.rows,
      meta: { total: parseInt(countResult.rows[0].count), limit, offset },
    });
  } catch (err) { next(err); }
});

// ── GET /iocs/lookup — search by exact IOC value ──────────────────────────────

router.get('/lookup', [
  query('value').trim().notEmpty(),
], validate, async (req, res, next) => {
  try {
    const result = await dbQuery(
      `SELECT i.*, 
              COALESCE(json_agg(e.* ORDER BY e.created_at DESC) FILTER (WHERE e.id IS NOT NULL), '[]') AS related_events
       FROM iocs i
       LEFT JOIN events e ON e.source_ip = i.value OR e.metadata->>'domain' = i.value
       WHERE i.value = $1
       GROUP BY i.id`,
      [req.query.value.trim()]
    );

    if (result.rows.length === 0) return res.status(404).json({ error: 'IOC not found' });
    res.json({ data: result.rows[0] });
  } catch (err) { next(err); }
});

// ── GET /iocs/:id ─────────────────────────────────────────────────────────────

router.get('/:id', param('id').isUUID(4), validate, async (req, res, next) => {
  try {
    const result = await dbQuery(
      `SELECT id, value, type, severity, threat_score, disposition, source, tags,
              enrichment_status, enrichment_data, error_message,
              first_seen, last_seen, created_at, updated_at
       FROM iocs WHERE id = $1`,
      [req.params.id]
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'IOC not found' });
    res.json({ data: result.rows[0] });
  } catch (err) { next(err); }
});

// ── POST /iocs ────────────────────────────────────────────────────────────────

router.post('/', [
  body('value').trim().notEmpty().isLength({ max: 2048 }).withMessage('value is required, max 2048 chars'),
  body('type').isIn(IOC_TYPES).withMessage(`type must be one of: ${IOC_TYPES.join(', ')}`),
  body('source').trim().notEmpty().isLength({ max: 255 }).withMessage('source is required'),
  body('severity').optional().isIn(SEVERITIES),
  body('tags').optional().isArray().custom((arr) => arr.every((t) => typeof t === 'string')),
  body('metadata').optional().isObject(),
  body('first_seen').optional().isISO8601(),
], validate, async (req, res, next) => {
  try {
    const {
      value, type, source,
      severity = 'medium',
      tags = [],
      metadata = {},
      first_seen = new Date().toISOString(),
    } = req.body;

    const id = uuidv4();

    const ioc = await withTransaction(async (client) => {
      // Upsert: if this exact IOC value already exists, update last_seen
      const result = await client.query(
        `INSERT INTO iocs (id, value, type, severity, source, tags, metadata, first_seen, enrichment_status)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'pending')
         ON CONFLICT (value) DO UPDATE SET
           last_seen = NOW(),
           severity  = EXCLUDED.severity,
           source    = EXCLUDED.source,
           tags      = iocs.tags || EXCLUDED.tags,
           updated_at = NOW()
         RETURNING *`,
        [id, value, type, severity, source, JSON.stringify(tags), JSON.stringify(metadata), first_seen]
      );
      return result.rows[0];
    });

    const job = await enqueueEnrichment({ iocId: ioc.id, value: ioc.value, type: ioc.type, severity });
    logger.info({ iocId: ioc.id, type, value: value.substring(0, 20), jobId: job.id }, 'IOC submitted for enrichment');

    res.status(201).json({ data: ioc });
  } catch (err) { next(err); }
});

// ── POST /iocs/bulk ───────────────────────────────────────────────────────────

router.post('/bulk', [
  body('iocs').isArray({ min: 1, max: 500 }).withMessage('iocs must be an array of 1–500 items'),
  body('iocs.*.value').trim().notEmpty(),
  body('iocs.*.type').isIn(IOC_TYPES),
  body('source').trim().notEmpty(),
], validate, async (req, res, next) => {
  try {
    const { iocs, source } = req.body;
    const results = { submitted: 0, errors: [] };

    for (const ioc of iocs) {
      try {
        const id = uuidv4();
        await dbQuery(
          `INSERT INTO iocs (id, value, type, source, enrichment_status)
           VALUES ($1, $2, $3, $4, 'pending')
           ON CONFLICT (value) DO UPDATE SET last_seen = NOW(), updated_at = NOW()
           RETURNING id`,
          [id, ioc.value, ioc.type, source]
        );
        await enqueueEnrichment({ iocId: id, value: ioc.value, type: ioc.type, severity: ioc.severity || 'medium' });
        results.submitted++;
      } catch (e) {
        results.errors.push({ value: ioc.value, error: e.message });
      }
    }

    logger.info({ submitted: results.submitted, errors: results.errors.length, source }, 'Bulk IOC submission');
    res.status(202).json({ data: results });
  } catch (err) { next(err); }
});

// ── PATCH /iocs/:id — analyst override ───────────────────────────────────────

router.patch('/:id', [
  param('id').isUUID(4),
  body('disposition').optional().isIn(DISPOSITIONS),
  body('severity').optional().isIn(SEVERITIES),
  body('tags').optional().isArray(),
], validate, async (req, res, next) => {
  try {
    const { disposition, severity, tags } = req.body;
    const fields = [];
    const params = [req.params.id];

    if (disposition !== undefined) { params.push(disposition); fields.push(`disposition = $${params.length}`); }
    if (severity !== undefined) { params.push(severity); fields.push(`severity = $${params.length}`); }
    if (tags !== undefined) { params.push(JSON.stringify(tags)); fields.push(`tags = $${params.length}`); }

    if (fields.length === 0) return res.status(400).json({ error: 'No fields to update' });
    fields.push(`updated_at = NOW()`);

    const result = await dbQuery(
      `UPDATE iocs SET ${fields.join(', ')} WHERE id = $1 RETURNING *`,
      params
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'IOC not found' });
    res.json({ data: result.rows[0] });
  } catch (err) { next(err); }
});

module.exports = router;
