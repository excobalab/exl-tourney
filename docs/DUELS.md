# Duel / room mode (v2.0)

Players create their own rooms: currency, stake, number of players, joining window, playing window, prize distribution and visibility are fixed **before anyone joins** and cannot be changed afterwards. Everyone in the room plays the same server seed, once, within the same playing window. Prizes are paid automatically; the room's `/proof` page shows the seed commitment, the reveal, every entry and every payout or refund.

## Fairness rules
1. **The creator pays too** — a room only opens once the creator's stake is on-chain (memo = room id). The creator has no special powers and cannot cancel.
2. **Joining window** — the room goes live the moment it is full, or when the window closes with ≥ 2 players. Fewer than 2 → cancelled, everyone refunded (only the on-chain fee is deducted).
3. **Seed commitment** — `sha256(seed)` is public from creation; the seed is handed out only to `/attempt/start` calls while the room is live, and revealed on the proof page after settlement. Nobody, including the creator, can preview the run.
4. **Playing window** — starts for everyone at the same instant; single attempt, burned at start. Not playing in time = score 0. If nobody posts a valid score the stakes are refunded.
5. **Ties** — equal scores split the prizes of the positions they occupy equally.
6. **Zero treasury risk** — prizes are always `stakes − service fee`; refunds come from the same stakes; the payout/refund transaction fee is deducted from the service fee (payout) or split across the refunds (cancellation). Minimum stakes keep the fee share negligible.

## Limits (server-enforced)
| | SOL | SKR |
|---|---|---|
| Stake | 0.02 – 5 SOL | 200 – 50 000 SKR |
| Service fee | 3 % | 5 % |
| Players | 2 – 10 | |
| Windows | 15 min · 1 h · 6 h · 24 h (joining and playing chosen separately) | |
| Distribution | winner-takes-all · top 2 (70/30) · top 3 (50/30/20) · top half equal | |

## Data model
`tournaments` row with `type='x'`, `id = <game>:x:<CODE>` (CODE doubles as the invite code) + one `duels` row with the settings. Entries, attempts, payouts and proof are shared with the periodic tournaments. Refunds are stored in `payouts` with `rank = -1`.
