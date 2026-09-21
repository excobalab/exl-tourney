# EXL Tourney — skill-based, real-prize tournaments for Solana Mobile games

> Drop a daily / weekly / monthly tournament with an on-chain SOL (or SKR) prize pool into any Android game. Everyone plays the **same server-seeded run**, scores are validated, winners are **paid automatically on-chain** every hour by a cron. No servers to run: one Cloudflare Worker + D1.

**Live on the Solana dApp Store (Seeker):** Sol Jump · Sol 2048 · Sol Snake · Sol Stack · Sol Tiles · Sol Dodge · Sol Bubble — search "Sol" by EXCOBALAB. Site: https://web3.excobalab.com · X: [@EXLTourney](https://x.com/EXLTourney)

*Türkçe özet aşağıda.*

---

## Why

Most "play-to-earn" leaderboards are luck-weighted, opaque, or need a custodial backend. EXL Tourney is the opposite:

- **Deterministic fairness** — every participant gets the same seed (`sha256(tournamentId | salt)`), so the run is identical for everyone. Pure skill.
- **Verifiable on-chain** — entry fee goes to a pool wallet with the tournament id in the memo; payouts leave the same wallet with rank memos. Anyone can audit on Solscan.
- **Serverless** — Cloudflare Worker + D1 + hourly cron. Free tier is enough for thousands of entries/day.
- **Mobile-native payments** — Mobile Wallet Adapter 2.0 (Seeker Wallet, Jupiter, Solflare, Backpack) via a tiny Kotlin bridge, plus Phantom encrypted deeplinks as a second rail. Flutter on top.

## What's in this repo

```
backend/src/index.js        Cloudflare Worker: API, cron settle/payout, duel rooms, proof, Jupiter USD prices (v3.2)
backend/schema.sql          D1 schema (tournaments, duels, entries, attempts, payouts) + migrations/
backend/scripts/            LOCAL_SETTLE.md — reproduce a payout / refund locally in DRY_RUN
flutter/exl_wallet/         Drop-in Flutter modules + Kotlin MWA bridge
  exl_wallet.dart           payment sheet: MWA 2.0 (Seed Vault, Jupiter, Solflare, Backpack) + Phantom deeplink; SOL and SKR (SPL)
  exl_duel.dart             DUELS tab: create-room wizard, join with code, room screen, rematch
  exl_proof.dart            PROOF screen: seed commitment / reveal, verified ranking, payout tx links
  exl_premium.dart          one-time premium unlock on the same rails
  android/MainActivity.kt   MWA bridge (signAndSendTransactions, signMessages)
docs/                       API.md · DUELS.md · SKR.md · TOURNAMENT_MODEL.md · ANTI_CHEAT.md · EVIDENCE.md (mainnet tx map) · deck/
```

**Evidence:** every claim below maps to a mainnet transaction — see [`docs/EVIDENCE.md`](docs/EVIDENCE.md). Demo video: https://www.youtube.com/watch?v=h5Us_DjI_eQ · Deck: [`docs/deck/EXL_Tourney_Pitch_Deck.pdf`](docs/deck/EXL_Tourney_Pitch_Deck.pdf)

## How it works

```
Game (Flutter) ──MWA / Phantom──► pool wallet   (transfer + memo "zipla:d:2026-10-01")
     │ POST /join {payTx}                              ▲
     ▼                                                 │ payouts (cron, hourly)
Worker ── verifies tx on RPC (recipient, amount, memo, payer) ── D1 (tournaments/entries/attempts/payouts)
     │ POST /attempt/start  → burns one attempt, returns {token, seed}
     │ POST /attempt/submit → telemetry plausibility + per-game score ceiling, flagged scores never rank
     └ GET  /leaderboard    → top 50 + your rank + payout tx links ("PAID ✓")
```

Economy (configurable per game in `GAMES`):

| Tournament | Entry | Attempts | Prize split | Service fee |
|---|---|---|---|---|
| Daily (UTC day) | 0.1 SOL | 1 | 1st 99 % | 1 % |
| Weekly (ISO week) | 0.3 SOL | 3 | 50 / 30 / 17 | 3 % |
| Monthly | 1 SOL | 10 | 30 18 12 9 7 6 5 4 2 2 | 5 % |

Ties: earlier submission ranks higher. Low turnout: pool is still distributed proportionally to existing ranks. The chain fee for the payout transaction is taken from the service fee, never from the prize.

## Quick start (backend, ~15 min)

```bash
cd backend
npm install
npx wrangler login
npx wrangler d1 create exl-tournaments          # paste database_id into wrangler.toml
cp wrangler.toml.example wrangler.toml
npx wrangler d1 execute exl-tournaments --file=schema.sql --remote
# generate a pool wallet (pool_wallet.html) → POOL_ADDRESS in wrangler.toml
npx wrangler secret put POOL_SECRET               # JSON byte array of the pool wallet
npx wrangler secret put SEED_SALT
npx wrangler secret put ADMIN_KEY
npx wrangler deploy
```

Smoke test: `GET https://<worker>/t?game=zipla` → three open tournaments. Keep `DRY_RUN="1"` until you have run a full join → play → submit → settle cycle with a tiny fee (we used 0.001 SOL), then set `"0"`.

Add a game: one line in `GAMES` (fees, attempts, `minDurationMs`, and either a deterministic `physics` formula or a `maxScorePerSec` ceiling). Your game then calls the four endpoints in `docs/API.md`.

## Quick start (Flutter client)

