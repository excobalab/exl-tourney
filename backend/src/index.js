// ============================================================================
// EXL TOURNAMENTS — Cloudflare Worker (API + cron settle)
// Tournament model v1 + hackathon additions (Sept 2026):
//   • SKR tournaments (SPL token entry fees + payouts)           [docs/SKR.md]
//   • wallet-signed scores (ed25519, "verified" badge)           [docs/ANTI_CHEAT.md]
//   • /proof endpoint (auditable tournament summary)             [docs/API.md]
// v2.0 (Oct 2026):
//   • DUEL / ROOM mode — player-created rooms, own stake & windows  [docs/DUELS.md]
// v3.3 — duplicate payment auto-refund · v4 — seat-mode rooms (pay from your seat, host starts)
// v5.0 (7 Oct) — Sol EXathlon: game 'exathlon' = 4 sub-games (zipla, dodge, stack, tiles), per-sub seeds/attempts, F1 points → entries.best_score
// v5.1 (9 Oct) — EXathlon: one wallet signature for all four scores — POST /exa/sign over `exl:exa:<id>:<wallet>:zipla=<b>:dodge=<b>:stack=<b>:tiles=<b>`
// v4.3 (6 Oct) — public rooms listed only after the host paid (hostPaid) · POST /duel/cancel (host closes an unstarted room, full refund)
//                · /duel/list batched (3–4 D1 queries per call instead of 2 per room), history capped at 20
// v4.2 (6 Oct) — duel rooms close early when everyone has played; rematch invites (inviteWallets) + room history (/duel/list past[])
// v4.1.1 (6 Oct) — withdraw: claim-first + full restore on any failure, self-healing schema, /admin/refund
// v4.1 (Oct 2026) — WITHDRAW before playing (immediate on-chain refund, no custodial balance),
//   GET /wallet (open items + history across games), GET /t/room (scheduled tournament as a room)
// ============================================================================
import { Keypair, PublicKey, SystemProgram, Transaction, TransactionInstruction } from '@solana/web3.js';
import bs58 from 'bs58';

// ---- Chain constants ----
const TOKEN_PROGRAM = new PublicKey('TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA');
const ATA_PROGRAM = new PublicKey('ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL');
const MEMO_PROGRAM = new PublicKey('MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr');
const SKR_DECIMALS = 6; // Seeker (SKR): classic SPL Token program, 6 decimals (verified on-chain 2026-09-20)
const SKR_UNIT = 10 ** SKR_DECIMALS;

// ---- Game / economy configuration ----
// SOL fees (lamports): daily 0.1 / weekly 0.3 / monthly 1 SOL.
const REAL_FEES = { d: 100_000_000, w: 300_000_000, m: 1_000_000_000 };
// SKR fees (base units): daily 500 / weekly 1 500 / monthly 5 000 SKR.
const SKR_FEES = { d: 500 * SKR_UNIT, w: 1_500 * SKR_UNIT, m: 5_000 * SKR_UNIT };
// Launch mode (LAUNCH_MODE="1"): 0.01 SOL / 50 SKR daily — for onboarding the first players.
const LAUNCH_FEES = { d: 10_000_000, w: 30_000_000, m: 100_000_000 };
const LAUNCH_SKR_FEES = { d: 50 * SKR_UNIT, w: 150 * SKR_UNIT, m: 500 * SKR_UNIT };
const STD_ATTEMPTS = { d: 1, w: 3, m: 10, x: 1 }; // x = duel room (single attempt)
const GAMES = {
  // Deterministic score formula (SOL JUMP): dist = v0*t + (acc/2)*t^2 ; score = floor(dist/div)
  zipla:  { minDurationMs: 700,  physics: { v0: 260, acc: 8, scoreDiv: 10 } },
  // Skill games: per-game ceiling (maxScorePerSec) + burned attempt token + server seed.
  s2048:  { minDurationMs: 4000, maxScorePerSec: 150 },
  snake:  { minDurationMs: 3000, maxScorePerSec: 12 },
  stack:  { minDurationMs: 2000, maxScorePerSec: 6 },
  tiles:  { minDurationMs: 3000, maxScorePerSec: 15 },
  dodge:  { minDurationMs: 3000, maxScorePerSec: 12 },
  bubble: { minDurationMs: 4000, maxScorePerSec: 120 },
};
for (const g of Object.values(GAMES)) g.attempts = STD_ATTEMPTS;
// ---- v5 — Sol EXathlon: one entry, four games, F1 points (Berkay, 7 Oct 2026) ----
// A tournament/room of game 'exathlon' is scored per sub-game (same seed per sub for everyone, attempts per sub as the
// type allows); each sub-game ranking awards F1 points; entries.best_score holds the TOTAL points so every existing
// ranking / settle / payout / proof path works unchanged. Tie-break: fewer total rank places, then the earlier finish.
const EXA_SUBS = ['zipla', 'dodge', 'stack', 'tiles'];
const EXA_POINTS = [25, 18, 15, 12, 10, 8, 6, 4, 2, 1];
GAMES.exathlon = { subs: EXA_SUBS, attempts: STD_ATTEMPTS, minDurationMs: 0 };
const isExa = tr => tr.game === 'exathlon';
function maxAttemptsFor(tr) { const a = GAMES[tr.game].attempts[tr.type]; return isExa(tr) ? a * EXA_SUBS.length : a; }

function feesFor(env, currency) {
  const launch = env.LAUNCH_MODE === '1';
  if (currency === 'SKR') return launch ? LAUNCH_SKR_FEES : SKR_FEES;
  return launch ? LAUNCH_FEES : REAL_FEES;
}
function expectedScore(cfg, durationMs) {
  const t = durationMs / 1000;
  return Math.floor((cfg.physics.v0 * t + (cfg.physics.acc / 2) * t * t) / cfg.physics.scoreDiv);
}
const FEE_PCT = { d: 1, w: 3, m: 5 };
const WEIGHTS = { d: [99], w: [50, 30, 17], m: [30, 18, 12, 9, 7, 6, 5, 4, 2, 2] }; // sum + FEE_PCT = 100

// ---- DUEL / ROOM mode (type 'x') ----
// Service fee: 3 % on SOL rooms, 5 % on SKR rooms (SKR payouts may need an ATA rent paid in SOL).
const DUEL_FEE_PCT = { SOL: 3, SKR: 5 };
const DUEL_STAKE = { SOL: { min: 20_000_000, max: 5_000_000_000 }, SKR: { min: 200 * SKR_UNIT, max: 50_000 * SKR_UNIT } };
const DUEL_WINDOWS_MIN = [15, 60, 360, 1440];          // joining / playing window options (minutes)
const DUEL_PLAYERS = { min: 2, max: 10 };
const SEAT_TTL_MS = 10 * 60 * 1000;                     // v4: an unpaid seat reservation expires after 10 min
const NUDGE_COOLDOWN_MS = 60 * 1000;                     // v4: one nudge per target per minute
const DUEL_DIST = { wta: 'Winner takes all', top2: 'Top 2 · 70/30', top3: 'Top 3 · 50/30/20', half: 'Top half split equally' };
const DUEL_PENDING_MS = 15 * 60 * 1000;                 // unpaid room reservations expire after 15 min
const DUEL_CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
function duelCode() { const a = crypto.getRandomValues(new Uint8Array(6)); return [...a].map(b => DUEL_CODE_ALPHABET[b % DUEL_CODE_ALPHABET.length]).join(''); }
const isDuel = tr => tr.type === 'x';
function feePctFor(tr) { return isDuel(tr) ? DUEL_FEE_PCT[tr.currency || 'SOL'] : FEE_PCT[tr.type]; }
// Prize weights (percent of the payable pool) for a room with `n` scored players.
function duelWeights(dist, n) {
  if (n <= 0) return [];
  if (dist === 'top2') return n >= 2 ? [70, 30] : [100];
  if (dist === 'top3') return n >= 3 ? [50, 30, 20] : (n === 2 ? [70, 30] : [100]);
  if (dist === 'half') { const k = Math.max(1, Math.floor(n / 2)); return Array(k).fill(100 / k); }
  return [100]; // wta
}
// Shares in base units; tied scores split the weights of the positions they occupy equally.
function duelShares(payable, dist, ranked) {
  const w = duelWeights(dist, ranked.length);
  const pos = ranked.map((_, i) => (i < w.length ? payable * w[i] / 100 : 0));
  const out = new Array(ranked.length).fill(0);
  let i = 0;
  while (i < ranked.length) {
    let j = i; while (j + 1 < ranked.length && ranked[j + 1].best_score === ranked[i].best_score) j++;
    const sum = pos.slice(i, j + 1).reduce((a, b) => a + b, 0);
    for (let k = i; k <= j; k++) out[k] = Math.floor(sum / (j - i + 1));
    i = j + 1;
  }
  return out;
}
const SUBMIT_WINDOW_MS = 24 * 3600 * 1000;
const RUN_GRACE_MS = 15 * 60 * 1000; // v4.2: a run started before the clock ends may finish up to 15 min after it

// ---- helpers ----
const J = (obj, status = 200) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: {
      'content-type': 'application/json',
      'access-control-allow-origin': '*',
      'access-control-allow-headers': 'content-type',
      'access-control-allow-methods': 'GET,POST,OPTIONS',
    },
  });
const bad = (msg, status = 400) => J({ error: msg }, status);
const now = () => Date.now();
const pad = n => String(n).padStart(2, '0');
const fmtAmount = (n, cur) => cur === 'SKR' ? `${(n / SKR_UNIT).toFixed(0)} SKR` : `${(n / 1e9).toFixed(3)} SOL`;
const skrEnabled = env => !!env.SKR_MINT;
function ataFor(owner, mint) {
  return PublicKey.findProgramAddressSync(
    [new PublicKey(owner).toBytes(), TOKEN_PROGRAM.toBytes(), new PublicKey(mint).toBytes()], ATA_PROGRAM,
  )[0];
}
// RPC with failover: RPC_URL may hold several endpoints separated by commas. A network error,
// an HTTP error or a JSON-RPC server error (-32xxx, e.g. node behind / rate limited) moves to the next.
async function rpc(env, method, params) {
  const urls = String(env.RPC_URL || '').split(',').map(u => u.trim()).filter(Boolean);
  let last = { error: { message: 'no RPC_URL configured' } };
  for (const url of urls) {
    try {
      const r = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
      if (!r.ok) { last = { error: { message: `HTTP ${r.status} from ${url}` } }; continue; }
      const j = await r.json();
      if (j.error && (j.error.code <= -32000 && j.error.code >= -32099 || j.error.code === 429)) { last = j; continue; }
      return j;
    } catch (e) { last = { error: { message: String(e) } }; }
  }
  return last;
}

// UTC period ids and bounds
function periods(game, t = new Date()) {
  const y = t.getUTCFullYear(), mo = t.getUTCMonth(), d = t.getUTCDate();
  const dayStart = Date.UTC(y, mo, d);
  const dayEnd = dayStart + 86400_000;
  const dow = (t.getUTCDay() + 6) % 7; // Mon=0
  const weekStart = dayStart - dow * 86400_000;
  const weekEnd = weekStart + 7 * 86400_000;
  const wDate = new Date(weekStart + 3 * 86400_000); // ISO week: Thursday rule
  const jan1 = Date.UTC(wDate.getUTCFullYear(), 0, 1);
  const weekNo = Math.ceil(((wDate.getTime() - jan1) / 86400_000 + 1) / 7);
  const monthStart = Date.UTC(y, mo, 1);
  const monthEnd = Date.UTC(y, mo + 1, 1);
  return [
    { id: `${game}:d:${y}-${pad(mo + 1)}-${pad(d)}`, type: 'd', starts: dayStart, ends: dayEnd },
    { id: `${game}:w:${wDate.getUTCFullYear()}-W${pad(weekNo)}`, type: 'w', starts: weekStart, ends: weekEnd },
    { id: `${game}:m:${y}-${pad(mo + 1)}`, type: 'm', starts: monthStart, ends: monthEnd },
  ];
}

// One SOL tournament per period, plus a parallel SKR one (id suffix ":skr") when SKR_MINT is set
async function ensureTournaments(env, game) {
  if (!GAMES[game]) return;
  const currencies = skrEnabled(env) ? ['SOL', 'SKR'] : ['SOL'];
  for (const p of periods(game)) {
    for (const cur of currencies) {
      const id = cur === 'SKR' ? `${p.id}:skr` : p.id;
      await env.DB.prepare(
        `INSERT OR IGNORE INTO tournaments (id, game, type, starts_at, ends_at, fee_lamports, currency) VALUES (?,?,?,?,?,?,?)`
      ).bind(id, game, p.type, p.starts, p.ends, feesFor(env, cur)[p.type], cur).run();
    }
  }
}

async function seedFor(env, tournamentId) {
  const data = new TextEncoder().encode(tournamentId + '|' + env.SEED_SALT);
  const h = await crypto.subtle.digest('SHA-256', data);
  return [...new Uint8Array(h)].map(b => b.toString(16).padStart(2, '0')).join('');
}
async function sha256hex(s) {
  const h = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return [...new Uint8Array(h)].map(b => b.toString(16).padStart(2, '0')).join('');
}

// ---- USD reference prices (informational only — payments are always in SOL/SKR) ----
// Jupiter price API by mint (works for any Solana token incl. SKR), CoinGecko as fallback for SOL.
// Cached in the Worker for 5 minutes so thousands of phones never hit the price APIs directly.
const SOL_MINT = 'So11111111111111111111111111111111111111112';
const PRICE_TTL_MS = 5 * 60 * 1000;
let _priceCache = { at: 0, prices: null };
async function getPrices(env) {
  if (now() - _priceCache.at < PRICE_TTL_MS && _priceCache.prices) return _priceCache.prices;
  const out = { SOL: null, SKR: null, at: now(), source: null };
  try {
    const ids = [SOL_MINT, env.SKR_MINT].filter(Boolean).join(',');
    const r = await fetch(`https://lite-api.jup.ag/price/v3?ids=${ids}`, { signal: AbortSignal.timeout(4000) });
    if (r.ok) {
      const j = await r.json();
      const pick = m => { const v = j?.[m] ?? j?.data?.[m]; const p = Number(v?.usdPrice ?? v?.price); return Number.isFinite(p) && p > 0 ? p : null; };
      out.SOL = pick(SOL_MINT); out.SKR = env.SKR_MINT ? pick(env.SKR_MINT) : null; out.source = 'jupiter';
    }
  } catch (_) { /* fall through */ }
  if (!out.SOL) {
    try {
      const r = await fetch('https://api.coingecko.com/api/v3/simple/price?ids=solana&vs_currencies=usd', { signal: AbortSignal.timeout(4000) });
      if (r.ok) { const p = Number((await r.json())?.solana?.usd); if (p > 0) { out.SOL = p; out.source = out.source ? out.source + '+coingecko' : 'coingecko'; } }
    } catch (_) { /* ignore */ }
  }
  if (out.SOL || out.SKR) _priceCache = { at: now(), prices: out };
  else if (_priceCache.prices) return _priceCache.prices; // stale is better than nothing
  return out;
}

