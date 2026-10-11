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

## v4 — seat mode (Oct 2026)
A room created with `seatMode: true` opens **without any payment**. Flow:
1. `POST /duel/create {…, seatMode: true, wallet}` → room `open`, creator is `host`, creator's seat reserved.
2. Others take a seat: `POST /duel/seat {id, wallet}` (no payment). Unpaid seats expire after 10 min; `POST /duel/leave` gives one up.
3. Each player pays from their own row when ready: the usual stake transfer (memo = room id) + `POST /join`.
4. `POST /duel/nudge {id, from, to}` pokes an unpaid seat (1/min); the target sees `myNudge` on its next refresh.
5. `POST /duel/transfer {id, wallet: host, to}` hands the host role over (payments stay personal). `POST /duel/kick {id, wallet: host, to}` removes an unpaid seat.
6. `POST /duel/start {id, wallet: host}` — allowed only when ≥ 2 players paid and **every** seat is paid → room `live` (same play window for everyone).
7. If the host never starts before the room's lifetime ends → every paid player is refunded in full (status `cancelled`).
Views (`/duel/get`, `/duel/list`) add `seatMode, host, seats[], unpaidSeats, canStart, myNudge`. Legacy (creator-pays-first) rooms keep working unchanged.

## v4.1 — WITHDRAW from a seat (Oct 2026)
A PAID seat can be taken back until the host presses START (`POST /withdraw`). Refund = stake − room service fee (3 % SOL / 5 % SKR) − network fee, sent on-chain immediately; the seat is freed, the host role passes on if the host withdrew, and an empty room closes. Once the room is `live` nothing can be withdrawn. Rooms that never start still refund **in full** at `join_ends_at` (v4 rule).

## v4.2 — early close · rematch invites · room history (6 Oct 2026)
- **Early close:** when every paid player of a `live` room has used and submitted all attempts (no attempt token still open), `/attempt/submit` sets `ends_at = now` and the worker settles in the background right after replying — nobody waits for the play window.
- **Rematch without codes:** `POST /duel/create` accepts `inviteWallets: [...]` (seat mode). Each invited wallet gets a reserved seat (`seats.nudged_by = 'invite'`) that lives until the room closes, so the room appears in their YOUR ROOMS list immediately; they just press PAY.
- **Room history:** `GET /duel/list` returns `past[]` — finished/cancelled rooms of the last 30 days the wallet took part in or hosted, with `participants[]`, `winner`, `myPrize`. The client's OPEN ROOMS screen lists them with a REMATCH button (same rules, same people).

## v4.3 — public listing after the host pays · host closes a room (6 Oct 2026)
- **Public rooms wait for the host:** `GET /duel/list` lists a `public` room only once its host has paid (`hostPaid: true` in every room view). A host who never pays cannot fill the public list with empty rooms; the room is still reachable by code and in the host's YOUR ROOMS.
- **Close room:** `POST /duel/cancel {id, wallet: host}` — allowed while the room is `open`/`pending` (not started). Every paid stake is refunded **in full** on-chain in the same call (SOL: minus the shared network fee), status → `cancelled`, the room leaves every list and shows up in ROOM HISTORY as REFUNDED. Claim-first (`status='settling'`), so a double tap never refunds twice; on failure the previous status is restored and the host can retry.