1. Copy `flutter/exl_wallet/exl_wallet.dart` into `lib/` and `android/MainActivity.kt` into your Android app (package name and `identityName` are the only edits).
2. Dependencies: `solana`, `http`, `shared_preferences`, `url_launcher`, `app_links`, `pinenacl`. MWA: `clientlib-ktx 2.2.0` + `web3-solana 0.3.1` in `build.gradle.kts`.
3. Register a deeplink scheme `<yourgame>://phconnect|phsign` for Phantom's return.
4. `showExlPaySheet(context, recipient: poolAddress, lamports: fee, memo: tournamentId)` returns the tx signature → `POST /join`.

Lessons baked in (cost us days): Phantom does not support `signAndSendTransaction` over its deeplink — sign, then send from the app; get the blockhash *before* opening the wallet; DNS can flap right after returning from a wallet → retry; `/join` retries "Transaction not found" without paying twice; never embed the pool address in the APK — read it from `/t`.

## Anti-cheat (v1, live)

- Attempt token is burned **before** the run starts (airplane mode doesn't refund it); one score per token, 24 h submit window.
- Server seed per tournament; identical run for everyone.
- Telemetry plausibility: duration ≤ real elapsed time, minimum duration, taps > 0, per-game `maxScorePerSec` ceiling (or exact formula for time-derived scores). Violations are stored, flagged and silently excluded from ranking.
- Identity = the wallet that paid; `pay_tx` is UNIQUE; one wallet per tournament; settle is idempotent (a half-finished settle can never pay twice).
- v2 (planned): deterministic replay of the tap log on the server — engines already run on a fixed time step.

Details and accepted risks: `docs/ANTI_CHEAT.md`.

## Hackathon (CLOCK IN, Sept 8 – Oct 8, 2026) — what's new in this window

- **SKR tournaments** — entry and prize pool in SKR (`SKRbvo6Gf7GondiT3BbTfuRDPqLWei4j2Qy2NPGZhW3`), SPL transfer verification + ATA payouts. See `docs/SKR.md`.
- **Wallet-signed scores** — the Seed Vault / wallet signs `exl:score:<token>:<score>:<duration>` (MWA `signMessages`, Phantom `signMessage`); the Worker verifies ed25519 and marks the score "verified" on the leaderboard.
- **Proof screen** — one page per finished tournament: seed hash, ranking, every payout with its Solscan link, fee breakdown. In-app and at `web3.excobalab.com/proof/?id=<id>`.
- **Duel rooms (v2.0)** — players create their own rooms: SOL or SKR stake (0.02–5 SOL / 200–50,000 SKR), 2–10 players, joining and playing windows (15 min – 1 day), prize split (winner-takes-all / top 2 / top 3 / top half), invite code or public list. The room goes live when it is full (or at the end of the joining window with ≥ 2 players); everyone's clock starts at the same second; ties split; under-filled rooms and rooms with no valid score are **refunded automatically**. `docs/DUELS.md`.
- **USD reference** next to every SOL/SKR amount (Jupiter price API, fetched server-side, 5-min cache). Payment is always in SOL/SKR.
- **Refund guarantee (v3.2)** — a period that ends with no valid score refunds every entry, for scheduled tournaments and rooms alike. The house never keeps a pool it did not pay a prize from.
- **First live results on mainnet (21 Sep 2026):** a 0.05 SOL duel between a Seeker and a regular Android phone settled itself — 0.097 SOL to the winner, tx [`4WGoRr…`](https://solscan.io/tx/4WGoRriJcacwDKZWZ3eTkBcDLEAaZVW5LdDSnhMgphZG4wYsthtBDz4WzmS48UtZbBMj8yteu68gP9p86Wqo9i7B); an under-filled 200 SKR room refunded itself, tx [`2rN8LN…`](https://solscan.io/tx/2rN8LN8Yf4XwiKVxhM6k3cTNCfFmSQptJEVEgmsLMuDZmAdtmSFDfmoLvHSn3pEPPCSuEg9DdVsxy2FoXmCAELXQ).

Commit history in this repo starts on 2026-09-20; everything above is built during the hackathon window. The games themselves shipped on the dApp Store in July 2026. The team is one person working with an AI-native workflow (product decisions by the founder, code written with Claude, tested on device).

## Roadmap

Deterministic replay validation (v2) · Anchor escrow for the pool (trust-minimised payouts) · restore-purchase from chain memo · 20 more games on the same engine · Play Solana PSG1 port.

## License

Apache-2.0 — see `LICENSE`. Built by [excoba.lab](https://excobalab.com) (Excoba Medikal Turizm İç ve Dış Ticaret A.Ş., Ankara). Contact: info@excobalab.com

---

## Türkçe özet

**EXL Tourney**, herhangi bir Android oyununa günlük/haftalık/aylık, **zincir üstü SOL (veya SKR) ödül havuzlu** beceri turnuvası ekleyen açık kaynak bir kittir. Herkes aynı sunucu tohumuyla oynar (şans yok), skorlar telemetriyle doğrulanır, kazananlara ödül her saat başı **otomatik olarak zincirde** ödenir. Sunucu yok: tek Cloudflare Worker + D1 + cron.

- `backend/` — Worker API + cron kapanış/ödeme + D1 şeması. Kurulum 15 dk (yukarıdaki komutlar).
- `flutter/exl_wallet/` — MWA 2.0 (Seeker Wallet, Jupiter, Solflare, Backpack) + Phantom şifreli deeplink ile ödeme sayfası; Kotlin köprüsü.
- `docs/` — API, turnuva modeli, hile koruması, SKR entegrasyonu.

Yeni oyun eklemek = `GAMES` yapılandırmasına bir satır + 4 API çağrısı. Solana dApp Store'da 7 oyunumuz bu altyapıyla yayında. Sorular: info@excobalab.com
