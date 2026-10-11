// ============================================================================
// EXL TOURNEY — TOURNAMENT ROOM (client v1.3 Phase B)
// A scheduled Daily / Weekly / Monthly tournament shown like a room: rules,
// pool, players, and YOUR row with PAY · PLAY · WITHDRAW. Cautious by design:
// nothing is paid until you press PAY, and you can take the entry back until
// your first run starts.
// Identical file in every EXL game.  Apache-2.0 — github.com/excobalab/exl-tourney
// ============================================================================
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'exl_duel.dart';
import 'exl_proof.dart';
import 'exl_ui.dart';
import 'exl_wallet.dart';

class TournamentRoomScreen extends StatefulWidget {
  final String apiBase, appName, tournamentId;
  final String? wallet;
  final DuelJoinFn onJoin;   // pays the entry fee (same flow as before)
  final DuelPlayFn onPlay;   // opens the game with a pending run
  final DuelRanksFn onRanks;
  /// v1.4 (EXathlon): label of the play button ('PLAY' by default, 'CHOOSE GAME' for multi-game entries) and an
  /// optional extra panel drawn under the header (per-game breakdown).
  final String playLabel;
  final Widget Function(Map<String, dynamic> r)? extra;
  const TournamentRoomScreen({super.key, required this.apiBase, required this.appName, required this.tournamentId, required this.wallet,
      required this.onJoin, required this.onPlay, required this.onRanks, this.playLabel = 'PLAY', this.extra});
  @override
  State<TournamentRoomScreen> createState() => _TournamentRoomScreenState();
}

class _TournamentRoomScreenState extends State<TournamentRoomScreen> {
  late final DuelApi _api = DuelApi(widget.apiBase);
  Map<String, dynamic>? _r;
  String? _error;
  bool _busy = false;
  Timer? _clock;
  /// v1.3: the active wallet. Re-read from prefs on every load — the screen is pushed with the wallet known at that
  /// moment, but the first payment (or a wallet switch) changes it, and `me` (PAY/PLAY/WITHDRAW) depends on it.
  String? _wallet;

