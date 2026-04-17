'use strict';
// ── processors/enrichIoc.js ───────────────────────────────────────────────────
// IOC Enrichment Pipeline
//
// Stages:
//   1. Classify & validate the IOC value
//   2. Run heuristic threat scoring rules
//   3. Correlate against existing events in the DB
//   4. Update the IOC record with score + disposition
//   5. Fire an alert if score exceeds threshold
//
// In production, stage 2 would call real threat intel APIs:
//   VirusTotal, AbuseIPDB, Shodan, URLScan, MalwareBazaar, etc.
// The scoring heuristics below simulate those responses deterministically
// so the system is fully functional without external API keys.

const { Pool } = require('pg');
const { v4: uuidv4 } = require('uuid');
const logger = require('../logger');

const pool = new Pool({
  host: process.env.DB_HOST,
  port: parseInt(process.env.DB_PORT || '5432'),
  database: process.env.DB_NAME,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  max: 5,
  ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: true } : false,
});

const ALERT_THRESHOLD = parseFloat(process.env.ALERT_SCORE_THRESHOLD || '7.0');

// ── Main processor ────────────────────────────────────────────────────────────

async function enrichIoc(job) {
  const { iocId, value, type, severity } = job.data;
  const client = await pool.connect();

  try {
    // Mark as processing
    await client.query(
      `UPDATE iocs SET enrichment_status = 'processing', updated_at = NOW() WHERE id = $1`,
      [iocId]
    );
    await job.updateProgress(10);

    // ── Stage 1: Classify ────────────────────────────────────────────────────
    logger.info({ iocId, type, step: 'classify' }, 'Classifying IOC');
    const classification = classify(value, type);
    await job.updateProgress(25);

    // ── Stage 2: Threat scoring ───────────────────────────────────────────────
    logger.info({ iocId, step: 'score' }, 'Running threat heuristics');
    const scoringResult = await scoreIoc(value, type, severity);
    await job.updateProgress(50);

    // ── Stage 3: Correlation ──────────────────────────────────────────────────
    logger.info({ iocId, step: 'correlate' }, 'Correlating against existing events');
    const correlation = await correlate(client, value, type);
    await job.updateProgress(70);

    // ── Stage 4: Determine disposition ───────────────────────────────────────
    const finalScore = Math.min(10, scoringResult.score + correlation.bonus);
    const disposition = calcDisposition(finalScore);

    const enrichmentData = {
      classification,
      scoring: scoringResult,
      correlation,
      finalScore,
      enrichedAt: new Date().toISOString(),
    };

    await client.query(
      `UPDATE iocs
       SET enrichment_status = 'enriched',
           threat_score      = $2,
           disposition       = $3,
           enrichment_data   = $4,
           severity          = $5,
           updated_at        = NOW()
       WHERE id = $1`,
      [iocId, finalScore, disposition, JSON.stringify(enrichmentData), scoringResult.derivedSeverity]
    );
    await job.updateProgress(85);

    // ── Stage 5: Alert if high threat ─────────────────────────────────────────
    if (finalScore >= ALERT_THRESHOLD) {
      await fireAlert(client, iocId, value, type, finalScore, scoringResult.derivedSeverity);
      logger.info({ iocId, finalScore, disposition }, 'Alert fired');
    }

    await job.updateProgress(100);
    logger.info({ iocId, finalScore, disposition }, 'IOC enrichment complete');
    return { iocId, finalScore, disposition };

  } catch (err) {
    await client.query(
      `UPDATE iocs SET enrichment_status = 'failed', error_message = $1, updated_at = NOW() WHERE id = $2`,
      [err.message, iocId]
    );
    logger.error({ iocId, err: err.message }, 'IOC enrichment failed');
    throw err;
  } finally {
    client.release();
  }
}

// ── Heuristic threat scoring ──────────────────────────────────────────────────
// Simulates the kind of signal aggregation a real threat intel platform does.

