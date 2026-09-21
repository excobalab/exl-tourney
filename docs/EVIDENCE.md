# Evidence — mainnet transactions behind the claims

Every claim in the README and the CLOCK IN submission maps to a public transaction from the **pool wallet** `25cZtbrmvNrMdLvzuy1KK8EbavyQLdMxKoeheQqyjvbL` (SOL) / its SKR token account `AYviCvmoEfDpUxPTv1vaQLmd746zgXj5DSQJoXsRDTkr`, or to a player wallet paying into it. Service fees go to `9oQgS5qbnWcY8AbJQ6Uuks3WS5adhWMcvz7APDq3dMbW`. All of it is reproducible from the API (`/duel/get`, `/proof`) and visible on Solscan.

| # | What | Currency | Amount | Tx | Produced by |
|---|---|---|---|---|---|
| 1 | Duel room **HFRZAX** — creator's stake (Seeker, Phantom) | SOL | 0.05 | entry tx in `/duel/get?game=zipla&code=HFRZAX` | app → `POST /duel/create` + pay sheet (`exl_duel.dart` → `exl_wallet.dart`) |
| 2 | Duel room HFRZAX — second player's stake (regular Android, Phantom) | SOL | 0.05 | same endpoint, `entries[1]` | app → JOIN WITH CODE → `POST /join` |
| 3 | Duel room HFRZAX — **prize to the winner** (766 vs 473, both wallet-signed ✓) | SOL | 0.097 | [`4WGoRr…9i7B`](https://solscan.io/tx/4WGoRriJcacwDKZWZ3eTkBcDLEAaZVW5LdDSnhMgphZG4wYsthtBDz4WzmS48UtZbBMj8yteu68gP9p86Wqo9i7B) | cron `settle()` → `sendTransfers()` |
| 4 | Duel room HFRZAX — service fee (3 %, minus the tx fee) | SOL | 0.002995 | same tx as #3 (two transfers in one transaction) | cron `settle()` |
| 5 | Duel room **KL997T** — under-filled room (1/2 after the joining window) → **automatic refund** | SKR | 200 | [`2rN8LN…ELXQ`](https://solscan.io/tx/2rN8LN8Yf4XwiKVxhM6k3cTNCfFmSQptJEVEgmsLMuDZmAdtmSFDfmoLvHSn3pEPPCSuEg9DdVsxy2FoXmCAELXQ) | cron `duelTick()` → `refundAll()` (SPL TransferChecked) |
| 6 | Scheduled SKR daily `bubble:d:2026-09-20:skr` — **SKR entry** (50 SKR, SPL transfer verified by the Worker) | SKR | 50 | [`47zAzB…Z735`](https://solscan.io/tx/47zAzBqYy79vcU1wGjmkDWwNfrKDpQsd1fcr4m7Nqd2QiZVLyV4WYVX7qQVwEyUzNVN4UVMemYLNQR7DaKfpZ735) | app → `POST /join` (SKR branch, `docs/SKR.md`) |
| 7 | Scheduled SKR daily `bubble:d:2026-09-21:skr` — SKR entry | SKR | 50 | [`7Bvr1J…fYAj`](https://solscan.io/tx/7Bvr1JShMpCeKZhichqhcyeL4e7qgCPiJCdFZZa3Bixzsp7n2SimXojCKpspMg9qoJUbdSadJiLj3dRPsJ7fYAj) | app → `POST /join` |
| 8 | Settlement of `bubble:d:2026-09-20:skr` (no valid score in the period) | SKR | 50 → service wallet | [`5iaiiF…ZxBZ`](https://solscan.io/tx/5iaiiFFHhL4tD3C5rBnym64vNdQDmhu4mH3ZeLdFvFKkWmm5kTdPd42mBCtaLNM8fMRq9HYkCHnQ3LXWDaAqZxBZ) | cron `settle()` — **see note below** |

Proof pages (seed commitment → revealed seed → ranking → payouts):

- Duel room: https://web3.excobalab.com/proof/?id=zipla:x:HFRZAX
- Cancelled room: https://web3.excobalab.com/proof/?id=zipla:x:KL997T
- Scheduled SKR daily: https://web3.excobalab.com/proof/?id=bubble:d:2026-09-20:skr

Earlier end-to-end tests (14 Jul 2026, SOL daily, 0.001 SOL entries) are in the pool wallet's history on Solscan.

## Note on #8 — and the fix it triggered (backend v3.2)

The 20 Sep SKR daily had one entry whose score submission failed during a database quota outage on our side, so the period closed with **no valid score**. The v3.1 settle logic paid a pool with no ranked score to the service wallet. That is not the behaviour we want: the house should never keep a pool it did not pay a prize from. **v3.2 (this repo) refunds every entry when a period ends without a valid score — for scheduled tournaments exactly as for duel rooms** (`refundAll()` in `backend/src/index.js`; the proof "rules" text says so). The 50 SKR from #8 was returned to the player manually. Both wallets in that test belong to the team.

## How to reproduce a settlement locally (no real funds)

See `backend/scripts/LOCAL_SETTLE.md`: run the Worker with `wrangler dev --local`, `DRY_RUN="1"`, create a room, join twice with fake `payTx` values (the RPC check is skipped in DRY_RUN), submit two scores, then hit `/admin/settle?key=…` — the report shows the exact transfers that would be sent.
