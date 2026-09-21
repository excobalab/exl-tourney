// ============================================================================
// EXL TOURNAMENTS — Cloudflare Worker (API + cron settle)
// Tournament model v1 + hackathon additions (Sept 2026):
//   • SKR tournaments (SPL token entry fees + payouts)           [docs/SKR.md]
//   • wallet-signed scores (ed25519, "verified" badge)           [docs/ANTI_CHEAT.md]
//   • /proof endpoint (auditable tournament summary)             [docs/API.md]
// v2.0 (Oct 2026):
//   • DUEL / ROOM mode — player-created rooms, own stake & windows  [docs/DUELS.md]
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
                  stack: 'Sol Stack', tiles: 'Sol Tiles', dodge: 'Sol Dodge', bubble: 'Sol Bubble' };
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
      if (e) me = { attemptsUsed: e.attempts_used, attemptsMax: GAMES[r.game].attempts[r.type], bestScore: e.best_score };
    }
    out.push({
      id: r.id, type: r.type, currency: r.currency || 'SOL', endsAt: r.ends_at,
      feeLamports: r.fee_lamports, feeAmount: r.fee_lamports,   // base units of `currency`
      participants: agg.c, poolLamports: agg.pool, poolAmount: agg.pool, feePct: feePctFor(r),
      attemptsMax: GAMES[r.game].attempts[r.type], me,
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
    if (tr.status === 'pending') {
      // created_by may be the placeholder 'new' when the creator had no wallet linked yet — the first payer becomes the creator
      if (wallet && duel.created_by !== 'new' && wallet !== duel.created_by) return bad('Room is not open yet', 403);
    } else if (tr.status !== 'open' || duel.join_ends_at <= now()) return bad('Room is not open for joining');
    const cnt = (await env.DB.prepare(`SELECT COUNT(*) c FROM entries WHERE tournament_id=?`).bind(tr.id).first()).c;
    if (cnt >= duel.max_players) return bad('Room is full', 409);
  } else if (tr.status !== 'open' || tr.ends_at <= now()) return bad('Tournament is not open');

  const v = await verifyPayment(env, payTx, wallet || null, tr);
  if (v.err) return bad(v.err, 402);
  const payer = v.payer;
  if (duel && tr.status === 'pending') {
    if (duel.created_by === 'new') { await env.DB.prepare(`UPDATE duels SET created_by=? WHERE id=?`).bind(payer, tr.id).run(); duel.created_by = payer; }
    else if (payer !== duel.created_by) return bad('Room is not open yet', 403);
  }

  try {
    await env.DB.prepare(`INSERT INTO entries (tournament_id, wallet, pay_tx, paid_lamports, joined_at) VALUES (?,?,?,?,?)`)
      .bind(tournamentId, payer, payTx, tr.fee_lamports, now()).run();
  } catch (e) {
    const msg = String(e);
    if (msg.includes('pay_tx')) return bad('This payment was already used', 409);
    if (msg.includes('tournament_id')) return bad('Wallet already joined this tournament', 409);
    throw e;
  }
  const agg = await env.DB.prepare(`SELECT COUNT(*) c, COALESCE(SUM(paid_lamports),0) p FROM entries WHERE tournament_id=?`).bind(tournamentId).first();
  let roomStatus = tr.status;
  if (duel) {
    if (tr.status === 'pending') { await env.DB.prepare(`UPDATE tournaments SET status='open' WHERE id=?`).bind(tr.id).run(); roomStatus = 'open'; }
    if (agg.c >= duel.max_players) { await duelGoLive(env, tr.id, duel.play_ms); roomStatus = 'live'; }
  }
  await tgBildir(env,
    `🏆 YENİ KATILIM\n${tournamentId}\nCüzdan: ${payer.slice(0, 4)}…${payer.slice(-4)}\n` +
    `Ücret: ${fmtAmount(tr.fee_lamports, tr.currency)}\nToplam: ${agg.c} katılımcı · havuz ${fmtAmount(agg.p, tr.currency)}`);
  return J({ ok: true, wallet: payer, attemptsMax: GAMES[tr.game].attempts[tr.type], status: roomStatus });
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
  const maxA = GAMES[tr.game].attempts[tr.type];
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
  const cfg = GAMES[tr.game];

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
  if (!flagged && score > entry.best_score) {
    await env.DB.prepare(`UPDATE entries SET best_score=?, best_at=?, best_verified=? WHERE id=?`).bind(score, now(), verified, entry.id).run();
    newBest = true;
  }
  return J({ ok: true, accepted: !flagged, newBest, verified: !!verified, signatureValid });
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
                  feeAmount: tr.fee_lamports, feePct: feePctFor(tr), status: tr.status, attemptsMax: GAMES[tr.game].attempts[tr.type] },
    duel: duel ? { code: id.split(':')[2], maxPlayers: duel.max_players, joinEndsAt: duel.join_ends_at, liveAt: duel.live_at, playMs: duel.play_ms,
                   dist: duel.dist, distLabel: DUEL_DIST[duel.dist], visibility: duel.visibility, createdBy: duel.created_by,
                   weights: duelWeights(duel.dist, Math.max(1, entries.filter(e => e.best_score > 0).length)) } : null,
    // The seed itself is revealed once the tournament is settled; before that only its SHA-256 commitment is public.
    seed: tr.status === 'paid' || tr.status === 'cancelled' ? seed : null,
    seedCommitment: await sha256hex(seed),
    poolAddress: env.POOL_ADDRESS,
    pool, participants: entries.length,
    ranking: entries.map(e => ({
      rank: e.best_score > 0 ? ++rank : null, wallet: e.wallet, score: e.best_score, verified: !!e.best_verified,
      attemptsUsed: e.attempts_used, entryTx: e.pay_tx, joinedAt: e.joined_at,
    })),
    payouts: payouts.map(p => ({
      rank: p.rank, role: p.rank === 0 ? 'service_fee' : (p.rank < 0 ? 'refund' : 'prize'), wallet: p.wallet, amount: p.lamports, txSig: p.tx_sig, paidAt: p.paid_at,
      explorer: p.tx_sig && p.tx_sig !== 'DRY_RUN' ? `https://solscan.io/tx/${p.tx_sig}` : null,
    })),
    rules: duel
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

