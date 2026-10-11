// ============================================================================
// EXL TOURNEY — MY WALLET (client v1.3 Phase B)
// Everything you have in play across EXL games — open seats and entries with
// PLAY / WITHDRAW shortcuts — plus the history of payments, prizes and refunds
// with Solscan links. There is NO balance here on purpose: EXL never holds
// funds for you; every refund and prize goes straight to your wallet on-chain.
// Identical file in every EXL game.  Apache-2.0 — github.com/excobalab/exl-tourney
// ============================================================================
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'exl_duel.dart';
import 'exl_ui.dart';
import 'exl_wallet.dart';

class MyWalletScreen extends StatefulWidget {
  final String apiBase, appName, gameId, phantomScheme;
  final String? wallet;
  /// Called when the screen learned the wallet via a signature (host app stores it).
  final DuelWalletFn? onWallet;
  /// Switch wallet (host app clears the stored wallet). Optional.
  final VoidCallback? onSwitchWallet;
  /// Open one of THIS game's items: a duel room (type x) or a tournament room.
  final void Function(Map item) onOpenItem;
  /// v1.3: true → body only (used as the WALLET page inside the COMPETE screen); false → own Scaffold + AppBar.
  final bool embedded;
  const MyWalletScreen({super.key, required this.apiBase, required this.appName, required this.gameId, required this.wallet,
      this.phantomScheme = '', this.onWallet, this.onSwitchWallet, required this.onOpenItem, this.embedded = false});
  @override
  State<MyWalletScreen> createState() => _MyWalletScreenState();
}

class _MyWalletScreenState extends State<MyWalletScreen> {
  late final DuelApi _api = DuelApi(widget.apiBase);
  String? _wallet;
  Map<String, dynamic>? _d;
  String? _error;
  bool _busy = false;

  @override
  void initState() { super.initState(); _wallet = widget.wallet; if (_wallet != null) _load(); }

  @override
  void didUpdateWidget(covariant MyWalletScreen old) {
    super.didUpdateWidget(old);
    if (old.wallet != widget.wallet) { _wallet = widget.wallet; _d = null; if (_wallet != null) _load(); else setState(() {}); }
  }

