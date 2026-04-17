'use strict';
// ── queue.js ──────────────────────────────────────────────────────────────────
const { Queue } = require('bullmq');
const { Redis } = require('ioredis');
const logger = require('./logger');

const QUEUE_NAME = 'ioc-enrichment';

let redisClient;
let enrichmentQueue;

function getRedisClient() {
  if (!redisClient) {
    redisClient = new Redis({
      host: process.env.REDIS_HOST || 'localhost',
      port: parseInt(process.env.REDIS_PORT || '6379'),
      password: process.env.REDIS_PASSWORD || undefined,
      tls: process.env.REDIS_TLS === 'true' ? {} : undefined,
      maxRetriesPerRequest: null,
      retryStrategy: (times) => Math.min(times * 200, 3000),
    });
    redisClient.on('error', (err) => logger.error({ err }, 'Redis error'));
    redisClient.on('connect', () => logger.info('Redis connected'));
  }
  return redisClient;
}

function getQueue() {
  if (!enrichmentQueue) {
    enrichmentQueue = new Queue(QUEUE_NAME, {
      connection: getRedisClient(),
      defaultJobOptions: {
        removeOnComplete: { count: 1000, age: 24 * 60 * 60 },
        removeOnFail: { count: 5000, age: 7 * 24 * 60 * 60 },
        attempts: 3,
        backoff: { type: 'exponential', delay: 2000 },
      },
    });
  }
  return enrichmentQueue;
}

// Priority: critical=1, high=2, medium=5, low=10
const SEVERITY_PRIORITY = { critical: 1, high: 2, medium: 5, low: 10 };

async function enqueueEnrichment(payload) {
  return getQueue().add('enrich-ioc', payload, {
    priority: SEVERITY_PRIORITY[payload.severity] || 5,
    jobId: `ioc:${payload.iocId}`,
  });
}

async function enqueueScan(payload) {
  return getQueue().add('process-scan', payload, {
    priority: 3,
    jobId: `scan:${payload.scanId}`,
  });
}

module.exports = { getRedisClient, getQueue, enqueueEnrichment, enqueueScan, QUEUE_NAME };