// ---- Wallet-signed scores: ed25519 over `exl:score:<token>:<score>:<durationMs>` ----
async function verifyScoreSignature(wallet, message, signatureB58) {
  try {
    const pub = bs58.decode(wallet);
    const sig = bs58.decode(signatureB58);
    if (pub.length !== 32 || sig.length !== 64) return false;
    const key = await crypto.subtle.importKey('raw', pub, { name: 'Ed25519' }, false, ['verify']);
    return await crypto.subtle.verify({ name: 'Ed25519' }, key, sig, new TextEncoder().encode(message));
  } catch (_) { return false; }
}

// ---- Telegram (optional: TG_TOKEN + TG_CHAT) — never blocks game flow ----
async function tgBildir(env, metin) {
  if (!env.TG_TOKEN || !env.TG_CHAT) return;
  try {
    await fetch(`https://api.telegram.org/bot${env.TG_TOKEN}/sendMessage`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ chat_id: env.TG_CHAT, text: metin }),
    });
  } catch (_) { /* ignore */ }
}

// ---- X (Twitter) auto-posting — @EXLTourney (optional: X_* secrets) ----
const OYUN_AD = { zipla: 'Sol Jump', s2048: 'Sol 2048', snake: 'Sol Snake',
                  stack: 'Sol Stack', tiles: 'Sol Tiles', dodge: 'Sol Dodge', bubble: 'Sol Bubble', exathlon: 'Sol EXathlon' };
