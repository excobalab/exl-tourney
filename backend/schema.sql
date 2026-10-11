-- EXL Tournaments — D1 schema v2.0 (fresh install). Existing databases: run migrations/0002_*.sql then migrations/0003_duels.sql instead.
CREATE TABLE IF NOT EXISTS tournaments (
  id TEXT PRIMARY KEY,              -- zipla:d:2026-07-12 | zipla:w:2026-W28 | zipla:m:2026-07
  game TEXT NOT NULL,
  type TEXT NOT NULL,               -- d | w | m | x (duel room)
  starts_at INTEGER NOT NULL,       -- unix ms (UTC)
  ends_at INTEGER NOT NULL,
  fee_lamports INTEGER NOT NULL,    -- base units of `currency` (lamports for SOL, 1e-6 SKR for SKR)
  currency TEXT NOT NULL DEFAULT 'SOL',  -- SOL | SKR
  status TEXT NOT NULL DEFAULT 'open'   -- open | settling | paid  (duels: pending | open | live | settling | paid | cancelled)
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
  rank INTEGER NOT NULL,            -- 0 = service fee, -1 = refund (cancelled duel)
  wallet TEXT NOT NULL,
  lamports INTEGER NOT NULL,
  tx_sig TEXT,
  paid_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_entries_t ON entries(tournament_id, best_score DESC, best_at ASC);
CREATE INDEX IF NOT EXISTS idx_attempts_e ON attempts(entry_id);
CREATE INDEX IF NOT EXISTS idx_tourn_status ON tournaments(status, ends_at);

-- v2.0 DUEL / ROOM mode: room settings for tournaments rows with type='x'
CREATE TABLE IF NOT EXISTS duels (
  id TEXT PRIMARY KEY,               -- <game>:x:<CODE>  (CODE = 6-char invite code)
  max_players INTEGER NOT NULL,      -- 2..10
  join_ms INTEGER NOT NULL,
  play_ms INTEGER NOT NULL,
  join_ends_at INTEGER NOT NULL,
  live_at INTEGER,
  dist TEXT NOT NULL,                -- wta | top2 | top3 | half
  visibility TEXT NOT NULL,          -- public | private
  created_by TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  seat_mode INTEGER NOT NULL DEFAULT 0, -- v4: open without payment, players pay from their seats, host starts
  host TEXT,                         -- v4: current host (transferable)
  started_by TEXT                    -- v4: who pressed START
);
CREATE INDEX IF NOT EXISTS idx_tourn_game_type ON tournaments(game, type, status);

-- v3.3: duplicate entry payments (same wallet, same tournament) are refunded once
CREATE TABLE IF NOT EXISTS dup_refunds (
  pay_tx TEXT PRIMARY KEY,
  tournament_id TEXT NOT NULL,
  wallet TEXT NOT NULL,
  lamports INTEGER NOT NULL,
  tx_sig TEXT,
  created_at INTEGER NOT NULL,
  refunded_at INTEGER
);

-- v4: seat mode (see migrations/0005_seats.sql)
-- duels gains: seat_mode INTEGER NOT NULL DEFAULT 0, host TEXT, started_by TEXT
CREATE TABLE IF NOT EXISTS seats (
  room_id TEXT NOT NULL,
  wallet TEXT NOT NULL,
  reserved_at INTEGER NOT NULL,
  nudged_at INTEGER,
  nudged_by TEXT,
  PRIMARY KEY (room_id, wallet)
);
CREATE INDEX IF NOT EXISTS idx_seats_room ON seats(room_id);

-- v4.1: withdrawals (entry taken back before playing; refund paid on-chain immediately) — payouts.rank -3 = withdrawal refund
CREATE TABLE IF NOT EXISTS withdrawals (
  pay_tx TEXT PRIMARY KEY,
  tournament_id TEXT NOT NULL,
  wallet TEXT NOT NULL,
  paid_lamports INTEGER NOT NULL,
  refund_lamports INTEGER NOT NULL,
  fee_lamports INTEGER NOT NULL,
  tx_sig TEXT,
  created_at INTEGER NOT NULL,
  refunded_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_withdrawals_wallet ON withdrawals(wallet, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_entries_wallet ON entries(wallet);
CREATE INDEX IF NOT EXISTS idx_payouts_wallet ON payouts(wallet);
