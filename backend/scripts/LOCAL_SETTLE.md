# Reproduce a duel settlement / refund locally (DRY_RUN, no funds)

```bash
cd backend
cp wrangler.toml.example wrangler.toml           # set DRY_RUN = "1", any POOL_ADDRESS
npx wrangler d1 execute exl-tournaments --local --file=schema.sql
npx wrangler dev --local                          # http://127.0.0.1:8787
```

In a second shell (`KEY` = your ADMIN_KEY from wrangler.toml):

```bash
B=http://127.0.0.1:8787
# 1) create a 2-player SOL room, 0.02 SOL stake, 15 min join / 15 min play, winner takes all
curl -s -X POST $B/duel/create -H 'content-type: application/json' \
  -d '{"game":"zipla","currency":"SOL","stake":20000000,"players":2,"joinMin":15,"playMin":15,"dist":"wta","visibility":"private","wallet":"W1"}'
# → {"id":"zipla:x:ABCDEF", ...}   (DRY_RUN: no RPC verification of payTx)
ID='zipla:x:ABCDEF'
curl -s -X POST $B/join -H 'content-type: application/json' -d "{\"tournamentId\":\"$ID\",\"wallet\":\"W1\",\"payTx\":\"tx1\"}"
curl -s -X POST $B/join -H 'content-type: application/json' -d "{\"tournamentId\":\"$ID\",\"wallet\":\"W2\",\"payTx\":\"tx2\"}"   # room goes LIVE (2/2)
# 2) play: start an attempt per wallet, submit two scores
curl -s -X POST $B/attempt/start  -H 'content-type: application/json' -d "{\"tournamentId\":\"$ID\",\"wallet\":\"W1\"}"   # → token1, seed
curl -s -X POST $B/attempt/submit -H 'content-type: application/json' -d '{"token":"<token1>","score":766,"durationMs":21000,"taps":40}'
# same for W2 with score 473
# 3) end the play window early and settle
curl -s "$B/admin/end?key=$KEY&id=$ID"        # only for status=open; for a live room wait for ends_at or create the room with the smallest window (`joinMin`/`playMin` = 15) and let the tick pass
curl -s "$B/admin/settle?key=$KEY"
# → {"settle":[{"id":"zipla:x:ABCDEF","currency":"SOL","pool":40000000,"winners":2,"sig":"DRY_RUN"}]}
curl -s "$B/duel/get?id=$ID" | jq .payouts    # prize 0.0388 SOL to W1 (97 %), 0.001195 SOL service fee
```

Refund paths: create a room and join once → after `joinMs` the tick cancels it and refunds (`payouts[].rank == -1`); or join twice and submit nothing → `settle()` refunds both ("no valid score"). Scheduled tournaments use the same `refundAll()` since v3.2.