const TIP_AD = { d: 'Daily', w: 'Weekly', m: 'Monthly' };
const _pe = s => encodeURIComponent(s).replace(/[!'()*]/g, c => '%' + c.charCodeAt(0).toString(16).toUpperCase());
async function _hmacSha1(key, msg) {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(key), { name: 'HMAC', hash: 'SHA-1' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(msg));
  let bin = ''; for (const b of new Uint8Array(sig)) bin += String.fromCharCode(b);
  return btoa(bin);
}
async function xTweet(env, text) {
  if (!env.X_API_KEY || !env.X_API_SECRET || !env.X_ACCESS_TOKEN || !env.X_ACCESS_SECRET) return { skipped: 'no X keys' };
  try {
    const url = 'https://api.x.com/2/tweets';
    const oauth = {
      oauth_consumer_key: env.X_API_KEY, oauth_nonce: crypto.randomUUID().replace(/-/g, ''),
      oauth_signature_method: 'HMAC-SHA1', oauth_timestamp: String(Math.floor(Date.now() / 1000)),
      oauth_token: env.X_ACCESS_TOKEN, oauth_version: '1.0',
    };
    const paramStr = Object.keys(oauth).sort().map(k => `${_pe(k)}=${_pe(oauth[k])}`).join('&');
    oauth.oauth_signature = await _hmacSha1(`${_pe(env.X_API_SECRET)}&${_pe(env.X_ACCESS_SECRET)}`, `POST&${_pe(url)}&${_pe(paramStr)}`);
    const header = 'OAuth ' + Object.keys(oauth).sort().map(k => `${_pe(k)}="${_pe(oauth[k])}"`).join(', ');
    const r = await fetch(url, { method: 'POST', headers: { authorization: header, 'content-type': 'application/json' }, body: JSON.stringify({ text }) });
    return { status: r.status, body: await r.text() };
  } catch (e) { return { error: String(e) }; }
}
async function xGunlukOzet(env) {
  const t = now();
  const rows = (await env.DB.prepare(
    `SELECT tr.id, tr.type, tr.currency, tr.ends_at, COUNT(e.id) c, COALESCE(SUM(e.paid_lamports),0) p
       FROM tournaments tr JOIN entries e ON e.tournament_id = tr.id
      WHERE tr.status='open' AND tr.starts_at<=? AND tr.ends_at>?
      GROUP BY tr.id HAVING c > 0 ORDER BY c DESC LIMIT 3`
  ).bind(t, t).all()).results;
  if (!rows.length) return;
  const sat = rows.map(r => {
    const oyun = OYUN_AD[r.id.split(':')[0]] || r.id.split(':')[0];
    const kalan = Math.max(1, Math.round((r.ends_at - t) / 3600000));
    return `${oyun} ${TIP_AD[r.type]}: ${r.c}p · ${fmtAmount(r.p, r.currency)} · ${kalan}h left`;
  });
  await xTweet(env,
    `🏆 LIVE TOURNAMENTS\n\n${sat.join('\n')}\n\nSame seed for everyone — pure skill.\n` +
    `Prizes paid on-chain, automatically.\n\n📲 Seeker → dApp Store → search "Sol" · by EXCOBALAB 👑\n#Solana #SolanaMobile #Seeker`);
}

// ---- On-chain entry payment verification (SOL transfer or SKR SPL transfer) ----
async function verifyPayment(env, payTx, wallet, tr) {
  const tx = (await rpc(env, 'getTransaction',
    [payTx, { encoding: 'jsonParsed', commitment: 'confirmed', maxSupportedTransactionVersion: 0 }])).result;
  if (!tx) return { err: 'Transaction not found (wait a few seconds and retry)' };
  if (tx.meta?.err) return { err: 'Transaction failed on-chain' };

  const payer = tx.transaction.message.accountKeys.find(k => k.signer)?.pubkey;
  if (!payer) return { err: 'No signer found in transaction' };
  if (wallet && payer !== wallet) return { err: 'Payer does not match wallet' };

  const isSkr = tr.currency === 'SKR';
  const poolAta = isSkr ? ataFor(env.POOL_ADDRESS, env.SKR_MINT).toBase58() : null;
  let paid = 0, memoOk = false;
  const scan = (ins) => {
    for (const i of ins) {
      if (!isSkr && i.program === 'system' && i.parsed?.type === 'transfer') {
        const info = i.parsed.info;
        if (info.destination === env.POOL_ADDRESS && info.source === payer) paid += Number(info.lamports);
      }
      if (isSkr && i.program === 'spl-token' && (i.parsed?.type === 'transfer' || i.parsed?.type === 'transferChecked')) {
        const info = i.parsed.info;
        const amt = Number(info.amount ?? info.tokenAmount?.amount ?? 0);
        const mintOk = i.parsed.type === 'transfer' || info.mint === env.SKR_MINT;
        if (info.destination === poolAta && info.authority === payer && mintOk) paid += amt;
      }
      if (i.program === 'spl-memo' && typeof i.parsed === 'string' && i.parsed.includes(tr.id)) memoOk = true;
    }
  };
  scan(tx.transaction.message.instructions || []);
  for (const inner of tx.meta?.innerInstructions || []) scan(inner.instructions || []);

  if (!memoOk) return { err: 'Memo does not reference this tournament' };
  if (paid < tr.fee_lamports) return { err: `Insufficient payment (${paid} < ${tr.fee_lamports})` };
  return { err: null, payer };
}

// ---- API ----
async function handleTournaments(env, url) {
  const game = url.searchParams.get('game') || 'zipla';
  const wallet = url.searchParams.get('wallet');
  // SKR tournaments are only listed to clients that opt in (?skr=1). Older app builds
  // don't understand `currency` and must never see an SKR fee as if it were lamports.
  const wantSkr = url.searchParams.get('skr') === '1' && skrEnabled(env);
  await ensureTournaments(env, game);
  const t = now();
  const rows = (await env.DB.prepare(
    `SELECT * FROM tournaments WHERE game=? AND type<>'x' AND status='open' AND starts_at<=? AND ends_at>? AND (currency='SOL' OR ?=1) ORDER BY ends_at, currency`
  ).bind(game, t, t, wantSkr ? 1 : 0).all()).results;

  const out = [];
  for (const r of rows) {
    const agg = await env.DB.prepare(`SELECT COUNT(*) c, COALESCE(SUM(paid_lamports),0) pool FROM entries WHERE tournament_id=?`).bind(r.id).first();
    let me = null;
    if (wallet) {
      const e = await env.DB.prepare(`SELECT attempts_used, best_score FROM entries WHERE tournament_id=? AND wallet=?`).bind(r.id, wallet).first();
      if (e) me = { attemptsUsed: e.attempts_used, attemptsMax: maxAttemptsFor(r), bestScore: e.best_score };
    }
    out.push({
      id: r.id, type: r.type, currency: r.currency || 'SOL', endsAt: r.ends_at,
      feeLamports: r.fee_lamports, feeAmount: r.fee_lamports,   // base units of `currency`
      participants: agg.c, poolLamports: agg.pool, poolAmount: agg.pool, feePct: feePctFor(r),
      attemptsMax: maxAttemptsFor(r), me,
      ...(isExa(r) ? { subs: EXA_SUBS, attemptsPerGame: GAMES[r.game].attempts[r.type] } : {}),   // v5
    });
  }
  return J({
    poolAddress: env.POOL_ADDRESS,
    skr: wantSkr ? { mint: env.SKR_MINT, decimals: SKR_DECIMALS, poolTokenAccount: ataFor(env.POOL_ADDRESS, env.SKR_MINT).toBase58() } : null,
    tournaments: out,
    prices: await getPrices(env),   // USD reference (≈), informational only
  });
}

async function handleJoin(env, body) {
  const { tournamentId, wallet, payTx } = body || {};
  if (!tournamentId || !payTx) return bad('tournamentId, payTx required');
  const tr = await env.DB.prepare(`SELECT * FROM tournaments WHERE id=?`).bind(tournamentId).first();
  if (!tr) return bad('Tournament is not open');
  let duel = null;
  if (isDuel(tr)) {
    duel = await env.DB.prepare(`SELECT * FROM duels WHERE id=?`).bind(tr.id).first();
    if (!duel) return bad('Unknown room', 404);
    if (duel.seat_mode) {
      // v4 seat mode: the room is open from creation; anyone with a seat (or a free seat) can pay when ready
      if (tr.status !== 'open' || duel.join_ends_at <= now()) return bad('Room is not open for joining');
      const cnt = (await env.DB.prepare(`SELECT COUNT(*) c FROM entries WHERE tournament_id=?`).bind(tr.id).first()).c;
      if (cnt >= duel.max_players) return bad('Room is full', 409);
    } else if (tr.status === 'pending') {
      // created_by may be the placeholder 'new' when the creator had no wallet linked yet — the first payer becomes the creator
      if (wallet && duel.created_by !== 'new' && wallet !== duel.created_by) return bad('Room is not open yet', 403);
    } else if (tr.status !== 'open' || duel.join_ends_at <= now()) return bad('Room is not open for joining');
    if (!duel.seat_mode) {
      const cnt = (await env.DB.prepare(`SELECT COUNT(*) c FROM entries WHERE tournament_id=?`).bind(tr.id).first()).c;
      if (cnt >= duel.max_players) return bad('Room is full', 409);
    }
  } else if (tr.status !== 'open' || tr.ends_at <= now()) return bad('Tournament is not open');

  const v = await verifyPayment(env, payTx, wallet || null, tr);
  if (v.err) return bad(v.err, 402);
  const payer = v.payer;
  if (duel && !duel.seat_mode && tr.status === 'pending') {
    if (duel.created_by === 'new') { await env.DB.prepare(`UPDATE duels SET created_by=? WHERE id=?`).bind(payer, tr.id).run(); duel.created_by = payer; }
    else if (payer !== duel.created_by) return bad('Room is not open yet', 403);
  }
  if (duel && duel.seat_mode) {
    // paying without a reserved seat is fine as long as a seat is free (paid + reserved < max)
    const seat = await env.DB.prepare(`SELECT 1 FROM seats WHERE room_id=? AND wallet=?`).bind(tr.id, payer).first();
    if (!seat) {
      const taken = (await env.DB.prepare(`SELECT (SELECT COUNT(*) FROM entries WHERE tournament_id=?) + (SELECT COUNT(*) FROM seats WHERE room_id=?) c`).bind(tr.id, tr.id).first()).c;
      if (taken >= duel.max_players) return bad('Room is full', 409);
      await env.DB.prepare(`INSERT OR IGNORE INTO seats (room_id, wallet, reserved_at) VALUES (?,?,?)`).bind(tr.id, payer, now()).run();
    }
  }

  try {
    await env.DB.prepare(`INSERT INTO entries (tournament_id, wallet, pay_tx, paid_lamports, joined_at) VALUES (?,?,?,?,?)`)
      .bind(tournamentId, payer, payTx, tr.fee_lamports, now()).run();
  } catch (e) {
    const msg = String(e);
    if (msg.includes('pay_tx')) return bad('This payment was already used', 409);
    if (msg.includes('tournament_id')) {
      // v3.3: the same wallet paid a second time for a tournament it already joined (stale client state, retry…).
      // The payment was verified above, so send it back once — pay_tx is unique in dup_refunds, so a replayed /join can't double-refund.
      const sig = await refundDuplicate(env, tr, payer, payTx);
      return bad(sig
        ? `Wallet already joined this tournament — duplicate payment refunded (${sig === 'DRY_RUN' ? sig : sig.slice(0, 8) + '…'})`
        : 'Wallet already joined this tournament', 409);
    }
    throw e;
  }
  const agg = await env.DB.prepare(`SELECT COUNT(*) c, COALESCE(SUM(paid_lamports),0) p FROM entries WHERE tournament_id=?`).bind(tournamentId).first();
  let roomStatus = tr.status;
  if (duel && !duel.seat_mode) {
    if (tr.status === 'pending') { await env.DB.prepare(`UPDATE tournaments SET status='open' WHERE id=?`).bind(tr.id).run(); roomStatus = 'open'; }
    if (agg.c >= duel.max_players) { await duelGoLive(env, tr.id, duel.play_ms); roomStatus = 'live'; }
  }
  // v4 seat mode: the room goes live only when the host presses START (or auto-starts when full and every seat is paid — see duelTick)
  await tgBildir(env,
    `🏆 YENİ KATILIM\n${tournamentId}\nCüzdan: ${payer.slice(0, 4)}…${payer.slice(-4)}\n` +
    `Ücret: ${fmtAmount(tr.fee_lamports, tr.currency)}\nToplam: ${agg.c} katılımcı · havuz ${fmtAmount(agg.p, tr.currency)}`);
  return J({ ok: true, wallet: payer, attemptsMax: maxAttemptsFor(tr), status: roomStatus });
}

async function handleAttemptStart(env, body) {
  const { tournamentId, wallet } = body || {};
  if (!tournamentId || !wallet) return bad('tournamentId, wallet required');
  const tr = await env.DB.prepare(`SELECT * FROM tournaments WHERE id=?`).bind(tournamentId).first();
  if (!tr) return bad('Tournament is not open');
  if (isDuel(tr)) { if (tr.status !== 'live' || tr.ends_at <= now()) return bad(tr.status === 'open' || tr.status === 'pending' ? 'Room has not started yet' : 'Room is closed', 409); }
  else if (tr.status !== 'open' || tr.ends_at <= now()) return bad('Tournament is not open');
  const entry = await env.DB.prepare(`SELECT * FROM entries WHERE tournament_id=? AND wallet=?`).bind(tournamentId, wallet).first();
  if (!entry) return bad('Join the tournament first', 403);
  try { if (await env.DB.prepare(`SELECT 1 FROM withdrawals WHERE pay_tx=? AND tx_sig IS NULL`).bind(entry.pay_tx).first()) return bad('Withdrawal in progress', 409); } catch (_) { /* table not there yet — nothing in flight */ }
  const maxA = GAMES[tr.game].attempts[tr.type];
  if (isExa(tr)) {
    // v5: attempts are per sub-game; `sub` picks the game. The sub seed differs per game, same for every player.
    const sub = body.sub;
    if (!EXA_SUBS.includes(sub)) return bad('sub must be one of ' + EXA_SUBS.join(','));
    await ensureSchema(env);
    await env.DB.prepare(`INSERT OR IGNORE INTO exa_scores (tournament_id, wallet, sub) VALUES (?,?,?)`).bind(tr.id, wallet, sub).run();
    const u = await env.DB.prepare(`UPDATE exa_scores SET attempts_used = attempts_used + 1 WHERE tournament_id=? AND wallet=? AND sub=? AND attempts_used < ?`).bind(tr.id, wallet, sub, maxA).run();
    if (!u.meta.changes) return bad('No attempts left in this game', 403);
    await env.DB.prepare(`UPDATE entries SET attempts_used = attempts_used + 1 WHERE id=?`).bind(entry.id).run();
    const token = crypto.randomUUID();
    await env.DB.prepare(`INSERT INTO attempts (token, entry_id, started_at) VALUES (?,?,?)`).bind(token, entry.id, now()).run();
    await env.DB.prepare(`INSERT INTO exa_attempts (token, sub) VALUES (?,?)`).bind(token, sub).run();
    const used = (await env.DB.prepare(`SELECT attempts_used FROM exa_scores WHERE tournament_id=? AND wallet=? AND sub=?`).bind(tr.id, wallet, sub).first())?.attempts_used ?? maxA;
    return J({ token, sub, seed: await seedFor(env, tr.id + ':' + sub), attemptsLeft: Math.max(0, maxA - used) });
  }
  if (entry.attempts_used >= maxA) return bad('No attempts left', 403);

  // ATTEMPT IS BURNED HERE (airplane-mode protection) — atomic
  const upd = await env.DB.prepare(`UPDATE entries SET attempts_used = attempts_used + 1 WHERE id=? AND attempts_used < ?`).bind(entry.id, maxA).run();
  if (!upd.meta.changes) return bad('No attempts left', 403);

  const token = crypto.randomUUID();
  await env.DB.prepare(`INSERT INTO attempts (token, entry_id, started_at) VALUES (?,?,?)`).bind(token, entry.id, now()).run();
  return J({ token, seed: await seedFor(env, tournamentId), attemptsLeft: maxA - entry.attempts_used - 1 });
}

async function handleSubmit(env, body) {
  const { token, score, durationMs, taps, samples, signature, wallet } = body || {};
  if (!token || typeof score !== 'number') return bad('token, score required');
  const at = await env.DB.prepare(`SELECT * FROM attempts WHERE token=?`).bind(token).first();
  if (!at) return bad('Unknown attempt token', 404);
  if (at.submitted_at) return bad('Attempt already submitted', 409);
  if (now() - at.started_at > SUBMIT_WINDOW_MS) return bad('Submit window expired', 410);

  const entry = await env.DB.prepare(`SELECT * FROM entries WHERE id=?`).bind(at.entry_id).first();
  const tr = await env.DB.prepare(`SELECT * FROM tournaments WHERE id=?`).bind(entry.tournament_id).first();
  let cfg = GAMES[tr.game], sub = null;
  if (isExa(tr)) {   // v5: plausibility rules of the sub-game the token was started for
    await ensureSchema(env);
    sub = (await env.DB.prepare(`SELECT sub FROM exa_attempts WHERE token=?`).bind(token).first())?.sub;
    if (!sub || !GAMES[sub]) return bad('Unknown attempt token', 404);
    cfg = GAMES[sub];
  }

  // Telemetry plausibility — a violation stores the score but keeps it out of the ranking
  let flagged = 0;
  const dur = Number(durationMs) || 0;
  const elapsed = now() - at.started_at;
  if (score < 0 || dur < cfg.minDurationMs) flagged = 1;
  if (dur > elapsed + 60_000) flagged = 1;
  if (!Number.isInteger(score)) flagged = 1;
  if ((Number(taps) || 0) < 1 && score > 0) flagged = 1;
  if (cfg.physics) {
    const exp = expectedScore(cfg, dur);
    if (Math.abs(score - exp) > exp * 0.05 + 8) flagged = 1;
  } else if (cfg.maxScorePerSec) {
    if (score > cfg.maxScorePerSec * (dur / 1000) + 10) flagged = 1;
  }

  // Optional wallet signature → "verified" badge. Unsigned or badly-signed submissions still count
  // (the score is already bound to a burned attempt token); they just don't get the badge.
  let verified = 0, signatureValid = null;
  if (signature) {
    const sameWallet = !wallet || wallet === entry.wallet;
    signatureValid = sameWallet && await verifyScoreSignature(entry.wallet, `exl:score:${token}:${score}:${dur}`, signature);
    verified = signatureValid ? 1 : 0;
  }

  await env.DB.prepare(
    `UPDATE attempts SET submitted_at=?, score=?, duration_ms=?, taps=?, flagged=?, telemetry_json=?, sig=?, verified=? WHERE token=?`
  ).bind(now(), score, dur, Number(taps) || 0, flagged, JSON.stringify(samples || null), verified ? signature : null, verified, token).run();

  let newBest = false;
  if (isExa(tr)) {
    if (!flagged && score > 0) {
      const r = await env.DB.prepare(`UPDATE exa_scores SET best_score=?, best_at=?, best_verified=? WHERE tournament_id=? AND wallet=? AND sub=? AND best_score < ?`)
        .bind(score, now(), verified, tr.id, entry.wallet, sub, score).run();
      newBest = !!r.meta.changes;
      if (newBest) await exaRecompute(env, tr.id);
    }
  } else if (!flagged && score > entry.best_score) {
    await env.DB.prepare(`UPDATE entries SET best_score=?, best_at=?, best_verified=? WHERE id=?`).bind(score, now(), verified, entry.id).run();
    newBest = true;
  }
  // v4.2 — early close (Berkay, 6 Oct): a live duel room whose paid players have ALL used and submitted their run ends now,
  // instead of waiting for the play window; the cron/settle path pays it out within minutes.
  let roomClosed = false;
  if (isDuel(tr) && tr.status === 'live') {
    const maxA = maxAttemptsFor(tr);
    const open = await env.DB.prepare(
      `SELECT (SELECT COUNT(*) FROM entries e WHERE e.tournament_id=? AND e.attempts_used < ?) +
              (SELECT COUNT(*) FROM attempts a JOIN entries e2 ON e2.id=a.entry_id WHERE e2.tournament_id=? AND a.submitted_at IS NULL) c`
    ).bind(tr.id, maxA, tr.id).first();
    if ((open?.c ?? 1) === 0) {
      const r = await env.DB.prepare(`UPDATE tournaments SET ends_at=? WHERE id=? AND status='live' AND ends_at>?`).bind(now(), tr.id, now()).run();
      roomClosed = !!r.meta.changes;
      if (roomClosed) { _settleSoon = true; await tgBildir(env, `⏩ ODA ERKEN KAPANDI (herkes oynadı)\n${tr.id}`); }
    }
  }
  return J({ ok: true, accepted: !flagged, newBest, verified: !!verified, signatureValid, roomClosed });
}
let _settleSoon = false; // set by handleSubmit; the router settles in the background right after replying

// v5 — F1 totals: per sub-game ranking → points; entries.best_score = total points, entries.best_at = tie-break key
// (ASC = better): total rank places (an unplayed game counts as last place + 1), then the time the total was reached.
async function exaRecompute(env, tournamentId) {
  const rows = (await env.DB.prepare(`SELECT wallet, sub, best_score, best_at, best_verified FROM exa_scores WHERE tournament_id=? AND best_score>0`).bind(tournamentId).all()).results;
  const entries = (await env.DB.prepare(`SELECT id, wallet FROM entries WHERE tournament_id=?`).bind(tournamentId).all()).results;
  const pts = new Map(), places = new Map(), last = new Map(), unverified = new Set();
  for (const sub of EXA_SUBS) {
    const r = rows.filter(x => x.sub === sub).sort((a, b) => b.best_score - a.best_score || a.best_at - b.best_at);
    const seen = new Set();
    r.forEach((x, i) => {
      seen.add(x.wallet);
      pts.set(x.wallet, (pts.get(x.wallet) || 0) + (EXA_POINTS[i] || 0));
      places.set(x.wallet, (places.get(x.wallet) || 0) + i + 1);
      last.set(x.wallet, Math.max(last.get(x.wallet) || 0, x.best_at || 0));
      if (!x.best_verified) unverified.add(x.wallet);
    });
    for (const e of entries) if (!seen.has(e.wallet)) places.set(e.wallet, (places.get(e.wallet) || 0) + r.length + 1);
  }
  for (const e of entries) {
    const p = pts.get(e.wallet) || 0;
    const key = p > 0 ? (places.get(e.wallet) || 0) * 10_000_000_000_000 + (last.get(e.wallet) || 0) : null;
    await env.DB.prepare(`UPDATE entries SET best_score=?, best_at=?, best_verified=? WHERE id=?`).bind(p, key, p > 0 && !unverified.has(e.wallet) ? 1 : 0, e.id).run();
  }
}
// Per-sub-game boards + per-wallet breakdown for the room / proof screens.
async function exaBoard(env, tr, wallet) {
  await ensureSchema(env);
  const rows = (await env.DB.prepare(`SELECT wallet, sub, attempts_used, best_score, best_at, best_verified FROM exa_scores WHERE tournament_id=?`).bind(tr.id).all()).results;
  const maxA = GAMES[tr.game].attempts[tr.type];
  const subs = EXA_SUBS.map(sub => {
    const r = rows.filter(x => x.sub === sub && x.best_score > 0).sort((a, b) => b.best_score - a.best_score || a.best_at - b.best_at);
    return { sub, name: OYUN_AD[sub], attemptsMax: maxA,
             ranking: r.map((x, i) => ({ rank: i + 1, wallet: x.wallet, score: x.best_score, verified: !!x.best_verified, points: EXA_POINTS[i] || 0 })) };
  });
  const me = wallet ? EXA_SUBS.map(sub => {
    const x = rows.find(y => y.wallet === wallet && y.sub === sub);
    const rk = subs.find(s => s.sub === sub).ranking.find(y => y.wallet === wallet);
    return { sub, name: OYUN_AD[sub], attemptsUsed: x?.attempts_used || 0, attemptsMax: maxA, bestScore: x?.best_score || 0, verified: !!x?.best_verified,
             rank: rk?.rank || null, points: rk?.points || 0 };
  }) : null;
  // v5.1 — one signature for all four: the message is offered once every game has been played at least once;
  // `signed` is true while the stored signature still covers the current four bests (a new best → sign again)
  let signMessage = null, signed = false;
  if (me && me.every(m => m.attemptsUsed > 0)) {
    signMessage = exaSignMessage(tr.id, wallet, me);
    signed = me.every(m => m.bestScore === 0 || m.verified);
  }
  return { subs, points: EXA_POINTS, me, signMessage, signed };
}
const exaSignMessage = (id, wallet, me) => `exl:exa:${id}:${wallet}:` + EXA_SUBS.map(s => `${s}=${me.find(m => m.sub === s)?.bestScore || 0}`).join(':');

// v5.1 — POST /exa/sign { tournamentId, wallet, signature }: ed25519 over the four-best message → all four scores verified at once.
async function handleExaSign(env, body) {
  await ensureSchema(env);
  const { tournamentId, wallet, signature } = body || {};
  if (!tournamentId || !wallet || !signature) return bad('tournamentId, wallet, signature required');
  const tr = await env.DB.prepare(`SELECT * FROM tournaments WHERE id=?`).bind(tournamentId).first();
  if (!tr || !isExa(tr)) return bad('not an EXathlon tournament', 404);
  const entry = await env.DB.prepare(`SELECT id FROM entries WHERE tournament_id=? AND wallet=?`).bind(tr.id, wallet).first();
  if (!entry) return bad('no entry for this wallet', 404);
  const board = await exaBoard(env, tr, wallet);
  if (!board.signMessage) return bad('play all four games first');
  const ok = await verifyScoreSignature(wallet, board.signMessage, signature);
  if (!ok) return J({ ok: true, verified: false, signatureValid: false, message: board.signMessage });
  await env.DB.prepare(`UPDATE exa_scores SET best_verified=1 WHERE tournament_id=? AND wallet=? AND best_score>0`).bind(tr.id, wallet).run();
  await env.DB.prepare(`INSERT OR REPLACE INTO exa_sigs (tournament_id, wallet, message, sig, signed_at) VALUES (?,?,?,?,?)`).bind(tr.id, wallet, board.signMessage, signature, now()).run();
  await exaRecompute(env, tr.id);
  return J({ ok: true, verified: true, signatureValid: true, message: board.signMessage });
}

async function handleLeaderboard(env, url) {
  const id = url.searchParams.get('tournamentId');
  const top = Math.min(Number(url.searchParams.get('top') || 50), 100);
  const wallet = url.searchParams.get('wallet');
  if (!id) return bad('tournamentId required');
  const tr = await env.DB.prepare(`SELECT currency FROM tournaments WHERE id=?`).bind(id).first();
  const rows = (await env.DB.prepare(
    `SELECT wallet, best_score, best_at, best_verified FROM entries
      WHERE tournament_id=? AND best_score>0 ORDER BY best_score DESC, best_at ASC LIMIT ?`
  ).bind(id, top).all()).results;
  let myRank = null;
  if (wallet) {
    const me = await env.DB.prepare(`SELECT best_score, best_at FROM entries WHERE tournament_id=? AND wallet=?`).bind(id, wallet).first();
    if (me && me.best_score > 0) {
      const r = await env.DB.prepare(
        `SELECT COUNT(*) c FROM entries WHERE tournament_id=? AND best_score>0 AND (best_score > ? OR (best_score = ? AND best_at < ?))`
      ).bind(id, me.best_score, me.best_score, me.best_at).first();
      myRank = { rank: r.c + 1, bestScore: me.best_score };
    }
  }
  const payouts = (await env.DB.prepare(`SELECT rank, wallet, lamports, tx_sig FROM payouts WHERE tournament_id=? AND rank>0 ORDER BY rank`).bind(id).all()).results;
  return J({
    currency: tr?.currency || 'SOL',
    leaderboard: rows.map((r, i) => ({ rank: i + 1, wallet: r.wallet, score: r.best_score, verified: !!r.best_verified })),
    myRank, payouts,
  });
}

// ---- /proof — everything needed to audit one tournament ----
async function handleProof(env, url) {
  const id = url.searchParams.get('tournamentId');
  if (!id) return bad('tournamentId required');
  const tr = await env.DB.prepare(`SELECT * FROM tournaments WHERE id=?`).bind(id).first();
  if (!tr) return bad('Unknown tournament', 404);
  const duel = isDuel(tr) ? await env.DB.prepare(`SELECT * FROM duels WHERE id=?`).bind(id).first() : null;
  const entries = (await env.DB.prepare(
    `SELECT wallet, pay_tx, paid_lamports, joined_at, attempts_used, best_score, best_at, best_verified
       FROM entries WHERE tournament_id=? ORDER BY best_score DESC, best_at ASC`
  ).bind(id).all()).results;
  const payouts = (await env.DB.prepare(`SELECT rank, wallet, lamports, tx_sig, paid_at FROM payouts WHERE tournament_id=? ORDER BY rank`).bind(id).all()).results;
  const pool = entries.reduce((a, e) => a + e.paid_lamports, 0);
  const seed = await seedFor(env, id);
  let rank = 0;
  return J({
    tournament: { id, game: tr.game, type: tr.type, currency: tr.currency || 'SOL', startsAt: tr.starts_at, endsAt: tr.ends_at,
                  feeAmount: tr.fee_lamports, feePct: feePctFor(tr), status: tr.status, attemptsMax: maxAttemptsFor(tr) },
    duel: duel ? { code: id.split(':')[2], maxPlayers: duel.max_players, joinEndsAt: duel.join_ends_at, liveAt: duel.live_at, playMs: duel.play_ms,
                   dist: duel.dist, distLabel: DUEL_DIST[duel.dist], visibility: duel.visibility, createdBy: duel.created_by,
                   weights: duelWeights(duel.dist, Math.max(1, entries.filter(e => e.best_score > 0).length)) } : null,
    // The seed itself is revealed once the tournament is settled; before that only its SHA-256 commitment is public.
    seed: tr.status === 'paid' || tr.status === 'cancelled' ? seed : null,
    seedCommitment: await sha256hex(seed),
    exa: isExa(tr) ? { ...(await exaBoard(env, tr, null)), subSeeds: tr.status === 'paid' || tr.status === 'cancelled' ? Object.fromEntries(await Promise.all(EXA_SUBS.map(async x => [x, await seedFor(env, id + ':' + x)]))) : null,
                        signatures: (await env.DB.prepare(`SELECT wallet, message, sig, signed_at FROM exa_sigs WHERE tournament_id=?`).bind(id).all()).results.map(x => ({ wallet: x.wallet, message: x.message, signature: x.sig, signedAt: x.signed_at })) } : null,   // v5 · v5.1 signatures
    poolAddress: env.POOL_ADDRESS,
    pool, participants: entries.length,
    ranking: entries.map(e => ({
      rank: e.best_score > 0 ? ++rank : null, wallet: e.wallet, score: e.best_score, verified: !!e.best_verified,
      attemptsUsed: e.attempts_used, entryTx: e.pay_tx, joinedAt: e.joined_at,
    })),
    payouts: payouts.map(p => ({
      rank: p.rank, role: p.rank === 0 ? 'service_fee' : (p.rank === -3 ? 'withdraw' : (p.rank < 0 ? 'refund' : 'prize')), wallet: p.wallet, amount: p.lamports, txSig: p.tx_sig, paidAt: p.paid_at,
      explorer: p.tx_sig && p.tx_sig !== 'DRY_RUN' ? `https://solscan.io/tx/${p.tx_sig}` : null,
    })),
    rules: isExa(tr)
      ? 'EXathlon rules: four games, one entry; every sub-game has its own server seed (same for everyone) and its own attempts; each sub-game ranking awards F1 points 25-18-15-12-10-8-6-4-2-1; total points rank the board; ties → fewer total rank places, then the earlier finish; flagged scores never rank; no valid score → every entry refunded; the payout transaction fee is deducted from the service fee, never from prizes.'
      : duel
      ? 'Room rules: one attempt each, same seed for everyone, the playing clock starts for all players at once; ties split the prize equally; flagged scores never rank; fewer than 2 players or no valid score → full refund minus the on-chain fee; the payout transaction fee is deducted from the service fee, never from prizes.'
      : 'Same server seed for every participant; ties → earlier submission wins; flagged scores never rank; no valid score in the period → every entry is refunded; the payout transaction fee is deducted from the service fee, never from prizes.',
  });
}

// ---- Settlement + payouts ----
async function accountExists(env, pubkey) {
  return !!(await rpc(env, 'getAccountInfo', [pubkey, { encoding: 'base64', commitment: 'confirmed' }])).result?.value;
}
function u64le(n) { const b = new Uint8Array(8); let x = BigInt(n); for (let i = 0; i < 8; i++) { b[i] = Number(x & 0xffn); x >>= 8n; } return b; }

async function buildPayoutIxs(env, kp, tr, transfers, memoSuffix = 'payout') {
  const ixs = [];
  if (tr.currency !== 'SKR') {
    for (const t of transfers) ixs.push(SystemProgram.transfer({ fromPubkey: kp.publicKey, toPubkey: new PublicKey(t.to), lamports: t.lamports }));
  } else {
    const mint = new PublicKey(env.SKR_MINT);
    const srcAta = ataFor(kp.publicKey, mint);
    for (const t of transfers) {
      const owner = new PublicKey(t.to);
      const dstAta = ataFor(owner, mint);
      if (!(await accountExists(env, dstAta.toBase58()))) {
        // CreateAssociatedTokenAccountIdempotent (ATA program instruction 1); rent paid from pool SOL
        ixs.push(new TransactionInstruction({
          programId: ATA_PROGRAM, data: Uint8Array.from([1]),
          keys: [
            { pubkey: kp.publicKey, isSigner: true, isWritable: true },
            { pubkey: dstAta, isSigner: false, isWritable: true },
            { pubkey: owner, isSigner: false, isWritable: false },
            { pubkey: mint, isSigner: false, isWritable: false },
            { pubkey: SystemProgram.programId, isSigner: false, isWritable: false },
            { pubkey: TOKEN_PROGRAM, isSigner: false, isWritable: false },
          ],
        }));
      }
      // TransferChecked (Token program instruction 12): [12, amount u64 LE, decimals u8]
      ixs.push(new TransactionInstruction({
        programId: TOKEN_PROGRAM,
        data: Uint8Array.from([12, ...u64le(t.lamports), SKR_DECIMALS]),
        keys: [
          { pubkey: srcAta, isSigner: false, isWritable: true },
          { pubkey: mint, isSigner: false, isWritable: false },
          { pubkey: dstAta, isSigner: false, isWritable: true },
          { pubkey: kp.publicKey, isSigner: true, isWritable: false },
        ],
      }));
    }
  }
  // Memo on every payout tx: anyone can see which tournament it settled
  ixs.push(new TransactionInstruction({
    programId: MEMO_PROGRAM, keys: [{ pubkey: kp.publicKey, isSigner: true, isWritable: false }],
    data: new TextEncoder().encode(`${tr.id}:${memoSuffix}`),
  }));
  return ixs;
}

// Signs + sends one payout/refund transaction from the pool wallet; returns the signature ('DRY_RUN' when simulating).
async function sendTransfers(env, tr, transfers, memoSuffix) {
  if (env.DRY_RUN === '1') return 'DRY_RUN';
  const kp = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(env.POOL_SECRET)));
  const blockhash = (await rpc(env, 'getLatestBlockhash', [{ commitment: 'confirmed' }])).result?.value?.blockhash;
  if (!blockhash) throw new Error('Failed to fetch blockhash for payout');
  const tx = new Transaction();
  tx.recentBlockhash = blockhash;
  tx.feePayer = kp.publicKey;
  for (const ix of await buildPayoutIxs(env, kp, tr, transfers, memoSuffix)) tx.add(ix);
  tx.sign(kp);
  let bin = ''; for (const b of tx.serialize()) bin += String.fromCharCode(b);
  const sendJson = await rpc(env, 'sendTransaction', [btoa(bin), { encoding: 'base64', preflightCommitment: 'confirmed' }]);
  if (sendJson.error) throw new Error('sendTransaction: ' + JSON.stringify(sendJson.error));
  if (!sendJson.result) throw new Error('sendTransaction returned no signature');
  return sendJson.result;
}

