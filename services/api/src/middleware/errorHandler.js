'use strict';
const logger = require('../logger');

function notFoundHandler(req, res) {
  res.status(404).json({ error: `${req.method} ${req.url} not found` });
}

function errorHandler(err, req, res, next) {
  if (err.code === '23505') return res.status(409).json({ error: 'Duplicate record', detail: err.detail });
  if (err.code === '23503') return res.status(400).json({ error: 'Constraint violation', detail: err.detail });

  const status = err.statusCode || err.status || 500;
  logger.error({ err, path: req.url, method: req.method }, 'Request error');

  res.status(status).json({
    error: status >= 500 ? 'Internal server error' : err.message,
    ...(process.env.NODE_ENV !== 'production' && { stack: err.stack }),
  });
}

module.exports = { errorHandler, notFoundHandler };
