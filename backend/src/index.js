// ============================================================================
// EXL TOURNAMENTS — Cloudflare Worker (API + cron settle)
// Turnuva Modeli v1 — şartname: TURNUVA_MODELI.md
// ============================================================================
import { Keypair, PublicKey, SystemProgram, Transaction, Connection } from '@solana/web3.js';

// ---- Oyun/ekonomi yapılandırması ----
// LANSMAN ÜCRETLERİ (15 Tem 2026): günlük 0.1 / haftalık 0.3 / aylık 1 SOL.
// (Test dönemi TEST_FEES 0.001/0.002/0.003 idi — gerekirse geçici geri dönüş için tutuldu.)
const REAL_FEES = { d: 100_000_000, w: 300_000_000, m: 1_000_000_000 };
// eslint-disable-next-line no-unused-vars
const TEST_FEES = { d: 1_000_000, w: 2_000_000, m: 3_000_000 };
const STD_ATTEMPTS = { d: 1, w: 3, m: 10 };
const GAMES = {
  zipla: {
    fees: REAL_FEES,
    attempts: STD_ATTEMPTS,
    minDurationMs: 700, // erken ölüm meşru olabilir; asıl koruma deterministik formül
    // Deterministik skor formülü (SOL JUMP): dist = v0*t + (acc/2)*t^2 ; score = floor(dist/div)
    physics: { v0: 260, acc: 8, scoreDiv: 10 },
  },
  // Beceri oyunları: skor süreden türetilemez → süreye göre makul üst sınır (maxScorePerSec)
  // + hak-token + sunucu tohumu. Gerçek doğrulama v2'de deterministik replay ile sıkılaşır.
  // s2048 tavanı 3000→150: 3000 fiilen sınırsızdı (hileci idle bekleyip dev skor
  // basabilirdi). 150/sn dürüst hızlı oyuncunun çok üstü, hile tavanını 20x düşürür.
  s2048: { fees: REAL_FEES, attempts: STD_ATTEMPTS, minDurationMs: 4000, maxScorePerSec: 150 },
  snake: { fees: REAL_FEES, attempts: STD_ATTEMPTS, minDurationMs: 3000, maxScorePerSec: 12 },
  stack: { fees: REAL_FEES, attempts: STD_ATTEMPTS, minDurationMs: 2000, maxScorePerSec: 6 },
  tiles: { fees: REAL_FEES, attempts: STD_ATTEMPTS, minDurationMs: 3000, maxScorePerSec: 15 },
  dodge: { fees: REAL_FEES, attempts: STD_ATTEMPTS, minDurationMs: 3000, maxScorePerSec: 12 },
  bubble: { fees: REAL_FEES, attempts: STD_ATTEMPTS, minDurationMs: 4000, maxScorePerSec: 120 },
};

function expectedScore(cfg, durationMs) {
  const t = durationMs / 1000;
  return Math.floor((cfg.physics.v0 * t + (cfg.physics.acc / 2) * t * t) / cfg.physics.scoreDiv);
}
const FEE_PCT = { d: 1, w: 3, m: 5 };
// Havuzun SABİT yüzde payları (rank başına). WEIGHTS toplamı + FEE_PCT = 100.
//   d: 1. %99                                  (+ %1 hizmet)
//   w: 1.%50 2.%30 3.%17                        (+ %3 hizmet)
//   m: 30 18 12 9 7 6 5 4 2 2                    (+ %5 hizmet)
const WEIGHTS = { d: [99], w: [50, 30, 17], m: [30, 18, 12, 9, 7, 6, 5, 4, 2, 2] };
const SUBMIT_WINDOW_MS = 24 * 3600 * 1000;

// ---- yardımcılar ----
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

function pad(n) { return String(n).padStart(2, '0'); }

