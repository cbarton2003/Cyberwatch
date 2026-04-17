'use strict';
// ── routes/alerts.js ──────────────────────────────────────────────────────────
const express = require('express');
const { param, query, body, validationResult } = require('express-validator');
const { query: dbQuery } = require('../db');
const router = express.Router();

const validate = (req, res, next) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) return res.status(400).json({ errors: errors.array() });
  next();
};

// GET /alerts
router.get('/', [
  query('acknowledged').optional().isBoolean().toBoolean(),
  query('min_score').optional().isFloat({ min: 0, max: 10 }).toFloat(),
  query('limit').optional().isInt({ min: 1, max: 200 }).toInt(),
  query('offset').optional().isInt({ min: 0 }).toInt(),
], validate, async (req, res, next) => {
  try {
    const { acknowledged, min_score, limit = 25, offset = 0 } = req.query;
    const conditions = [];
    const params = [];

    if (acknowledged !== undefined) { params.push(acknowledged); conditions.push(`acknowledged = $${params.length}`); }
    if (min_score !== undefined)    { params.push(min_score);    conditions.push(`threat_score >= $${params.length}`); }

    const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';
    params.push(limit, offset);

    const [result, countResult] = await Promise.all([
      dbQuery(
        `SELECT id, title, ioc_id, ioc_value, ioc_type, threat_score,
                severity, acknowledged, acknowledged_by, fired_at, created_at
         FROM alerts ${where}
         ORDER BY threat_score DESC, fired_at DESC
         LIMIT $${params.length - 1} OFFSET $${params.length}`,
        params
      ),
      dbQuery(`SELECT COUNT(*) FROM alerts ${where}`, params.slice(0, -2)),
    ]);

    res.json({ data: result.rows, meta: { total: parseInt(countResult.rows[0].count), limit, offset } });
  } catch (err) { next(err); }
});

// GET /alerts/:id
router.get('/:id', param('id').isUUID(4), validate, async (req, res, next) => {
  try {
    const result = await dbQuery('SELECT * FROM alerts WHERE id = $1', [req.params.id]);
    if (result.rows.length === 0) return res.status(404).json({ error: 'Alert not found' });
    res.json({ data: result.rows[0] });
  } catch (err) { next(err); }
});

// POST /alerts/:id/acknowledge
router.post('/:id/acknowledge', [
  param('id').isUUID(4),
  body('analyst').trim().notEmpty().isLength({ max: 255 }),
  body('notes').optional().trim().isLength({ max: 2000 }),
], validate, async (req, res, next) => {
  try {
    const { analyst, notes } = req.body;
    const result = await dbQuery(
      `UPDATE alerts
       SET acknowledged = true, acknowledged_by = $2,
           notes = $3, acknowledged_at = NOW(), updated_at = NOW()
       WHERE id = $1 RETURNING *`,
      [req.params.id, analyst, notes || null]
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'Alert not found' });
    res.json({ data: result.rows[0] });
  } catch (err) { next(err); }
});

module.exports = router;
