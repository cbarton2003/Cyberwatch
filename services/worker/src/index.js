'use strict';
require('dotenv').config();
const { Worker, MetricsTime } = require('bullmq');
const { Redis } = require('ioredis');
const logger = require('./logger');
const { enrichIoc } = require('./processors/enrichIoc');
const { processScan } = require('./processors/processScan');

const QUEUE_NAME = 'ioc-enrichment';
const CONCURRENCY = parseInt(process.env.WORKER_CONCURRENCY || '5');

const connection = new Redis({
  host: process.env.REDIS_HOST || 'localhost',
  port: parseInt(process.env.REDIS_PORT || '6379'),
  password: process.env.REDIS_PASSWORD || undefined,
  tls: process.env.REDIS_TLS === 'true' ? {} : undefined,
  maxRetriesPerRequest: null,
  retryStrategy: (times) => Math.min(times * 200, 5000),
  enableReadyCheck: false,
});

connection.on('connect', () => logger.info('Worker Redis connected'));
connection.on('error', (err) => logger.error({ err }, 'Worker Redis error'));

const worker = new Worker(
  QUEUE_NAME,
  async (job) => {
    logger.info({ jobId: job.id, name: job.name, iocId: job.data.iocId }, 'Processing job');

    switch (job.name) {
      case 'enrich-ioc':   return enrichIoc(job);
      case 'process-scan': return processScan(job);
      default: throw new Error(`Unknown job type: ${job.name}`);
    }
  },
  {
    connection,
    concurrency: CONCURRENCY,
    metrics: { maxDataPoints: MetricsTime.ONE_WEEK * 2 },
  }
);

worker.on('completed', (job, result) => {
  logger.info({ jobId: job.id, name: job.name, result }, 'Job completed');
});

worker.on('failed', (job, err) => {
  logger.error({ jobId: job?.id, name: job?.name, err: err.message, attempts: job?.attemptsMade }, 'Job failed');
});

worker.on('stalled', (jobId) => logger.warn({ jobId }, 'Job stalled'));
worker.on('error', (err) => logger.error({ err }, 'Worker error'));

const shutdown = async (signal) => {
  logger.info({ signal }, 'Shutting down enrichment worker...');
  await worker.close();
  await connection.quit();
  process.exit(0);
};

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));
process.on('uncaughtException', (err) => { logger.error({ err }, 'Uncaught exception'); process.exit(1); });

logger.info({ queue: QUEUE_NAME, concurrency: CONCURRENCY }, 'CyberWatch enrichment worker started');