// UTC dönem kimlikleri ve sınırları
function periods(game, t = new Date()) {
  const y = t.getUTCFullYear(), mo = t.getUTCMonth(), d = t.getUTCDate();
  const dayStart = Date.UTC(y, mo, d);
  const dayEnd = dayStart + 86400_000;
  // ISO hafta (Pzt başlangıç)
  const dow = (t.getUTCDay() + 6) % 7; // Pzt=0
  const weekStart = dayStart - dow * 86400_000;
  const weekEnd = weekStart + 7 * 86400_000;
  const wDate = new Date(weekStart + 3 * 86400_000); // ISO hafta no: Perşembe kuralı
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

async function ensureTournaments(env, game) {
  const cfg = GAMES[game];
  if (!cfg) return;
  for (const p of periods(game)) {
    await env.DB.prepare(
      `INSERT OR IGNORE INTO tournaments (id, game, type, starts_at, ends_at, fee_lamports) VALUES (?,?,?,?,?,?)`
    ).bind(p.id, game, p.type, p.starts, p.ends, cfg.fees[p.type]).run();
  }
}

async function seedFor(env, tournamentId) {
  const data = new TextEncoder().encode(tournamentId + '|' + env.SEED_SALT);
  const h = await crypto.subtle.digest('SHA-256', data);
  return [...new Uint8Array(h)].map(b => b.toString(16).padStart(2, '0')).join('');
}

// ---- Telegram bildirimi (opsiyonel: TG_TOKEN + TG_CHAT secret'ları tanımlıysa) ----
// Bildirim hatası oyun akışını ASLA etkilemez (sessizce yutulur).
async function tgBildir(env, metin) {
  if (!env.TG_TOKEN || !env.TG_CHAT) return;
  try {
    await fetch(`https://api.telegram.org/bot${env.TG_TOKEN}/sendMessage`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ chat_id: env.TG_CHAT, text: metin }),
    });
  } catch (_) { /* bildirimsiz devam */ }
}

// ---- X (Twitter) otomatik paylaşım — @EXLTourney ----
// Opsiyonel: X_API_KEY / X_API_SECRET / X_ACCESS_TOKEN / X_ACCESS_SECRET
// secret'ları tanımlıysa çalışır; hata oyun akışını ASLA etkilemez.
const OYUN_AD = { zipla: 'Sol Jump', s2048: 'Sol 2048', snake: 'Sol Snake',
                  stack: 'Sol Stack', tiles: 'Sol Tiles', dodge: 'Sol Dodge',
                  bubble: 'Sol Bubble' };
const TIP_AD = { d: 'Daily', w: 'Weekly', m: 'Monthly' };

