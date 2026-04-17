'use strict';
const request = require('supertest');
const { Pool } = require('pg');
const { createApp } = require('../../src/app');

jest.mock('../../src/queue', () => ({
  enqueueEnrichment: jest.fn().mockResolvedValue({ id: 'mock-job-001' }),
  enqueueScan:       jest.fn().mockResolvedValue({ id: 'mock-job-002' }),
  getRedisClient:    jest.fn().mockReturnValue({ ping: jest.fn().mockResolvedValue('PONG') }),
}));

const API_KEY = 'test-key-ci';
let app, pool;

beforeAll(async () => {
  process.env.DB_HOST     = process.env.DB_HOST     || 'localhost';
  process.env.DB_PORT     = process.env.DB_PORT     || '5432';
  process.env.DB_NAME     = process.env.DB_NAME     || 'cyberwatch_test';
  process.env.DB_USER     = process.env.DB_USER     || 'cyberwatch';
  process.env.DB_PASSWORD = process.env.DB_PASSWORD || 'testpass';
  process.env.API_KEYS    = API_KEY;
  pool = new Pool({ host: process.env.DB_HOST, port: process.env.DB_PORT, database: process.env.DB_NAME, user: process.env.DB_USER, password: process.env.DB_PASSWORD });
  app = createApp();
});

afterAll(async () => {
  await pool.end();
  const { pool: dbPool } = require('../../src/db');
  await dbPool.end();
});

beforeEach(async () => {
  await pool.query('TRUNCATE TABLE alerts, iocs, events, scans RESTART IDENTITY CASCADE');
});

const auth = () => ({ 'X-API-Key': API_KEY });

describe('GET /health', () => {
  it('returns 200', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body.services.postgres).toBe('ok');
  });
});

describe('Auth middleware', () => {
  it('returns 401 with no key', async () => {
    expect((await request(app).get('/iocs')).status).toBe(401);
  });
  it('returns 401 with wrong key', async () => {
    expect((await request(app).get('/iocs').set('X-API-Key', 'bad')).status).toBe(401);
  });
  it('allows valid key', async () => {
    expect((await request(app).get('/iocs').set(auth())).status).toBe(200);
  });
});

describe('POST /iocs', () => {
  it('creates an IP IOC', async () => {
    const res = await request(app).post('/iocs').set(auth())
      .send({ value: '198.51.100.42', type: 'ip', source: 'honeypot' });
    expect(res.status).toBe(201);
    expect(res.body.data).toMatchObject({ value: '198.51.100.42', type: 'ip', enrichment_status: 'pending' });
  });
  it('upserts duplicate value', async () => {
    await request(app).post('/iocs').set(auth()).send({ value: '1.2.3.4', type: 'ip', source: 'a' });
    await request(app).post('/iocs').set(auth()).send({ value: '1.2.3.4', type: 'ip', source: 'b' });
    const count = await pool.query("SELECT COUNT(*) FROM iocs WHERE value='1.2.3.4'");
    expect(parseInt(count.rows[0].count)).toBe(1);
  });
  it('rejects missing value', async () => {
    expect((await request(app).post('/iocs').set(auth()).send({ type: 'ip', source: 'x' })).status).toBe(400);
  });
  it('rejects invalid type', async () => {
    expect((await request(app).post('/iocs').set(auth()).send({ value: '1.1.1.1', type: 'invalid', source: 'x' })).status).toBe(400);
  });
});

describe('GET /iocs', () => {
  beforeEach(async () => {
    await pool.query(`
      INSERT INTO iocs (id,value,type,severity,threat_score,disposition,source,enrichment_status) VALUES
      (gen_random_uuid(),'10.0.0.1','ip','low',1.5,'benign','internal','enriched'),
      (gen_random_uuid(),'evil.xyz','domain','high',8.2,'malicious','feed','enriched'),
      (gen_random_uuid(),'198.51.100.99','ip','medium',4.5,'suspicious','honeypot','enriched')
    `);
  });
  it('returns all IOCs sorted by score desc', async () => {
    const res = await request(app).get('/iocs').set(auth());
    expect(res.body.data).toHaveLength(3);
    expect(res.body.data[0].threat_score).toBeGreaterThanOrEqual(res.body.data[1].threat_score);
  });
  it('filters by disposition=malicious', async () => {
    const res = await request(app).get('/iocs?disposition=malicious').set(auth());
    expect(res.body.data).toHaveLength(1);
    expect(res.body.data[0].value).toBe('evil.xyz');
  });
  it('filters by min_score', async () => {
    const res = await request(app).get('/iocs?min_score=5').set(auth());
    expect(res.body.data.every(i => i.threat_score >= 5)).toBe(true);
  });
});

describe('GET /iocs/lookup', () => {
  it('returns IOC by value', async () => {
    await pool.query(`INSERT INTO iocs (id,value,type,source,enrichment_status) VALUES (gen_random_uuid(),'5.5.5.5','ip','test','pending')`);
    const res = await request(app).get('/iocs/lookup?value=5.5.5.5').set(auth());
    expect(res.status).toBe(200);
    expect(res.body.data.value).toBe('5.5.5.5');
  });
  it('returns 404 for unknown value', async () => {
    expect((await request(app).get('/iocs/lookup?value=9.9.9.9').set(auth())).status).toBe(404);
  });
});

describe('POST /events', () => {
  it('ingests a security event', async () => {
    const res = await request(app).post('/events').set(auth())
      .send({ title: 'SSH brute force', severity: 'high', category: 'brute_force', source_ip: '198.51.100.42' });
    expect(res.status).toBe(201);
    expect(res.body.data).toMatchObject({ severity: 'high', category: 'brute_force', status: 'new' });
  });
  it('rejects invalid severity', async () => {
    expect((await request(app).post('/events').set(auth()).send({ title: 'x', severity: 'extreme', category: 'other' })).status).toBe(400);
  });
});

describe('POST /iocs/bulk', () => {
  it('accepts a batch', async () => {
    const res = await request(app).post('/iocs/bulk').set(auth())
      .send({ iocs: [{ value: '1.1.1.1', type: 'ip' }, { value: 'bad.xyz', type: 'domain' }], source: 'feed' });
    expect(res.status).toBe(202);
    expect(res.body.data.submitted).toBe(2);
  });
  it('rejects empty batch', async () => {
    expect((await request(app).post('/iocs/bulk').set(auth()).send({ iocs: [], source: 'x' })).status).toBe(400);
  });
});

describe('Alert acknowledgement', () => {
  it('acknowledges an alert', async () => {
    await pool.query(`INSERT INTO iocs (id,value,type,source,enrichment_status) VALUES ('aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa','7.7.7.7','ip','test','enriched')`);
    await pool.query(`INSERT INTO alerts (id,title,ioc_id,ioc_value,ioc_type,threat_score,severity) VALUES (gen_random_uuid(),'Test alert','aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa','7.7.7.7','ip',8.5,'high')`);
    const list = await request(app).get('/alerts').set(auth());
    const id = list.body.data[0].id;
    const res = await request(app).post('/alerts/' + id + '/acknowledge').set(auth())
      .send({ analyst: 'analyst@sec.io', notes: 'Confirmed' });
    expect(res.status).toBe(200);
    expect(res.body.data.acknowledged).toBe(true);
  });
});
