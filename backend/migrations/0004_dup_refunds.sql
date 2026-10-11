-- EXL Tournaments — migration 0004 (v3.3): duplicate entry payments are refunded once
-- Run once on the existing D1 database:
--   npx wrangler d1 execute exl-tournaments --file=migrations/0004_dup_refunds.sql --remote --yes
CREATE TABLE IF NOT EXISTS dup_refunds (
  pay_tx TEXT PRIMARY KEY,          -- the duplicate payment (claimed before sending, so a replayed /join cannot refund twice)
  tournament_id TEXT NOT NULL,
  wallet TEXT NOT NULL,
  lamports INTEGER NOT NULL,        -- amount paid (base units of the tournament currency)
  tx_sig TEXT,                      -- refund transaction; NULL = claimed but refund failed → settle by hand
  created_at INTEGER NOT NULL,
  refunded_at INTEGER
);
