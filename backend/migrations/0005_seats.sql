-- EXL Tournaments — migration 0005 (v4): seat mode for duel rooms
-- Run once on the existing D1 database:
--   npx wrangler d1 execute exl-tournaments --file=migrations/0005_seats.sql --remote --yes
-- A seat-mode room opens WITHOUT payment: players take seats, each pays from their own row when ready,
-- the host presses START once every seat is paid. Unpaid seats expire after 10 min; an un-started room
-- is refunded in full when its lifetime ends.
ALTER TABLE duels ADD COLUMN seat_mode INTEGER NOT NULL DEFAULT 0;
ALTER TABLE duels ADD COLUMN host TEXT;
ALTER TABLE duels ADD COLUMN started_by TEXT;
CREATE TABLE IF NOT EXISTS seats (
  room_id TEXT NOT NULL,
  wallet TEXT NOT NULL,
  reserved_at INTEGER NOT NULL,
  nudged_at INTEGER,
  nudged_by TEXT,
  PRIMARY KEY (room_id, wallet)
);
CREATE INDEX IF NOT EXISTS idx_seats_room ON seats(room_id);