// ---- Duel lifecycle ----
async function duelGoLive(env, id, playMs) {
  const t = now();
  const r = await env.DB.prepare(`UPDATE tournaments SET status='live', starts_at=?, ends_at=? WHERE id=? AND status='open'`).bind(t, t + playMs, id).run();
  if (r.meta.changes) {
    await env.DB.prepare(`UPDATE duels SET live_at=? WHERE id=?`).bind(t, id).run();
    await tgBildir(env, `⚔️ DÜELLO BAŞLADI\n${id}\nSüre: ${Math.round(playMs / 60000)} dk`);
  }
  return !!r.meta.changes;
}

// Full refund to every entry (minus the on-chain tx fee, split evenly on SOL); tournament/room → cancelled.
async function refundAll(env, tr, reason) {
  const entries = (await env.DB.prepare(`SELECT wallet, paid_lamports FROM entries WHERE tournament_id=?`).bind(tr.id).all()).results;
  let sig = null;
  if (entries.length) {
    const per = tr.currency === 'SKR' ? 0 : Math.ceil(5000 / entries.length);
    const transfers = entries.map(e => ({ to: e.wallet, lamports: Math.max(0, e.paid_lamports - per), rank: -1 })).filter(t => t.lamports > 0);
    sig = await sendTransfers(env, tr, transfers, 'refund');
    for (const t of transfers) {
      await env.DB.prepare(`INSERT INTO payouts (tournament_id, rank, wallet, lamports, tx_sig, paid_at) VALUES (?,?,?,?,?,?)`)
        .bind(tr.id, -1, t.to, t.lamports, sig, now()).run();
    }
  }
  await env.DB.prepare(`UPDATE tournaments SET status='cancelled' WHERE id=?`).bind(tr.id).run();
  await tgBildir(env, `↩️ ${isDuel(tr) ? 'DÜELLO İPTAL' : 'TURNUVA İADE'} (${reason})\n${tr.id}\n${entries.length} iade · tx ${sig}`);
  return { id: tr.id, cancelled: reason, refunds: entries.length, sig };
}
const duelRefund = refundAll;

// v3.3 — refund a duplicate entry payment (same wallet, same tournament). Claims the pay_tx first (PRIMARY KEY) so it runs at most once.
async function refundDuplicate(env, tr, wallet, payTx) {
  try {
    await env.DB.prepare(`INSERT INTO dup_refunds (pay_tx, tournament_id, wallet, lamports, created_at) VALUES (?,?,?,?,?)`)
      .bind(payTx, tr.id, wallet, tr.fee_lamports, now()).run();
  } catch (_) { return null; } // already claimed/refunded
  const lamports = tr.currency === 'SKR' ? tr.fee_lamports : Math.max(0, tr.fee_lamports - 5000);
  if (lamports <= 0) return null;
  try {
    const sig = await sendTransfers(env, tr, [{ to: wallet, lamports, rank: -2 }], 'dup-refund');
    await env.DB.prepare(`UPDATE dup_refunds SET tx_sig=?, refunded_at=? WHERE pay_tx=?`).bind(sig, now(), payTx).run();
    await tgBildir(env, `↩️ ÇİFT ÖDEME İADESİ\n${tr.id}\nCüzdan: ${wallet.slice(0, 4)}…${wallet.slice(-4)}\n${fmtAmount(lamports, tr.currency)} · tx ${sig}`);
    return sig;
  } catch (e) {
    // leave the claim row without tx_sig so it can be settled by hand (scripts/LOCAL_SETTLE.md); never throw into /join
    await tgBildir(env, `⚠️ ÇİFT ÖDEME İADESİ BAŞARISIZ\n${tr.id}\n${wallet}\n${String(e).slice(0, 200)}`);
    return null;
  }
}

