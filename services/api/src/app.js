'use strict';

require('dotenv').config();
const express = require('express');
const helmet = require('helmet');
const cors = require('cors');
const rateLimit = require('express-rate-limit');
const pinoHttp = require('pino-http');
const logger = require('./logger');
const { connectDB } = require('./db');
const { apiKeyAuth } = require('./middleware/apiKey');
const eventsRoutes = require('./routes/events');
const iocsRoutes = require('./routes/iocs');
const alertsRoutes = require('./routes/alerts');
const scansRoutes = require('./routes/scans');
const healthRoutes = require('./routes/health');
const { errorHandler, notFoundHandler } = require('./middleware/errorHandler');

function createApp() {
  const app = express();

  // ── Security headers ────────────────────────────────────────────────────────
  app.use(helmet({
    contentSecurityPolicy: true,
    hsts: { maxAge: 31536000, includeSubDomains: true },
  }));

  app.use(cors({
    origin: process.env.ALLOWED_ORIGINS?.split(',') || [],
    methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'],
  }));

  // ── Rate limiting — tighter limits for a security API ───────────────────────
  app.use(rateLimit({
    windowMs: 60 * 1000,
    max: parseInt(process.env.RATE_LIMIT_MAX || '300'),
    standardHeaders: true,
    legacyHeaders: false,
    message: { error: 'Rate limit exceeded. Slow your roll.' },
  }));

  // ── Logging ─────────────────────────────────────────────────────────────────
  app.use(pinoHttp({
    logger,
    autoLogging: { ignore: (req) => req.url === '/health' },
    // Redact sensitive fields from logs
    redact: ['req.headers["x-api-key"]', 'req.body.password'],
  }));

  // ── Body parsing ─────────────────────────────────────────────────────────────
  app.use(express.json({ limit: '2mb' }));
  app.use(express.urlencoded({ extended: false }));

  // ── Public routes (no auth) ─────────────────────────────────────────────────
  app.use('/health', healthRoutes);

  // ── Authenticated routes ────────────────────────────────────────────────────
  app.use(apiKeyAuth);
  app.use('/events', eventsRoutes);
  app.use('/iocs', iocsRoutes);
  app.use('/alerts', alertsRoutes);
  app.use('/scans', scansRoutes);

  // ── Error handling ──────────────────────────────────────────────────────────
  app.use(notFoundHandler);
  app.use(errorHandler);

  return app;
}

async function start() {
  await connectDB();

  const app = createApp();
  const port = parseInt(process.env.PORT || '3000');

  const server = app.listen(port, '0.0.0.0', () => {
    logger.info({ port }, 'CyberWatch API started');
  });

  const shutdown = async (signal) => {
    logger.info({ signal }, 'Shutting down gracefully...');
    server.close(async () => {
      const { pool } = require('./db');
      await pool.end();
      logger.info('Clean shutdown complete');
      process.exit(0);
    });
    setTimeout(() => process.exit(1), 10_000);
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('uncaughtException', (err) => {
    logger.error({ err }, 'Uncaught exception');
    process.exit(1);
  });
  process.on('unhandledRejection', (reason) => {
    logger.error({ reason }, 'Unhandled rejection');
    process.exit(1);
  });
}

if (require.main === module) {
  start().catch((err) => { console.error('Startup failed:', err); process.exit(1); });
}

module.exports = { createApp };
