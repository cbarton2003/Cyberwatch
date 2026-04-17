'use strict';
// ── routes/scans.js ───────────────────────────────────────────────────────────
// Bulk scan jobs: submit a list of IOC values for batch enrichment + reporting.
const express = require('express');
const { body, param, validationResult } = require('express-validator');
const { v4: uuidv4 } = require('uuid');
const { query: dbQuery } = require('../db');
const { enqueueScan } = require('../queue');
const logger = require('../logger');
const router = express.Router();

const validate = (req, res, next) => {
  const errors = validationResult(req);
  if (!errors.isEmpty()) return res.status(400).json({ errors: errors.array() });
  next();
};

// POST /scans — kick off a batch enrichment scan
router.post('/', [
  body('name').trim().notEmpty().isLength({ max: 255 }),
  body('values').isArray({ min: 1, max: 10000 }).withMessage('values: 1–10,000 items'),
  body('values.*').trim().notEmpty(),
], validate, async (req, res, next) => {
  try {
    const { name, values } = req.body;
    const id = uuidv4();

    await dbQuery(
      `INSERT INTO scans (id, name, total_iocs, status)
       VALUES ($1, $2, $3, 'queued')`,
      [id, name, values.length]
    );

    const job = await enqueueScan({ scanId: id, name, values });
    logger.info({ scanId: id, total: values.length, jobId: job.id }, 'Scan submitted');
    res.status(202).json({ data: { id, name, total: values.length, status: 'queued' } });
  } catch (err) { next(err); }
});

// GET /scans/:id
router.get('/:id', param('id').isUUID(4), validate, async (req, res, next) => {
  try {
    const result = await dbQuery('SELECT * FROM scans WHERE id = $1', [req.params.id]);
    if (result.rows.length === 0) return res.status(404).json({ error: 'Scan not found' });
    res.json({ data: result.rows[0] });
  } catch (err) { next(err); }
});

module.exports = router;