function _pe(s) { // RFC3986 percent-encode (OAuth 1.0a)
  return encodeURIComponent(s).replace(/[!'()*]/g, c => '%' + c.charCodeAt(0).toString(16).toUpperCase());
}

async function _hmacSha1(key, msg) {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(key),
    { name: 'HMAC', hash: 'SHA-1' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(msg));
  let bin = '';
  for (const b of new Uint8Array(sig)) bin += String.fromCharCode(b);
  return btoa(bin);
}

async function xTweet(env, text) {
  if (!env.X_API_KEY || !env.X_API_SECRET || !env.X_ACCESS_TOKEN || !env.X_ACCESS_SECRET) {
    return { skipped: 'X anahtarları tanımlı değil' };
  }
  try {
    const url = 'https://api.x.com/2/tweets';
    const oauth = {
      oauth_consumer_key: env.X_API_KEY,
      oauth_nonce: crypto.randomUUID().replace(/-/g, ''),
      oauth_signature_method: 'HMAC-SHA1',
      oauth_timestamp: String(Math.floor(Date.now() / 1000)),
      oauth_token: env.X_ACCESS_TOKEN,
      oauth_version: '1.0',
    };
    const paramStr = Object.keys(oauth).sort().map(k => `${_pe(k)}=${_pe(oauth[k])}`).join('&');
    const base = `POST&${_pe(url)}&${_pe(paramStr)}`;
    const signKey = `${_pe(env.X_API_SECRET)}&${_pe(env.X_ACCESS_SECRET)}`;
    oauth.oauth_signature = await _hmacSha1(signKey, base);
    const header = 'OAuth ' + Object.keys(oauth).sort()
      .map(k => `${_pe(k)}="${_pe(oauth[k])}"`).join(', ');
    const r = await fetch(url, {
      method: 'POST',
      headers: { authorization: header, 'content-type': 'application/json' },
      body: JSON.stringify({ text }),
    });
    return { status: r.status, body: await r.text() };
  } catch (e) { return { error: String(e) }; /* paylaşımsız devam */ }
}

// Günlük özet: YALNIZ katılımı olan açık turnuvalar (en dolu 3'ü) tek tweet'te.
async function xGunlukOzet(env) {
  const t = now();
  const rows = (await env.DB.prepare(
    `SELECT tr.id, tr.type, tr.ends_at, COUNT(e.id) c, COALESCE(SUM(e.paid_lamports),0) p
       FROM tournaments tr JOIN entries e ON e.tournament_id = tr.id
      WHERE tr.status='open' AND tr.starts_at<=? AND tr.ends_at>?
      GROUP BY tr.id HAVING c > 0 ORDER BY p DESC LIMIT 3`
  ).bind(t, t).all()).results;
  if (!rows.length) return; // katılım yoksa tweet de yok
  const sat = rows.map(r => {
    const oyun = OYUN_AD[r.id.split(':')[0]] || r.id.split(':')[0];
    const kalan = Math.max(1, Math.round((r.ends_at - t) / 3600000));
    return `${oyun} ${TIP_AD[r.type]}: ${r.c}p · ${(r.p / 1e9).toFixed(2)} SOL · ${kalan}h left`;
  });
  await xTweet(env,
    `🏆 LIVE TOURNAMENTS\n\n${sat.join('\n')}\n\nSame seed for everyone — pure skill.\n` +
    `Real SOL, paid on-chain.\n\n📲 Seeker → dApp Store → search "Sol" · by EXCOBALAB 👑\n` +
    `#Solana #SolanaMobile #Seeker`);
}

// ---- Zincirden giriş ödemesi doğrulama ----
// wallet parametresi verilmezse ödeyen cüzdan işlemden türetilir ve döndürülür.
async function verifyPayment(env, payTx, wallet, tournamentId, feeLamports) {
  const res = await fetch(env.RPC_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      jsonrpc: '2.0', id: 1, method: 'getTransaction',
      params: [payTx, { encoding: 'jsonParsed', commitment: 'confirmed', maxSupportedTransactionVersion: 0 }],
    }),
  });
  const j = await res.json();
  const tx = j.result;
  if (!tx) return 'Transaction not found (wait a few seconds and retry)';
  if (tx.meta?.err) return 'Transaction failed on-chain';

  const keys = tx.transaction.message.accountKeys;
  const payer = keys.find(k => k.signer)?.pubkey;
  if (!payer) return { err: 'No signer found in transaction' };
  if (wallet && payer !== wallet) return { err: 'Payer does not match wallet' };

  let paid = 0, memoOk = false;
  const scan = (ins) => {
    for (const i of ins) {
      if (i.program === 'system' && i.parsed?.type === 'transfer') {
        const info = i.parsed.info;
        if (info.destination === env.POOL_ADDRESS && info.source === payer) paid += Number(info.lamports);
      }
      if (i.program === 'spl-memo' && typeof i.parsed === 'string' && i.parsed.includes(tournamentId)) memoOk = true;
    }
  };
  scan(tx.transaction.message.instructions || []);
  for (const inner of tx.meta?.innerInstructions || []) scan(inner.instructions || []);

  if (!memoOk) return { err: 'Memo does not reference this tournament' };
  if (paid < feeLamports) return { err: `Insufficient payment (${paid} < ${feeLamports})` };
  return { err: null, payer }; // OK
}

