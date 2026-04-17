'use strict';
const express = require('express');
const { pool } = require('../db');
const { getRedisClient } = require('../queue');
const router = express.Router();

router.get('/', async (req, res) => {
  const checks = { status: 'ok', service: 'cyberwatch-api', timestamp: new Date().toISOString(), services: {} };

  try { await pool.query('SELECT 1'); checks.services.postgres = 'ok'; }
  catch { checks.services.postgres = 'error'; checks.status = 'degraded'; }

  try { await getRedisClient().ping(); checks.services.redis = 'ok'; }
  catch { checks.services.redis = 'error'; checks.status = 'degraded'; }

  res.status(checks.status === 'ok' ? 200 : 503).json(checks);
});

module.exports = router;
