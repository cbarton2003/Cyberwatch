'use strict';
// ── logger.js ─────────────────────────────────────────────────────────────────
const pino = require('pino');

module.exports = pino({
  level: process.env.LOG_LEVEL || 'info',
  ...(process.env.NODE_ENV !== 'production' && {
    transport: { target: 'pino-pretty', options: { colorize: true } },
  }),
  base: {
    service: process.env.SERVICE_NAME || 'cyberwatch-api',
    env: process.env.NODE_ENV || 'development',
  },
});
