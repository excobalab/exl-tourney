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
