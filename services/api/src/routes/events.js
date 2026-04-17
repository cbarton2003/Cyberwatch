'use strict';
// ── routes/events.js ──────────────────────────────────────────────────────────
// Security events: raw incidents from EDRs, firewalls, honeypots, SIEMs.

const express = require('express');
const { body, param, query, validationResult } = require('express-validator');
const { v4: uuidv4 } = require('uuid');
const { query: dbQuery } = require('../db');
const logger = require('../logger');

const router = express.Router();

const SEVERITIES = ['info', 'low', 'medium', 'high', 'critical'];
const CATEGORIES = [
  'brute_force', 'malware', 'phishing', 'data_exfiltration',
  'privilege_escalation', 'lateral_movement', 'c2_communication',
  'reconnaissance', 'dos', 'policy_violation', 'other',
];
const STATUSES = ['new', 'investigating', 'contained', 'resolved', 'false_positive'];

const validate = (req, res, next) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) return res.status(400).json({ errors: errors.array() });
  next();
};

// ── GET /events ───────────────────────────────────────────────────────────────

router.get('/', [
  query('severity').optional().isIn(SEVERITIES),
  query('category').optional().isIn(CATEGORIES),
  query('status').optional().isIn(STATUSES),
  query('source_ip').optional().isIP(),
  query('since').optional().isISO8601(),
  query('limit').optional().isInt({ min: 1, max: 1000 }).toInt(),
  query('offset').optional().isInt({ min: 0 }).toInt(),
], validate, async (req, res, next) => {
  try {
    const { severity, category, status, source_ip, since, limit = 50, offset = 0 } = req.query;
    const conditions = [];
    const params = [];

    if (severity)  { params.push(severity);  conditions.push(`severity = $${params.length}`); }
    if (category)  { params.push(category);  conditions.push(`category = $${params.length}`); }
    if (status)    { params.push(status);    conditions.push(`status = $${params.length}`); }
    if (source_ip) { params.push(source_ip); conditions.push(`source_ip = $${params.length}`); }
    if (since)     { params.push(since);     conditions.push(`occurred_at >= $${params.length}`); }

    const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';
    params.push(limit, offset);

    const [result, countResult] = await Promise.all([
      dbQuery(
        `SELECT id, title, severity, category, status, source_ip, hostname,
                occurred_at, created_at
         FROM events ${where}
         ORDER BY
           CASE severity
             WHEN 'critical' THEN 1 WHEN 'high' THEN 2 WHEN 'medium' THEN 3
             WHEN 'low' THEN 4 ELSE 5
           END,
           occurred_at DESC
         LIMIT $${params.length - 1} OFFSET $${params.length}`,
        params
      ),
      dbQuery(`SELECT COUNT(*) FROM events ${where}`, params.slice(0, -2)),
    ]);

    res.json({
      data: result.rows,
      meta: { total: parseInt(countResult.rows[0].count), limit, offset },
    });
  } catch (err) { next(err); }
});

// ── GET /events/:id ───────────────────────────────────────────────────────────

router.get('/:id', param('id').isUUID(4), validate, async (req, res, next) => {
  try {
    const result = await dbQuery(
      `SELECT e.*,
              COALESCE(
                json_agg(i.* ORDER BY i.threat_score DESC) FILTER (WHERE i.id IS NOT NULL),
                '[]'
              ) AS related_iocs
       FROM events e
       LEFT JOIN iocs i ON i.value = e.source_ip
                        OR i.value = e.metadata->>'domain'
                        OR i.value = e.metadata->>'file_hash'
       WHERE e.id = $1
       GROUP BY e.id`,
      [req.params.id]
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'Event not found' });
    res.json({ data: result.rows[0] });
  } catch (err) { next(err); }
});

// ── POST /events ──────────────────────────────────────────────────────────────

router.post('/', [
  body('title').trim().notEmpty().isLength({ max: 512 }),
  body('severity').isIn(SEVERITIES),
  body('category').isIn(CATEGORIES),
  body('source_ip').optional().isIP(),
  body('hostname').optional().trim().isLength({ max: 255 }),
  body('description').optional().trim().isLength({ max: 10000 }),
  body('occurred_at').optional().isISO8601(),
  body('metadata').optional().isObject(),
], validate, async (req, res, next) => {
  try {
    const {
      title, severity, category,
      source_ip = null, hostname = null,
      description = null, metadata = {},
      occurred_at = new Date().toISOString(),
    } = req.body;

    const result = await dbQuery(
      `INSERT INTO events
         (id, title, severity, category, source_ip, hostname, description, metadata, occurred_at, status)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'new')
       RETURNING *`,
      [uuidv4(), title, severity, category, source_ip, hostname, description, JSON.stringify(metadata), occurred_at]
    );

    const event = result.rows[0];
    logger.info({ eventId: event.id, severity, category }, 'Security event ingested');
    res.status(201).json({ data: event });
  } catch (err) { next(err); }
});

// ── PATCH /events/:id/status ──────────────────────────────────────────────────

router.patch('/:id/status', [
  param('id').isUUID(4),
  body('status').isIn(STATUSES),
  body('notes').optional().trim().isLength({ max: 5000 }),
], validate, async (req, res, next) => {
  try {
    const { status, notes } = req.body;
    const result = await dbQuery(
      `UPDATE events
       SET status = $2,
           metadata = metadata || jsonb_build_object('analyst_notes', $3::text),
           updated_at = NOW()
       WHERE id = $1 RETURNING *`,
      [req.params.id, status, notes || null]
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'Event not found' });
    res.json({ data: result.rows[0] });
  } catch (err) { next(err); }
});

module.exports = router;