async function scoreIoc(value, type, submittedSeverity) {
  const signals = [];
  let score = 0;

  if (type === 'ip') {
    // Known bad /8 ranges used in documentation — treat as suspicious
    if (value.startsWith('198.51.100.') || value.startsWith('203.0.113.')) {
      signals.push({ signal: 'documentation_range', weight: 4.0 });
      score += 4.0;
    }
    // RFC 1918 private addresses are never threats
    if (/^(10\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.)/.test(value)) {
      signals.push({ signal: 'private_address', weight: -2.0 });
      score = Math.max(0, score - 2.0);
    }
    // Simulate a port scan signature in metadata
    if (value.endsWith('.1') || value.endsWith('.254')) {
      signals.push({ signal: 'gateway_address', weight: 0.5 });
      score += 0.5;
    }
  }

  if (type === 'domain') {
    // DGA-like domains (high entropy, numeric-heavy)
    const entropy = shannonEntropy(value.split('.')[0]);
    if (entropy > 3.5) {
      signals.push({ signal: 'high_entropy_domain', weight: 3.5 });
      score += 3.5;
    }
    // Recently registered TLDs commonly abused
    if (/\.(xyz|top|click|gq|ml|cf|tk)$/.test(value)) {
      signals.push({ signal: 'suspicious_tld', weight: 2.0 });
      score += 2.0;
    }
    // Typosquatting patterns
    if (/g[o0]{2}g[l1]e|paypa[l1]|micros[o0]ft|arnazon/.test(value)) {
      signals.push({ signal: 'typosquatting_pattern', weight: 5.0 });
      score += 5.0;
    }
  }

  if (type === 'hash_md5' || type === 'hash_sha256') {
    // Simulate VirusTotal hit — in production: call VT API, check positives/total
    const simulatedPositives = pseudoRandom(value) * 72; // 0–72 AV engines
    if (simulatedPositives > 50) {
      signals.push({ signal: 'av_detections_high', weight: 8.0, detail: `${Math.floor(simulatedPositives)}/72 engines` });
      score += 8.0;
    } else if (simulatedPositives > 10) {
      signals.push({ signal: 'av_detections_medium', weight: 4.0, detail: `${Math.floor(simulatedPositives)}/72 engines` });
      score += 4.0;
    }
  }

  if (type === 'url') {
    if (value.includes('login') || value.includes('signin') || value.includes('account')) {
      signals.push({ signal: 'credential_harvesting_url', weight: 3.0 });
      score += 3.0;
    }
    if (/\.(exe|dll|bat|ps1|vbs|jar)(\?|$)/.test(value)) {
      signals.push({ signal: 'executable_download_url', weight: 4.0 });
      score += 4.0;
    }
  }

  // Boost from submitted severity
  const severityBoost = { low: 0, medium: 0.5, high: 1.5, critical: 2.5 };
  const boost = severityBoost[submittedSeverity] || 0;
  if (boost > 0) signals.push({ signal: 'severity_boost', weight: boost });
  score = Math.min(10, score + boost);

  // Simulate enrichment latency
  await new Promise((r) => setTimeout(r, 150 + Math.floor(Math.random() * 300)));

  return {
    score: Math.round(score * 100) / 100,
    signals,
    derivedSeverity: scoreToDerivedSeverity(score),
  };
}

// ── Correlation ───────────────────────────────────────────────────────────────

async function correlate(client, value, type) {
  let bonus = 0;
  const matches = [];

  // Check if this IOC value appears in recent security events
  const eventResult = await client.query(
    `SELECT COUNT(*) AS cnt FROM events
     WHERE (source_ip::text = $1 OR metadata->>'domain' = $1 OR metadata->>'file_hash' = $1)
       AND occurred_at > NOW() - INTERVAL '30 days'`,
    [value]
  );
  const eventCount = parseInt(eventResult.rows[0].cnt);
  if (eventCount > 0) {
    bonus += Math.min(2.0, eventCount * 0.5);
    matches.push({ type: 'security_events', count: eventCount });
  }

  // Check if seen in previous alerts
  const alertResult = await client.query(
    `SELECT COUNT(*) AS cnt FROM alerts WHERE ioc_value = $1`,
    [value]
  );
  const alertCount = parseInt(alertResult.rows[0].cnt);
  if (alertCount > 0) {
    bonus += Math.min(1.5, alertCount * 0.5);
    matches.push({ type: 'previous_alerts', count: alertCount });
  }

  return { bonus: Math.round(bonus * 100) / 100, matches };
}

// ── Alert creation ────────────────────────────────────────────────────────────

async function fireAlert(client, iocId, value, type, score, severity) {
  const title = buildAlertTitle(value, type, score);
  await client.query(
    `INSERT INTO alerts (id, title, ioc_id, ioc_value, ioc_type, threat_score, severity)
     VALUES ($1, $2, $3, $4, $5, $6, $7)
     ON CONFLICT DO NOTHING`,
    [uuidv4(), title, iocId, value, type, score, severity]
  );
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function classify(value, type) {
  if (type === 'ip') {
    const parts = value.split('.').map(Number);
    return {
      isPrivate: parts[0] === 10 || (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) || (parts[0] === 192 && parts[1] === 168),
      isLoopback: parts[0] === 127,
      octets: parts,
    };
  }
  if (type === 'domain') {
    const parts = value.split('.');
    return { tld: parts[parts.length - 1], subdomain: parts.length > 2, labelCount: parts.length };
  }
  return {};
}

function calcDisposition(score) {
  if (score >= 7) return 'malicious';
  if (score >= 4) return 'suspicious';
  if (score >= 1) return 'unknown';
  return 'benign';
}

function scoreToDerivedSeverity(score) {
  if (score >= 9) return 'critical';
  if (score >= 7) return 'high';
  if (score >= 4) return 'medium';
  if (score >= 2) return 'low';
  return 'info';
}

function buildAlertTitle(value, type, score) {
  const truncated = value.length > 40 ? `${value.substring(0, 40)}…` : value;
  return `High-threat ${type} detected: ${truncated} (score: ${score.toFixed(1)})`;
}

function shannonEntropy(str) {
  const freq = {};
  for (const c of str) freq[c] = (freq[c] || 0) + 1;
  return Object.values(freq).reduce((e, f) => {
    const p = f / str.length;
    return e - p * Math.log2(p);
  }, 0);
}

// Deterministic pseudo-random from a string (so same hash always scores the same)
function pseudoRandom(str) {
  let h = 0;
  for (let i = 0; i < str.length; i++) h = (Math.imul(31, h) + str.charCodeAt(i)) | 0;
  return (h >>> 0) / 4294967296;
}

module.exports = { enrichIoc };
