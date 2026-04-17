'use strict';
// ── middleware/apiKey.js ──────────────────────────────────────────────────────
// Simple static API key auth. In production you'd extend this to support
// per-key rate limits, key rotation, and audit logging.

const logger = require('../logger');

const VALID_KEYS = new Set(
  (process.env.API_KEYS || 'dev-key-local').split(',').map((k) => k.trim())
);

function apiKeyAuth(req, res, next) {
  const key = req.headers['x-api-key'];

  if (!key) {
    return res.status(401).json({ error: 'Missing X-API-Key header' });
  }

  if (!VALID_KEYS.has(key)) {
    // Log the attempt without exposing the submitted key
    logger.warn({ ip: req.ip, path: req.path }, 'Invalid API key attempt');
    return res.status(401).json({ error: 'Invalid API key' });
  }

  next();
}

module.exports = { apiKeyAuth };
