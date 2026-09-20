-- EXL Tournaments — migration 0003 (v2.0): DUEL / ROOM mode
-- Run once on the existing D1 database:
--   npx wrangler d1 execute exl-tournaments --file=migrations/0003_duels.sql --remote --yes
--
-- A duel is a tournaments row with type='x' (so entries/attempts/payouts/proof all work unchanged)
-- plus one row here holding the room settings. Lifecycle: pending (created, creator not paid yet)
-- → open (joining) → live (playing, same deadline for everyone) → settling → paid | cancelled (refunded).
CREATE TABLE IF NOT EXISTS duels (
  id TEXT PRIMARY KEY,               -- same as tournaments.id: <game>:x:<CODE>
  max_players INTEGER NOT NULL,      -- 2..10
  join_ms INTEGER NOT NULL,          -- joining window length (ms)
  play_ms INTEGER NOT NULL,          -- playing window length (ms), starts when the room goes live
  join_ends_at INTEGER NOT NULL,     -- unix ms
  live_at INTEGER,                   -- unix ms when the room went live
  dist TEXT NOT NULL,                -- wta | top2 | top3 | half
  visibility TEXT NOT NULL,          -- public | private
  created_by TEXT NOT NULL,          -- creator wallet
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tourn_game_type ON tournaments(game, type, status);