// Runs every cron tick: expire unpaid reservations, start or cancel rooms whose joining window closed.
async function duelTick(env) {
  const t = now();
  const report = [];
  const stale = (await env.DB.prepare(`SELECT id FROM tournaments WHERE type='x' AND status='pending' AND starts_at<?`).bind(t - DUEL_PENDING_MS).all()).results;
  for (const r of stale) {
    await env.DB.prepare(`DELETE FROM duels WHERE id=?`).bind(r.id).run();
    await env.DB.prepare(`DELETE FROM tournaments WHERE id=? AND status='pending'`).bind(r.id).run();
  }
  // v4: unpaid seat reservations expire; a seat whose room is still open and all other seats paid gets 2 extra minutes after a nudge
  await env.DB.prepare(`DELETE FROM seats WHERE room_id IN (SELECT id FROM tournaments WHERE status='open') AND reserved_at<? AND wallet NOT IN (SELECT wallet FROM entries e WHERE e.tournament_id=seats.room_id)`).bind(t - SEAT_TTL_MS).run();
  const closing = (await env.DB.prepare(
    `SELECT t.*, d.join_ends_at, d.play_ms, d.seat_mode FROM tournaments t JOIN duels d ON d.id=t.id WHERE t.type='x' AND t.status='open' AND d.join_ends_at<=?`
  ).bind(t).all()).results;
  for (const tr of closing) {
    const c = (await env.DB.prepare(`SELECT COUNT(*) c FROM entries WHERE tournament_id=?`).bind(tr.id).first()).c;
    try {
      if (tr.seat_mode) {
        // host never pressed START before the room expired → everyone gets their stake back (Berkay rule, 5 Oct)
        await env.DB.prepare(`UPDATE tournaments SET status='settling' WHERE id=?`).bind(tr.id).run();
        report.push(c ? await duelRefund(env, tr, 'room expired before start') : (await env.DB.prepare(`UPDATE tournaments SET status='cancelled' WHERE id=?`).bind(tr.id).run(), { id: tr.id, cancelled: 'empty room' }));
        continue;
      }
      if (c >= DUEL_PLAYERS.min) { await duelGoLive(env, tr.id, tr.play_ms); report.push({ id: tr.id, live: true, players: c }); }
      else {
        await env.DB.prepare(`UPDATE tournaments SET status='settling' WHERE id=?`).bind(tr.id).run();
        report.push(await duelRefund(env, tr, 'not enough players'));
      }
    } catch (e) {
      await env.DB.prepare(`UPDATE tournaments SET status='open' WHERE id=? AND status='settling'`).bind(tr.id).run();
      report.push({ id: tr.id, error: String(e) });
    }
  }
  return report;
}

async function settle(env) {
  const due = (await env.DB.prepare(
    `SELECT * FROM tournaments WHERE ((status='open' AND type<>'x') OR (status='live' AND type='x')) AND ends_at<=?`
  ).bind(now()).all()).results;
  const report = [];
  for (const tr of due) {
    const wasStatus = tr.status;
    // v4.2 — a run that STARTED before the clock ran out still counts: while an attempt is open (started, not yet
    // submitted) and the window closed less than RUN_GRACE_MS ago, settlement waits for the next tick.
    const inflight = await env.DB.prepare(
      `SELECT COUNT(*) c FROM attempts a JOIN entries e ON e.id=a.entry_id WHERE e.tournament_id=? AND a.submitted_at IS NULL AND a.started_at > ?`
    ).bind(tr.id, now() - RUN_GRACE_MS).first();
    if ((inflight?.c ?? 0) > 0 && now() - tr.ends_at < RUN_GRACE_MS) { report.push({ id: tr.id, deferred: 'run in progress' }); continue; }
    await env.DB.prepare(`UPDATE tournaments SET status='settling' WHERE id=?`).bind(tr.id).run();
    try {
      // IDEMPOTENCY GUARD: payouts already recorded → never pay twice
      const prior = await env.DB.prepare(`SELECT COUNT(*) c FROM payouts WHERE tournament_id=?`).bind(tr.id).first();
      if ((prior?.c ?? 0) > 0) {
        await env.DB.prepare(`UPDATE tournaments SET status='paid' WHERE id=?`).bind(tr.id).run();
        report.push({ id: tr.id, note: 'payouts already exist; marked paid (idempotency guard)' });
        continue;
      }
      const pool = (await env.DB.prepare(`SELECT COALESCE(SUM(paid_lamports),0) p FROM entries WHERE tournament_id=?`).bind(tr.id).first())?.p ?? 0;
      const ranked = (await env.DB.prepare(
        `SELECT wallet, best_score, best_at FROM entries WHERE tournament_id=? AND best_score>0 ORDER BY best_score DESC, best_at ASC LIMIT 10`
      ).bind(tr.id).all()).results;
      const duel = isDuel(tr) ? await env.DB.prepare(`SELECT * FROM duels WHERE id=?`).bind(tr.id).first() : null;

      if (ranked.length === 0 && pool > 0) {
        // No valid score (nobody played, or every score flagged/unsubmitted) → everyone gets their entry back
        // (minus the on-chain fee). Applies to duel rooms AND scheduled tournaments — the house never keeps
        // a pool it did not pay a prize from. (v3.2; before this, a scheduled pool with no ranked score went to the service wallet.)
        report.push(await refundAll(env, tr, 'no valid score'));
        continue;
      }
      if (pool > 0) {
        const isSkr = tr.currency === 'SKR';
        // SOL: the payout tx fee (5000 lamports) comes out of the service fee. SKR: fee is paid in SOL from the pool wallet's balance.
        const TX_FEE = isSkr ? 0 : 5000;
        let transfers;
        if (ranked.length > 0) {
          const payable = Math.floor(pool * (100 - feePctFor(tr)) / 100);
          let shares;
          if (duel) shares = duelShares(payable, duel.dist, ranked);
          else {
            const weights = WEIGHTS[tr.type].slice(0, ranked.length);
            const sumW = weights.reduce((a, b) => a + b, 0);
            shares = weights.map(w => Math.floor(payable * w / sumW));
          }
          const commission = Math.max(0, pool - shares.reduce((a, b) => a + b, 0) - TX_FEE);
          transfers = ranked.map((r, i) => ({ to: r.wallet, lamports: shares[i], rank: i + 1 }));
          transfers.push({ to: env.COMMISSION_ADDRESS, lamports: commission, rank: 0 });
        } else {
          transfers = [{ to: env.COMMISSION_ADDRESS, lamports: Math.max(0, pool - TX_FEE), rank: 0 }];
        }
        transfers = transfers.filter(t => t.lamports > 0);

        const sig = await sendTransfers(env, tr, transfers, 'payout');
        for (const t of transfers) {
          await env.DB.prepare(`INSERT INTO payouts (tournament_id, rank, wallet, lamports, tx_sig, paid_at) VALUES (?,?,?,?,?,?)`)
            .bind(tr.id, t.rank, t.to, t.lamports, sig, now()).run();
        }
        report.push({ id: tr.id, currency: tr.currency, pool, winners: ranked.length, sig });
        await tgBildir(env, `💰 ${duel ? 'DÜELLO' : 'TURNUVA'} KAPANDI\n${tr.id}\nHavuz: ${fmtAmount(pool, tr.currency)} · ${ranked.length} kazanan\nTx: ${sig}`);
        if (ranked.length > 0 && env.DRY_RUN !== '1' && !duel) {
          const oyun = OYUN_AD[tr.id.split(':')[0]] || tr.id.split(':')[0];
          const bir = transfers.find(x => x.rank === 1);
          const kz = ranked[0].wallet;
          await xTweet(env,
            `💰 ${oyun} ${TIP_AD[tr.type]}${isSkr ? ' (SKR)' : ''} champion!\n` +
            `${kz.slice(0, 4)}…${kz.slice(-4)} takes ${bir ? fmtAmount(bir.lamports, tr.currency) : ''} — paid on-chain ✅\n` +
            `solscan.io/tx/${sig}\n\n📲 Your turn: dApp Store → "${oyun}" by EXCOBALAB 👑\n#Solana #SolanaMobile #Seeker`);
        }
      } else {
        report.push({ id: tr.id, pool: 0, winners: 0, sig: null });
      }
      await env.DB.prepare(`UPDATE tournaments SET status='paid' WHERE id=?`).bind(tr.id).run();
    } catch (e) {
      await env.DB.prepare(`UPDATE tournaments SET status=? WHERE id=? AND status='settling'`).bind(wasStatus, tr.id).run(); // retry next tick
      report.push({ id: tr.id, error: String(e) });
    }
  }
  return report;
}

// ---- DUEL / ROOM API ----
function duelView(tr, duel, entries, wallet) {
  const scored = entries.filter(e => e.best_score > 0).length;
  const me = wallet ? entries.find(e => e.wallet === wallet) : null;
  return {
    id: tr.id, code: tr.id.split(':')[2], game: tr.game, currency: tr.currency, status: tr.status,
    stake: tr.fee_lamports, feePct: feePctFor(tr), pool: entries.reduce((a, e) => a + e.paid_lamports, 0),
    players: entries.length, maxPlayers: duel.max_players,
    joinEndsAt: duel.join_ends_at, liveAt: duel.live_at, joinMs: duel.join_ms, playMs: duel.play_ms, endsAt: tr.status === 'live' || tr.status === 'paid' ? tr.ends_at : null,
    dist: duel.dist, distLabel: DUEL_DIST[duel.dist], weights: duelWeights(duel.dist, Math.max(1, scored || Math.max(1, entries.length))),
    visibility: duel.visibility, createdBy: duel.created_by, createdAt: duel.created_at,
    entries: entries.map(e => ({ wallet: e.wallet, joinedAt: e.joined_at, played: e.attempts_used > 0, score: e.best_score, verified: !!e.best_verified })),
    me: me ? { attemptsUsed: me.attempts_used, attemptsMax: maxAttemptsFor(tr), bestScore: me.best_score,
               canWithdraw: ['open', 'pending'].includes(tr.status) && me.attempts_used === 0,
               withdraw: me.attempts_used === 0 ? withdrawQuote(tr, me.paid_lamports) : null } : null,   // v4.1
    // v4 seat mode
    seatMode: !!duel.seat_mode, host: duel.host || duel.created_by,
    hostPaid: entries.some(e => e.wallet === (duel.host || duel.created_by)),   // v4.3: public listing waits for this
    seats: (duel._seats || []).map(x => ({ wallet: x.wallet, paid: !!x.paid, reservedAt: x.reserved_at, paidAt: x.paid_at || null, isHost: x.wallet === (duel.host || duel.created_by),
                                           nudgedAt: x.nudged_at || null, nudgedBy: x.nudged_by || null })),
    unpaidSeats: (duel._seats || []).filter(x => !x.paid).length,
    canStart: !!duel.seat_mode && tr.status === 'open' && entries.length >= DUEL_PLAYERS.min && (duel._seats || []).every(x => x.paid),
    myNudge: (() => { const me2 = wallet ? (duel._seats || []).find(x => x.wallet === wallet) : null; return me2 && !me2.paid && me2.nudged_at && now() - me2.nudged_at < 120000 ? { by: me2.nudged_by, at: me2.nudged_at } : null; })(),
  };
}
// v4: merge paid entries and unpaid seat reservations into one seat list (host first, then by time)
async function duelSeats(env, id, duel, entries) {
  const res = (await env.DB.prepare(`SELECT wallet, reserved_at, nudged_at, nudged_by FROM seats WHERE room_id=? ORDER BY reserved_at ASC`).bind(id).all()).results;
  return duelSeatsFrom(duel, entries, res);
}
// v4.3 — batch loaders for /duel/list: one query per table for ALL listed rooms instead of one per room (N+1 → 3 queries).
async function duelEntriesMany(env, ids) {
  const out = new Map(ids.map(i => [i, []]));
  for (let i = 0; i < ids.length; i += 50) {   // SQLite bind limit safety
    const chunk = ids.slice(i, i + 50);
    const rows = (await env.DB.prepare(`SELECT tournament_id, wallet, joined_at, paid_lamports, attempts_used, best_score, best_verified FROM entries WHERE tournament_id IN (${chunk.map(() => '?').join(',')}) ORDER BY best_score DESC, best_at ASC, joined_at ASC`).bind(...chunk).all()).results;
    for (const r of rows) out.get(r.tournament_id).push(r);
  }
  return out;
}
async function duelSeatsMany(env, ids) {
  const out = new Map(ids.map(i => [i, []]));
  for (let i = 0; i < ids.length; i += 50) {
    const chunk = ids.slice(i, i + 50);
    const rows = (await env.DB.prepare(`SELECT room_id, wallet, reserved_at, nudged_at, nudged_by FROM seats WHERE room_id IN (${chunk.map(() => '?').join(',')}) ORDER BY reserved_at ASC`).bind(...chunk).all()).results;
    for (const r of rows) out.get(r.room_id).push(r);
  }
  return out;
}
function duelSeatsFrom(duel, entries, res) {
  const paid = new Map(entries.map(e => [e.wallet, e]));
  const out = [];
  for (const e of entries) { const r = res.find(x => x.wallet === e.wallet); out.push({ wallet: e.wallet, paid: true, paid_at: e.joined_at, reserved_at: r?.reserved_at ?? e.joined_at, nudged_at: null, nudged_by: null }); }
  for (const r of res) if (!paid.has(r.wallet)) out.push({ wallet: r.wallet, paid: false, paid_at: null, reserved_at: r.reserved_at, nudged_at: r.nudged_at, nudged_by: r.nudged_by });
  const host = duel.host || duel.created_by;
  out.sort((a, b) => (a.wallet === host ? -1 : b.wallet === host ? 1 : a.reserved_at - b.reserved_at));
  duel._seats = out;
  return out;
}
async function loadRoom(env, id) {
  const tr = await env.DB.prepare(`SELECT * FROM tournaments WHERE id=? AND type='x'`).bind(id).first();
  const duel = tr ? await env.DB.prepare(`SELECT * FROM duels WHERE id=?`).bind(id).first() : null;
  if (!tr || !duel) return null;
  const entries = await duelEntries(env, id);
  if (duel.seat_mode) await duelSeats(env, id, duel, entries);
  return { tr, duel, entries };
}
async function duelEntries(env, id) {
  return (await env.DB.prepare(`SELECT wallet, joined_at, paid_lamports, attempts_used, best_score, best_verified FROM entries WHERE tournament_id=? ORDER BY best_score DESC, best_at ASC, joined_at ASC`).bind(id).all()).results;
}

