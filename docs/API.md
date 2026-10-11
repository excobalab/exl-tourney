# EXL Tourney — Worker API

Base URL: your Worker (`https://exl-tournaments.<account>.workers.dev`). All responses are JSON with permissive CORS. Times are Unix ms (UTC). Amounts are lamports.

## GET /t?game=<gameId>&wallet=<pubkey?>&skr=1

Ensures the current daily / weekly / monthly tournaments exist for the game and returns the open ones. Pass `skr=1` to also receive the parallel SKR tournaments (ids end with `:skr`, `currency: "SKR"`, `feeAmount` in 1e-6 SKR) plus an `skr` object with `mint`, `decimals` and the pool's `poolTokenAccount`. Clients that don't send `skr=1` only ever see SOL tournaments.

```json
{
  "poolAddress": "…",              // pay entry fees here (read it from here, never hardcode)
  "tournaments": [{
    "id": "zipla:d:2026-10-01", "type": "d", "endsAt": 1790000000000,
    "feeLamports": 100000000, "participants": 12, "poolLamports": 1200000000,
    "feePct": 1, "attemptsMax": 1,
    "me": { "attemptsUsed": 0, "attemptsMax": 1, "bestScore": 0 }   // null if wallet not given / not joined
  }]
}
```

## POST /join

Body: `{ "tournamentId": "zipla:d:2026-10-01", "payTx": "<signature>", "wallet": "<pubkey, optional>" }`

The Worker fetches the transaction (`getTransaction`, commitment `confirmed`) and checks: not failed · signer == wallet (if given) · a `system transfer` from the signer to `POOL_ADDRESS` ≥ fee · an `spl-memo` instruction containing the tournament id. On success the entry is created; identity is the paying wallet.

Errors: `402` verification failed (message says why; "Transaction not found" → retry after a few seconds with the same `payTx`, do not pay again) · `409` payment already used / wallet already joined · `400` tournament not open.

## POST /attempt/start

Body: `{ "tournamentId", "wallet" }` → `{ "token": "<uuid>", "seed": "<sha256 hex>", "attemptsLeft": 0 }`

**The attempt is consumed here**, atomically. Build the run from `seed` (identical for every participant).

Errors: `403` not joined / no attempts left.

## POST /attempt/submit

Body: `{ "token", "score": 1234, "durationMs": 45210, "taps": 87, "samples": [[tMs, score], …] }`

Plausibility checks (see ANTI_CHEAT.md) → `{ "ok": true, "accepted": true|false, "newBest": true|false }`. A rejected score is stored with `flagged=1` and never ranks. One submit per token; window 24 h.

Hackathon addition: optional `"wallet"` + `"signature"` (base58 ed25519 over `exl:score:<token>:<score>:<durationMs>`, signed by the wallet that paid the entry). A valid signature sets `verified: true` (badge on the leaderboard and in `/proof`); a missing or invalid one never rejects the score — the response carries `signatureValid: true|false|null`.

## GET /leaderboard?tournamentId=&top=50&wallet=

```json
{ "leaderboard": [{ "rank": 1, "wallet": "…", "score": 3210 }],
  "myRank": { "rank": 7, "bestScore": 1200 },
  "payouts": [{ "rank": 1, "wallet": "…", "lamports": 1188000000, "tx_sig": "…" }] }
```

`payouts` is non-empty once the tournament is settled — show "PAID ✓" with the Solscan link.

## GET /proof?tournamentId= (hackathon addition)

Everything needed to audit a finished tournament: seed hash, participants, pool, ranking with verified flags, payouts with tx links, fee breakdown.

## Cron (`5 * * * *`)

`settle()` closes every tournament whose `ends_at` passed: ranks entries (score desc, earlier first), computes shares from `WEIGHTS`, signs **one** transaction from the pool wallet with a transfer per winner + the service-fee transfer, records `payouts`. Idempotent: if payouts already exist for the id, it only marks the tournament `paid`. With `DRY_RUN="1"` it records payouts with `tx_sig="DRY_RUN"` and sends nothing.

