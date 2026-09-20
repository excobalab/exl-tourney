# SKR integration (hackathon window, Sept 20 – Oct 8, 2026)

SKR is the Solana Mobile network token (mint `SKRbvo6Gf7GondiT3BbTfuRDPqLWei4j2Qy2NPGZhW3`, see solanamobile.com/skr). Seeker owners hold and stake it; dApps use it for incentives. EXL Tourney adds SKR as a **second tournament currency** next to SOL.

> Token program (SPL Token vs Token-2022) and decimals are confirmed on-chain before release — see "Open items".

## Product

- Every daily / weekly / monthly tournament exists twice: `zipla:d:2026-10-01` (SOL) and `zipla:d:2026-10-01:skr` (SKR). Same seed, same rules, separate pools.
- Entry fees in SKR (config `skrFees`), prize split and service fee identical to SOL tournaments.
- **Guardian Weekly** (stretch goal): players whose wallet has SKR staked get a reduced SKR entry fee. Only shipped if the stake account can be read reliably from the Worker; otherwise it stays in the roadmap — no fake features.

## Backend changes (`backend/src/index.js`)

1. `GAMES[game].skrFees = { d, w, m }` (base units) and `tournaments.currency TEXT DEFAULT 'SOL'` (`schema.sql` migration `ALTER TABLE tournaments ADD COLUMN currency TEXT NOT NULL DEFAULT 'SOL'`).
2. `ensureTournaments` creates the `:skr` twins; `/t` returns `currency`, `feeAmount`, `poolTokenAccount` (pool wallet's SKR ATA) and `mint`.
3. `verifyPayment` for SKR: scan `spl-token` (or `spl-token-2022`) instructions of type `transfer` / `transferChecked` where `destination == poolAta`, `authority == payer`, and (for `transferChecked`) `mint == SKR`; sum `amount`; memo rule unchanged.
4. `settle` for SKR: build transfers with `createTransferInstruction(poolAta, winnerAta, poolPubkey, amount)`; prepend `createAssociatedTokenAccountIdempotentInstruction` for winners without an ATA (rent paid from pool SOL); service fee to `COMMISSION_ADDRESS`'s ATA. Dependency: `@solana/spl-token`.
5. Telegram / X messages show the currency.

## Client changes

- `MainActivity.kt` `payPremium`: optional `mint`, `decimals`, `tokenProgram` arguments → SPL transfer instruction (`TransferChecked`, data `[12, amount u64 LE, decimals u8]`) with accounts `[sourceAta, mint, destAta, owner(signer)]`; ATA derivation with the Associated Token Program (`ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL`). Memo instruction unchanged.
- `exl_wallet.dart`: `showExlPaySheet(..., mint:, decimals:, tokenProgram:)`; Phantom rail uses the `solana` package's `TokenInstruction.transferChecked`.
- Tournament screen: two JOIN buttons per card ("0.1 SOL" / "N SKR"); leaderboard and Proof screen show the currency.

## Why it matters for the ecosystem

Any Seeker game that adopts this kit can run SKR-denominated skill tournaments in an afternoon; SKR gets a recurring, non-speculative use (entry → prize → re-entry loop), and the pool/payout trail stays fully auditable on-chain.

## Open items (checked before the first live SKR tournament)

- [ ] Token program and decimals of the SKR mint (Solscan) — affects instruction layout.
- [ ] Whether Seeker Wallet / Jupiter approve `TransferChecked` through MWA `signAndSendTransactions` without extra simulation flags.
- [ ] Minimum SKR fee that keeps the payout transaction economically sensible (ATA rent ≈ 0.002 SOL per new winner).