// POST /duel/create — reserves a room; the creator then pays the stake (memo = room id) and calls /join.
async function handleDuelCreate(env, body) {
  const { game, currency = 'SOL', stake, players, joinMin, playMin, dist = 'wta', visibility = 'private', wallet } = body || {};
  if (!GAMES[game]) return bad('Unknown game');
  if (!wallet) return bad('wallet required');
  if (!['SOL', 'SKR'].includes(currency) || (currency === 'SKR' && !skrEnabled(env))) return bad('Unsupported currency');
  const st = Number(stake);
  if (!Number.isInteger(st) || st < DUEL_STAKE[currency].min || st > DUEL_STAKE[currency].max) return bad(`Stake out of range (${fmtAmount(DUEL_STAKE[currency].min, currency)} – ${fmtAmount(DUEL_STAKE[currency].max, currency)})`);
  const n = Number(players);
  if (!Number.isInteger(n) || n < DUEL_PLAYERS.min || n > DUEL_PLAYERS.max) return bad('players must be 2–10');
  if (!DUEL_WINDOWS_MIN.includes(Number(joinMin)) || !DUEL_WINDOWS_MIN.includes(Number(playMin))) return bad('joinMin/playMin must be one of ' + DUEL_WINDOWS_MIN.join(','));
  if (!DUEL_DIST[dist]) return bad('dist must be wta|top2|top3|half');
  if (!['public', 'private'].includes(visibility)) return bad('visibility must be public|private');
  if (dist === 'top2' && n < 2 || dist === 'top3' && n < 3) return bad('Distribution needs more players');

  const seatMode = body.seatMode === true || body.seatMode === 1;   // v4: room opens without payment; everyone pays from their own seat
  const t = now();
  let id = null;
  for (let i = 0; i < 5 && !id; i++) {
    const cand = `${game}:x:${duelCode()}`;
    try {
      await env.DB.prepare(`INSERT INTO tournaments (id, game, type, starts_at, ends_at, fee_lamports, currency, status) VALUES (?,?,?,?,?,?,?,?)`)
        .bind(cand, game, 'x', t, t + Number(joinMin) * 60000, st, currency, seatMode ? 'open' : 'pending').run();
      id = cand;
    } catch (_) { /* code collision → retry */ }
  }
  if (!id) return bad('Could not allocate a room code, try again', 500);
  await env.DB.prepare(`INSERT INTO duels (id, max_players, join_ms, play_ms, join_ends_at, dist, visibility, created_by, created_at, seat_mode, host) VALUES (?,?,?,?,?,?,?,?,?,?,?)`)
    .bind(id, n, Number(joinMin) * 60000, Number(playMin) * 60000, t + Number(joinMin) * 60000, dist, visibility, wallet, t, seatMode ? 1 : 0, wallet).run();
  if (seatMode && wallet !== 'new') await env.DB.prepare(`INSERT OR IGNORE INTO seats (room_id, wallet, reserved_at) VALUES (?,?,?)`).bind(id, wallet, t).run();
  // v4.2 — rematch: invited wallets get a reserved seat that lives until the room closes (not the 10-min TTL),
  // so the room appears in their YOUR ROOMS list straight away — nobody types a code.
  let invited = 0;
  if (seatMode && Array.isArray(body.inviteWallets)) {
    const keep = (t + Number(joinMin) * 60000) - SEAT_TTL_MS - 1000; // reserved_at such that the TTL sweep lets it live until join_ends_at
    for (const w of body.inviteWallets.slice(0, n - 1)) {
      if (typeof w !== 'string' || w === wallet || w.length < 32) continue;
      const r = await env.DB.prepare(`INSERT OR IGNORE INTO seats (room_id, wallet, reserved_at, nudged_by) VALUES (?,?,?,?)`).bind(id, w, Math.max(t, keep), 'invite').run();
      invited += r.meta.changes;
    }
  }
  return J({
    ok: true, id, code: id.split(':')[2], memo: id, stake: st, currency, poolAddress: env.POOL_ADDRESS,
    skr: currency === 'SKR' ? { mint: env.SKR_MINT, decimals: SKR_DECIMALS, poolTokenAccount: ataFor(env.POOL_ADDRESS, env.SKR_MINT).toBase58() } : null,
    expiresAt: seatMode ? t + Number(joinMin) * 60000 : t + DUEL_PENDING_MS, feePct: DUEL_FEE_PCT[currency], seatMode, invited,
  });
}

// GET /duel/list?game=&wallet= — public rooms open for joining + the caller's own rooms (open/live/recently finished)
// v4.3: a public room is listed only once its host has paid — empty rooms never crowd the list.
async function handleDuelList(env, url) {
  const game = url.searchParams.get('game');
  const wallet = url.searchParams.get('wallet');
  const t = now();
  const pub = (await env.DB.prepare(
    `SELECT t.*, d.* FROM tournaments t JOIN duels d ON d.id=t.id
      WHERE t.type='x' AND t.status='open' AND d.visibility='public' AND d.join_ends_at>? ${game ? 'AND t.game=?' : ''}
        AND EXISTS (SELECT 1 FROM entries e WHERE e.tournament_id=t.id AND e.wallet=COALESCE(d.host, d.created_by))
      ORDER BY d.join_ends_at ASC LIMIT 50`
  ).bind(...(game ? [t, game] : [t])).all()).results;
  const out = { public: [], mine: [], past: [] };
  // v4.3 — one entries query + one seats query for the whole page (was 2 queries per room)
  const view = async (rows) => {
    const ids = rows.map(r => r.id);
    const ens = await duelEntriesMany(env, ids);
    const seatIds = rows.filter(r => r.seat_mode).map(r => r.id);
    const seats = seatIds.length ? await duelSeatsMany(env, seatIds) : new Map();
    return rows.map(r => { const en = ens.get(r.id) || []; if (r.seat_mode) duelSeatsFrom(r, en, seats.get(r.id) || []); return { r, en, v: duelView(r, r, en, wallet) }; });
  };
  for (const x of await view(pub)) out.public.push(x.v);
  if (wallet) {
    const mine = (await env.DB.prepare(
      `SELECT t.*, d.* FROM tournaments t JOIN duels d ON d.id=t.id
        WHERE t.type='x' AND (t.status IN ('open','live','settling') OR (t.status IN ('paid','cancelled') AND t.ends_at>?)) ${game ? 'AND t.game=?' : ''}
          AND (EXISTS (SELECT 1 FROM entries e WHERE e.tournament_id=t.id AND e.wallet=?) OR EXISTS (SELECT 1 FROM seats s WHERE s.room_id=t.id AND s.wallet=?) OR d.host=?)
        ORDER BY t.ends_at DESC LIMIT 30`
    ).bind(...(game ? [t - 7 * 86400_000, game, wallet, wallet, wallet] : [t - 7 * 86400_000, wallet, wallet, wallet])).all()).results;
    for (const x of await view(mine)) out.mine.push(x.v);
    // v4.2 — room history (rematch source): finished rooms of the last 30 days the wallet took part in or hosted
    const past = (await env.DB.prepare(
      `SELECT t.*, d.* FROM tournaments t JOIN duels d ON d.id=t.id
        WHERE t.type='x' AND t.status IN ('paid','cancelled') AND t.ends_at>? ${game ? 'AND t.game=?' : ''}
          AND (EXISTS (SELECT 1 FROM entries e WHERE e.tournament_id=t.id AND e.wallet=?) OR d.host=? OR d.created_by=?)
        ORDER BY t.ends_at DESC LIMIT 20`
    ).bind(...(game ? [t - 30 * 86400_000, game, wallet, wallet, wallet] : [t - 30 * 86400_000, wallet, wallet, wallet])).all()).results;
    out.past = [];
    if (past.length) {
      const pids = past.map(r => r.id);
      const pays = (await env.DB.prepare(`SELECT tournament_id, rank, wallet, lamports FROM payouts WHERE rank>0 AND tournament_id IN (${pids.map(() => '?').join(',')}) ORDER BY rank`).bind(...pids).all()).results;
      for (const x of await view(past)) {
        const pay = pays.filter(p => p.tournament_id === x.r.id);
        x.v.winner = pay[0]?.wallet || null; x.v.myPrize = pay.find(p => p.wallet === wallet)?.lamports || 0;
        x.v.participants = x.en.map(e => e.wallet);
        out.past.push(x.v);
      }
    }
  }
  out.public = out.public.filter(v => (v.seatMode ? v.seats.length : v.players) < v.maxPlayers);
  return J({ ...out, prices: await getPrices(env), limits: { stake: DUEL_STAKE, players: DUEL_PLAYERS, windowsMin: DUEL_WINDOWS_MIN, dist: DUEL_DIST, feePct: DUEL_FEE_PCT },
             poolAddress: env.POOL_ADDRESS,
             skr: skrEnabled(env) ? { mint: env.SKR_MINT, decimals: SKR_DECIMALS, poolTokenAccount: ataFor(env.POOL_ADDRESS, env.SKR_MINT).toBase58() } : null });
}

// GET /duel/get?id=<game:x:CODE>  or  ?game=&code=  — one room, with entries, live scores and payouts
async function handleDuelGet(env, url) {
  let id = url.searchParams.get('id');
  const code = url.searchParams.get('code'), game = url.searchParams.get('game');
  if (!id && code && game) id = `${game}:x:${String(code).toUpperCase().trim()}`;
  if (!id) return bad('id or game+code required');
  const room = await loadRoom(env, id);
  if (!room) return bad('Room not found', 404);
  const { tr, duel, entries } = room;
  const wallet = url.searchParams.get('wallet');
  const payouts = (await env.DB.prepare(`SELECT rank, wallet, lamports, tx_sig, paid_at FROM payouts WHERE tournament_id=? ORDER BY rank`).bind(id).all()).results;
  return J({
    ...duelView(tr, duel, entries, wallet), now: now(), prices: await getPrices(env),
    exa: isExa(tr) ? await exaBoard(env, tr, wallet) : null,   // v5
    payouts: payouts.map(p => ({ rank: p.rank, role: p.rank === 0 ? 'service_fee' : (p.rank === -3 ? 'withdraw' : (p.rank < 0 ? 'refund' : 'prize')), wallet: p.wallet, amount: p.lamports, txSig: p.tx_sig,
                                 explorer: p.tx_sig && p.tx_sig !== 'DRY_RUN' ? `https://solscan.io/tx/${p.tx_sig}` : null })),
    poolAddress: env.POOL_ADDRESS,
    skr: tr.currency === 'SKR' ? { mint: env.SKR_MINT, decimals: SKR_DECIMALS, poolTokenAccount: ataFor(env.POOL_ADDRESS, env.SKR_MINT).toBase58() } : null,
  });
}

// ---- v4 seat mode handlers ----
async function roomOrErr(env, id) {
  const room = await loadRoom(env, id);
  if (!room) return { err: bad('Room not found', 404) };
  if (!room.duel.seat_mode) return { err: bad('This room does not use seats', 400) };
  return room;
}
function roomJson(env, room, wallet) { return J({ ...duelView(room.tr, room.duel, room.entries, wallet), now: now() }); }

// POST /duel/seat {id, wallet} — take a free seat without paying
async function handleDuelSeat(env, body) {
  const { id, wallet } = body || {};
  if (!id || !wallet) return bad('id, wallet required');
  const room = await roomOrErr(env, id); if (room.err) return room.err;
  const { tr, duel } = room;
  if (tr.status !== 'open' || duel.join_ends_at <= now()) return bad('Room is not open', 409);
  if (!duel._seats.find(x => x.wallet === wallet)) {
    if (duel._seats.length >= duel.max_players) return bad('Room is full', 409);
    await env.DB.prepare(`INSERT OR IGNORE INTO seats (room_id, wallet, reserved_at) VALUES (?,?,?)`).bind(id, wallet, now()).run();
  }
  return roomJson(env, await loadRoom(env, id), wallet);
}
// POST /duel/leave {id, wallet} — give up an UNPAID seat (paid players withdraw in a later version)
async function handleDuelLeave(env, body) {
  const { id, wallet } = body || {};
  if (!id || !wallet) return bad('id, wallet required');
  const room = await roomOrErr(env, id); if (room.err) return room.err;
  if (room.entries.find(e => e.wallet === wallet)) return bad('You already paid — a paid seat cannot be left here', 409);
  await env.DB.prepare(`DELETE FROM seats WHERE room_id=? AND wallet=?`).bind(id, wallet).run();
  const host = room.duel.host || room.duel.created_by;
  if (host === wallet) {
    // host left without paying → host passes to the earliest paid player, else the earliest seat
    const next = room.entries[0]?.wallet || room.duel._seats.find(x => x.wallet !== wallet)?.wallet || null;
    if (next) await env.DB.prepare(`UPDATE duels SET host=? WHERE id=?`).bind(next, id).run();
  }
  const fresh = await loadRoom(env, id);
  if (fresh.duel._seats.length === 0 && fresh.entries.length === 0) {
    // empty room → close it quietly
    await env.DB.prepare(`UPDATE tournaments SET status='cancelled' WHERE id=? AND status='open'`).bind(id).run();
  }
  return roomJson(env, await loadRoom(env, id), wallet);
}
// POST /duel/kick {id, wallet(host), to} — host removes an UNPAID seat
async function handleDuelKick(env, body) {
  const { id, wallet, to } = body || {};
  if (!id || !wallet || !to) return bad('id, wallet, to required');
  const room = await roomOrErr(env, id); if (room.err) return room.err;
  if ((room.duel.host || room.duel.created_by) !== wallet) return bad('Only the host can do that', 403);
  if (room.entries.find(e => e.wallet === to)) return bad('That player already paid', 409);
  await env.DB.prepare(`DELETE FROM seats WHERE room_id=? AND wallet=?`).bind(id, to).run();
  return roomJson(env, await loadRoom(env, id), wallet);
}
// POST /duel/nudge {id, from, to} — poke an unpaid seat (shown on the target's screen on its next refresh)
async function handleDuelNudge(env, body) {
  const { id, from, to } = body || {};
  if (!id || !from || !to) return bad('id, from, to required');
  const room = await roomOrErr(env, id); if (room.err) return room.err;
  const seat = room.duel._seats.find(x => x.wallet === to);
  if (!seat) return bad('No such seat', 404);
  if (seat.paid) return bad('That player already paid', 409);
  if (!room.duel._seats.find(x => x.wallet === from)) return bad('Take a seat first', 403);
  if (seat.nudged_at && now() - seat.nudged_at < NUDGE_COOLDOWN_MS) return bad('Already nudged a moment ago', 429);
  await env.DB.prepare(`UPDATE seats SET nudged_at=?, nudged_by=? WHERE room_id=? AND wallet=?`).bind(now(), from, id, to).run();
  return roomJson(env, await loadRoom(env, id), from);
}
// POST /duel/transfer {id, wallet(host), to} — hand the host role to another seated player (payments stay personal)
async function handleDuelTransfer(env, body) {
  const { id, wallet, to } = body || {};
  if (!id || !wallet || !to) return bad('id, wallet, to required');
  const room = await roomOrErr(env, id); if (room.err) return room.err;
  if ((room.duel.host || room.duel.created_by) !== wallet) return bad('Only the host can do that', 403);
  if (!room.duel._seats.find(x => x.wallet === to)) return bad('That wallet is not in the room', 404);
  await env.DB.prepare(`UPDATE duels SET host=? WHERE id=?`).bind(to, id).run();
  await tgBildir(env, `👑 ODA SAHİPLİĞİ DEVRİ\n${id}\n${wallet.slice(0, 4)}… → ${to.slice(0, 4)}…`);
  return roomJson(env, await loadRoom(env, id), wallet);
}
// POST /duel/start {id, wallet(host)} — every seat paid and ≥2 players → room goes live
async function handleDuelStart(env, body) {
  const { id, wallet } = body || {};
  if (!id || !wallet) return bad('id, wallet required');
  const room = await roomOrErr(env, id); if (room.err) return room.err;
  const { tr, duel, entries } = room;
  if ((duel.host || duel.created_by) !== wallet) return bad('Only the host can start the room', 403);
  if (tr.status !== 'open') return bad('Room is not open', 409);
  if (entries.length < DUEL_PLAYERS.min) return bad('At least 2 paid players are needed', 409);
  const unpaid = duel._seats.filter(x => !x.paid);
  if (unpaid.length) return bad(`${unpaid.length} seat(s) not paid yet — nudge or remove them`, 409);
  await duelGoLive(env, id, duel.play_ms);
  await env.DB.prepare(`UPDATE duels SET started_by=? WHERE id=?`).bind(wallet, id).run();
  return roomJson(env, await loadRoom(env, id), wallet);
}