## Admin (`?key=ADMIN_KEY`)

`/admin/settle` run settle now · `/admin/pool` pool balance · `/admin/diag` secret sanity (never prints the key) · `/admin/end?id=` force-end a tournament (testing) · `/admin/purge?id=` / `/admin/purgeall&confirm=yes` wipe data (**testing only**) · `/admin/tweet?text=` · `/admin/tweetdigest`.

## Duel / room mode (v2.0)

Rooms are tournaments with `type = "x"`; every other endpoint (`/join`, `/attempt/*`, `/leaderboard`, `/proof`) works on a room id unchanged.

| Method | Path | Body / query | Notes |
|---|---|---|---|
| POST | `/duel/create` | `{game, currency: "SOL"\|"SKR", stake (base units), players 2–10, joinMin, playMin ∈ {15,60,360,1440}, dist: wta\|top2\|top3\|half, visibility: public\|private, wallet}` | Reserves a room (`status: pending`, expires in 15 min). Returns `{id, code, memo, stake, poolAddress, skr}`. The creator pays the stake with `memo = id`, then calls `/join` — the room becomes `open`. |
| POST | `/join` | `{tournamentId: id, payTx, wallet}` | Same as tournaments. Filling the room makes it `live` immediately. Response carries `status`. |
| GET | `/duel/list?game=&wallet=` | | `public`: rooms open for joining (not full). `mine`: rooms the wallet joined (open/live/finished ≤ 7 days). `limits`: stake ranges, windows, distributions, fee %. |
| GET | `/duel/get?id=` or `?game=&code=` | | One room: settings, entries with live scores, countdown fields (`joinEndsAt`, `endsAt`, `now`), `weights`, payouts (`role`: prize / service_fee / refund). |

Lifecycle: `pending → open → live → settling → paid`, or `→ cancelled` (full refund minus the on-chain fee) when fewer than 2 players joined by `joinEndsAt` or nobody posted a valid score. The 5-minute cron (`duelTick` + `settle`) drives the transitions; `/attempt/start` is only accepted while `live`. Service fee: 3 % (SOL) / 5 % (SKR). Ties split the tied positions' prizes equally.

## USD reference prices (v2.0)

`/t`, `/duel/list` and `/duel/get` include `prices: { SOL, SKR, at, source }` — USD per 1 SOL / 1 SKR, fetched by the Worker from the Jupiter price API (by mint; CoinGecko fallback for SOL) and cached for 5 minutes. Clients show them as a small "≈ $x" under amounts. Informational only: entry fees, stakes and prizes are always denominated and settled in SOL/SKR. `null` when no price source answered (clients hide the line).

## v4.1 — withdraw · wallet · tournament room (Oct 2026)

