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
backend/              Cloudflare Worker (API + cron settle) + D1 schema
flutter/exl_wallet/   Flutter payment sheet (MWA + Phantom) + the Kotlin MWA bridge
                      exl_wallet.dart   fixed-amount payment with memo (tournament entry)
                      exl_premium.dart  one-time $2.99 premium unlock (same rails, USD→SOL via CoinGecko)
docs/                 API, tournament model, anti-cheat, SKR integration
```

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
- **Proof screen** — one page per finished tournament: seed hash, ranking, every payout with its Solscan link, fee breakdown. In-app and at `web3.excobalab.com/proof/<id>`.

Commit history in this repo starts on 2026-09-20; everything above is built during the hackathon window.

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