// POST /duel/cancel {id, wallet(host)} — v4.3: the host closes a room that has not started (wrong settings, nobody came).
// Every paid stake goes straight back on-chain in full (SOL: minus the shared network fee), the room becomes 'cancelled'
// and leaves every list. Claim-first: two taps can never refund twice; on failure the status is restored so the host can retry.
async function handleDuelCancel(env, body) {
  const { id, wallet } = body || {};
  if (!id || !wallet) return bad('id, wallet required');
  const room = await loadRoom(env, id);
  if (!room) return bad('Room not found', 404);
  const { tr, duel } = room;
  if ((duel.host || duel.created_by) !== wallet) return bad('Only the host can close the room', 403);
  if (!['open', 'pending'].includes(tr.status)) return bad('Room already started', 409);
  const claim = await env.DB.prepare(`UPDATE tournaments SET status='settling' WHERE id=? AND status IN ('open','pending')`).bind(id).run();
  if (!claim.meta.changes) return bad('Room already closed', 409);
  try {
    const r = await refundAll(env, tr, 'host closed the room');
    return J({ ok: true, ...r });
  } catch (e) {
    await env.DB.prepare(`UPDATE tournaments SET status=? WHERE id=? AND status='settling'`).bind(tr.status, id).run();
    return bad('Refund failed — try again: ' + String(e).slice(0, 120), 500);
  }
}

// ---- v4.1 WITHDRAW — "cautious by design": a paid entry can be taken back until the player has played ----
// Duel room: until the host starts it (status open/pending). Scheduled tournament: while it is open and no attempt was used.
// Refund = stake − service fee (feePct of the pool share) − network fee (5000 lamports on SOL; SKR pays the SOL fee from the pool wallet).
// No balance is ever held for the player: the refund goes straight back on-chain in the same call.
const WITHDRAW_TX_FEE = 5000;
// v4.1.1 — self-healing schema: `withdrawals` is created on first use, so a missed `wrangler d1 migrations apply`
// can never turn a withdrawal into a lost entry (6 Oct incident: table missing → INSERT threw after the entry row was deleted).
let _schemaOk = false;
async function ensureSchema(env) {
  if (_schemaOk) return;
  await env.DB.prepare(`CREATE TABLE IF NOT EXISTS withdrawals (pay_tx TEXT PRIMARY KEY, tournament_id TEXT NOT NULL, wallet TEXT NOT NULL, paid_lamports INTEGER NOT NULL, refund_lamports INTEGER NOT NULL, fee_lamports INTEGER NOT NULL, tx_sig TEXT, created_at INTEGER NOT NULL, refunded_at INTEGER)`).run();
  await env.DB.prepare(`CREATE INDEX IF NOT EXISTS idx_withdrawals_wallet ON withdrawals(wallet, created_at DESC)`).run();
  // v5 — EXathlon per-sub-game scores + which sub an attempt token belongs to
  await env.DB.prepare(`CREATE TABLE IF NOT EXISTS exa_scores (tournament_id TEXT NOT NULL, wallet TEXT NOT NULL, sub TEXT NOT NULL, attempts_used INTEGER NOT NULL DEFAULT 0, best_score INTEGER NOT NULL DEFAULT 0, best_at INTEGER, best_verified INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (tournament_id, wallet, sub))`).run();
  await env.DB.prepare(`CREATE TABLE IF NOT EXISTS exa_attempts (token TEXT PRIMARY KEY, sub TEXT NOT NULL)`).run();
  // v5.1 — one signature per wallet covering its four best scores (the message it signed is stored for the proof page)
  await env.DB.prepare(`CREATE TABLE IF NOT EXISTS exa_sigs (tournament_id TEXT NOT NULL, wallet TEXT NOT NULL, message TEXT NOT NULL, sig TEXT NOT NULL, signed_at INTEGER NOT NULL, PRIMARY KEY (tournament_id, wallet))`).run();
  _schemaOk = true;
}
async function handleWithdraw(env, body) {
  const { tournamentId, wallet } = body || {};
  if (!tournamentId || !wallet) return bad('tournamentId, wallet required');
  const tr = await env.DB.prepare(`SELECT * FROM tournaments WHERE id=?`).bind(tournamentId).first();
  if (!tr) return bad('Not found', 404);
  const duel = isDuel(tr) ? await env.DB.prepare(`SELECT * FROM duels WHERE id=?`).bind(tr.id).first() : null;
  if (duel) { if (!['open', 'pending'].includes(tr.status)) return bad(tr.status === 'live' ? 'The room already started — no withdrawal once live' : 'Room is closed', 409); }
  else if (tr.status !== 'open' || tr.ends_at <= now()) return bad('Tournament is closed', 409);
  const entry = await env.DB.prepare(`SELECT * FROM entries WHERE tournament_id=? AND wallet=?`).bind(tr.id, wallet).first();
  if (!entry) return bad('No paid entry for this wallet', 404);
  if (entry.attempts_used > 0) return bad('You already played — the entry stays in', 409);

  const fee = Math.floor(entry.paid_lamports * feePctFor(tr) / 100);
  const netFee = tr.currency === 'SKR' ? 0 : WITHDRAW_TX_FEE;
  const refund = entry.paid_lamports - fee - netFee;
  if (refund <= 0) return bad('Nothing to refund', 409);

  await ensureSchema(env);
  // claim first: one withdrawal per payment (pay_tx is the PRIMARY KEY). Nothing else has changed yet if this fails.
  try {
    await env.DB.prepare(`INSERT INTO withdrawals (pay_tx, tournament_id, wallet, paid_lamports, refund_lamports, fee_lamports, created_at) VALUES (?,?,?,?,?,?,?)`)
      .bind(entry.pay_tx, tr.id, wallet, entry.paid_lamports, refund, fee, now()).run();
  } catch (e) {
    const prior = await env.DB.prepare(`SELECT tx_sig FROM withdrawals WHERE pay_tx=?`).bind(entry.pay_tx).first();
    if (prior) return bad(prior.tx_sig ? 'This entry was already withdrawn' : 'Withdrawal already in progress — refresh in a moment', 409);
    throw e;
  }
  // then the entry row disappears atomically (so /attempt/start, START and a second withdraw all fail from here on)
  const del = await env.DB.prepare(`DELETE FROM entries WHERE id=? AND attempts_used=0`).bind(entry.id).run();
  if (!del.meta.changes) { await env.DB.prepare(`DELETE FROM withdrawals WHERE pay_tx=?`).bind(entry.pay_tx).run(); return bad('Entry changed, try again', 409); }
  let sig;
  try {
    const transfers = [{ to: wallet, lamports: refund, rank: -3 }];
    if (fee > 0) transfers.push({ to: env.COMMISSION_ADDRESS, lamports: fee, rank: 0 });
    sig = await sendTransfers(env, tr, transfers, 'withdraw');
  } catch (e) {
    // ANY failure here → restore the entry exactly as it was; the player keeps their seat and can retry
    try {
      await env.DB.prepare(`INSERT OR IGNORE INTO entries (id, tournament_id, wallet, pay_tx, paid_lamports, joined_at, attempts_used, best_score, best_at, best_verified) VALUES (?,?,?,?,?,?,?,?,?,?)`)
        .bind(entry.id, entry.tournament_id, entry.wallet, entry.pay_tx, entry.paid_lamports, entry.joined_at, 0, entry.best_score, entry.best_at, entry.best_verified).run();
      await env.DB.prepare(`DELETE FROM withdrawals WHERE pay_tx=?`).bind(entry.pay_tx).run();
    } catch (e2) {
      await tgBildir(env, `🚨 ÇEKİM GERİ YÜKLEME BAŞARISIZ — ELLE MÜDAHALE\n${tr.id}\n${wallet}\npay_tx ${entry.pay_tx}\n${String(e2).slice(0, 200)}`);
    }
    await tgBildir(env, `⚠️ ÇEKİM BAŞARISIZ (entry geri yüklendi)\n${tr.id}\n${wallet}\n${String(e).slice(0, 200)}`);
    return bad('Refund transaction failed — your entry is untouched. Try again in a moment.', 502);
  }
  await env.DB.prepare(`UPDATE withdrawals SET tx_sig=?, refunded_at=? WHERE pay_tx=?`).bind(sig, now(), entry.pay_tx).run();
  await env.DB.prepare(`INSERT INTO payouts (tournament_id, rank, wallet, lamports, tx_sig, paid_at) VALUES (?,?,?,?,?,?)`).bind(tr.id, -3, wallet, refund, sig, now()).run();
  if (fee > 0) await env.DB.prepare(`INSERT INTO payouts (tournament_id, rank, wallet, lamports, tx_sig, paid_at) VALUES (?,?,?,?,?,?)`).bind(tr.id, 0, env.COMMISSION_ADDRESS, fee, sig, now()).run();
  if (duel) {
    // the seat is freed; if the host withdrew, the host role passes on; an empty room closes
    await env.DB.prepare(`DELETE FROM seats WHERE room_id=? AND wallet=?`).bind(tr.id, wallet).run();
    const left = await loadRoom(env, tr.id);
    if ((duel.host || duel.created_by) === wallet) {
      const next = left.entries[0]?.wallet || (left.duel._seats || []).find(x => x.wallet !== wallet)?.wallet || null;
      if (next) await env.DB.prepare(`UPDATE duels SET host=? WHERE id=?`).bind(next, tr.id).run();
    }
    if (left.entries.length === 0 && (left.duel._seats || []).length === 0) await env.DB.prepare(`UPDATE tournaments SET status='cancelled' WHERE id=? AND status IN ('open','pending')`).bind(tr.id).run();
  }
  await tgBildir(env, `↩️ ÇEKİM\n${tr.id}\nCüzdan: ${wallet.slice(0, 4)}…${wallet.slice(-4)}\nİade ${fmtAmount(refund, tr.currency)} · ücret ${fmtAmount(fee, tr.currency)} · tx ${sig}`);
  return J({ ok: true, refund, fee, networkFee: netFee, currency: tr.currency, tx: sig, explorer: sig === 'DRY_RUN' ? null : `https://solscan.io/tx/${sig}` });
}
// Preview of a withdrawal (no side effects) — the client shows this before asking for confirmation
function withdrawQuote(tr, paid) {
  const fee = Math.floor(paid * feePctFor(tr) / 100);
  const netFee = tr.currency === 'SKR' ? 0 : WITHDRAW_TX_FEE;
  return { paid, fee, networkFee: netFee, refund: Math.max(0, paid - fee - netFee), feePct: feePctFor(tr) };
}

// ---- v4.1 GET /wallet?wallet=… — "My Wallet": open items + history across ALL EXL games. No balance (nothing is held). ----
const TYPE_LABEL = { d: 'Daily', w: 'Weekly', m: 'Monthly', x: 'Duel room' };
async function handleWallet(env, url) {
  const wallet = url.searchParams.get('wallet');
  if (!wallet) return bad('wallet required');
  await ensureSchema(env);
  const t = now();
  const open = (await env.DB.prepare(
    `SELECT e.*, t.game, t.type, t.currency, t.status, t.ends_at, t.fee_lamports FROM entries e JOIN tournaments t ON t.id=e.tournament_id
      WHERE e.wallet=? AND t.status IN ('open','pending','live') ORDER BY t.ends_at ASC`).bind(wallet).all()).results;
  const items = [];
  for (const e of open) {
    const duel = e.type === 'x' ? await env.DB.prepare(`SELECT * FROM duels WHERE id=?`).bind(e.tournament_id).first() : null;
    const maxA = GAMES[e.game]?.attempts[e.type] ?? 1;
    const canPlay = e.attempts_used < maxA && (duel ? e.status === 'live' && e.ends_at > t : e.status === 'open' && e.ends_at > t);
    const canWithdraw = e.attempts_used === 0 && (duel ? ['open', 'pending'].includes(e.status) : e.status === 'open' && e.ends_at > t);
    items.push({
      id: e.tournament_id, game: e.game, gameName: OYUN_AD[e.game] || e.game, type: e.type, typeLabel: TYPE_LABEL[e.type], currency: e.currency || 'SOL',
      code: e.type === 'x' ? e.tournament_id.split(':')[2] : null, status: e.status, paid: e.paid_lamports, paidAt: e.joined_at, payTx: e.pay_tx,
      attemptsUsed: e.attempts_used, attemptsMax: maxA, bestScore: e.best_score,
      endsAt: duel && e.status !== 'live' ? duel.join_ends_at : e.ends_at, canPlay, canWithdraw,
      withdraw: canWithdraw ? withdrawQuote({ type: e.type, currency: e.currency }, e.paid_lamports) : null,
    });
  }
  // history: payments (entries incl. finished ones), prizes, refunds, withdrawals, duplicate refunds
  const hist = [];
  const paidRows = (await env.DB.prepare(
    `SELECT e.tournament_id, e.pay_tx, e.paid_lamports, e.joined_at, e.best_score, t.game, t.type, t.currency, t.status FROM entries e JOIN tournaments t ON t.id=e.tournament_id WHERE e.wallet=? ORDER BY e.joined_at DESC LIMIT 100`).bind(wallet).all()).results;
  for (const r of paidRows) hist.push({ kind: 'entry', id: r.tournament_id, game: r.game, gameName: OYUN_AD[r.game] || r.game, type: r.type, typeLabel: TYPE_LABEL[r.type], currency: r.currency || 'SOL', amount: -r.paid_lamports, at: r.joined_at, tx: r.pay_tx, status: r.status, bestScore: r.best_score });
  const wRows = (await env.DB.prepare(`SELECT w.*, t.game, t.type, t.currency FROM withdrawals w JOIN tournaments t ON t.id=w.tournament_id WHERE w.wallet=? ORDER BY w.created_at DESC LIMIT 100`).bind(wallet).all()).results;
  for (const r of wRows) {
    hist.push({ kind: 'entry', id: r.tournament_id, game: r.game, gameName: OYUN_AD[r.game] || r.game, type: r.type, typeLabel: TYPE_LABEL[r.type], currency: r.currency || 'SOL', amount: -r.paid_lamports, at: r.created_at - 1, tx: r.pay_tx, status: 'withdrawn' });
    hist.push({ kind: 'withdraw', id: r.tournament_id, game: r.game, gameName: OYUN_AD[r.game] || r.game, type: r.type, typeLabel: TYPE_LABEL[r.type], currency: r.currency || 'SOL', amount: r.refund_lamports, fee: r.fee_lamports, at: r.refunded_at || r.created_at, tx: r.tx_sig, pending: !r.tx_sig });
  }
  const pRows = (await env.DB.prepare(`SELECT p.*, t.game, t.type, t.currency FROM payouts p JOIN tournaments t ON t.id=p.tournament_id WHERE p.wallet=? AND p.rank<>0 AND p.rank<>-3 ORDER BY p.paid_at DESC LIMIT 100`).bind(wallet).all()).results;
  for (const r of pRows) hist.push({ kind: r.rank > 0 ? 'prize' : 'refund', rank: r.rank > 0 ? r.rank : null, id: r.tournament_id, game: r.game, gameName: OYUN_AD[r.game] || r.game, type: r.type, typeLabel: TYPE_LABEL[r.type], currency: r.currency || 'SOL', amount: r.lamports, at: r.paid_at, tx: r.tx_sig });
  const dRows = (await env.DB.prepare(`SELECT d.*, t.game, t.type, t.currency FROM dup_refunds d JOIN tournaments t ON t.id=d.tournament_id WHERE d.wallet=? ORDER BY d.created_at DESC LIMIT 50`).bind(wallet).all()).results;
  for (const r of dRows) hist.push({ kind: 'refund', note: 'duplicate payment', id: r.tournament_id, game: r.game, gameName: OYUN_AD[r.game] || r.game, type: r.type, typeLabel: TYPE_LABEL[r.type], currency: r.currency || 'SOL', amount: r.lamports, at: r.refunded_at || r.created_at, tx: r.tx_sig, pending: !r.tx_sig });
  hist.sort((a, b) => (b.at || 0) - (a.at || 0));
  return J({ wallet, open: items, history: hist.slice(0, 150), prices: await getPrices(env), now: t });
}