// ---- API uçları ----
async function handleTournaments(env, url) {
  const game = url.searchParams.get('game') || 'zipla';
  const wallet = url.searchParams.get('wallet');
  await ensureTournaments(env, game);
  const t = now();
  const rows = (await env.DB.prepare(
    `SELECT * FROM tournaments WHERE game=? AND status='open' AND starts_at<=? AND ends_at>? ORDER BY ends_at`
  ).bind(game, t, t).all()).results;

  const out = [];
  for (const r of rows) {
    const agg = await env.DB.prepare(
      `SELECT COUNT(*) c, COALESCE(SUM(paid_lamports),0) pool FROM entries WHERE tournament_id=?`
    ).bind(r.id).first();
    let me = null;
    if (wallet) {
      const e = await env.DB.prepare(
        `SELECT attempts_used, best_score FROM entries WHERE tournament_id=? AND wallet=?`
      ).bind(r.id, wallet).first();
      if (e) me = { attemptsUsed: e.attempts_used, attemptsMax: GAMES[r.game].attempts[r.type], bestScore: e.best_score };
    }
    out.push({
      id: r.id, type: r.type, endsAt: r.ends_at, feeLamports: r.fee_lamports,
      participants: agg.c, poolLamports: agg.pool, feePct: FEE_PCT[r.type],
      attemptsMax: GAMES[r.game].attempts[r.type], me,
    });
  }
  return J({ poolAddress: env.POOL_ADDRESS, tournaments: out });
}

async function handleJoin(env, body) {
  const { tournamentId, wallet, payTx } = body || {};
  if (!tournamentId || !payTx) return bad('tournamentId, payTx required');
  const tr = await env.DB.prepare(`SELECT * FROM tournaments WHERE id=?`).bind(tournamentId).first();
  if (!tr || tr.status !== 'open' || tr.ends_at <= now()) return bad('Tournament is not open');

  const v = await verifyPayment(env, payTx, wallet || null, tournamentId, tr.fee_lamports);
  if (v.err) return bad(v.err, 402);
  const payer = v.payer; // cüzdan kimliği = ödemeyi yapan

  try {
    await env.DB.prepare(
      `INSERT INTO entries (tournament_id, wallet, pay_tx, paid_lamports, joined_at) VALUES (?,?,?,?,?)`
    ).bind(tournamentId, payer, payTx, tr.fee_lamports, now()).run();
  } catch (e) {
    const msg = String(e);
    if (msg.includes('pay_tx')) return bad('This payment was already used', 409);
    if (msg.includes('tournament_id')) return bad('Wallet already joined this tournament', 409);
    throw e;
  }
  // Telegram: yeni katılım bildirimi (katılımcı sayısı + havuz ile)
  const agg = await env.DB.prepare(
    `SELECT COUNT(*) c, COALESCE(SUM(paid_lamports),0) p FROM entries WHERE tournament_id=?`
  ).bind(tournamentId).first();
  await tgBildir(env,
    `🏆 YENİ KATILIM\n${tournamentId}\nCüzdan: ${payer.slice(0, 4)}…${payer.slice(-4)}\n` +
    `Ücret: ${(tr.fee_lamports / 1e9).toFixed(2)} SOL\n` +
    `Toplam: ${agg.c} katılımcı · havuz ${(agg.p / 1e9).toFixed(2)} SOL`);
  return J({ ok: true, wallet: payer, attemptsMax: GAMES[tr.game].attempts[tr.type] });
}

async function handleAttemptStart(env, body) {
  const { tournamentId, wallet } = body || {};
  if (!tournamentId || !wallet) return bad('tournamentId, wallet required');
  const tr = await env.DB.prepare(`SELECT * FROM tournaments WHERE id=?`).bind(tournamentId).first();
  if (!tr || tr.status !== 'open' || tr.ends_at <= now()) return bad('Tournament is not open');
  const entry = await env.DB.prepare(
    `SELECT * FROM entries WHERE tournament_id=? AND wallet=?`
  ).bind(tournamentId, wallet).first();
  if (!entry) return bad('Join the tournament first', 403);
  const maxA = GAMES[tr.game].attempts[tr.type];
  if (entry.attempts_used >= maxA) return bad('No attempts left', 403);

  // HAK BURADA DÜŞER (uçak modu koruması) — atomik güncelleme
  const upd = await env.DB.prepare(
    `UPDATE entries SET attempts_used = attempts_used + 1 WHERE id=? AND attempts_used < ?`
  ).bind(entry.id, maxA).run();
  if (!upd.meta.changes) return bad('No attempts left', 403);

  const token = crypto.randomUUID();
  await env.DB.prepare(
    `INSERT INTO attempts (token, entry_id, started_at) VALUES (?,?,?)`
  ).bind(token, entry.id, now()).run();

  return J({
    token,
    seed: await seedFor(env, tournamentId),
    attemptsLeft: maxA - entry.attempts_used - 1,
  });
}

