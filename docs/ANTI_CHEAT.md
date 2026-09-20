# Anti-cheat and fairness model

The goal is not "unhackable" — it is *cheaper to play honestly than to cheat*, with every accepted risk written down.

## Threat model

| Threat | Mitigation (v1, live) | Residual risk |
|---|---|---|
| Replay a good run / retry until lucky | Attempt token is burned **before** the run (`/attempt/start`); one score per token; 24 h window | none — airplane mode or force-close just loses the attempt |
| Different players get different (easier) runs | Seed = `sha256(tournamentId \| SEED_SALT)`, served after the attempt is burned; every engine derives *all* randomness from it (tile stream, food, obstacles, block speeds, bubble colours) | salt leak would let a player pre-compute the run; salt lives only in Worker secrets |
| Forged score | Time-derived games (Sol Jump): exact formula check (`dist = v0·t + a/2·t²`). Skill games: `score ≤ maxScorePerSec × seconds + 10`; `durationMs ≤ real elapsed + 60 s`; `durationMs ≥ minDurationMs`; `taps ≥ 1` | ceiling-based check only bounds the score; a skilled cheater can still submit a plausible high score → v2 replay |
| Idle-cheat (wait, then post a huge score) | Per-game ceilings tuned on real play (2048 lowered 3000→150/s after audit) | see above |
| Sybil / multi-entry | Identity = paying wallet; `UNIQUE(tournament_id, wallet)`; `pay_tx UNIQUE` | a second wallet is a second paid entry — economically neutral for the pool |
| Pay once, join twice | `pay_tx` UNIQUE; memo must contain the tournament id; amount ≥ fee; recipient = pool | — |
| Double payout on crash | Settle marks `settling`, checks existing `payouts` before paying (idempotency guard), reverts to `open` on error | — |
| Pool key compromise | Key only in Worker secret; APKs never contain it; pool address fetched from `/t` (rotated once without rebuilding 7 apps) | single-signer hot wallet; Anchor escrow on roadmap |
| Flagged-score leakage | Flagged attempts are stored with telemetry but never rank; player just sees "not accepted" | — |

## Telemetry

`/attempt/submit` accepts `samples: [[tMs, score], …]` (a few dozen points). v1 stores them; v2 will check the score curve's monotonicity and slope against the engine's physical maximum.

## Hackathon additions (Sept–Oct 2026)

- **Wallet-signed scores** — the client asks the wallet (Seed Vault via MWA `signMessages`, or Phantom `signMessage`) to sign `exl:score:<token>:<score>:<durationMs>`. The Worker verifies the ed25519 signature against the entry's wallet. This binds the score to the key that paid, defeats man-in-the-middle submission, and gives the leaderboard a "verified" badge. Unsigned submissions still work (backwards compatible) but are unbadged.
- **Proof endpoint** — `/proof?tournamentId=` publishes seed hash, ranking, verified flags, payouts and fee split so a third party can audit any finished tournament without trusting us.

## v2 — deterministic replay (planned)

All seven engines already run on a fixed time step with seed-derived randomness. v2 sends the tap log (`[tMs, x?, y?]`) with the score; the Worker (or an isolated verifier) replays the run and rejects any score that does not reproduce bit-for-bit. Sol Jump's log is a few hundred bytes; the most complex (Bubble) a few KB.

## Accepted risks (as of 2026-09-20)

1. Score validation for skill games is ceiling-based until replay v2.
2. `confirmed` commitment for payment verification (not `finalized`) — chosen for UX; reorg risk on Solana mainnet is negligible for these amounts.
3. Single RPC provider (publicnode) with client-side retry; no failover yet.
4. Hot pool wallet signed by the Worker; escrow program is the long-term answer.