// Runs every cron tick: expire unpaid reservations, start or cancel rooms whose joining window closed.
async function duelTick(env) {
  const t = now();
  const report = [];
  const stale = (await env.DB.prepare(`SELECT id FROM tournaments WHERE type='x' AND status='pending' AND starts_at<?`).bind(t - DUEL_PENDING_MS).all()).results;
  for (const r of stale) {
    await env.DB.prepare(`DELETE FROM duels WHERE id=?`).bind(r.id).run();
    await env.DB.prepare(`DELETE FROM tournaments WHERE id=? AND status='pending'`).bind(r.id).run();
  }
  const closing = (await env.DB.prepare(
    `SELECT t.*, d.join_ends_at, d.play_ms FROM tournaments t JOIN duels d ON d.id=t.id WHERE t.type='x' AND t.status='open' AND d.join_ends_at<=?`
  ).bind(t).all()).results;
  for (const tr of closing) {
    const c = (await env.DB.prepare(`SELECT COUNT(*) c FROM entries WHERE tournament_id=?`).bind(tr.id).first()).c;
    try {
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
    me: me ? { attemptsUsed: me.attempts_used, attemptsMax: 1, bestScore: me.best_score } : null,
  };
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

  const t = now();
  let id = null;
  for (let i = 0; i < 5 && !id; i++) {
    const cand = `${game}:x:${duelCode()}`;
    try {
      await env.DB.prepare(`INSERT INTO tournaments (id, game, type, starts_at, ends_at, fee_lamports, currency, status) VALUES (?,?,?,?,?,?,?,'pending')`)
        .bind(cand, game, 'x', t, t + Number(joinMin) * 60000, st, currency).run();
      id = cand;
    } catch (_) { /* code collision → retry */ }
  }
  if (!id) return bad('Could not allocate a room code, try again', 500);
  await env.DB.prepare(`INSERT INTO duels (id, max_players, join_ms, play_ms, join_ends_at, dist, visibility, created_by, created_at) VALUES (?,?,?,?,?,?,?,?,?)`)
    .bind(id, n, Number(joinMin) * 60000, Number(playMin) * 60000, t + Number(joinMin) * 60000, dist, visibility, wallet, t).run();
  return J({
    ok: true, id, code: id.split(':')[2], memo: id, stake: st, currency, poolAddress: env.POOL_ADDRESS,
    skr: currency === 'SKR' ? { mint: env.SKR_MINT, decimals: SKR_DECIMALS, poolTokenAccount: ataFor(env.POOL_ADDRESS, env.SKR_MINT).toBase58() } : null,
    expiresAt: t + DUEL_PENDING_MS, feePct: DUEL_FEE_PCT[currency],
  });
}

// GET /duel/list?game=&wallet= — public rooms open for joining + the caller's own rooms (open/live/recently finished)
async function handleDuelList(env, url) {
  const game = url.searchParams.get('game');
  const wallet = url.searchParams.get('wallet');
  const t = now();
  const pub = (await env.DB.prepare(
    `SELECT t.*, d.* FROM tournaments t JOIN duels d ON d.id=t.id
      WHERE t.type='x' AND t.status='open' AND d.visibility='public' AND d.join_ends_at>? ${game ? 'AND t.game=?' : ''}
      ORDER BY d.join_ends_at ASC LIMIT 50`
  ).bind(...(game ? [t, game] : [t])).all()).results;
  const out = { public: [], mine: [] };
  for (const r of pub) out.public.push(duelView(r, r, await duelEntries(env, r.id), wallet));
  if (wallet) {
    const mine = (await env.DB.prepare(
      `SELECT t.*, d.* FROM tournaments t JOIN duels d ON d.id=t.id JOIN entries e ON e.tournament_id=t.id AND e.wallet=?
        WHERE t.type='x' AND (t.status IN ('open','live','settling') OR (t.status IN ('paid','cancelled') AND t.ends_at>?)) ${game ? 'AND t.game=?' : ''}
        ORDER BY t.ends_at DESC LIMIT 30`
    ).bind(...(game ? [wallet, t - 7 * 86400_000, game] : [wallet, t - 7 * 86400_000])).all()).results;
    for (const r of mine) out.mine.push(duelView(r, r, await duelEntries(env, r.id), wallet));
  }
  out.public = out.public.filter(v => v.players < v.maxPlayers);
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
  const tr = await env.DB.prepare(`SELECT * FROM tournaments WHERE id=? AND type='x'`).bind(id).first();
  const duel = tr ? await env.DB.prepare(`SELECT * FROM duels WHERE id=?`).bind(id).first() : null;
  if (!tr || !duel) return bad('Room not found', 404);
  const wallet = url.searchParams.get('wallet');
  const entries = await duelEntries(env, id);
  const payouts = (await env.DB.prepare(`SELECT rank, wallet, lamports, tx_sig, paid_at FROM payouts WHERE tournament_id=? ORDER BY rank`).bind(id).all()).results;
  return J({
    ...duelView(tr, duel, entries, wallet), now: now(), prices: await getPrices(env),
    payouts: payouts.map(p => ({ rank: p.rank, role: p.rank === 0 ? 'service_fee' : (p.rank < 0 ? 'refund' : 'prize'), wallet: p.wallet, amount: p.lamports, txSig: p.tx_sig,
                                 explorer: p.tx_sig && p.tx_sig !== 'DRY_RUN' ? `https://solscan.io/tx/${p.tx_sig}` : null })),
    poolAddress: env.POOL_ADDRESS,
    skr: tr.currency === 'SKR' ? { mint: env.SKR_MINT, decimals: SKR_DECIMALS, poolTokenAccount: ataFor(env.POOL_ADDRESS, env.SKR_MINT).toBase58() } : null,
  });
}

// ---- Router ----
export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (req.method === 'OPTIONS') return J({});
    try {
      if (req.method === 'GET' && url.pathname === '/t') return await handleTournaments(env, url);
      if (req.method === 'POST' && url.pathname === '/join') return await handleJoin(env, await req.json());
      if (req.method === 'POST' && url.pathname === '/attempt/start') return await handleAttemptStart(env, await req.json());
      if (req.method === 'POST' && url.pathname === '/attempt/submit') return await handleSubmit(env, await req.json());
      if (req.method === 'GET' && url.pathname === '/leaderboard') return await handleLeaderboard(env, url);
      if (req.method === 'GET' && url.pathname === '/proof') return await handleProof(env, url);
      if (req.method === 'POST' && url.pathname === '/duel/create') return await handleDuelCreate(env, await req.json());
      if (req.method === 'GET' && url.pathname === '/duel/list') return await handleDuelList(env, url);
      if (req.method === 'GET' && url.pathname === '/duel/get') return await handleDuelGet(env, url);

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
