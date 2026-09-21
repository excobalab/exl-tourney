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