### POST /withdraw  `{tournamentId, wallet}`
Takes a paid entry back **before the player has played**. Duel rooms: until the host presses START (status `open`/`pending`). Scheduled tournaments: while open and `attempts_used = 0`.
Refund = stake − service fee (the tournament's `feePct`: 1/3/5 % scheduled, 3 % SOL / 5 % SKR rooms) − network fee (5000 lamports on SOL; none on SKR). The refund is sent on-chain in the same call — **no balance is ever held for the player**. The entry row is deleted atomically first, so a concurrent `/attempt/start`, host START or second `/withdraw` fails; if the transaction fails the entry is restored untouched.
Response: `{ok, refund, fee, networkFee, currency, tx, explorer}`. Recorded in `withdrawals` (pay_tx PK) and `payouts` (rank −3 = withdrawal refund, rank 0 = fee).

### GET /wallet?wallet=…
"My Wallet" across **all** EXL games. `open[]`: paid entries in open/pending/live tournaments and rooms with `canPlay`, `canWithdraw` and a `withdraw` quote `{paid, fee, networkFee, refund, feePct}`. `history[]`: `entry` (−), `prize`, `refund`, `withdraw` items with `tx` (Solscan). No balance field by design (see SARTNAME_V13 §1).

### GET /t/room?id=…&wallet=…
A scheduled tournament rendered like a room: rules, pool, `entries[]` (played/score/verified), `me` (attempts, `canPlay`, `canWithdraw`, `withdraw` quote), `payouts[]` with explorer links, `poolAddress`/`skr` for paying.

### Changed
- `duelView.me` gains `canWithdraw` + `withdraw` quote. Payout `role` gains `withdraw`.
- `/attempt/start` returns 409 `Withdrawal in progress` while a refund tx is in flight.
- Migration: `migrations/0006_withdrawals.sql`.

### v4.1.1 (6 Oct 2026) — hardening after the first withdrawal incident
- `withdrawals` table is created lazily (`ensureSchema`) — a missed migration can no longer break `/withdraw`, `/wallet` or `/attempt/start`.
- `/withdraw` order: claim row first, then delete the entry, then send; **any** failure restores the entry (`INSERT OR IGNORE`) and removes the claim. Telegram alert if even the restore fails.
- Admin: `GET /admin/refund?key=…&id=<tournamentId>&to=<wallet>&amount=<base units>&currency=SOL|SKR&note=…` (manual transfer from the pool, recorded as payouts rank −3); `GET /admin/entries?key=…&wallet=…` (entries + withdrawals + payouts of one wallet).

## v5 — Sol EXathlon (7 Oct 2026)
Game id `exathlon` = four sub-games (`zipla`, `dodge`, `stack`, `tiles`) under one entry. Everything else (periods, fees, SOL/SKR, duel rooms, withdraw, proof) is the standard model.
- `GET /t?game=exathlon` — tournaments carry `subs[]` and `attemptsPerGame`; `attemptsMax` is the total (per game × 4).
- `POST /attempt/start {tournamentId, wallet, sub}` — `sub` is required for exathlon; attempts are counted per sub; the reply has `sub`, the sub seed (`sha256(id + ':' + sub | salt)`) and `attemptsLeft` for that sub.
- `POST /attempt/submit` — unchanged; plausibility rules are those of the sub-game the token was started for. A new sub best triggers a recompute: per sub ranking → F1 points (25-18-15-12-10-8-6-4-2-1); `entries.best_score` = total points, so `/leaderboard`, settle and payouts are unchanged. Tie-break: fewer total rank places (an unplayed sub counts as last + 1), then the earlier finish.
- `GET /t/room`, `GET /duel/get`, `GET /proof` — add `exa: { subs: [{sub, name, attemptsMax, ranking: [{rank, wallet, score, verified, points}]}], points, me: [{sub, attemptsUsed, attemptsMax, bestScore, verified, rank, points}] }` (`me` only with `?wallet=`); proof also reveals `subSeeds` after settlement.
- Tables (created on first use): `exa_scores(tournament_id, wallet, sub, attempts_used, best_score, best_at, best_verified)`, `exa_attempts(token, sub)`.

## v5.1 — EXathlon: one signature for four scores (9 Oct 2026)
- Scores of an EXathlon run are submitted unsigned; `POST /exa/sign {tournamentId, wallet, signature}` verifies one ed25519 signature over `exl:exa:<tournamentId>:<wallet>:zipla=<best>:dodge=<best>:stack=<best>:tiles=<best>` and marks all four sub bests verified. The message is only offered (`exa.signMessage` in `/t/room` and `/duel/get` with `?wallet=`) once every sub has at least one attempt; `exa.signed` is true while the stored signature still covers the current bests — a new sub best clears that sub's ✓ until the player signs again. A bad signature answers `{verified:false, signatureValid:false}` and changes nothing.
- `/proof` → `exa.signatures: [{wallet, message, signature, signedAt}]` (table `exa_sigs`).
