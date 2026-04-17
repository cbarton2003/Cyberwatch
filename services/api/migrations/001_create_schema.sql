-- migrations/001_create_schema.sql
-- CyberWatch: security events, IOCs, alerts, scans

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ── Enums ─────────────────────────────────────────────────────────────────────

CREATE TYPE severity_level  AS ENUM ('info', 'low', 'medium', 'high', 'critical');
CREATE TYPE event_category  AS ENUM (
  'brute_force', 'malware', 'phishing', 'data_exfiltration',
  'privilege_escalation', 'lateral_movement', 'c2_communication',
  'reconnaissance', 'dos', 'policy_violation', 'other'
);
CREATE TYPE event_status    AS ENUM ('new', 'investigating', 'contained', 'resolved', 'false_positive');
CREATE TYPE ioc_type        AS ENUM ('ip', 'domain', 'hash_md5', 'hash_sha1', 'hash_sha256', 'url', 'email');
CREATE TYPE enrich_status   AS ENUM ('pending', 'processing', 'enriched', 'failed');
CREATE TYPE disposition     AS ENUM ('unknown', 'benign', 'suspicious', 'malicious');
CREATE TYPE scan_status     AS ENUM ('queued', 'running', 'completed', 'failed');

-- ── Security Events ───────────────────────────────────────────────────────────

CREATE TABLE events (
  id           UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  title        VARCHAR(512)  NOT NULL,
  description  TEXT,
  severity     severity_level NOT NULL DEFAULT 'medium',
  category     event_category NOT NULL DEFAULT 'other',
  status       event_status   NOT NULL DEFAULT 'new',
  source_ip    INET,
  hostname     VARCHAR(255),
  metadata     JSONB          NOT NULL DEFAULT '{}',
  occurred_at  TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  created_at   TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_events_severity    ON events(severity);
CREATE INDEX idx_events_category    ON events(category);
CREATE INDEX idx_events_status      ON events(status);
CREATE INDEX idx_events_source_ip   ON events(source_ip);
CREATE INDEX idx_events_occurred_at ON events(occurred_at DESC);
CREATE INDEX idx_events_metadata    ON events USING gin(metadata);

-- ── Indicators of Compromise ──────────────────────────────────────────────────

CREATE TABLE iocs (
  id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  value            TEXT          NOT NULL,
  type             ioc_type      NOT NULL,
  severity         severity_level NOT NULL DEFAULT 'medium',
  threat_score     NUMERIC(4,2)   NOT NULL DEFAULT 0 CHECK (threat_score BETWEEN 0 AND 10),
  disposition      disposition    NOT NULL DEFAULT 'unknown',
  source           VARCHAR(255)   NOT NULL,
  tags             JSONB          NOT NULL DEFAULT '[]',
  metadata         JSONB          NOT NULL DEFAULT '{}',
  enrichment_status enrich_status NOT NULL DEFAULT 'pending',
  enrichment_data  JSONB          NOT NULL DEFAULT '{}',
  job_id           TEXT,
  error_message    TEXT,
  first_seen       TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  last_seen        TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  created_at       TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_ioc_value UNIQUE (value)
);

CREATE INDEX idx_iocs_type            ON iocs(type);
CREATE INDEX idx_iocs_threat_score    ON iocs(threat_score DESC);
CREATE INDEX idx_iocs_disposition     ON iocs(disposition);
CREATE INDEX idx_iocs_enrichment_status ON iocs(enrichment_status);
CREATE INDEX idx_iocs_severity        ON iocs(severity);
CREATE INDEX idx_iocs_tags            ON iocs USING gin(tags);
CREATE INDEX idx_iocs_enrichment_data ON iocs USING gin(enrichment_data);

-- ── Alerts ────────────────────────────────────────────────────────────────────

CREATE TABLE alerts (
  id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  title            VARCHAR(512)  NOT NULL,
  ioc_id           UUID          REFERENCES iocs(id) ON DELETE SET NULL,
  ioc_value        TEXT          NOT NULL,
  ioc_type         ioc_type      NOT NULL,
  threat_score     NUMERIC(4,2)  NOT NULL,
  severity         severity_level NOT NULL,
  acknowledged     BOOLEAN       NOT NULL DEFAULT false,
  acknowledged_by  VARCHAR(255),
  acknowledged_at  TIMESTAMPTZ,
  notes            TEXT,
  fired_at         TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  created_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_alerts_ioc_id        ON alerts(ioc_id);
CREATE INDEX idx_alerts_acknowledged  ON alerts(acknowledged);
CREATE INDEX idx_alerts_threat_score  ON alerts(threat_score DESC);
CREATE INDEX idx_alerts_fired_at      ON alerts(fired_at DESC);

-- ── Bulk Scans ────────────────────────────────────────────────────────────────

CREATE TABLE scans (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name          VARCHAR(255) NOT NULL,
  total_iocs    INTEGER      NOT NULL DEFAULT 0,
  processed     INTEGER      NOT NULL DEFAULT 0,
  malicious     INTEGER      NOT NULL DEFAULT 0,
  suspicious    INTEGER      NOT NULL DEFAULT 0,
  benign        INTEGER      NOT NULL DEFAULT 0,
  errors        INTEGER      NOT NULL DEFAULT 0,
  status        scan_status  NOT NULL DEFAULT 'queued',
  job_id        TEXT,
  error_message TEXT,
  completed_at  TIMESTAMPTZ,
  created_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ── Auto-update updated_at ────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_updated_at_events BEFORE UPDATE ON events  FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER set_updated_at_iocs   BEFORE UPDATE ON iocs    FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER set_updated_at_alerts BEFORE UPDATE ON alerts  FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER set_updated_at_scans  BEFORE UPDATE ON scans   FOR EACH ROW EXECUTE FUNCTION update_updated_at();
