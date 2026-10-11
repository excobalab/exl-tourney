-- v4.1 (Oct 2026): withdrawals — a paid entry taken back before playing (refund = stake − service fee − network fee, paid on-chain at once)
CREATE TABLE IF NOT EXISTS withdrawals (
  pay_tx TEXT PRIMARY KEY,           -- the original entry payment (one withdrawal per payment)
  tournament_id TEXT NOT NULL,
  wallet TEXT NOT NULL,
  paid_lamports INTEGER NOT NULL,
  refund_lamports INTEGER NOT NULL,
  fee_lamports INTEGER NOT NULL,
  tx_sig TEXT,                       -- NULL while the refund transaction is in flight
  created_at INTEGER NOT NULL,
  refunded_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_withdrawals_wallet ON withdrawals(wallet, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_entries_wallet ON entries(wallet);
CREATE INDEX IF NOT EXISTS idx_payouts_wallet ON payouts(wallet);