// ---- v4.1 GET /t/room?id=…&wallet=… — scheduled tournament as a "room": rules, players, my seat, payouts ----
async function handleTournamentRoom(env, url) {
  const id = url.searchParams.get('id'); const wallet = url.searchParams.get('wallet');
  if (!id) return bad('id required');
  const tr = await env.DB.prepare(`SELECT * FROM tournaments WHERE id=? AND type<>'x'`).bind(id).first();
  if (!tr) return bad('Tournament not found', 404);
  const entries = (await env.DB.prepare(`SELECT wallet, joined_at, paid_lamports, attempts_used, best_score, best_verified FROM entries WHERE tournament_id=? ORDER BY best_score DESC, best_at ASC, joined_at ASC`).bind(id).all()).results;
  const payouts = (await env.DB.prepare(`SELECT rank, wallet, lamports, tx_sig FROM payouts WHERE tournament_id=? AND rank<>0 ORDER BY rank`).bind(id).all()).results;
  const me = wallet ? entries.find(e => e.wallet === wallet) : null;
  const maxA = maxAttemptsFor(tr);
  const pool = entries.reduce((a, e) => a + e.paid_lamports, 0);
  const t = now();
  return J({
    id: tr.id, game: tr.game, type: tr.type, typeLabel: TYPE_LABEL[tr.type], currency: tr.currency || 'SOL', status: tr.status,
    exa: isExa(tr) ? await exaBoard(env, tr, wallet) : null,   // v5: per-game boards + my per-game attempts
    startsAt: tr.starts_at, endsAt: tr.ends_at, feeLamports: tr.fee_lamports, feePct: feePctFor(tr), attemptsMax: maxA,
    pool, players: entries.length, weights: WEIGHTS[tr.type],
    entries: entries.map(e => ({ wallet: e.wallet, joinedAt: e.joined_at, played: e.attempts_used > 0, attemptsUsed: e.attempts_used, score: e.best_score, verified: !!e.best_verified })),
    me: me ? { attemptsUsed: me.attempts_used, attemptsMax: maxA, bestScore: me.best_score, paid: me.paid_lamports,
               canPlay: tr.status === 'open' && tr.ends_at > t && me.attempts_used < maxA,
               canWithdraw: tr.status === 'open' && tr.ends_at > t && me.attempts_used === 0,
               withdraw: me.attempts_used === 0 ? withdrawQuote(tr, me.paid_lamports) : null } : null,
    payouts: payouts.map(p => ({ rank: p.rank, role: p.rank > 0 ? 'prize' : (p.rank === -3 ? 'withdraw' : 'refund'), wallet: p.wallet, amount: p.lamports, tx: p.tx_sig, explorer: p.tx_sig && p.tx_sig !== 'DRY_RUN' ? `https://solscan.io/tx/${p.tx_sig}` : null })),
    poolAddress: env.POOL_ADDRESS,
    skr: tr.currency === 'SKR' && skrEnabled(env) ? { mint: env.SKR_MINT, decimals: SKR_DECIMALS, poolTokenAccount: ataFor(env.POOL_ADDRESS, env.SKR_MINT).toBase58() } : null,
    prices: await getPrices(env), now: t,
  });
}

// ---- Router ----
export default {
  async fetch(req, env, ctx) {
    const url = new URL(req.url);
    if (req.method === 'OPTIONS') return J({});
    try {
      if (req.method === 'GET' && url.pathname === '/t') return await handleTournaments(env, url);
      if (req.method === 'POST' && url.pathname === '/join') return await handleJoin(env, await req.json());
      if (req.method === 'POST' && url.pathname === '/attempt/start') return await handleAttemptStart(env, await req.json());
      if (req.method === 'POST' && url.pathname === '/attempt/submit') {
        const res = await handleSubmit(env, await req.json());
        if (_settleSoon) { _settleSoon = false; ctx.waitUntil(settle(env).catch(() => {})); }
        return res;
      }
      if (req.method === 'GET' && url.pathname === '/leaderboard') return await handleLeaderboard(env, url);
      if (req.method === 'GET' && url.pathname === '/proof') return await handleProof(env, url);
      if (req.method === 'POST' && url.pathname === '/duel/create') return await handleDuelCreate(env, await req.json());
      if (req.method === 'GET' && url.pathname === '/duel/list') return await handleDuelList(env, url);
      if (req.method === 'GET' && url.pathname === '/duel/get') return await handleDuelGet(env, url);
      if (req.method === 'POST' && url.pathname === '/duel/seat') return await handleDuelSeat(env, await req.json());
      if (req.method === 'POST' && url.pathname === '/duel/leave') return await handleDuelLeave(env, await req.json());
      if (req.method === 'POST' && url.pathname === '/duel/kick') return await handleDuelKick(env, await req.json());
      if (req.method === 'POST' && url.pathname === '/duel/nudge') return await handleDuelNudge(env, await req.json());
      if (req.method === 'POST' && url.pathname === '/duel/transfer') return await handleDuelTransfer(env, await req.json());
      if (req.method === 'POST' && url.pathname === '/duel/start') return await handleDuelStart(env, await req.json());
      if (req.method === 'POST' && url.pathname === '/duel/cancel') return await handleDuelCancel(env, await req.json());   // v4.3
      if (req.method === 'POST' && url.pathname === '/exa/sign') return await handleExaSign(env, await req.json());   // v5.1
      if (req.method === 'POST' && url.pathname === '/withdraw') return await handleWithdraw(env, await req.json());      // v4.1
      if (req.method === 'GET' && url.pathname === '/wallet') return await handleWallet(env, url);                       // v4.1
      if (req.method === 'GET' && url.pathname === '/t/room') return await handleTournamentRoom(env, url);              // v4.1

      if (url.searchParams.get('key') === env.ADMIN_KEY) {
        if (url.pathname === '/admin/settle') return J({ duels: await duelTick(env), settle: await settle(env) });
        if (url.pathname === '/admin/diag') {
          let secretOk = false, secretLen = 0, secretErr = null;
          try { const a = JSON.parse(env.POOL_SECRET || ''); secretOk = Array.isArray(a); secretLen = a.length; } catch (e) { secretErr = String(e); }
          return J({ secretOk, secretLen, secretErr, dryRun: env.DRY_RUN, launchMode: env.LAUNCH_MODE, poolAddr: env.POOL_ADDRESS,
                     skr: skrEnabled(env) ? { mint: env.SKR_MINT, poolAta: ataFor(env.POOL_ADDRESS, env.SKR_MINT).toBase58() } : null });
        }
        if (url.pathname === '/admin/pool') {
          const bal = await rpc(env, 'getBalance', [env.POOL_ADDRESS]);
          let skr = null, skrErr = null;
          if (skrEnabled(env)) {
            // getAccountInfo(jsonParsed) is supported by every provider; getTokenAccountBalance is not.
            const j = await rpc(env, 'getAccountInfo', [ataFor(env.POOL_ADDRESS, env.SKR_MINT).toBase58(), { encoding: 'jsonParsed', commitment: 'confirmed' }]);
            skr = j.result?.value?.data?.parsed?.info?.tokenAmount?.uiAmountString ?? (j.result && !j.result.value ? 'no ATA yet' : null);
            skrErr = j.error?.message ?? null;
          }
          return J({ poolAddress: env.POOL_ADDRESS, balanceLamports: bal.result?.value ?? null, rpcError: bal.error?.message ?? null,
                     skr, skrError: skrErr, skrAta: skrEnabled(env) ? ataFor(env.POOL_ADDRESS, env.SKR_MINT).toBase58() : null });
        }
        if (url.pathname === '/admin/purgeall') {
          if (url.searchParams.get('confirm') !== 'yes') return bad('Add &confirm=yes to wipe ALL tournament data');
          for (const t of ['attempts', 'entries', 'payouts', 'tournaments']) await env.DB.prepare(`DELETE FROM ${t}`).run();
          return J({ purgedAll: true });
        }
        if (url.pathname === '/admin/purge') {
          const id = url.searchParams.get('id'); if (!id) return bad('id required');
          await env.DB.prepare(`DELETE FROM attempts WHERE entry_id IN (SELECT id FROM entries WHERE tournament_id=?)`).bind(id).run();
          await env.DB.prepare(`DELETE FROM entries WHERE tournament_id=?`).bind(id).run();
          await env.DB.prepare(`DELETE FROM payouts WHERE tournament_id=?`).bind(id).run();
          try { await env.DB.prepare(`DELETE FROM exa_scores WHERE tournament_id=?`).bind(id).run(); } catch (_) {}
          await env.DB.prepare(`DELETE FROM tournaments WHERE id=?`).bind(id).run();
          return J({ purged: id });
        }
        if (url.pathname === '/admin/end') {
          const id = url.searchParams.get('id'); if (!id) return bad('id required');
          const r = await env.DB.prepare(`UPDATE tournaments SET ends_at=? WHERE id=? AND status='open'`).bind(now() - 1000, id).run();
          return J({ ended: r.meta.changes, id });
        }
        if (url.pathname === '/admin/tweet') {
          const metin = url.searchParams.get('text'); if (!metin) return bad('text required');
          return J({ text: metin, x: await xTweet(env, metin) });
        }
        if (url.pathname === '/admin/tweetdigest') { await xGunlukOzet(env); return J({ ok: true }); }
        if (url.pathname === '/admin/refund') {
          // manual transfer from the pool wallet: &id=<tournamentId>&to=<wallet>&amount=<base units>&currency=SOL|SKR&note=…  (records payouts rank -3)
          const id = url.searchParams.get('id'), to = url.searchParams.get('to'), amount = Number(url.searchParams.get('amount')), cur = url.searchParams.get('currency') || 'SOL';
          if (!id || !to || !(amount > 0)) return bad('id, to, amount required');
          const sig = await sendTransfers(env, { id, currency: cur }, [{ to, lamports: Math.floor(amount), rank: -3 }], url.searchParams.get('note') || 'manual-refund');
          await env.DB.prepare(`INSERT INTO payouts (tournament_id, rank, wallet, lamports, tx_sig, paid_at) VALUES (?,?,?,?,?,?)`).bind(id, -3, to, Math.floor(amount), sig, now()).run();
          await tgBildir(env, `↩️ ELLE İADE\n${id}\n${to}\n${fmtAmount(Math.floor(amount), cur)} · tx ${sig}`);
          return J({ ok: true, id, to, amount: Math.floor(amount), currency: cur, tx: sig, explorer: sig === 'DRY_RUN' ? null : `https://solscan.io/tx/${sig}` });
        }
        if (url.pathname === '/admin/entries') {
          // list a wallet's entries + withdrawals (incident forensics)
          const w = url.searchParams.get('wallet'); if (!w) return bad('wallet required');
          await ensureSchema(env);
          const entries = (await env.DB.prepare(`SELECT * FROM entries WHERE wallet=? ORDER BY joined_at DESC LIMIT 50`).bind(w).all()).results;
          const withdrawals = (await env.DB.prepare(`SELECT * FROM withdrawals WHERE wallet=? ORDER BY created_at DESC LIMIT 50`).bind(w).all()).results;
          const payouts = (await env.DB.prepare(`SELECT * FROM payouts WHERE wallet=? ORDER BY paid_at DESC LIMIT 50`).bind(w).all()).results;
          return J({ wallet: w, entries, withdrawals, payouts });
        }
        if (url.pathname === '/admin/prices') { _priceCache = { at: 0, prices: null }; return J(await getPrices(env)); }
      }
      return bad('Not found', 404);
    } catch (e) {
      return bad('Server error: ' + String(e), 500);
    }
  },
  async scheduled(ev, env, ctx) {
    // Cron runs every 5 minutes (duel rooms): start/cancel rooms, then settle everything that ended.
    ctx.waitUntil((async () => { await duelTick(env); await settle(env); })());
    const d = new Date(ev.scheduledTime);
    if (d.getUTCHours() === 18 && d.getUTCMinutes() < 5) ctx.waitUntil(xGunlukOzet(env)); // 21:0x TR, once a day
  },
};