  @override
  void initState() {
    super.initState();
    _wallet = widget.wallet;
    _load();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); });
  }

  @override
  void dispose() { _clock?.cancel(); super.dispose(); }

  @override
  void didUpdateWidget(covariant TournamentRoomScreen old) { super.didUpdateWidget(old); if (old.wallet != widget.wallet) _load(); }

  Future<void> _load() async {
    try {
      try { final p = await SharedPreferences.getInstance(); _wallet = p.getString('wallet') ?? widget.wallet ?? _wallet; } catch (_) {}
      final r = await _api.troom(widget.tournamentId, _wallet);
      if (mounted) setState(() { _r = r; _error = null; });
    } catch (e) { if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', '')); }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  Map<String, dynamic> _asT(Map r) => {
        'id': r['id'], 'type': r['type'], 'currency': r['currency'], 'feeLamports': r['feeLamports'], 'attemptsMax': r['attemptsMax'], 'endsAt': r['endsAt'],
        'title': 'PAY · ${(r['typeLabel'] as String).toUpperCase()} ${r['currency']}',
        'subtitle': 'Entry fee goes to the on-chain prize pool. Attempts: ${r['attemptsMax']}. Withdraw available until your first run.',
      };

  Future<void> _pay(Map r) async {
    setState(() => _busy = true);
    final ok = await widget.onJoin(_asT(r), r['skr'] as Map?, r['poolAddress'] as String);
    if (mounted) setState(() => _busy = false);
    if (ok) _load();
  }

  Future<void> _withdraw(Map r) async {
    final me = r['me'] as Map?; final q = me?['withdraw'] as Map?;
    final w = _wallet;
    if (q == null || w == null) return;
    final cur = r['currency'] as String;
    final ok = await exlConfirmWithdraw(context, quote: q, cur: cur, prices: r['prices'] as Map?,
        what: 'Refund of your entry fee, minus the service fee and network fee, sent to your wallet on-chain.');
    if (!ok) return;
    setState(() => _busy = true);
    try {
      final res = await _api.withdraw(r['id'] as String, w);
      _snack('Refunded ${exlFmtAmt(res['refund'] as num, cur)} to your wallet');
    } catch (e) {
      if (!mounted) return;
      final again = await exlRetryDialog(context, title: 'WITHDRAW FAILED', message: '${e.toString().replaceFirst('Exception: ', '')}\n\nYour entry is unchanged.');
      if (mounted) setState(() => _busy = false);
      await _load();
      if (again && mounted) { final fresh = _r; if (fresh != null) return _withdraw(fresh); }
      return;
    }
    finally { if (mounted) setState(() => _busy = false); _load(); }
  }

  /// Steps strip: where the player is in the tournament flow.
  /// My best score was submitted without a wallet signature → the "Sign score" step shows as skipped, not done.
  bool _unsigned(Map? me, List<Map> entries) {
    if (me == null || (me['attemptsUsed'] as int) == 0) return false;
    final mine = entries.cast<Map?>().firstWhere((e) => e!['wallet'] == _wallet, orElse: () => null);
    return mine != null && mine['verified'] != true;
  }

  int _stepIndex(Map? me, bool open, int left) {
    if (me == null) return open ? 1 : 0;            // connect wallet / pay
    if ((me['attemptsUsed'] as int) == 0) return 2;  // play
    if (left > 0) return 2;                          // more runs available
    return open ? 4 : 5;                             // wait for the clock / payout
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, centerTitle: true,
        leading: IconButton(onPressed: () => Navigator.of(context).maybePop(), icon: const Icon(Icons.arrow_back, color: exlCyanDim)),
        title: ExlEmboss(r == null ? 'TOURNAMENT' : (r['typeLabel'] as String).toUpperCase(), size: 22, spacing: 3),
        actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh, color: exlCyanDim))],
      ),
      body: Container(
        decoration: const BoxDecoration(gradient: RadialGradient(center: Alignment(0, -0.6), radius: 1.5, colors: [Color(0xFF0E2A52), exlBgBottom])),
        child: SafeArea(
          child: _error != null && r == null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: exlRed))))
              : r == null ? const Center(child: CircularProgressIndicator(strokeWidth: 2, color: exlCyan)) : _safeBody(r),
        ),
      ),
    );
  }

  /// A rendering problem must never leave the player on a blank page without a way back or a retry.
  Widget _safeBody(Map<String, dynamic> r) {
    try { return _body(r); } catch (e) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('This page could not be drawn.\n$e', textAlign: TextAlign.center, style: const TextStyle(color: exlRed, fontSize: 12.5, height: 1.4)),
        const SizedBox(height: 14),
        ExlButton3D('TRY AGAIN', tone: ExlTone.ghost, expand: false, height: 44, fontSize: 14, onTap: _load),
      ])));
    }
  }

  Widget _body(Map<String, dynamic> r) {
    final cur = r['currency'] as String;
    final accent = cur == 'SKR' ? exlGoldBright : exlCyan;
    final st = r['status'] as String;
    final me = r['me'] as Map?;
    final entries = (r['entries'] as List).cast<Map>();
    final payouts = (r['payouts'] as List).cast<Map>();
    final prices = r['prices'] as Map?;
    final pool = r['pool'] as num;
    final feePct = r['feePct'] as num;
    final weights = (r['weights'] as List).cast<num>();
    final finished = st == 'paid' || st == 'cancelled';
    final open = st == 'open' && (r['endsAt'] as int) > DateTime.now().millisecondsSinceEpoch;
    final attemptsMax = r['attemptsMax'] as int;
    final used = me == null ? 0 : me['attemptsUsed'] as int;
    final left = attemptsMax - used;
    final type = r['type'] as String;
    final punch = type == 'd' ? 'WINNER TAKES ALL' : (type == 'w' ? 'TOP 3 SPLIT THE POT' : 'TOP 10 GET PAID');

    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 28), children: [
      // ---- header
      ExlPanel(
        glow: accent,
        child: Column(children: [
          Row(children: [
            ExlPill(cur, color: accent),
            const SizedBox(width: 6),
            if (open) const ExlPill('LIVE', color: exlGreenGo, asset: 'rozet_live', icon: Icons.play_arrow)
            else if (finished) ExlPill(st == 'cancelled' ? 'REFUNDED' : 'FINISHED', color: exlGoldBright)
            else const ExlPill('SETTLING', color: exlOrange),
            const Spacer(),
            Text(open ? '⏱ ${exlCountdown(r['endsAt'] as int)}' : '', style: const TextStyle(color: exlIce, fontSize: 13, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 10),
          SizedBox(height: 44, child: ExlUiImage('ikon_tournaments', fallback: ExlIcon3D(Icons.emoji_events, size: 40, color: exlGoldBright))),
          const SizedBox(height: 6),
          Text(punch, style: exlT(13, color: accent, spacing: 2)),
          const SizedBox(height: 2),
          Text('Same course for everyone · $attemptsMax attempt${attemptsMax == 1 ? '' : 's'} · best score counts', style: exlBody(12, color: exlCyanDim)),
          const SizedBox(height: 14),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            _stat('PRIZE POOL', exlFmtAmt(pool, cur), exlUsd(prices, pool, cur), accent, flex: 5),
            _stat('ENTRY', exlFmtAmt(r['feeLamports'] as num, cur), exlUsd(prices, r['feeLamports'] as num, cur), exlIce, flex: 4),
            _stat('PLAYERS', '${r['players']}', null, exlIce, flex: 3),
          ]),
          const SizedBox(height: 14),
          // ---- MY ROW
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: exlInk.withOpacity(0.35), border: Border.all(color: me != null ? accent.withOpacity(0.6) : exlCyanDim.withOpacity(0.5))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                if (_wallet != null) ExlAvatar(_wallet!, me: true) else Container(width: 34, height: 34, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: exlCyanDim, width: 2))),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(me == null ? 'YOUR SEAT' : 'YOU ARE IN', style: exlT(13, color: me == null ? exlCyanDim : accent, spacing: 2)),
                  Text(me == null
                      ? (open ? 'Pay the entry fee to join. Withdraw available until your first run.' : 'Entries are closed.')
                      : (used == 0 ? 'Paid · $left attempt${left == 1 ? '' : 's'} ready' : 'Best score ${me['bestScore']} · $left of $attemptsMax attempt${attemptsMax == 1 ? '' : 's'} left'),
                      style: exlBody(11.5, color: exlIce)),
                ])),
                if (me != null) const ExlPill('PAID', color: exlGreenGo, asset: 'rozet_paid', icon: Icons.check),
              ]),
              const SizedBox(height: 10),
              if (me == null && open)
                ExlButton3D('PAY ${exlFmtAmt(r['feeLamports'] as num, cur)}', tone: ExlTone.gold, height: 50, onTap: _busy ? null : () => _pay(r),
                    leading: SizedBox(width: 22, height: 22, child: ExlUiImage('rozet_pay', fallback: const Icon(Icons.paid, color: exlInk, size: 22)))),
              if (me != null && open) Row(children: [
                Expanded(flex: 3, child: ExlButton3D(left > 0 ? '${widget.playLabel}  ($left/$attemptsMax left)' : 'RUN SUBMITTED', tone: ExlTone.green, height: 50, fontSize: 15,
                    onTap: left > 0 && !_busy ? () async { await widget.onPlay(_asT(r)); _load(); } : null)),
                if (me['canWithdraw'] == true) ...[
                  const SizedBox(width: 8),
                  Expanded(flex: 2, child: ExlButton3D('WITHDRAW', tone: ExlTone.ghost, height: 50, fontSize: 13, onTap: _busy ? null : () => _withdraw(r))),
                ],
              ]),
              if (finished || !open) Padding(padding: const EdgeInsets.only(top: 2), child: ExlButton3D('RANKS', tone: ExlTone.ghost, height: 44, fontSize: 14, onTap: () => widget.onRanks(r['id'] as String))),
            ]),
          ),
        ]),
      ),
      if (widget.extra != null) ...[const SizedBox(height: 10), widget.extra!(r)],
      const SizedBox(height: 10),
      ExlSteps(accent: accent, title: 'HOW IT WORKS', current: finished ? 6 : _stepIndex(me, open, left), skipped: _unsigned(me, entries) ? const {3} : const {}, onTap: () => showTourneyHowItWorks(context, accent: accent),
          steps: [for (final st in kTourneyHowSteps) st.label]),
      const SizedBox(height: 10),
      // ---- players
      _panel('PLAYERS · ${entries.length}', [
        if (entries.isEmpty) Text('No players yet.', style: exlBody(12, color: exlCyanDim)),
        for (var i = 0; i < entries.length; i++) _row(i, entries[i], payouts, cur, finished),
      ]),
      const SizedBox(height: 12),
      // ---- prize split
      _panel(finished ? 'PAYOUTS' : 'PRIZE SPLIT', [
        if (!finished) for (var i = 0; i < weights.length; i++) Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(children: [
          Text('#${i + 1}', style: exlT(13, color: exlIce)), const SizedBox(width: 8),
          Text('${weights[i]}%', style: const TextStyle(color: exlCyanDim, fontSize: 11)), const Spacer(),
          Text(exlFmtAmt(pool * weights[i] / 100, cur), style: exlT(13, color: exlIce)), const SizedBox(width: 6),
          exlUsdText(prices, pool * weights[i] / 100, cur),
        ])),
        if (!finished) Text('Based on the current pool · service fee $feePct% · fewer finishers than places → the whole pool is shared among the finishers · no valid score → full refund',
            style: TextStyle(color: exlCyanDim.withOpacity(0.9), fontSize: 10.5, height: 1.4)),
        if (finished && payouts.isEmpty) Text('No payouts recorded.', style: exlBody(12, color: exlCyanDim)),
        for (final p in payouts) GestureDetector(
          onTap: p['explorer'] != null ? () => launchUrl(Uri.parse(p['explorer'] as String), mode: LaunchMode.externalApplication) : null,
          child: Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(children: [
            Text(p['role'] == 'prize' ? '#${p['rank']}' : (p['role'] as String), style: exlT(12, color: p['role'] == 'prize' ? exlIce : exlCyanDim)), const SizedBox(width: 8),
            Text(_short(p['wallet'] as String), style: const TextStyle(color: exlCyanDim, fontSize: 11.5)), const Spacer(),
            Text(exlFmtAmt(p['amount'] as num, cur), style: exlT(13, color: exlIce)),
            if (p['explorer'] != null) ...[const SizedBox(width: 6), const Icon(Icons.open_in_new, size: 12, color: exlCyanDim)],
          ])),
        ),
      ]),
      const SizedBox(height: 12),
      Center(child: GestureDetector(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProofScreen(apiBase: widget.apiBase, tournamentId: r['id'] as String))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.verified_outlined, size: 12, color: exlCyanDim.withOpacity(0.9)), const SizedBox(width: 4),
          Text('provably fair · seed commitment · proof', style: TextStyle(color: exlCyanDim.withOpacity(0.9), fontSize: 11)),
        ]),
      )),
    ]);
  }

  Widget _row(int i, Map e, List<Map> payouts, String cur, bool finished) {
    final w = e['wallet'] as String;
    final mine = w == _wallet;
    final prize = payouts.cast<Map?>().firstWhere((p) => p!['role'] == 'prize' && p['wallet'] == w, orElse: () => null);
    final played = e['played'] == true;
    return Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Row(children: [
      ExlAvatar(w, me: mine), const SizedBox(width: 10),
      Expanded(child: Row(children: [
        Flexible(child: Text(mine ? 'you' : _short(w), overflow: TextOverflow.ellipsis, style: exlT(14, color: mine ? exlCyan : exlIce))),
        if (e['verified'] == true) ...[const SizedBox(width: 4), const Icon(Icons.verified, size: 13, color: exlGreenGo)],
      ])),
      if (prize != null) Padding(padding: const EdgeInsets.only(right: 8), child: Text('+${exlFmtAmt(prize['amount'] as num, cur)}', style: exlT(12, color: exlGoldBright))),
      played ? Text('${e['score']}', style: exlT(15, color: exlIce))
             : ExlPill(finished ? 'NO RUN' : 'NOT PLAYED', color: const Color(0xFF8FA3BF), asset: 'rozet_waiting', icon: Icons.hourglass_bottom),
    ]));
  }

  Widget _panel(String title, List<Widget> children) => ExlPanel(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: exlT(12, color: exlCyan, spacing: 2)), const SizedBox(height: 6), ...children]));

  Widget _stat(String label, String value, String? sub, Color color, {int flex = 1}) => Expanded(flex: flex, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(color: exlCyanDim, fontSize: 10, letterSpacing: 1.5)), const SizedBox(height: 2),
    Text(value, style: TextStyle(fontFamily: exlFont, color: color, fontSize: 15)),
    if (sub != null) Text(sub, style: const TextStyle(color: exlCyanDim, fontSize: 10)),
  ]));

  String _short(String w) => w.length > 10 ? '${w.substring(0, 4)}…${w.substring(w.length - 4)}' : w;
}