async function handleSubmit(env, body) {
  const { token, score, durationMs, taps, samples } = body || {};
  if (!token || typeof score !== 'number') return bad('token, score required');
  const at = await env.DB.prepare(`SELECT * FROM attempts WHERE token=?`).bind(token).first();
  if (!at) return bad('Unknown attempt token', 404);
  if (at.submitted_at) return bad('Attempt already submitted', 409);
  if (now() - at.started_at > SUBMIT_WINDOW_MS) return bad('Submit window expired', 410);

  const entry = await env.DB.prepare(`SELECT * FROM entries WHERE id=?`).bind(at.entry_id).first();
  const tr = await env.DB.prepare(`SELECT * FROM tournaments WHERE id=?`).bind(entry.tournament_id).first();
  const cfg = GAMES[tr.game];

  // Telemetri akla-yatkınlık — ihlal skoru siler ve işaretler
  let flagged = 0;
  const dur = Number(durationMs) || 0;
  const elapsed = now() - at.started_at;
  if (score < 0 || dur < cfg.minDurationMs) flagged = 1;
  if (dur > elapsed + 60_000) flagged = 1; // oyun süresi gerçek süreyi aşamaz
  if (!Number.isInteger(score)) flagged = 1;
  if ((Number(taps) || 0) < 1 && score > 0) flagged = 1;
  // Skor doğrulama — oyun tipine göre
  if (cfg.physics) {
    // süre→skor deterministik (SOL JUMP): birebir hesaplanabilmeli
    const exp = expectedScore(cfg, dur);
    if (Math.abs(score - exp) > exp * 0.05 + 8) flagged = 1;
  } else if (cfg.maxScorePerSec) {
    // beceri oyunları: süreye göre makul üst sınır (deterministik replay v2'de sıkılaşır)
    if (score > cfg.maxScorePerSec * (dur / 1000) + 10) flagged = 1;
  }

  await env.DB.prepare(
    `UPDATE attempts SET submitted_at=?, score=?, duration_ms=?, taps=?, flagged=?, telemetry_json=? WHERE token=?`
  ).bind(now(), score, dur, Number(taps) || 0, flagged, JSON.stringify(samples || null), token).run();

  let newBest = false;
  if (!flagged && score > entry.best_score) {
    await env.DB.prepare(
      `UPDATE entries SET best_score=?, best_at=? WHERE id=?`
    ).bind(score, now(), entry.id).run();
    newBest = true;
  }
  return J({ ok: true, accepted: !flagged, newBest });
}

async function handleLeaderboard(env, url) {
  const id = url.searchParams.get('tournamentId');
  const top = Math.min(Number(url.searchParams.get('top') || 50), 100);
  const wallet = url.searchParams.get('wallet');
  if (!id) return bad('tournamentId required');
  const rows = (await env.DB.prepare(
    `SELECT wallet, best_score, best_at FROM entries
     WHERE tournament_id=? AND best_score>0 ORDER BY best_score DESC, best_at ASC LIMIT ?`
  ).bind(id, top).all()).results;
  let myRank = null;
  if (wallet) {
    const me = await env.DB.prepare(
      `SELECT best_score, best_at FROM entries WHERE tournament_id=? AND wallet=?`
    ).bind(id, wallet).first();
    if (me && me.best_score > 0) {
      const r = await env.DB.prepare(
        `SELECT COUNT(*) c FROM entries WHERE tournament_id=? AND best_score>0
         AND (best_score > ? OR (best_score = ? AND best_at < ?))`
      ).bind(id, me.best_score, me.best_score, me.best_at).first();
      myRank = { rank: r.c + 1, bestScore: me.best_score };
    }
  }
  const payouts = (await env.DB.prepare(
    `SELECT rank, wallet, lamports, tx_sig FROM payouts WHERE tournament_id=? AND rank>0 ORDER BY rank`
  ).bind(id).all()).results;
  return J({
    leaderboard: rows.map((r, i) => ({ rank: i + 1, wallet: r.wallet, score: r.best_score })),
    myRank, payouts,
  });
}

