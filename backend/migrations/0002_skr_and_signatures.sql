-- EXL Tournaments — migration 0002 (Sept 2026 hackathon): SKR tournaments + wallet-signed scores
-- Run once on the existing D1 database:
--   npx wrangler d1 execute exl-tournaments --file=migrations/0002_skr_and_signatures.sql --remote
ALTER TABLE tournaments ADD COLUMN currency TEXT NOT NULL DEFAULT 'SOL';   -- SOL | SKR
ALTER TABLE attempts    ADD COLUMN sig TEXT;                                -- base58 ed25519 signature (optional)
ALTER TABLE attempts    ADD COLUMN verified INTEGER NOT NULL DEFAULT 0;     -- 1 = signature verified
ALTER TABLE entries     ADD COLUMN best_verified INTEGER NOT NULL DEFAULT 0;