// ============================================================================
// ExlTournamentGrid — the TOURNEYS tab on ONE page: SOL column left, SKR column
// right, three tiles each (Daily → Weekly → Monthly, smallest stake on top).
// Tapping a tile opens the tournament room (PAY · PLAY · WITHDRAW live there).
// ============================================================================
// v1.3: the tournament flow as steps — strip labels + one line each (HOW IT WORKS sheet).
const List<ExlHowStep> kTourneyHowSteps = [
  ExlHowStep('Connect\nwallet', 'Seeker (Seed Vault) or Phantom through Mobile Wallet Adapter. The game stays free to play without one.'),
  ExlHowStep('Pay\nentry', 'One entry per tournament, in SOL or SKR. You can WITHDRAW until your first run starts (minus the service and network fee); after that the entry is final.'),
  ExlHowStep('Play\ngame', 'Daily 1 · Weekly 3 · Monthly 10 attempts. Everyone plays the same course (same server seed). An attempt is used the moment the run starts; if you leave a run, the score reached so far is your result for it.'),
  ExlHowStep('Sign\nscore', 'After the run, SIGN YOUR SCORE asks your wallet for a signature — only a message, no transaction. Your best valid score is your result; signed scores carry a ✓ and prove the score came from your wallet. If the wallet gives no signature you can sign again or still submit the run.'),
  ExlHowStep('Wait for\nthe clock', 'The leaderboard is live until the clock ends. A run started before the end still counts when it finishes.'),
  ExlHowStep('Auto\npayout', 'Prizes are paid on-chain the moment the clock ends. Daily: winner 99%. Weekly top 3: 50 · 30 · 17%. Monthly top 10: 30 · 18 · 12 · 9 · 7 · 6 · 5 · 4 · 2 · 2%. Fewer finishers than places → the pool is still split among the finishers.'),
];

