-- EXL Tournaments — D1 schema v2 (fresh install). Existing v1 databases: run migrations/0002_skr_and_signatures.sql instead.
CREATE TABLE IF NOT EXISTS tournaments (
  id TEXT PRIMARY KEY,              -- zipla:d:2026-07-12 | zipla:w:2026-W28 | zipla:m:2026-07
  game TEXT NOT NULL,
  type TEXT NOT NULL,               -- d | w | m
  starts_at INTEGER NOT NULL,       -- unix ms (UTC)
  ends_at INTEGER NOT NULL,
  fee_lamports INTEGER NOT NULL,    -- base units of `currency` (lamports for SOL, 1e-6 SKR for SKR)
  currency TEXT NOT NULL DEFAULT 'SOL',  -- SOL | SKR
  status TEXT NOT NULL DEFAULT 'open'   -- open | settling | paid
);

CREATE TABLE IF NOT EXISTS entries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  tournament_id TEXT NOT NULL,
  wallet TEXT NOT NULL,
  pay_tx TEXT NOT NULL UNIQUE,
  paid_lamports INTEGER NOT NULL,
  joined_at INTEGER NOT NULL,
  attempts_used INTEGER NOT NULL DEFAULT 0,
  best_score INTEGER NOT NULL DEFAULT 0,
  best_at INTEGER,
  best_verified INTEGER NOT NULL DEFAULT 0,  -- best score carried a valid wallet signature
  UNIQUE(tournament_id, wallet)
);

CREATE TABLE IF NOT EXISTS attempts (
  token TEXT PRIMARY KEY,
  entry_id INTEGER NOT NULL,
  started_at INTEGER NOT NULL,
  submitted_at INTEGER,
  score INTEGER,
  duration_ms INTEGER,
  taps INTEGER,
  flagged INTEGER NOT NULL DEFAULT 0,
  telemetry_json TEXT,
  sig TEXT,                          -- base58 ed25519 signature over exl:score:<token>:<score>:<durationMs>
  verified INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS payouts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  tournament_id TEXT NOT NULL,
  rank INTEGER NOT NULL,            -- 0 = komisyon
  wallet TEXT NOT NULL,
  lamports INTEGER NOT NULL,
  tx_sig TEXT,
  paid_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_entries_t ON entries(tournament_id, best_score DESC, best_at ASC);
CREATE INDEX IF NOT EXISTS idx_attempts_e ON attempts(entry_id);
CREATE INDEX IF NOT EXISTS idx_tourn_status ON tournaments(status, ends_at);