// ---- Kapanış + ödeme ----
async function settle(env) {
  const due = (await env.DB.prepare(
    `SELECT * FROM tournaments WHERE status='open' AND ends_at<=?`
  ).bind(now()).all()).results;
  const report = [];
  for (const tr of due) {
    await env.DB.prepare(`UPDATE tournaments SET status='settling' WHERE id=?`).bind(tr.id).run();
    try {
      // İDEMPOTENCY GUARD: bu turnuva için daha önce payout yazılmışsa (yarım
      // kalmış settle — ödeme zincire gitti ama DB yazımı kesildi), ASLA ikinci
      // kez ödeme yapma; turnuvayı paid'e çekip geç.
      const prior = await env.DB.prepare(
        `SELECT COUNT(*) c FROM payouts WHERE tournament_id=?`
      ).bind(tr.id).first();
      if ((prior?.c ?? 0) > 0) {
        await env.DB.prepare(`UPDATE tournaments SET status='paid' WHERE id=?`).bind(tr.id).run();
        report.push({ id: tr.id, note: 'payouts already exist; marked paid (idempotency guard)' });
        continue;
      }
      const pool = (await env.DB.prepare(
        `SELECT COALESCE(SUM(paid_lamports),0) p FROM entries WHERE tournament_id=?`
      ).bind(tr.id).first())?.p ?? 0;
      const ranked = (await env.DB.prepare(
        `SELECT wallet, best_score, best_at FROM entries
         WHERE tournament_id=? AND best_score>0 ORDER BY best_score DESC, best_at ASC LIMIT 10`
      ).bind(tr.id).all()).results;

      if (pool > 0) {
        // transfers listesini her durumda kur:
        //  - Kazanan varsa: eksik sıralar yeniden bölüştürülür, hizmet payı sabit.
        //  - Hiç geçerli skor yoksa: TÜM havuz hizmet payı cüzdanına gider (para boşlukta kalmaz).
        // Zincir işlem ücreti HİZMET PAYINDAN düşülür (havuz cüzdanı erimez).
        // 5000 lamport/imza; tek imzalı tek işlem gönderiyoruz.
        const TX_FEE_LAMPORTS = 5000;
        let transfers;
        if (ranked.length > 0) {
          const weights = WEIGHTS[tr.type].slice(0, ranked.length);
          const sumW = weights.reduce((a, b) => a + b, 0);
          const payable = Math.floor(pool * (100 - FEE_PCT[tr.type]) / 100);
          const shares = weights.map(w => Math.floor(payable * w / sumW));
          const commission = Math.max(0, pool - shares.reduce((a, b) => a + b, 0) - TX_FEE_LAMPORTS);
          transfers = ranked.map((r, i) => ({ to: r.wallet, lamports: shares[i], rank: i + 1 }));
          transfers.push({ to: env.COMMISSION_ADDRESS, lamports: commission, rank: 0 });
        } else {
          transfers = [{ to: env.COMMISSION_ADDRESS, lamports: Math.max(0, pool - TX_FEE_LAMPORTS), rank: 0 }];
        }
        transfers = transfers.filter(t => t.lamports > 0);

        let sig = 'DRY_RUN';
        if (env.DRY_RUN !== '1') {
          // Connection sınıfı Workers'da RPC yanıtını parse edemiyor ( hatası) —
          // ham RPC ile blockhash al, işlemi elle imzala/serialize et, sendTransaction çağır.
          const kp = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(env.POOL_SECRET)));
          const bhRes = await fetch(env.RPC_URL, {
            method: 'POST', headers: { 'content-type': 'application/json' },
            body: JSON.stringify({
              jsonrpc: '2.0', id: 1, method: 'getLatestBlockhash',
              params: [{ commitment: 'confirmed' }],
            }),
          });
          const blockhash = (await bhRes.json()).result?.value?.blockhash;
          if (!blockhash) throw new Error('Failed to fetch blockhash for payout');

          const tx = new Transaction();
          tx.recentBlockhash = blockhash;
          tx.feePayer = kp.publicKey;
          for (const t of transfers) {
            if (t.lamports > 0) tx.add(SystemProgram.transfer({
              fromPubkey: kp.publicKey, toPubkey: new PublicKey(t.to), lamports: t.lamports,
            }));
          }
          tx.sign(kp);
          const raw = tx.serialize();
          let bin = '';
          for (const b of raw) bin += String.fromCharCode(b);
          const b64 = btoa(bin);

          const sendRes = await fetch(env.RPC_URL, {
            method: 'POST', headers: { 'content-type': 'application/json' },
            body: JSON.stringify({
              jsonrpc: '2.0', id: 1, method: 'sendTransaction',
              params: [b64, { encoding: 'base64', preflightCommitment: 'confirmed' }],
            }),
          });
          const sendJson = await sendRes.json();
          if (sendJson.error) throw new Error('sendTransaction: ' + JSON.stringify(sendJson.error));
          sig = sendJson.result;
          if (!sig) throw new Error('sendTransaction returned no signature');
        }
        for (const t of transfers) {
          await env.DB.prepare(
            `INSERT INTO payouts (tournament_id, rank, wallet, lamports, tx_sig, paid_at) VALUES (?,?,?,?,?,?)`
          ).bind(tr.id, t.rank, t.to, t.lamports, sig, now()).run();
        }
        report.push({ id: tr.id, pool, winners: ranked.length, sig });
        // Telegram: kapanış/ödeme özeti
        await tgBildir(env,
          `💰 TURNUVA KAPANDI\n${tr.id}\nHavuz: ${(pool / 1e9).toFixed(3)} SOL · ` +
          `${ranked.length} kazanan\nTx: ${sig}`);
        // X: şampiyon duyurusu (yalnız gerçek dağıtımda ve kazanan varsa)
        if (ranked.length > 0 && env.DRY_RUN !== '1') {
          const oyun = OYUN_AD[tr.id.split(':')[0]] || tr.id.split(':')[0];
          const bir = transfers.find(x => x.rank === 1);
          const kz = ranked[0].wallet;
          await xTweet(env,
            `💰 ${oyun} ${TIP_AD[tr.type]} champion!\n` +
            `${kz.slice(0, 4)}…${kz.slice(-4)} takes ${(bir ? bir.lamports / 1e9 : 0).toFixed(3)} SOL ` +
            `— paid on-chain ✅\nsolscan.io/tx/${sig}\n\n` +
            `📲 Your turn: dApp Store → "${oyun}" by EXCOBALAB 👑\n#Solana #SolanaMobile #Seeker`);
        }
      } else {
        report.push({ id: tr.id, pool: 0, winners: 0, sig: null });
      }
      await env.DB.prepare(`UPDATE tournaments SET status='paid' WHERE id=?`).bind(tr.id).run();
    } catch (e) {
      // hata: tekrar denensin diye geri aç
      await env.DB.prepare(`UPDATE tournaments SET status='open' WHERE id=?`).bind(tr.id).run();
      report.push({ id: tr.id, error: String(e) });
    }
  }
  return report;
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

      // Admin
      if (url.searchParams.get('key') === env.ADMIN_KEY) {
        if (url.pathname === '/admin/settle') return J(await settle(env));
        // TEŞHİS: havuz secret'ı parse edilebiliyor mu (anahtarı AÇMADAN)
        if (url.pathname === '/admin/diag') {
          let secretOk = false, secretLen = 0, secretErr = null, firstChars = null;
          try {
            const raw = env.POOL_SECRET || '';
            firstChars = raw.slice(0, 3);
            const a = JSON.parse(raw);
            secretOk = Array.isArray(a);
            secretLen = a.length;
          } catch (e) { secretErr = String(e); }
          return J({ secretOk, secretLen, secretErr, firstChars, dryRun: env.DRY_RUN, poolAddr: env.POOL_ADDRESS });
        }
        // TEST ARACI: açık bir turnuvayı hemen sonlandırır (sonraki settle onu kapatıp öder)
        // TEST ARACI: bir turnuvanın tüm kayıtlarını siler (test verisi temizliği)
        // LANSMAN TEMİZLİĞİ: TÜM turnuva/katılım/deneme/ödeme kayıtlarını siler.
        // Bir sonraki /t çağrısında dönem turnuvaları YENİ (gerçek) ücretlerle
        // yeniden oluşur. Tek seferlik, lansman öncesi kullanım için.
        if (url.pathname === '/admin/purgeall') {
          if (url.searchParams.get('confirm') !== 'yes') {
            return bad("Add &confirm=yes to wipe ALL tournament data");
          }
          await env.DB.prepare(`DELETE FROM attempts`).run();
          await env.DB.prepare(`DELETE FROM entries`).run();
          await env.DB.prepare(`DELETE FROM payouts`).run();
          await env.DB.prepare(`DELETE FROM tournaments`).run();
          return J({ purgedAll: true });
        }
        if (url.pathname === '/admin/purge') {
          const id = url.searchParams.get('id');
          if (!id) return bad('id required');
          await env.DB.prepare(`DELETE FROM attempts WHERE entry_id IN (SELECT id FROM entries WHERE tournament_id=?)`).bind(id).run();
          await env.DB.prepare(`DELETE FROM entries WHERE tournament_id=?`).bind(id).run();
          await env.DB.prepare(`DELETE FROM payouts WHERE tournament_id=?`).bind(id).run();
          await env.DB.prepare(`DELETE FROM tournaments WHERE id=?`).bind(id).run();
          return J({ purged: id });
        }
        if (url.pathname === '/admin/end') {
          const id = url.searchParams.get('id');
          if (!id) return bad('id required');
          const r = await env.DB.prepare(
            `UPDATE tournaments SET ends_at=? WHERE id=? AND status='open'`
          ).bind(now() - 1000, id).run();
          return J({ ended: r.meta.changes, id });
        }
        // TEST/ARAÇ: elle tweet at (X entegrasyon testi + manuel duyurular)
        if (url.pathname === '/admin/tweet') {
          const metin = url.searchParams.get('text');
          if (!metin) return bad('text required');
          const sonuc = await xTweet(env, metin);
          return J({ text: metin, x: sonuc });
        }
        // TEST/ARAÇ: günlük X özetini hemen çalıştır (saat beklemeden)
        if (url.pathname === '/admin/tweetdigest') {
          await xGunlukOzet(env);
          return J({ ok: true, note: 'katılımlı açık turnuva yoksa tweet atılmaz' });
        }
        if (url.pathname === '/admin/pool') {
          const r = await fetch(env.RPC_URL, {
            method: 'POST', headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'getBalance', params: [env.POOL_ADDRESS] }),
          });
          return J({ poolAddress: env.POOL_ADDRESS, balance: (await r.json()).result?.value });
        }
      }
      return bad('Not found', 404);
    } catch (e) {
      return bad('Server error: ' + String(e), 500);
    }
  },
  async scheduled(ev, env, ctx) {
    ctx.waitUntil(settle(env));
    // Günlük X özeti: 18:05 UTC (21:05 TR) — prime time, tek tweet
    if (new Date(ev.scheduledTime).getUTCHours() === 18) {
      ctx.waitUntil(xGunlukOzet(env));
    }
  },
};