Future<void> showTourneyHowItWorks(BuildContext context, {Color accent = exlCyan, VoidCallback? onMore}) =>
    showExlHowItWorks(context, title: 'HOW TOURNAMENTS WORK', accent: accent, steps: kTourneyHowSteps,
        footer: 'Fees 1% (daily) · 3% (weekly) · 5% (monthly) cover network costs and automated payouts · ties go to the earlier score · flagged scores never rank · every tournament has a PROOF page with each payout\'s Solscan link.',
        moreLabel: 'Full rules & Terms →', onMore: onMore);

class ExlTournamentGrid extends StatelessWidget {
  final List<Map> tournaments;
  final Map? prices;
  final String? wallet;
  final void Function(Map t) onOpen;
  final VoidCallback? onDetails;
  const ExlTournamentGrid({super.key, required this.tournaments, required this.prices, required this.wallet, required this.onOpen, this.onDetails});

  static const _order = {'d': 0, 'w': 1, 'm': 2};
  List<Map> _col(String cur) {
    final l = tournaments.where((t) => (t['currency'] ?? 'SOL') == cur).toList();
    l.sort((a, b) {
      final fa = a['feeLamports'] as num, fb = b['feeLamports'] as num;
      if (fa != fb) return fa.compareTo(fb);
      return (_order[a['type']] ?? 9).compareTo(_order[b['type']] ?? 9);
    });
    return l;
  }

