# Tournament model (v1)

| Tournament | Period (UTC) | Entry | Attempts | Prize split (of pool after fee) | Service fee |
|---|---|---|---|---|---|
| Daily | 00:00–24:00 | 0.1 SOL | 1 | 1st 99 % | 1 % |
| Weekly | Mon–Sun (ISO week) | 0.3 SOL | 3 | 50 / 30 / 17 | 3 % |
| Monthly | calendar month | 1 SOL | 10 | 30 18 12 9 7 6 5 4 2 2 | 5 % |

- Pools and prizes are denominated in SOL (or SKR): percentages, not fixed amounts, so price volatility is neutral.
- Ties: the earlier submission ranks higher (`best_at`).
- Low turnout: the pool is still paid out. Missing ranks are redistributed proportionally to the ranks that exist; the fee percentage stays fixed. A daily with two players still pays 99 % to the winner. The only refund case is a period with no valid score at all (below) — stated in the ToS.
- No valid score at all (v3.2): every entry is refunded (`payouts.rank = -1`, same path as duel-room cancellations). Money never gets stuck, and the house never keeps a pool it did not pay a prize from. (Before v3.2 such a pool went to the fee wallet — see `EVIDENCE.md` #8.)
- The payout transaction's network fee (5000 lamports) is deducted from the service fee, never from prizes.
- One wallet joins a tournament once. A second wallet is a second paid entry.
- The pool wallet is separate from the fee wallet; tournaments are separated by memo, and settle filters by `tournament_id`, so pools can never mix.
- Timezone: UTC on the server; the app shows local time.

Terms shown to the player before the first JOIN: 18+, skill-based, same seed for everyone, fees 1–5 %, prizes paid on-chain automatically, refunds only when a period ends with no valid score. Terms/privacy pages per game: `https://excobalab.com/terms/<game>.html`, `/privacy/<game>.html`.

## v3.3 / client 1.2.1 (1 Oct 2026)
- **Attempt starts on GO.** The client calls `/attempt/start` only after the player taps *TAP TO START* and the 3-2-1 countdown ends; backing out before GO spends nothing. An attempt that was started but never submitted (app killed, crash) is submitted as **0** by the client on the next launch — the attempt is spent either way, so there is no replay window.
- **Duplicate entry payment → refunded once.** If a wallet pays a second time for a tournament it already joined, `/join` verifies the payment, records it in `dup_refunds` (pay_tx is the primary key) and sends it back immediately (SOL: minus the 5 000-lamport network fee). Uniqueness is per tournament id — the same wallet can still enter every other tournament and room once.

### v4.2 — late finish grace (6 Oct 2026)
A run that started before `ends_at` counts even if it finishes after it: `settle()` defers a tournament/room while an attempt is open (started, not submitted, started within the last 15 min) and the window closed less than 15 min ago. `/attempt/start` still requires `ends_at > now`.

## Sol EXathlon (v5, 7 Oct 2026) — a standalone app on the same model
One entry (daily / weekly / monthly, SOL or SKR, same fees and prize tables) covers four games: Sol Jump, Sol Dodge, Sol Stack, Sol Tiles. The player picks a game (CHOOSE GAME), spends one of that game's attempts (daily 1 · weekly 3 · monthly 10 per game), and the best score per game is ranked against the other players; each game's ranking pays F1 points 25-18-15-12-10-8-6-4-2-1. Total points rank the EXathlon board; ties go to fewer total rank places, then the earlier finish. Duel rooms work the same way with one run per game. Withdraw is allowed until the first run in any game; a left run counts with the score reached. Every rule of the single-game apps applies unchanged; the EXathlon app contains the four game engines and the shared EXL kit.