  Future<void> _load() async {
    final w = _wallet; if (w == null) return;
    try { final d = await _api.wallet(w); if (mounted) setState(() { _d = d; _error = null; }); }
    catch (e) { if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', '')); }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  Future<void> _identify() async {
    final w = await exlIdentifyWallet(context, appName: widget.appName, phantomScheme: widget.phantomScheme,
        purpose: 'Sign to open your wallet', message: 'exl:wallet:view:${DateTime.now().millisecondsSinceEpoch}');
    if (w == null) return;
    widget.onWallet?.call(w);
    setState(() { _wallet = w; _d = null; });
    _load();
  }

  Future<void> _withdraw(Map it) async {
    final q = it['withdraw'] as Map?; final w = _wallet;
    if (q == null || w == null) return;
    final cur = it['currency'] as String;
    final ok = await exlConfirmWithdraw(context, quote: q, cur: cur, prices: _d?['prices'] as Map?,
        what: it['type'] == 'x' ? 'Take your stake back before the host starts the room.' : 'Take your entry fee back before your first run.');
    if (!ok) return;
    setState(() => _busy = true);
    try { final r = await _api.withdraw(it['id'] as String, w); _snack('Refunded ${exlFmtAmt(r['refund'] as num, cur)} to your wallet'); }
    catch (e) {
      if (!mounted) return;
      final again = await exlRetryDialog(context, title: 'WITHDRAW FAILED', message: '${e.toString().replaceFirst('Exception: ', '')}\n\nYour entry is unchanged.');
      if (mounted) setState(() => _busy = false);
      await _load();
      if (again && mounted) return _withdraw(it);
      return;
    }
    finally { if (mounted) setState(() => _busy = false); _load(); }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) return _wallet == null ? _noWallet() : _body();
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, centerTitle: true,
        title: const ExlEmboss('WALLET', size: 22, spacing: 3),
        actions: [
          if (_wallet != null && widget.onSwitchWallet != null)
            IconButton(tooltip: 'Switch wallet', onPressed: () { widget.onSwitchWallet!(); if (!widget.embedded) Navigator.pop(context); }, icon: const Icon(Icons.swap_horiz, color: exlCyanDim)),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh, color: exlCyanDim)),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(gradient: RadialGradient(center: Alignment(0, -0.6), radius: 1.5, colors: [Color(0xFF0E2A52), exlBgBottom])),
        child: SafeArea(child: _wallet == null ? _noWallet() : _body()),
      ),
    );
  }

  Widget _noWallet() => Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [
    SizedBox(height: 90, child: ExlUiImage('ikon_wallet', fallback: const ExlIcon3D(Icons.account_balance_wallet, size: 80))),
    const SizedBox(height: 16),
    const ExlEmboss('NO WALLET YET', size: 20, spacing: 2),
    const SizedBox(height: 8),
    Text('Sign a short message with your wallet to see your seats, entries, prizes and refunds across all EXL games.',
        textAlign: TextAlign.center, style: exlBody(12.5, color: exlIce)),
    const SizedBox(height: 18),
    ExlButton3D('SIGN TO VIEW', tone: ExlTone.cyan, onTap: _identify),
  ])));

  Widget _body() {
    final d = _d;
    if (_error != null && d == null) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: exlRed)), const SizedBox(height: 12),
      ExlButton3D('RETRY', tone: ExlTone.ghost, expand: false, height: 44, fontSize: 14, onTap: _load),
    ])));
    if (d == null) return const Center(child: CircularProgressIndicator(strokeWidth: 2, color: exlCyan));
    final open = (d['open'] as List).cast<Map>();
    final hist = (d['history'] as List).cast<Map>();
    final prices = d['prices'] as Map?;
    final w = _wallet!;
    return RefreshIndicator(
      color: exlCyan, backgroundColor: exlPanel, onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 28), children: [
        // ---- identity card
        ExlPanel(glow: exlCyan, child: Row(children: [
          ExlAvatar(w, size: 44, me: true),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_short(w), style: exlT(18, color: exlIce, spacing: 1)),
            const SizedBox(height: 2),
            Text('Entries, prizes and refunds of this wallet across EXL games.', style: exlBody(11, color: exlCyanDim)),
          ])),
          IconButton(tooltip: 'Copy address', onPressed: () { Clipboard.setData(ClipboardData(text: w)); _snack('Address copied'); }, icon: const Icon(Icons.copy, size: 18, color: exlCyanDim)),
          if (widget.embedded && widget.onSwitchWallet != null)
            IconButton(tooltip: 'Switch wallet', onPressed: () { widget.onSwitchWallet!(); setState(() { _wallet = null; _d = null; }); }, icon: const Icon(Icons.swap_horiz, size: 20, color: exlCyanDim)),
        ])),
        const SizedBox(height: 18),
        exlLabel('IN PLAY · ${open.length}'),
        if (open.isEmpty) _empty('Nothing in play. Paid entries and seats show up here.'),
        for (final it in open) _openCard(it, prices),
        const SizedBox(height: 10),
        exlLabel('HISTORY'),
        if (hist.isEmpty) _empty('No payments yet.'),
        for (final h in hist) _histRow(h, prices),
        const SizedBox(height: 14),
        Center(child: Text('Tap a row to open the transaction on Solscan', style: TextStyle(color: exlCyanDim.withOpacity(0.9), fontSize: 10.5))),
      ]),
    );
  }

  Widget _empty(String t) => Container(margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: exlCyanDim.withOpacity(0.5))),
      child: Text(t, style: exlBody(12.5, color: exlCyanDim)));

  Widget _openCard(Map it, Map? prices) {
    final cur = it['currency'] as String;
    final accent = cur == 'SKR' ? exlGoldBright : exlCyan;
    final thisGame = it['game'] == widget.gameId;
    final isRoom = it['type'] == 'x';
    final st = it['status'] as String;
    final title = isRoom ? 'ROOM ${it['code']}' : (it['typeLabel'] as String).toUpperCase();
    final canPlay = it['canPlay'] == true, canWd = it['canWithdraw'] == true;
    return Padding(padding: const EdgeInsets.only(bottom: 10), child: ExlPanel(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12), glow: st == 'live' ? exlGreenGo : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          SizedBox(width: 26, height: 26, child: ExlUiImage(isRoom ? 'ikon_duels' : 'ikon_tournaments', fallback: ExlIcon3D(isRoom ? Icons.bolt : Icons.emoji_events, size: 24, color: exlGoldBright))),
          const SizedBox(width: 8),
          Expanded(child: Text('${it['gameName']} · $title', overflow: TextOverflow.ellipsis, style: exlT(14, color: exlIce))),
          ExlPill(cur, color: accent),
          const SizedBox(width: 6),
          _statusPill(st, isRoom),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Text('PAID ${exlFmtAmt(it['paid'] as num, cur)}', style: exlT(12.5, color: accent)),
          const SizedBox(width: 6), exlUsdText(prices, it['paid'] as num, cur),
          const Spacer(),
          Text(isRoom && st != 'live' ? 'room closes ${exlCountdown(it['endsAt'] as int)}' : 'ends ${exlCountdown(it['endsAt'] as int)}', style: const TextStyle(color: exlCyanDim, fontSize: 11)),
        ]),
        const SizedBox(height: 4),
        Text((it['attemptsUsed'] as int) == 0
                ? (isRoom && st != 'live' ? 'Waiting for the host to start' : 'Not played yet')
                : 'Played · best ${it['bestScore']} · ${(it['attemptsMax'] as int) - (it['attemptsUsed'] as int)} attempt(s) left',
            style: exlBody(11.5, color: exlCyanDim)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(flex: 3, child: ExlButton3D(
              thisGame ? (canPlay ? 'PLAY' : 'OPEN ROOM') : 'OPEN IN ${(it['gameName'] as String).toUpperCase()}',
              tone: canPlay && thisGame ? ExlTone.green : ExlTone.cyan, height: 44, fontSize: 13,
              onTap: thisGame ? () => widget.onOpenItem(it) : null)),
          if (canWd) ...[const SizedBox(width: 8), Expanded(flex: 2, child: ExlButton3D('WITHDRAW', tone: ExlTone.ghost, height: 44, fontSize: 12.5, onTap: _busy ? null : () => _withdraw(it)))],
        ]),
      ]),
    ));
  }

  Widget _statusPill(String st, bool isRoom) {
    switch (st) {
      case 'live': return const ExlPill('LIVE', color: exlGreenGo, asset: 'rozet_live', icon: Icons.play_arrow);
      case 'open': return isRoom ? const ExlPill('WAITING', color: exlCyan, asset: 'rozet_waiting', icon: Icons.hourglass_bottom) : const ExlPill('OPEN', color: exlCyan);
      case 'pending': return const ExlPill('UNPAID ROOM', color: exlOrange);
      default: return ExlPill(st.toUpperCase(), color: const Color(0xFF8FA3BF));
    }
  }

  Widget _histRow(Map h, Map? prices) {
    final kind = h['kind'] as String;
    final cur = h['currency'] as String;
    final amt = h['amount'] as num;
    final tx = h['tx'] as String?;
    final pending = h['pending'] == true;
    final at = DateTime.fromMillisecondsSinceEpoch((h['at'] as num).toInt());
    final isRoom = h['type'] == 'x';
    String label; Color color; String asset; IconData icon;
    switch (kind) {
      case 'prize': label = 'PRIZE · #${h['rank']}'; color = exlGoldBright; asset = 'ikon_tournaments'; icon = Icons.emoji_events; break;
      case 'withdraw': label = 'WITHDRAWN'; color = exlCyan; asset = 'rozet_withdraw'; icon = Icons.undo; break;
      case 'refund': label = h['note'] == 'duplicate payment' ? 'REFUND · DUPLICATE' : 'REFUND'; color = exlCyan; asset = 'rozet_withdraw'; icon = Icons.replay; break;
      default: label = h['status'] == 'withdrawn' ? 'ENTRY (withdrawn)' : 'ENTRY'; color = exlIce; asset = 'rozet_pay'; icon = Icons.paid;
    }
    final sub = '${h['gameName']} · ${isRoom ? 'room ${(h['id'] as String).split(':').last}' : h['typeLabel']} · ${_fmtDate(at)}';
    return GestureDetector(
      onTap: tx == null || tx == 'DRY_RUN' ? null : () => launchUrl(Uri.parse('https://solscan.io/tx/$tx'), mode: LaunchMode.externalApplication),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6), padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: exlPanel.withOpacity(0.7), border: Border.all(color: exlInk, width: 1.5)),
        child: Row(children: [
          SizedBox(width: 24, height: 24, child: ExlUiImage(asset, fallback: ExlIcon3D(icon, size: 22, color: color))),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: exlT(12, color: color, spacing: 1.5)),
            Text(sub, style: const TextStyle(color: exlCyanDim, fontSize: 10.5)),
          ])),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${amt < 0 ? '−' : '+'}${exlFmtAmt(amt.abs(), cur)}', style: exlT(14, color: amt < 0 ? exlIce : exlGreenGo)),
            if (pending) const Text('pending', style: TextStyle(color: exlOrange, fontSize: 10))
            else if (tx != null) const Icon(Icons.open_in_new, size: 11, color: exlCyanDim),
          ]),
        ]),
      ),
    );
  }

  String _fmtDate(DateTime d) => '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  String _short(String w) => w.length > 12 ? '${w.substring(0, 6)}…${w.substring(w.length - 6)}' : w;
}