  @override
  Widget build(BuildContext context) {
    final sol = _col('SOL'), skr = _col('SKR');
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Column(children: [
        Text('same course for everyone · best score counts · prizes paid on-chain when the clock ends', textAlign: TextAlign.center, style: exlBody(10.5, color: exlCyanDim)),
        const SizedBox(height: 8),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: _column('SOL', exlCyan, sol)),
            const SizedBox(width: 10),
            Expanded(child: _column('SKR', exlGoldBright, skr)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => showTourneyHowItWorks(context, onMore: onDetails),
            child: Text('ⓘ  how tournaments work', style: TextStyle(color: exlCyan.withOpacity(0.95), fontSize: 11.5, letterSpacing: 0.5)),
          ),
        ),
      ]),
    );
  }

  Widget _column(String cur, Color accent, List<Map> list) {
    return Column(children: [
      Container(
        width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 5),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: accent.withOpacity(0.14), border: Border.all(color: exlInk, width: 1.5)),
        child: Center(child: ExlEmboss(cur, size: 16, spacing: 3, face: cur == 'SKR' ? const [Color(0xFFFFF4C2), Color(0xFFFFC94D), Color(0xFFE08E12)] : const [Color(0xFFFFFFFF), Color(0xFF3EE0F0), Color(0xFF1AA6C0)])),
      ),
      const SizedBox(height: 8),
      if (list.isEmpty)
        Expanded(child: Center(child: Text(cur == 'SKR' ? 'SKR pools\nnot available' : 'No open\ntournaments', textAlign: TextAlign.center, style: exlBody(11, color: exlCyanDim))))
      else
        for (var i = 0; i < list.length; i++) ...[
          Expanded(child: _tile(list[i], accent)),
          if (i < list.length - 1) const SizedBox(height: 8),
        ],
    ]);
  }

  Widget _tile(Map t, Color accent) {
    final type = t['type'] as String;
    final name = type == 'd' ? 'DAILY' : (type == 'w' ? 'WEEKLY' : 'MONTHLY');
    final cur = t['currency'] as String? ?? 'SOL';
    final me = t['me'] as Map?;
    final joined = me != null;
    final left = joined ? (t['attemptsMax'] as int) - (me['attemptsUsed'] as int) : 0;
    final endsAt = t['endsAt'] as int;
    final lastHour = endsAt - DateTime.now().millisecondsSinceEpoch < 3600 * 1000;
    final pool = t['poolLamports'] as num;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onOpen(t),
      child: ExlPanel(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        glow: joined ? accent : null,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Row(children: [
            Expanded(child: Text(name, style: exlT(14, color: accent, spacing: 2))),
            Text(exlCountdown(endsAt), style: TextStyle(color: lastHour ? exlOrange : exlIce, fontSize: 10.5, fontWeight: FontWeight.w700)),
          ]),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('POOL', style: TextStyle(color: exlCyanDim, fontSize: 9, letterSpacing: 1.5)),
            FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: ExlEmboss.gold(exlFmtAmt(pool, cur), size: 19, spacing: 0.3, align: TextAlign.left)),
            exlUsdText(prices, pool, cur, size: 9.5),
          ]),
          Row(children: [
            Expanded(child: Text('entry ${exlFmtAmt(t['feeLamports'] as num, cur)}', overflow: TextOverflow.ellipsis, style: const TextStyle(color: exlIce, fontSize: 10.5, fontWeight: FontWeight.w700))),
            Text('${t['participants'] ?? 0} 👤', style: const TextStyle(color: exlCyanDim, fontSize: 10.5)),
          ]),
          const SizedBox(height: 4),
          joined
              ? Row(children: [
                  const ExlPill('IN', color: exlGreenGo, asset: 'rozet_paid', icon: Icons.check),
                  const SizedBox(width: 6),
                  Expanded(child: Text(left > 0 ? '$left run${left == 1 ? '' : 's'} left · tap to PLAY' : 'run submitted · best ${me['bestScore']}', overflow: TextOverflow.ellipsis, style: TextStyle(color: left > 0 ? exlGreenGo : exlCyanDim, fontSize: 10, fontWeight: FontWeight.w700))),
                ])
              : ExlButton3D('ENTER ROOM', tone: cur == 'SKR' ? ExlTone.gold : ExlTone.cyan, height: 32, fontSize: 11.5, onTap: () => onOpen(t)),
        ]),
      ),
    );
  }
}
