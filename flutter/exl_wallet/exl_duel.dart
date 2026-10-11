// ============================================================================
// EXL TOURNEY — DUEL / ROOM MODE (client v1.3 · seat mode)
// "Cautious by design": a room opens WITHOUT payment. Players take seats, each
// pays from their own row when they feel ready, the host presses START once
// every seat is paid. Nothing is spent before the player decides to.
// Identical file in every EXL game; game-specific bits come through DuelTab.
// Apache-2.0 — github.com/excobalab/exl-tourney
// ============================================================================
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'exl_proof.dart';
import 'exl_ui.dart';
import 'exl_wallet.dart';

const Color exlGold = Color(0xFFD4B26A);
const Color exlGreen = Color(0xFF7FE0A8);
const Color exlOrange = Color(0xFFFFA24A);

// ---- formatting helpers (shared with main.dart) ----
String exlFmtAmt(num v, String cur) {
  if (cur == 'SKR') {
    final x = v / 1e6;
    return '${x % 1 == 0 ? x.toStringAsFixed(0) : x.toStringAsFixed(1)} SKR';
  }
  final s = v / 1e9;
  return '${s >= 1 ? s.toStringAsFixed(2) : s.toStringAsFixed(3)} SOL';
}

String? exlUsd(Map? prices, num v, String cur) {
  if (prices == null) return null;
  final p = prices[cur];
  if (p is! num || p <= 0) return null;
  final usd = (cur == 'SKR' ? v / 1e6 : v / 1e9) * p;
  if (usd <= 0) return null;
  return '≈ \$${usd >= 100 ? usd.toStringAsFixed(0) : (usd >= 1 ? usd.toStringAsFixed(2) : usd.toStringAsFixed(3))}';
}

Widget exlUsdText(Map? prices, num v, String cur, {double size = 10}) {
  final s = exlUsd(prices, v, cur);
  if (s == null) return const SizedBox.shrink();
  return Text(s, style: TextStyle(color: exlCyanDim, fontSize: size, letterSpacing: 0.3));
}

String exlCountdown(int endsAt, {int? nowMs}) {
  var s = ((endsAt - (nowMs ?? DateTime.now().millisecondsSinceEpoch)) / 1000).floor();
  if (s < 0) s = 0;
  final d = s ~/ 86400;
  s %= 86400;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  if (d > 0) return '${d}d ${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
}

String _short(String w) => w.length > 10 ? '${w.substring(0, 4)}…${w.substring(w.length - 4)}' : w;
String _win(int min) => min < 60 ? '$min min' : (min < 1440 ? '${min ~/ 60} h' : '${min ~/ 1440} day');

// ---- API ----
class DuelApi {
  final String apiBase;
  DuelApi(this.apiBase);

  Future<Map<String, dynamic>> _get(String path) async {
    final r = await http.get(Uri.parse('$apiBase$path')).timeout(const Duration(seconds: 20));
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    if (r.statusCode >= 400) throw Exception(j['error'] ?? 'Server error');
    return j;
  }

  Future<Map<String, dynamic>> _post(String path, Map body) async {
    final r = await http
        .post(Uri.parse('$apiBase$path'), headers: {'content-type': 'application/json'}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 25));
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    if (r.statusCode >= 400) throw Exception(j['error'] ?? 'Server error');
    return j;
  }

  Future<Map<String, dynamic>> list(String game, String? wallet) => _get('/duel/list?game=$game${wallet != null ? '&wallet=$wallet' : ''}');
  Future<Map<String, dynamic>> get(String id, String? wallet) => _get('/duel/get?id=${Uri.encodeComponent(id)}${wallet != null ? '&wallet=$wallet' : ''}');
  Future<Map<String, dynamic>> byCode(String game, String code, String? wallet) =>
      _get('/duel/get?game=$game&code=${Uri.encodeComponent(code)}${wallet != null ? '&wallet=$wallet' : ''}');
  Future<Map<String, dynamic>> create(Map body) => _post('/duel/create', body);
  // v1.3 seat mode
  Future<Map<String, dynamic>> seat(String id, String wallet) => _post('/duel/seat', {'id': id, 'wallet': wallet});
  Future<Map<String, dynamic>> leave(String id, String wallet) => _post('/duel/leave', {'id': id, 'wallet': wallet});
  Future<Map<String, dynamic>> kick(String id, String wallet, String to) => _post('/duel/kick', {'id': id, 'wallet': wallet, 'to': to});
  Future<Map<String, dynamic>> nudge(String id, String from, String to) => _post('/duel/nudge', {'id': id, 'from': from, 'to': to});
  Future<Map<String, dynamic>> transfer(String id, String wallet, String to) => _post('/duel/transfer', {'id': id, 'wallet': wallet, 'to': to});
  Future<Map<String, dynamic>> start(String id, String wallet) => _post('/duel/start', {'id': id, 'wallet': wallet});
  Future<Map<String, dynamic>> cancel(String id, String wallet) => _post('/duel/cancel', {'id': id, 'wallet': wallet}); // v4.3 host closes an unstarted room
  // v1.3 Phase B — withdraw a paid entry before playing (rooms until START; tournaments until the first run)
  Future<Map<String, dynamic>> withdraw(String tournamentId, String wallet) => _post('/withdraw', {'tournamentId': tournamentId, 'wallet': wallet});
  Future<Map<String, dynamic>> wallet(String wallet) => _get('/wallet?wallet=$wallet');
  Future<Map<String, dynamic>> troom(String id, String? wallet) => _get('/t/room?id=${Uri.encodeComponent(id)}${wallet != null ? '&wallet=$wallet' : ''}');
}

/// Confirmation sheet for a withdrawal. `quote` = {paid, fee, networkFee, refund, feePct} from the server. Returns true when confirmed.
Future<bool> exlConfirmWithdraw(BuildContext context, {required Map quote, required String cur, Map? prices, String? what}) async {
  final r = await showModalBottomSheet<bool>(
    context: context, backgroundColor: Colors.transparent, isScrollControlled: true,
    builder: (ctx) => Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
      decoration: const BoxDecoration(color: exlPanel, borderRadius: BorderRadius.vertical(top: Radius.circular(24)), border: Border(top: BorderSide(color: exlInk, width: 2))),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 42, height: 4, decoration: BoxDecoration(color: exlCyanDim, borderRadius: BorderRadius.circular(2)))),
        const SizedBox(height: 16),
        Row(children: [
          SizedBox(width: 34, height: 34, child: ExlUiImage('rozet_withdraw', fallback: const ExlIcon3D(Icons.undo, size: 30, color: exlGoldBright))),
          const SizedBox(width: 10),
          const ExlEmboss('WITHDRAW', size: 22, spacing: 3, align: TextAlign.left),
        ]),
        const SizedBox(height: 6),
        Text(what ?? 'Refund of your stake, minus the service fee and network fee, sent to your wallet on-chain.', style: exlBody(12.5, color: exlIce)),
        const SizedBox(height: 14),
        _qrow('You paid', exlFmtAmt(quote['paid'] as num, cur), exlIce),
        _qrow('Service fee (${quote['feePct']}%)', '− ${exlFmtAmt(quote['fee'] as num, cur)}', exlCyanDim),
        if ((quote['networkFee'] as num) > 0) _qrow('Network fee', '− ${exlFmtAmt(quote['networkFee'] as num, cur)}', exlCyanDim),
        const Divider(color: exlCyanDim, height: 18),
        Row(children: [
          Text('YOU GET BACK', style: exlT(12, color: exlCyan, spacing: 2)),
          const Spacer(),
          ExlEmboss.gold(exlFmtAmt(quote['refund'] as num, cur), size: 22, spacing: 0.5),
          const SizedBox(width: 6),
          exlUsdText(prices, quote['refund'] as num, cur, size: 11),
        ]),
        const SizedBox(height: 18),
        ExlButton3D('WITHDRAW ${exlFmtAmt(quote['refund'] as num, cur)}', tone: ExlTone.gold, onTap: () => Navigator.pop(ctx, true),
            leading: SizedBox(width: 22, height: 22, child: ExlUiImage('rozet_withdraw', fallback: const Icon(Icons.undo, color: exlInk, size: 22)))),
        const SizedBox(height: 8),
        ExlButton3D('KEEP MY SEAT', tone: ExlTone.ghost, height: 44, fontSize: 14, onTap: () => Navigator.pop(ctx, false)),
      ]),
    ),
  );
  return r == true;
}
Widget _qrow(String a, String b, Color c) => Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(children: [
  Text(a, style: TextStyle(color: c, fontSize: 12.5, fontWeight: FontWeight.w700)), const Spacer(), Text(b, style: exlT(14, color: c)),
]));

/// Pays the stake and registers the entry. Returns true on success.
typedef DuelJoinFn = Future<bool> Function(Map<String, dynamic> t, Map? skr, String poolAddress);
typedef DuelPlayFn = Future<void> Function(Map<String, dynamic> t);
typedef DuelRanksFn = void Function(String tournamentId);
/// Called when the duel UI learned the player's wallet (seat signature) so the host app can remember it.
typedef DuelWalletFn = void Function(String wallet);

Map<String, dynamic> _asTournament(Map room) => {
      'id': room['id'], 'type': 'x', 'currency': room['currency'] ?? 'SOL',
      'feeLamports': room['stake'], 'attemptsMax': 1, 'endsAt': room['endsAt'] ?? room['joinEndsAt'],
      'title': 'PAY YOUR SEAT · ${room['code']}',
      'subtitle': 'Stake goes to the on-chain pot. One run, same seed for everyone. Withdraw available until the host starts.',
    };

/// Ask the wallet for a signature to identify the player (no payment). Returns the wallet or null.
Future<String?> exlIdentifyWallet(BuildContext context, {required String appName, required String phantomScheme, required String purpose, required String message}) async {
  final r = await showExlSignSheet(context,
      appName: appName, phantomScheme: phantomScheme, message: message, score: 0,
      title: purpose.toUpperCase(), body: 'Signs a short message to identify your wallet in this room. No transaction.', skipLabel: '');
  return r?.wallet;
}

// ============================== DUEL TAB ==============================

// v1.3: the duel flow as steps — strip labels + one line each (shown in the HOW IT WORKS sheet).
const List<ExlHowStep> kDuelHowSteps = [
  ExlHowStep('Create\nroom', 'Pick SOL or SKR, the stake, 2–10 players, the clock and how the pot is split. The room gets a code. Creating costs nothing.'),
  ExlHowStep('Share\ncode', 'Players join with the code or from PUBLIC ROOMS. A public room is listed once the host has paid. Invited wallets get a reserved seat.'),
  ExlHowStep('Players\npay', 'Each player pays the stake from their own seat. A paid seat can WITHDRAW until the host starts (minus the service fee).'),
  ExlHowStep('Host\nSTARTs', 'When every seat has paid, the host presses START and the clock begins for everyone at once. Until then the host can CLOSE the room; a closed room or one that never starts refunds every stake in full.'),
  ExlHowStep('Play\ngame', 'One run each, on the same course. If you leave a run, the score reached so far is your result. The room closes early once everyone has played; a run started before the clock ends still counts.'),
  ExlHowStep('Sign\nscore', 'After the run, SIGN YOUR SCORE asks your wallet for a signature — only a message, no transaction. Signed scores carry a ✓ and prove the score came from your wallet. If the wallet gives no signature you can sign again or still submit the run.'),
  ExlHowStep('Auto\npayout', 'The pot is paid on-chain to the winner(s) the moment the room ends. Service fee 3% (SOL) · 5% (SKR). Ties split the prize equally.'),
];

Future<void> showDuelHowItWorks(BuildContext context, {Color accent = exlGoldBright}) =>
    showExlHowItWorks(context, title: 'HOW DUELS WORK', accent: accent, steps: kDuelHowSteps,
        footer: 'Flagged scores never rank · fewer than 2 players or no valid score → full refund minus the network fee · every payout has a Solscan link on the room\'s PROOF page.');

class DuelTab extends StatefulWidget {
  final String apiBase, gameId, appName, phantomScheme;
  final String? wallet;
  final bool busy;
  final DuelJoinFn onJoin;
  final DuelPlayFn onPlay;
  final DuelRanksFn onRanks;
  final DuelWalletFn? onWallet;
  /// v1.4 (EXathlon): play button label + extra room panel, passed through to every RoomScreen opened from here.
  final String playLabel;
  final Widget Function(Map<String, dynamic> r)? roomExtra;
  const DuelTab({
    super.key, required this.apiBase, required this.gameId, required this.appName, required this.wallet,
    required this.busy, required this.onJoin, required this.onPlay, required this.onRanks,
    this.phantomScheme = '', this.onWallet, this.playLabel = 'PLAY YOUR RUN', this.roomExtra,
  });

  @override
  State<DuelTab> createState() => DuelTabState();
}

class DuelTabState extends State<DuelTab> {
  late final DuelApi _api = DuelApi(widget.apiBase);
  Map<String, dynamic>? _data;
  String? _error;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    load();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); });
  }

  @override
  void dispose() { _clock?.cancel(); super.dispose(); }

  @override
  void didUpdateWidget(covariant DuelTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.wallet != widget.wallet) load();
  }

  Future<void> load() async {
    setState(() => _error = null);
    try {
      final d = await _api.list(widget.gameId, widget.wallet);
      if (mounted) setState(() => _data = d);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 4)));

  Future<void> _openRoom(String id) async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => RoomScreen(
            apiBase: widget.apiBase, gameId: widget.gameId, appName: widget.appName, phantomScheme: widget.phantomScheme, roomId: id, wallet: widget.wallet,
            onJoin: widget.onJoin, onPlay: widget.onPlay, onRanks: widget.onRanks, onWallet: widget.onWallet,
            playLabel: widget.playLabel, extra: widget.roomExtra,
            onRematch: (room) => _rematch(room))));
    load();
  }

  Future<void> _joinWithCode() async {
    final ctrl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: exlPanel, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: exlInk, width: 2)),
        title: Text('JOIN WITH CODE', style: exlT(16, color: exlCyan, spacing: 2)),
        content: TextField(
          controller: ctrl, autofocus: true, textCapitalization: TextCapitalization.characters, maxLength: 6,
          style: const TextStyle(color: exlIce, fontSize: 24, letterSpacing: 6, fontWeight: FontWeight.w800, fontFamily: 'monospace'),
          decoration: const InputDecoration(hintText: 'ABC123', hintStyle: TextStyle(color: exlCyanDim, letterSpacing: 6), counterText: ''),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('CANCEL', style: TextStyle(color: exlCyanDim))),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('OPEN', style: TextStyle(color: exlCyan))),
        ],
      ),
    );
    if (code == null || code.trim().isEmpty) return;
    try {
      final r = await _api.byCode(widget.gameId, code.trim().toUpperCase(), widget.wallet);
      await _openRoom(r['id'] as String);
    } catch (e) { _snack(e.toString().replaceFirst('Exception: ', '')); }
  }

  /// v1.3: CREATE opens the room without payment; the creator pays from their own seat later.
  /// [prefill] opens the Create Room form with those settings. [direct] skips the form (REMATCH: same rules, same people —
  /// [invite] wallets get a reserved seat so the room shows up in their list without a code).
  Future<void> _create({Map? prefill, bool direct = false, List<String> invite = const []}) async {
    final limits = _data?['limits'] as Map?;
    if (limits == null) { _snack('Loading room limits, try again'); return; }
    Map<String, dynamic>? settings;
    if (direct && prefill != null) {
      settings = Map<String, dynamic>.from(prefill);
    } else {
      settings = await Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(
        builder: (_) => CreateRoomScreen(limits: limits, prices: _data?['prices'] as Map?, skrAvailable: _data?['skr'] != null, prefill: prefill),
      ));
    }
    if (settings == null || !mounted) return;
    var wallet = widget.wallet;
    if (wallet == null) {
      wallet = await exlIdentifyWallet(context, appName: widget.appName, phantomScheme: widget.phantomScheme,
          purpose: 'Sign to open your room', message: 'exl:room:create:${widget.gameId}:${DateTime.now().millisecondsSinceEpoch}');
      if (wallet == null) { _snack('A wallet signature is needed to host a room.'); return; }
      widget.onWallet?.call(wallet);
    }
    try {
      final others = invite.where((w) => w != wallet).toList();
      final r = await _api.create({...settings, 'game': widget.gameId, 'wallet': wallet, 'seatMode': true, if (others.isNotEmpty) 'inviteWallets': others});
      if (!mounted) return;
      if ((r['invited'] as int? ?? 0) > 0) _snack('Room ${r['code']} opened — ${r['invited']} player(s) invited to their seats');
      await _openRoom(r['id'] as String);
    } catch (e) { _snack(e.toString().replaceFirst('Exception: ', '')); }
  }

  /// Same rules + same people, no form, no code.
  Map<String, dynamic> _settingsOf(Map r) => {
        'currency': r['currency'], 'stake': r['stake'], 'players': r['maxPlayers'], 'dist': r['dist'], 'visibility': r['visibility'],
        'joinMin': _nearestWin((r['joinMs'] as int?) ?? 3600000), 'playMin': _nearestWin((r['playMs'] as int?) ?? 3600000),
      };
  static int _nearestWin(int ms) { const opts = [15, 60, 360, 1440]; final m = ms ~/ 60000; return opts.reduce((a, b) => (a - m).abs() <= (b - m).abs() ? a : b); }
  Future<void> _rematch(Map r) => _create(prefill: _settingsOf(r), direct: true,
      invite: ((r['participants'] as List?) ?? (r['entries'] as List).map((e) => (e as Map)['wallet'])).cast<String>().toList());

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: exlRed, fontSize: 14, height: 1.5)),
        const SizedBox(height: 14),
        ExlButton3D('RETRY', onTap: load, tone: ExlTone.ghost, expand: false, height: 44, fontSize: 14),
      ])));
    }
    if (_data == null) return const Center(child: CircularProgressIndicator(strokeWidth: 2, color: exlCyan));
    final mine = (_data!['mine'] as List).cast<Map>();
    final pub = (_data!['public'] as List).cast<Map>().where((r) => !_imIn(r)).toList();
    final live = mine.where((r) => r['status'] == 'live').length;
    final waiting = mine.where((r) => r['status'] == 'open' || r['status'] == 'pending').length;
    final roomsSub = mine.isEmpty && pub.isEmpty
        ? 'no rooms yet'
        : [if (live > 0) '$live live', if (waiting > 0) '$waiting waiting', if (pub.isNotEmpty) '${pub.length} public'].join(' · ');
    // v1.3: the DUELS page is one centred panel — Create · Join with code · Open rooms (the lists live on their own screen)
    return RefreshIndicator(
      color: exlCyan, backgroundColor: exlPanel, onRefresh: load,
      child: LayoutBuilder(builder: (ctx, c) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: c.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: ExlPanel(
                  glow: exlGoldBright,
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    SizedBox(width: 64, height: 64, child: ExlUiImage('ikon_duels', fallback: const ExlIcon3D(Icons.bolt, size: 56, color: exlGoldBright))),
                    const SizedBox(height: 8),
                    const ExlEmboss.gold('CHALLENGE ANYONE', size: 22, spacing: 1.5),
                    const SizedBox(height: 6),
                    Text('Set the stake, players and clock. Share the code. Each player pays from their own seat; the host starts the room.',
                        textAlign: TextAlign.center, style: exlBody(12, color: exlIce)),
                    const SizedBox(height: 16),
                    ExlButton3D('CREATE ROOM', height: 56, onTap: widget.busy ? null : () => _create(),
                        leading: SizedBox(width: 24, height: 24, child: ExlUiImage('rozet_start', fallback: const Icon(Icons.add_circle, color: exlInk, size: 22)))),
                    const SizedBox(height: 10),
                    ExlButton3D('JOIN WITH CODE', tone: ExlTone.cyan, height: 50, fontSize: 15, onTap: widget.busy ? null : _joinWithCode,
                        leading: SizedBox(width: 24, height: 24, child: ExlUiImage('rozet_pay', fallback: const Icon(Icons.vpn_key, color: exlInk, size: 22)))),
                    const SizedBox(height: 10),
                    ExlButton3D('PUBLIC ROOMS', sub: roomsSub, tone: ExlTone.cyan, height: 56, fontSize: 15, onTap: () => _openRoomsList(),
                        leading: SizedBox(width: 24, height: 24, child: ExlUiImage('ikon_ranks', fallback: const Icon(Icons.meeting_room, color: exlInk, size: 22)))),
                    const SizedBox(height: 14),
                    ExlSteps(accent: exlGoldBright, title: 'HOW IT WORKS', current: -1, onTap: () => showDuelHowItWorks(context),
                        steps: [for (final st in kDuelHowSteps) st.label]),
                    const SizedBox(height: 10),
                    Text('Service fee 3% (SOL) · 5% (SKR) · withdraw until the host starts · rooms that never start refund every stake',
                        textAlign: TextAlign.center, style: TextStyle(color: exlCyanDim.withOpacity(0.95), fontSize: 10.5, height: 1.4)),
                  ]),
                ),
              ),
            ),
          ),
        ),
      )),
    );
  }

  Future<void> _openRoomsList() async {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => OpenRoomsScreen(api: _api, gameId: widget.gameId, wallet: widget.wallet, busy: widget.busy, onOpen: (id) => _openRoom(id), onCreate: () => _create(), onRematch: (room) async { Navigator.pop(context); await _rematch(room); })));
    load();
  }

  bool _imIn(Map r) {
    if (widget.wallet == null) return false;
    if (r['me'] != null) return true;
    final seats = (r['seats'] as List?)?.cast<Map>() ?? const [];
    return seats.any((s) => s['wallet'] == widget.wallet);
  }

}

// ============================== OPEN ROOMS (list screen) ==============================
/// v1.3: rooms shown as tiles like the tournaments page — YOUR ROOMS first, then PUBLIC rooms. Tap → room screen.
class OpenRoomsScreen extends StatefulWidget {
  final DuelApi api;
  final String gameId;
  final String? wallet;
  final bool busy;
  final void Function(String id) onOpen;
  final VoidCallback onCreate;
  final void Function(Map room) onRematch;
  const OpenRoomsScreen({super.key, required this.api, required this.gameId, required this.wallet, required this.busy, required this.onOpen, required this.onCreate, required this.onRematch});
  @override
  State<OpenRoomsScreen> createState() => _OpenRoomsScreenState();
}

class _OpenRoomsScreenState extends State<OpenRoomsScreen> {
  Map<String, dynamic>? _data;
  String? _error;
  Timer? _clock;
  bool _showMine = true;    // v1.3: every heading folds — YOUR ROOMS starts open, PUBLIC ROOMS and ROOM HISTORY start folded
  bool _showPublic = false;
  bool _showPast = false;

  @override
  void initState() {
    super.initState();
    _load();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); });
  }
  @override
  void dispose() { _clock?.cancel(); super.dispose(); }

  Future<void> _load() async {
    try { final d = await widget.api.list(widget.gameId, widget.wallet); if (mounted) setState(() { _data = d; _error = null; }); }
    catch (e) { if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', '')); }
  }

  bool _imIn(Map r) {
    if (widget.wallet == null) return false;
    if (r['me'] != null) return true;
    return ((r['seats'] as List?)?.cast<Map>() ?? const []).any((s) => s['wallet'] == widget.wallet);
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, centerTitle: true,
        leading: IconButton(onPressed: () => Navigator.of(context).maybePop(), icon: const Icon(Icons.arrow_back, color: exlCyanDim)),
        title: const ExlEmboss('PUBLIC ROOMS', size: 22, spacing: 3),
        actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh, color: exlCyanDim))],
      ),
      body: Container(
        decoration: const BoxDecoration(gradient: RadialGradient(center: Alignment(0, -0.6), radius: 1.5, colors: [Color(0xFF0E2A52), exlBgBottom])),
        child: SafeArea(
          child: _error != null && d == null
              ? Center(child: Text(_error!, style: const TextStyle(color: exlRed)))
              : d == null
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2, color: exlCyan))
                  : _body(d),
        ),
      ),
    );
  }

  Widget _body(Map<String, dynamic> d) {
    final all = (d['mine'] as List).cast<Map>();
    bool done(Map r) => r['status'] == 'paid' || r['status'] == 'cancelled';
    final mine = all.where((r) => !done(r)).toList();                       // only open / live / settling rooms up here
    final pub = (d['public'] as List).cast<Map>().where((r) => !_imIn(r)).toList();
    final past = ((d['past'] as List?) ?? const []).cast<Map>().toList();
    for (final r in all.where(done)) { if (!past.any((p) => p['id'] == r['id'])) past.add(r); }   // finished rooms → history
    final prices = d['prices'] as Map?;
    return RefreshIndicator(
      color: exlCyan, backgroundColor: exlPanel, onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(14, 8, 14, 24), children: [
        _section('YOUR ROOMS', mine.length, exlGoldBright, open: _showMine, icon: Icons.person, onToggle: () => setState(() => _showMine = !_showMine)),
        if (_showMine) ...[
          if (mine.isEmpty) _empty(widget.wallet == null ? 'Rooms you create or join show up here.' : 'No open or live rooms — create one or join with a code. Finished rooms are under ROOM HISTORY.'),
          _grid(mine, prices),
        ],
        const SizedBox(height: 14),
        _section('PUBLIC ROOMS', pub.length, exlCyan, open: _showPublic, icon: Icons.public, onToggle: () => setState(() => _showPublic = !_showPublic)),
        if (_showPublic) ...[
          if (pub.isEmpty) _empty('No public rooms right now.'),
          _grid(pub, prices),
        ],
        const SizedBox(height: 14),
        _section('ROOM HISTORY', past.length, exlCyanDim, open: _showPast, icon: Icons.history, onToggle: () => setState(() => _showPast = !_showPast)),
        if (_showPast) ...[
          if (past.isEmpty) _empty('Finished rooms from the last 30 days show up here — with REMATCH.'),
          for (final r in past) _pastRow(r, prices),
        ],
        const SizedBox(height: 16),
        ExlButton3D('CREATE ROOM', height: 52, onTap: widget.busy ? null : () { Navigator.pop(context); widget.onCreate(); },
            leading: SizedBox(width: 24, height: 24, child: ExlUiImage('rozet_start', fallback: const Icon(Icons.add_circle, color: exlInk, size: 22)))),
      ]),
    );
  }

  /// Section heading: embossed title · count pill · chevron (foldable when [onToggle] is set).
  Widget _section(String title, int count, Color color, {required bool open, required IconData icon, VoidCallback? onToggle}) {
    final head = Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: exlInk.withOpacity(0.35),
        border: Border.all(color: color.withOpacity(open ? 0.9 : 0.45), width: 1.4),
      ),
      child: Row(children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(child: ExlEmboss(title, size: 15, spacing: 2, align: TextAlign.left)),
        ExlPill('$count', color: color),
        if (onToggle != null) ...[
          const SizedBox(width: 4),
          Icon(open ? Icons.expand_less : Icons.expand_more, color: color, size: 24),
        ],
      ]),
    );
    return onToggle == null ? head : GestureDetector(behavior: HitTestBehavior.opaque, onTap: onToggle, child: head);
  }

  Widget _empty(String t) => Container(margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: exlCyanDim.withOpacity(0.5))),
      child: Text(t, style: exlBody(12, color: exlCyanDim)));

  /// Finished room: code · stake · players · result · REMATCH (same rules, same people, no code)
  Widget _pastRow(Map r, Map? prices) {
    final cur = r['currency'] as String? ?? 'SOL';
    final accent = cur == 'SKR' ? exlGoldBright : exlCyan;
    final won = (r['myPrize'] as num? ?? 0) > 0;
    final cancelled = r['status'] == 'cancelled';
    final parts = ((r['participants'] as List?) ?? const []).length;
    final isHost = widget.wallet != null && (r['host'] == widget.wallet || r['createdBy'] == widget.wallet);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ExlPanel(
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 6, runSpacing: 3, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(r['code'] as String, style: TextStyle(fontFamily: exlFont, color: accent, fontSize: 15, letterSpacing: 2)),
              ExlPill(cur, color: accent),
              _visPill(r),
              if (isHost) const ExlPill('HOST', color: exlGoldBright, asset: 'rozet_host', icon: Icons.workspace_premium),
            ]),
            const SizedBox(height: 3),
            Text('${exlFmtAmt(r['stake'] as num, cur)} · $parts player${parts == 1 ? '' : 's'} · ${(r['distLabel'] as String).split(' · ').first}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: exlIce, fontSize: 11, fontWeight: FontWeight.w700)),
            Text(cancelled ? 'refunded' : (won ? 'you won +${exlFmtAmt(r['myPrize'] as num, cur)}' : (r['winner'] != null ? 'winner ${_short(r['winner'] as String)}' : 'finished')),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: cancelled ? exlCyanDim : (won ? exlGreenGo : exlCyanDim), fontSize: 10.5)),
          ])),
          const SizedBox(width: 8),
          SizedBox(width: 118, child: ExlButton3D('REMATCH', tone: ExlTone.gold, height: 40, fontSize: 12.5, onTap: widget.busy ? null : () => widget.onRematch(r))),
          IconButton(padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 32), onPressed: () => widget.onOpen(r['id'] as String), icon: const Icon(Icons.chevron_right, color: exlCyanDim)),
        ]),
      ),
    );
  }

  Widget _grid(List<Map> rooms, Map? prices) {
    if (rooms.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(builder: (_, c) {
      final w = (c.maxWidth - 10) / 2;
      return Wrap(spacing: 10, runSpacing: 10, children: [for (final r in rooms) SizedBox(width: w, child: _tile(r, prices))]);
    });
  }

  Widget _tile(Map r, Map? prices) {
    final cur = r['currency'] as String? ?? 'SOL';
    final accent = cur == 'SKR' ? exlGoldBright : exlCyan;
    final st = r['status'] as String;
    final seatMode = r['seatMode'] == true;
    final seats = (r['seats'] as List?)?.cast<Map>() ?? const [];
    final players = r['players'] as int, max = r['maxPlayers'] as int;
    final isHost = widget.wallet != null && r['host'] == widget.wallet;
    final me = r['me'] as Map?;
    final canPlay = st == 'live' && me != null && (me['attemptsUsed'] as int) < ((me['attemptsMax'] as int?) ?? 1);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onOpen(r['id'] as String),
      child: ExlPanel(
        padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
        glow: st == 'live' ? exlGreenGo : (isHost ? exlGoldBright : null),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            _visPill(r), const SizedBox(width: 6),
            Expanded(child: Text(r['code'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontFamily: exlFont, color: accent, fontSize: 17, letterSpacing: 2))),
          ]),
          const SizedBox(height: 4),
          Wrap(spacing: 4, runSpacing: 4, children: [
            ExlPill(cur, color: accent), _statusPill(r),
            if (isHost) const ExlPill('HOST', color: exlGoldBright, asset: 'rozet_host', icon: Icons.workspace_premium),
          ]),
          const SizedBox(height: 8),
          const Text('STAKE', style: TextStyle(color: exlCyanDim, fontSize: 9, letterSpacing: 1.5)),
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: ExlEmboss.gold(exlFmtAmt(r['stake'] as num, cur), size: 17, spacing: 0.3, align: TextAlign.left)),
          exlUsdText(prices, r['stake'] as num, cur, size: 9.5),
          const SizedBox(height: 6),
          Text(seatMode ? '${seats.length}/$max seated · $players paid' : '$players/$max players', style: const TextStyle(color: exlIce, fontSize: 10.5, fontWeight: FontWeight.w700)),
          Text((r['distLabel'] as String).split(' · ').first, overflow: TextOverflow.ellipsis, style: const TextStyle(color: exlCyanDim, fontSize: 10)),
          const SizedBox(height: 6),
          Text(_countFor(r), style: TextStyle(color: st == 'live' ? exlOrange : exlIce, fontSize: 11, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          ExlButton3D(canPlay ? 'PLAY' : (st == 'open' ? (_imIn(r) ? 'OPEN' : (seatMode ? 'TAKE A SEAT' : 'ENTER')) : 'OPEN'),
              tone: canPlay ? ExlTone.green : (cur == 'SKR' ? ExlTone.gold : ExlTone.cyan), height: 32, fontSize: 11.5, onTap: () => widget.onOpen(r['id'] as String)),
        ]),
      ),
    );
  }

  String _countFor(Map r) {
    final st = r['status'] as String;
    if (st == 'open') return '⏱ ${exlCountdown(r['joinEndsAt'] as int)}';
    if (st == 'live') return '▶ ${exlCountdown(r['endsAt'] as int)}';
    return st.toUpperCase();
  }
}

// ---- small shared widgets ----
/// PUBLIC (green) / PRIVATE (grey) — short, coloured, same look as the status pills.
/// PUBLIC turns green only once the room is actually listed (host paid); until then it stays grey.
Widget _visPill(Map r) => r['visibility'] == 'public'
    ? (r['hostPaid'] == true || (r['status'] != 'open' && r['status'] != 'pending')
        ? const ExlPill('PUBLIC', color: exlGreenGo, icon: Icons.public)
        : const ExlPill('PUBLIC', color: Color(0xFF8FA3BF), icon: Icons.public_off))
    : const ExlPill('PRIVATE', color: Color(0xFF8FA3BF), icon: Icons.lock_outline);

Widget _statusPill(Map r) {
  final st = r['status'] as String;
  switch (st) {
    case 'pending': return const ExlPill('UNPAID', color: exlOrange);
    case 'open': return const ExlPill('WAITING', color: exlCyan, asset: 'rozet_waiting', icon: Icons.hourglass_bottom);
    case 'live': return const ExlPill('LIVE', color: exlGreenGo, asset: 'rozet_live', icon: Icons.play_arrow);
    case 'paid': return const ExlPill('FINISHED', color: exlGoldBright);
    case 'cancelled': return const ExlPill('REFUNDED', color: Color(0xFF8FA3BF));
    case 'settling': return const ExlPill('SETTLING', color: exlOrange);
    default: return ExlPill(st.toUpperCase(), color: const Color(0xFF8FA3BF));
  }
}

Widget _stat(String label, String value, String? sub, Color color, {int flex = 1}) => Expanded(
    flex: flex,
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(color: exlCyanDim, fontSize: 10, letterSpacing: 1.5)),
      const SizedBox(height: 2),
      Text(value, style: TextStyle(fontFamily: exlFont, color: color, fontSize: 15)),
      if (sub != null) Text(sub, style: const TextStyle(color: exlCyanDim, fontSize: 10)),
    ]));

// ============================== CREATE ROOM (accordion) ==============================

class CreateRoomScreen extends StatefulWidget {
  final Map limits;
  final Map? prices;
  final bool skrAvailable;
  final Map? prefill;
  const CreateRoomScreen({super.key, required this.limits, required this.prices, required this.skrAvailable, this.prefill});
  @override
  State<CreateRoomScreen> createState() => _CreateRoomScreenState();
}

class _CreateRoomScreenState extends State<CreateRoomScreen> {
  String cur = 'SOL';
  int stake = 50000000;
  int players = 2;
  int joinMin = 60, playMin = 60;
  String dist = 'wta';
  bool isPublic = false;
  int open = 0; // which accordion is open (-1 none)
  final _custom = TextEditingController();

  static const solPresets = [20000000, 50000000, 100000000, 250000000, 500000000, 1000000000];
  static const skrPresets = [200000000, 500000000, 1000000000, 2500000000, 5000000000, 10000000000];

  @override
  void initState() {
    super.initState();
    final p = widget.prefill;
    if (p != null) {
      cur = p['currency'] ?? 'SOL'; stake = (p['stake'] as num).toInt(); players = p['players'] ?? 2;
      joinMin = p['joinMin'] ?? 60; playMin = p['playMin'] ?? 60; dist = p['dist'] ?? 'wta'; isPublic = p['visibility'] == 'public';
    }
  }

  Map get _lim => (widget.limits['stake'] as Map)[cur] as Map;
  int get _feePct => ((widget.limits['feePct'] as Map)[cur] as num).toInt();
  List<int> get _presets => cur == 'SKR' ? skrPresets : solPresets;
  bool _distOk(String d) => d == 'top2' ? players >= 2 : (d == 'top3' ? players >= 3 : true);

  List<double> _weights() {
    switch (dist) {
      case 'top2': return [70, 30];
      case 'top3': return [50, 30, 20];
      case 'half': final k = (players ~/ 2).clamp(1, 10); return List.filled(k, 100 / k);
      default: return [100];
    }
  }

  void _setCustom(String v) {
    final x = double.tryParse(v.replaceAll(',', '.'));
    if (x == null) return;
    setState(() => stake = (cur == 'SKR' ? x * 1e6 : x * 1e9).round());
  }

  void _toggle(int i) => setState(() => open = open == i ? -1 : i);

  @override
  Widget build(BuildContext context) {
    final min = (_lim['min'] as num).toInt(), max = (_lim['max'] as num).toInt();
    final stakeOk = stake >= min && stake <= max;
    final pool = stake * players;
    final payable = pool * (100 - _feePct) / 100;
    final w = _weights();
    final windows = (widget.limits['windowsMin'] as List).cast<num>().map((e) => e.toInt()).toList();
    final accent = cur == 'SKR' ? exlGoldBright : exlCyan;
    final distLabel = ((widget.limits['dist'] as Map)[dist] as String?) ?? dist;

    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent, centerTitle: true, title: const ExlEmboss('CREATE ROOM', size: 22, spacing: 3),
          leading: IconButton(onPressed: () => Navigator.of(context).maybePop(), icon: const Icon(Icons.arrow_back, color: exlCyanDim))),
      body: Container(
        decoration: const BoxDecoration(gradient: RadialGradient(center: Alignment(0, -0.6), radius: 1.5, colors: [Color(0xFF0E2A52), exlBgBottom])),
        child: SafeArea(
          child: Column(children: [
            Expanded(
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 8), children: [
                ExlSteps(accent: accent, title: 'HOW IT WORKS', current: 0, onTap: () => showDuelHowItWorks(context, accent: accent),
                    steps: [for (final st in kDuelHowSteps) st.label]),
                const SizedBox(height: 10),
                Text('Tap a heading to change it. The room opens with these rules; players pay from their seats.',
                    style: exlBody(12, color: exlCyanDim)),
                const SizedBox(height: 12),
                // 1 · STAKE
                ExlAccordion(
                  title: 'STAKE', accent: accent, open: open == 0, onToggle: () => _toggle(0),
                  summary: '${exlFmtAmt(stake, cur)} per player${exlUsd(widget.prices, stake, cur) != null ? '  ·  ${exlUsd(widget.prices, stake, cur)}' : ''}',
                  leading: SizedBox(width: 30, height: 30, child: ExlUiImage('rozet_pay', fallback: ExlIcon3D(Icons.paid, size: 28, color: accent))),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    exlLabel('CURRENCY'),
                    Row(children: [
                      ExlChoice('SOL', on: cur == 'SOL', accent: exlCyan, onTap: () => setState(() { cur = 'SOL'; stake = solPresets[1]; })),
                      const SizedBox(width: 8),
                      ExlChoice('SKR', on: cur == 'SKR', accent: exlGoldBright, onTap: widget.skrAvailable ? () => setState(() { cur = 'SKR'; stake = skrPresets[1]; }) : null),
                    ]),
                    const SizedBox(height: 12),
                    exlLabel('AMOUNT PER PLAYER'),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final p in _presets) ExlChoice(exlFmtAmt(p, cur), on: stake == p, accent: accent, onTap: () => setState(() => stake = p), sub: exlUsd(widget.prices, p, cur)),
                      SizedBox(
                        width: 120,
                        child: TextField(
                          controller: _custom, keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: _setCustom,
                          style: const TextStyle(color: exlIce, fontSize: 13),
                          decoration: InputDecoration(
                            isDense: true, hintText: 'custom', hintStyle: const TextStyle(color: exlCyanDim, fontSize: 12),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: exlCyanDim)),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: accent)),
                          ),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    Text(stakeOk ? 'allowed ${exlFmtAmt(min, cur)} – ${exlFmtAmt(max, cur)}' : 'must be ${exlFmtAmt(min, cur)} – ${exlFmtAmt(max, cur)}',
                        style: TextStyle(color: stakeOk ? exlCyanDim : exlRed, fontSize: 10.5)),
                  ]),
                ),
                // 2 · PLAYERS
                ExlAccordion(
                  title: 'PLAYERS', accent: accent, open: open == 1, onToggle: () => _toggle(1),
                  summary: '$players players  ·  full pot ${exlFmtAmt(pool, cur)}',
                  leading: const SizedBox(width: 30, height: 30, child: ExlIcon3D(Icons.groups, size: 28)),
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    for (var n = 2; n <= 10; n++) ExlChoice('$n', on: players == n, accent: accent, onTap: () => setState(() { players = n; if (!_distOk(dist)) dist = 'wta'; })),
                  ]),
                ),
                // 3 · CLOCK
                ExlAccordion(
                  title: 'CLOCK', accent: accent, open: open == 2, onToggle: () => _toggle(2),
                  summary: 'room open ${_win(joinMin)}  ·  play window ${_win(playMin)}',
                  leading: SizedBox(width: 30, height: 30, child: ExlUiImage('rozet_waiting', fallback: const ExlIcon3D(Icons.timer, size: 28))),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    exlLabel('ROOM STAYS OPEN FOR  (everyone must pay and the host must start within this time)'),
                    Wrap(spacing: 8, runSpacing: 8, children: [for (final m in windows) ExlChoice(_win(m), on: joinMin == m, accent: accent, onTap: () => setState(() => joinMin = m))]),
                    const SizedBox(height: 12),
                    exlLabel('PLAYING WINDOW  (starts when the host presses START)'),
                    Wrap(spacing: 8, runSpacing: 8, children: [for (final m in windows) ExlChoice(_win(m), on: playMin == m, accent: accent, onTap: () => setState(() => playMin = m))]),
                  ]),
                ),
                // 4 · PRIZE SPLIT
                ExlAccordion(
                  title: 'PRIZE SPLIT', accent: accent, open: open == 3, onToggle: () => _toggle(3),
                  summary: distLabel,
                  leading: SizedBox(width: 30, height: 30, child: ExlUiImage('ikon_tournaments', fallback: ExlIcon3D(Icons.emoji_events, size: 28, color: exlGoldBright))),
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final e in (widget.limits['dist'] as Map).entries)
                      ExlChoice(e.value as String, on: dist == e.key, accent: accent, onTap: _distOk(e.key as String) ? () => setState(() => dist = e.key as String) : null),
                  ]),
                ),
                // 5 · PRIVACY
                ExlAccordion(
                  title: 'PRIVACY', accent: accent, open: open == 4, onToggle: () => _toggle(4),
                  summary: isPublic ? 'Public — listed in OPEN ROOMS' : 'Private — invite code only',
                  leading: SizedBox(width: 30, height: 30, child: ExlIcon3D(isPublic ? Icons.public : Icons.lock, size: 28)),
                  child: Row(children: [
                    Expanded(child: ExlChoice('PRIVATE', sub: 'invite code', on: !isPublic, accent: accent, onTap: () => setState(() => isPublic = false))),
                    const SizedBox(width: 8),
                    Expanded(child: ExlChoice('PUBLIC', sub: 'open list', on: isPublic, accent: accent, onTap: () => setState(() => isPublic = true))),
                  ]),
                ),
                const SizedBox(height: 6),
                // preview
                ExlPanel(
                  glow: accent,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      exlLabel('PREVIEW · FULL ROOM', color: accent),
                      const Spacer(),
                      ExlEmboss.gold(exlFmtAmt(pool, cur), size: 20, spacing: 0.5),
                    ]),
                    for (var i = 0; i < w.length; i++)
                      Padding(padding: const EdgeInsets.only(top: 4), child: Row(children: [
                        Text('#${i + 1}', style: exlT(13, color: exlIce)),
                        const SizedBox(width: 8),
                        Text('${w[i].toStringAsFixed(0)}%', style: const TextStyle(color: exlCyanDim, fontSize: 11)),
                        const Spacer(),
                        Text(exlFmtAmt(payable * w[i] / 100, cur), style: exlT(13, color: exlIce)),
                        const SizedBox(width: 6),
                        exlUsdText(widget.prices, payable * w[i] / 100, cur),
                      ])),
                    const SizedBox(height: 8),
                    Text('Service fee $_feePct% · one run each · same seed for everyone · rooms that never start refund every stake',
                        style: TextStyle(color: exlCyanDim.withOpacity(0.95), fontSize: 10.5, height: 1.4)),
                  ]),
                ),
                const SizedBox(height: 10),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: ExlButton3D('CREATE ROOM', height: 56,
                  onTap: stakeOk
                      ? () => Navigator.pop(context, {
                            'currency': cur, 'stake': stake, 'players': players, 'joinMin': joinMin, 'playMin': playMin,
                            'dist': dist, 'visibility': isPublic ? 'public' : 'private',
                          })
                      : null),
            ),
          ]),
        ),
      ),
    );
  }
}

// ============================== ROOM SCREEN ==============================

class RoomScreen extends StatefulWidget {
  final String apiBase, gameId, appName, phantomScheme, roomId;
  final String? wallet;
  final DuelJoinFn onJoin;
  final DuelPlayFn onPlay;
  final DuelRanksFn onRanks;
  final DuelWalletFn? onWallet;
  final void Function(Map room) onRematch; // v1.3: gets the finished room → same rules + same people
  final String playLabel;                                   // v1.4: 'CHOOSE GAME' for EXathlon rooms
  final Widget Function(Map<String, dynamic> r)? extra;     // v1.4: per-game breakdown panel
  const RoomScreen({
    super.key, required this.apiBase, required this.gameId, required this.appName, required this.roomId, required this.wallet,
    required this.onJoin, required this.onPlay, required this.onRanks, required this.onRematch, this.phantomScheme = '', this.onWallet,
    this.playLabel = 'PLAY YOUR RUN', this.extra,
  });
  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  late final DuelApi _api = DuelApi(widget.apiBase);
  Map<String, dynamic>? _r;
  String? _error;
  bool _busy = false;
  Timer? _clock, _poll;
  int _skew = 0;
  String? _wallet; // may be learned here (seat signature)
  int? _nudgeSeenAt;

  @override
  void initState() {
    super.initState();
    _wallet = widget.wallet;
    _load();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); });
    // v1.3: live/settling rooms refresh every 4 s, waiting rooms every 8 s (half the requests while people sit in a lobby)
    _poll = Timer.periodic(const Duration(seconds: 4), (t) { final st = _r?['status']; if (st == 'live' || st == 'settling' || ((st == 'open' || st == 'pending') && t.tick.isEven)) _load(); });
  }

  @override
  void dispose() { _clock?.cancel(); _poll?.cancel(); super.dispose(); }

  Future<void> _load() async {
    try {
      // v1.3: the active wallet may have changed since this screen was opened (first payment, wallet switch) — prefs hold the current one
      try { final p = await SharedPreferences.getInstance(); _wallet = p.getString('wallet') ?? _wallet; } catch (_) {}
      final r = await _api.get(widget.roomId, _wallet);
      if (mounted) setState(() { _r = r; _error = null; _skew = (r['now'] as int) - DateTime.now().millisecondsSinceEpoch; });
      final n = r['myNudge'] as Map?;
      if (n != null && n['at'] != _nudgeSeenAt) { _nudgeSeenAt = n['at'] as int?; HapticFeedback.heavyImpact(); }
    } catch (e) { if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', '')); }
  }

  int get _now => DateTime.now().millisecondsSinceEpoch + _skew;
  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 3)));

  Future<void> _share() async {
    final r = _r!;
    final text = 'Duel me in ${widget.appName}! Room code ${r['code']} · stake ${exlFmtAmt(r['stake'] as num, r['currency'] as String)} · ${r['distLabel']}. '
        'Open ${widget.appName} → COMPETE → DUELS → JOIN WITH CODE, take a seat and pay your stake.';
    await Clipboard.setData(ClipboardData(text: text));
    _snack('Invite copied — paste it anywhere');
  }

  Future<String?> _ensureWallet(String purpose) async {
    if (_wallet != null) return _wallet;
    final w = await exlIdentifyWallet(context, appName: widget.appName, phantomScheme: widget.phantomScheme,
        purpose: purpose, message: 'exl:seat:${widget.roomId}:${DateTime.now().millisecondsSinceEpoch}');
    if (w != null) { setState(() => _wallet = w); widget.onWallet?.call(w); }
    return w;
  }

  Future<void> _act(Future<Map<String, dynamic>> Function() f, {String? ok}) async {
    setState(() => _busy = true);
    try { final r = await f(); if (mounted) setState(() { _r = {..._r!, ...r}; }); if (ok != null) _snack(ok); }
    catch (e) { _snack(e.toString().replaceFirst('Exception: ', '')); }
    finally { if (mounted) setState(() => _busy = false); _load(); }
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, centerTitle: true,
        leading: IconButton(onPressed: () => Navigator.of(context).maybePop(), icon: const Icon(Icons.arrow_back, color: exlCyanDim)),
        title: const ExlEmboss('DUEL ROOM', size: 22, spacing: 3),
        actions: [
          if (r != null) IconButton(onPressed: _share, tooltip: 'Share invite', icon: const Icon(Icons.ios_share, color: exlCyanDim)),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh, color: exlCyanDim)),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(gradient: RadialGradient(center: Alignment(0, -0.6), radius: 1.5, colors: [Color(0xFF0E2A52), exlBgBottom])),
        child: SafeArea(
          child: _error != null && r == null
              ? Center(child: Text(_error!, style: const TextStyle(color: exlRed)))
              : r == null
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2, color: exlCyan))
                  : _body(r),
        ),
      ),
    );
  }

  Widget _body(Map<String, dynamic> r) {
    final cur = r['currency'] as String? ?? 'SOL';
    final accent = cur == 'SKR' ? exlGoldBright : exlCyan;
    final st = r['status'] as String;
    final me = r['me'] as Map?;
    final seatMode = r['seatMode'] == true;
    final entries = (r['entries'] as List).cast<Map>();
    final seats = (r['seats'] as List?)?.cast<Map>() ?? const [];
    final prices = r['prices'] as Map?;
    final players = r['players'] as int, max = r['maxPlayers'] as int;
    final pool = r['pool'] as num;
    final payable = pool * (100 - (r['feePct'] as num)) / 100;
    final weights = (r['weights'] as List).cast<num>();
    final payouts = (r['payouts'] as List).cast<Map>();
    final finished = st == 'paid' || st == 'cancelled';
    final host = r['host'] as String?;
    final isHost = _wallet != null && host == _wallet;
    final mySeat = _wallet == null ? null : seats.cast<Map?>().firstWhere((s) => s!['wallet'] == _wallet, orElse: () => null);
    final canPlay = me != null && st == 'live' && (me['attemptsUsed'] as int) < ((me['attemptsMax'] as int?) ?? 1) && (r['endsAt'] as int) > _now;   // v1.4: multi-run entries (EXathlon)
    final unpaid = seats.where((s) => s['paid'] != true).length;
    final canStart = r['canStart'] == true;
    final nudge = r['myNudge'] as Map?;

    String headline, sub;
    switch (st) {
      case 'pending': headline = 'WAITING FOR PAYMENT'; sub = 'The creator\'s stake has not arrived yet.'; break;
      case 'open':
        if (seatMode) {
          headline = canStart ? 'EVERYONE PAID — READY TO START' : 'WAITING FOR PLAYERS';
          sub = 'Room closes in ${exlCountdown(r['joinEndsAt'] as int, nowMs: _now)}'
              '${unpaid > 0 ? ' · $unpaid seat${unpaid == 1 ? '' : 's'} not paid yet' : ''}';
        } else { headline = 'WAITING FOR PLAYERS'; sub = 'Starts when full or in ${exlCountdown(r['joinEndsAt'] as int, nowMs: _now)}'; }
        break;
      case 'live': headline = 'LIVE — PLAY NOW'; sub = 'Clock ends in ${exlCountdown(r['endsAt'] as int, nowMs: _now)} · closes early once everyone has played'; break;
      case 'settling': headline = 'SETTLING'; sub = 'Paying out on-chain…'; break;
      case 'paid': headline = 'FINISHED'; sub = 'Prizes paid on-chain.'; break;
      default: headline = 'CANCELLED'; sub = 'Stakes refunded in full (minus network fee).';
    }

    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 28), children: [
      // ---- nudge banner
      if (nudge != null && mySeat != null && mySeat['paid'] != true)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: ExlPanel(
            fill: const Color(0xFF3A2A08), glow: exlGoldBright, padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(children: [
              SizedBox(width: 28, height: 28, child: ExlUiImage('rozet_nudge', fallback: const ExlIcon3D(Icons.notifications_active, size: 26, color: exlGoldBright))),
              const SizedBox(width: 10),
              Expanded(child: Text('${_short(nudge['by'] as String? ?? '')} nudged you — pay your seat to get the room started.', style: exlBody(12.5, color: exlIce))),
            ]),
          ),
        ),
      // ---- header
      ExlPanel(
        glow: st == 'live' ? exlGreenGo : accent,
        child: Column(children: [
          Row(children: [
            ExlPill(cur, color: cur == 'SKR' ? exlGoldBright : exlCyan), const SizedBox(width: 6), _statusPill(r), const SizedBox(width: 8),
            Expanded(child: Text(r['visibility'] == 'public' ? (r['hostPaid'] == true || st != 'open' ? 'PUBLIC' : 'PUBLIC · listed once\nthe host pays') : 'PRIVATE',
                textAlign: TextAlign.right, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: exlCyanDim, fontSize: 10, letterSpacing: 1.5, height: 1.2))),
          ]),
          const SizedBox(height: 10),
          GestureDetector(onTap: _share, child: ExlEmboss(r['code'] as String, size: 40, spacing: 8)),
          const SizedBox(height: 6),
          Text(headline, style: exlT(13, color: st == 'live' ? exlGreenGo : (canStart ? exlGoldBright : exlIce), spacing: 1.5)),
          const SizedBox(height: 2),
          Text(sub, style: exlBody(12, color: exlCyanDim)),
          const SizedBox(height: 14),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            _stat('POT', exlFmtAmt(pool, cur), exlUsd(prices, pool, cur), accent, flex: 4),
            _stat('STAKE', exlFmtAmt(r['stake'] as num, cur), exlUsd(prices, r['stake'] as num, cur), exlIce, flex: 4),
            _stat(seatMode ? 'PAID' : 'PLAYERS', seatMode ? '$players / ${seats.length} seated' : '$players / $max', null, exlIce, flex: 4),
          ]),
          const SizedBox(height: 14),
          // ---- primary actions
          if (!seatMode && me == null && st == 'open' && players < max)
            ExlButton3D('ENTER — ${exlFmtAmt(r['stake'] as num, cur)}', onTap: _busy ? null : () async {
              setState(() => _busy = true);
              final ok = await widget.onJoin(_asTournament(r), r['skr'] as Map?, r['poolAddress'] as String);
              if (mounted) setState(() => _busy = false);
              if (ok) _load();
            }),
          if (seatMode && st == 'open' && isHost)
            ExlButton3D(canStart ? 'START THE ROOM' : 'START', tone: ExlTone.green, height: 56,
                sub: canStart ? '$players players · everyone paid' : (players < 2 ? 'needs at least 2 paid players' : 'waiting for $unpaid payment${unpaid == 1 ? '' : 's'}'),
                leading: SizedBox(width: 24, height: 24, child: ExlUiImage('rozet_start', fallback: const Icon(Icons.rocket_launch, color: exlInk, size: 22))),
                onTap: _busy || !canStart ? null : () => _act(() => _api.start(r['id'] as String, _wallet!), ok: 'Room is live — play your run!')),
          if (seatMode && st == 'open' && !isHost && mySeat != null)
            Text(mySeat['paid'] == true ? 'Paid. The host starts the room once every seat is paid.' : 'Pay your seat below to lock your place.',
                textAlign: TextAlign.center, style: exlBody(12, color: exlCyanDim)),
          if (canPlay) ExlButton3D(widget.playLabel, tone: ExlTone.green, height: 56, onTap: _busy ? null : () async { await widget.onPlay(_asTournament(r)); _load(); }),
          if (me != null && st == 'live' && !canPlay && (me['attemptsUsed'] as int) > 0)
            Text('Run submitted · score ${me['bestScore']} · waiting for the clock', style: exlT(12, color: exlGreenGo)),
          if (st == 'open' && (mySeat != null || me != null))
            Padding(padding: const EdgeInsets.only(top: 8), child: ExlButton3D('SHARE INVITE', tone: ExlTone.ghost, height: 44, fontSize: 14, onTap: _share)),
          if (finished) Row(children: [
            Expanded(child: ExlButton3D('RANKS', tone: ExlTone.ghost, height: 46, fontSize: 14, onTap: () => widget.onRanks(r['id'] as String))),
            const SizedBox(width: 8),
            Expanded(child: ExlButton3D('REMATCH', sub: 'same rules · same players', height: 46, fontSize: 14, onTap: () {
              Navigator.pop(context);
              widget.onRematch(r);
            })),
          ]),
        ]),
      ),
      if (widget.extra != null) ...[const SizedBox(height: 10), widget.extra!(r)],
      const SizedBox(height: 10),
      ExlSteps(accent: accent, title: 'HOW IT WORKS', current: _roomStep(st, mySeat, me, finished), onTap: () => showDuelHowItWorks(context, accent: accent),
          skipped: entries.any((e) => e['wallet'] == _wallet && e['played'] == true && e['verified'] != true) ? const {4} : const {},
          steps: const ['Take a\nseat', 'Pay your\nstake', 'Host\nSTARTs', 'Play\ngame', 'Sign\nscore', 'Clock\nends', 'Auto\npayout']),
      const SizedBox(height: 10),
      // ---- seats / players
      if (seatMode) _seatsPanel(r, seats, entries, st, finished, payouts, cur, prices, max, isHost, mySeat, accent)
      else _panel('PLAYERS', [
        if (entries.isEmpty) Text('Nobody yet.', style: exlBody(12, color: exlCyanDim)),
        for (var i = 0; i < entries.length; i++) _entryRow(i, entries[i], st, finished, payouts, cur),
        for (var i = entries.length; i < max; i++) _openSeatRow(null),
      ]),
      const SizedBox(height: 12),
      // ---- payout table
      _panel(finished ? 'PAYOUTS' : 'PRIZE SPLIT · ${r['distLabel']}', [
        if (!finished) for (var i = 0; i < weights.length; i++) Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(children: [
          Text('#${i + 1}', style: exlT(13, color: exlIce)),
          const SizedBox(width: 8),
          Text('${weights[i].toStringAsFixed(0)}%', style: const TextStyle(color: exlCyanDim, fontSize: 11)),
          const Spacer(),
          Text(exlFmtAmt(payable * weights[i] / 100, cur), style: exlT(13, color: exlIce)),
          const SizedBox(width: 6), exlUsdText(prices, payable * weights[i] / 100, cur),
        ])),
        if (!finished) Padding(padding: const EdgeInsets.only(top: 4), child: Text(
            'Based on the current pot · service fee ${r['feePct']}% · ties split equally · no valid score or never started → every stake refunded',
            style: TextStyle(color: exlCyanDim.withOpacity(0.9), fontSize: 10.5, height: 1.4))),
        if (finished && payouts.isEmpty) Text('No payouts recorded.', style: exlBody(12, color: exlCyanDim)),
        for (final p in payouts) Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(children: [
          Text(p['role'] == 'prize' ? '#${p['rank']}' : (p['role'] == 'refund' ? 'refund' : 'fee'), style: exlT(12, color: p['role'] == 'prize' ? exlIce : exlCyanDim)),
          const SizedBox(width: 8),
          Text(_short(p['wallet'] as String), style: const TextStyle(color: exlCyanDim, fontSize: 11.5)),
          const Spacer(),
          Text(exlFmtAmt(p['amount'] as num, cur), style: exlT(13, color: exlIce)),
          if (p['explorer'] != null) ...[const SizedBox(width: 6), const Icon(Icons.open_in_new, size: 12, color: exlCyanDim)],
        ])),
      ]),
      const SizedBox(height: 12),
      Center(child: GestureDetector(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProofScreen(apiBase: widget.apiBase, tournamentId: r['id'] as String))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.verified_outlined, size: 12, color: exlCyanDim.withOpacity(0.9)),
          const SizedBox(width: 4),
          Text('provably fair · seed commitment · proof', style: TextStyle(color: exlCyanDim.withOpacity(0.9), fontSize: 11)),
        ]),
      )),
      // ---- host: close the room (bottom of the page, framed red — only while the room has not started)
      if (isHost && (st == 'open' || st == 'pending')) ...[
        const SizedBox(height: 22),
        ExlPanel(
          glow: exlRed, padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Column(children: [
            exlLabel('HOST', color: exlRed),
            ExlButton3D('CLOSE ROOM', tone: ExlTone.danger, height: 56,
                sub: players == 0 ? 'nobody has paid · the room is removed' : 'every paid stake goes back in full',
                leading: const SizedBox(width: 24, height: 24, child: Icon(Icons.close_rounded, color: exlInk, size: 22)),
                onTap: _busy ? null : () => _closeRoom(r, players)),
          ]),
        ),
      ],
    ]);
  }

  // ---- seat list (v1.3)
  Widget _seatsPanel(Map r, List<Map> seats, List<Map> entries, String st, bool finished, List<Map> payouts, String cur, Map? prices, int max, bool isHost, Map? mySeat, Color accent) {
    final showScore = st == 'live' || finished;
    final id = r['id'] as String;
    final rows = <Widget>[];
    for (var i = 0; i < seats.length; i++) {
      final s = seats[i];
      final w = s['wallet'] as String;
      final mine = w == _wallet;
      final paid = s['paid'] == true;
      final entry = entries.cast<Map?>().firstWhere((e) => e!['wallet'] == w, orElse: () => null);
      final prize = payouts.cast<Map?>().firstWhere((p) => p!['role'] == 'prize' && p['wallet'] == w, orElse: () => null);
      Widget trailing;
      if (showScore) {
        trailing = Text(entry != null && entry['played'] == true ? '${entry['score']}' : (finished ? '—' : 'playing'),
            style: exlT(15, color: entry != null && entry['played'] == true ? exlIce : exlCyanDim));
      } else if (mine && !paid && st == 'open') {
        trailing = SizedBox(width: 128, child: ExlButton3D('PAY ${exlFmtAmt(r['stake'] as num, cur)}', height: 40, fontSize: 13, onTap: _busy ? null : () async {
          setState(() => _busy = true);
          final ok = await widget.onJoin(_asTournament(r), r['skr'] as Map?, r['poolAddress'] as String);
          if (mounted) setState(() => _busy = false);
          if (ok) _load();
        }));
      } else if (paid && mine && st == 'open' && (r['me'] as Map?)?['canWithdraw'] == true) {
        trailing = Row(mainAxisSize: MainAxisSize.min, children: [
          const ExlPill('PAID', color: exlGreenGo, asset: 'rozet_paid', icon: Icons.check),
          const SizedBox(width: 6),
          SizedBox(width: 112, child: ExlButton3D('WITHDRAW', tone: ExlTone.ghost, height: 36, fontSize: 11.5, onTap: _busy ? null : () => _withdraw(r))),
        ]);
      } else if (paid) {
        trailing = const ExlPill('PAID', color: exlGreenGo, asset: 'rozet_paid', icon: Icons.check);
      } else {
        // someone else's unpaid seat → nudge (if I have a seat) / host tools
        trailing = Row(mainAxisSize: MainAxisSize.min, children: [
          s['nudgedBy'] == 'invite' ? const ExlPill('INVITED', color: exlGoldBright, asset: 'rozet_nudge', icon: Icons.mail) : const ExlPill('WAITING', color: Color(0xFF8FA3BF), asset: 'rozet_waiting', icon: Icons.hourglass_bottom),
          if (mySeat != null && st == 'open') IconButton(
            tooltip: 'Nudge', padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            onPressed: _busy ? null : () => _act(() => _api.nudge(id, _wallet!, w), ok: 'Nudged ${_short(w)}'),
            icon: SizedBox(width: 24, height: 24, child: ExlUiImage('rozet_nudge', fallback: const ExlIcon3D(Icons.notifications_active, size: 22, color: exlGoldBright)))),
        ]);
      }
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          ExlAvatar(w, me: mine),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(mine ? 'you' : _short(w), overflow: TextOverflow.ellipsis, style: exlT(14, color: mine ? exlCyan : exlIce))),
                if (s['isHost'] == true) ...[const SizedBox(width: 6), const ExlPill('HOST', color: exlGoldBright, asset: 'rozet_host', icon: Icons.workspace_premium)],
                if (entry != null && entry['verified'] == true) ...[const SizedBox(width: 4), const Icon(Icons.verified, size: 13, color: exlGreenGo)],
              ]),
              if (prize != null) Text('+${exlFmtAmt(prize['amount'] as num, cur)}', style: exlT(12, color: exlGoldBright)),
            ]),
          ),
          trailing,
          if (isHost && !mine && st == 'open') PopupMenuButton<String>(
            color: exlPanel, iconColor: exlCyanDim, padding: EdgeInsets.zero,
            onSelected: (v) {
              if (v == 'host') _act(() => _api.transfer(id, _wallet!, w), ok: '${_short(w)} is the host now');
              if (v == 'kick') _act(() => _api.kick(id, _wallet!, w), ok: 'Seat freed');
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'host', child: Text('Make host', style: TextStyle(color: exlIce))),
              if (!paid) const PopupMenuItem(value: 'kick', child: Text('Remove unpaid seat', style: TextStyle(color: exlRed))),
            ],
          ),
        ]),
      ));
    }
    // empty seats
    final canTake = st == 'open' && mySeat == null && seats.length < max;
    for (var i = seats.length; i < max; i++) rows.add(_openSeatRow(canTake && i == seats.length ? () async {
      final w = await _ensureWallet('Sign to take a seat');
      if (w == null) return;
      await _act(() => _api.seat(id, w), ok: 'Seat taken');
    } : null));
    // leave (unpaid seat)
    if (mySeat != null && mySeat['paid'] != true && st == 'open') {
      rows.add(Padding(padding: const EdgeInsets.only(top: 8), child: Align(alignment: Alignment.centerRight, child: TextButton(
          onPressed: _busy ? null : () async { await _act(() => _api.leave(id, _wallet!), ok: 'You left the seat'); if (mounted) Navigator.pop(context); },
          child: const Text('LEAVE SEAT', style: TextStyle(color: exlCyanDim, fontSize: 12, letterSpacing: 1.5))))));
    }
    return _panel('SEATS · ${seats.length} / $max', rows);
  }

  /// v4.3: host closes a room that has not started. Paid stakes are refunded in full on-chain in the same call.
  Future<void> _closeRoom(Map r, int paidPlayers) async {
    if (_wallet == null) return;
    final cur = r['currency'] as String? ?? 'SOL';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: exlPanel, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: exlInk, width: 2)),
        title: const ExlEmboss('CLOSE ROOM', size: 18, spacing: 2),
        content: Text(paidPlayers == 0
            ? 'Room ${r['code']} is removed from every list. Nobody has paid, so there is nothing to refund.'
            : 'Room ${r['code']} is closed and every paid stake ($paidPlayers × ${exlFmtAmt(r['stake'] as num, cur)}) goes back to its wallet in full${cur == 'SOL' ? ' minus the shared network fee' : ''}. The room moves to ROOM HISTORY as REFUNDED.',
            style: exlBody(13, color: exlIce)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('KEEP ROOM', style: TextStyle(color: exlCyanDim))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('CLOSE & REFUND', style: TextStyle(color: exlRed, fontWeight: FontWeight.w800))),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final res = await _api.cancel(r['id'] as String, _wallet!);
      _snack((res['refunds'] as num? ?? 0) > 0 ? 'Room closed · ${res['refunds']} stake(s) refunded' : 'Room closed');
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      final again = await exlRetryDialog(context, title: 'CLOSE FAILED', message: '${e.toString().replaceFirst('Exception: ', '')}\n\nThe room and every payment are unchanged.');
      if (mounted) setState(() => _busy = false);
      await _load();
      if (again && mounted) { final fresh = _r; if (fresh != null) return _closeRoom(fresh, fresh['players'] as int); }
    } finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _withdraw(Map r) async {
    final me = r['me'] as Map?; final q = me?['withdraw'] as Map?;
    if (q == null || _wallet == null) return;
    final cur = r['currency'] as String? ?? 'SOL';
    final ok = await exlConfirmWithdraw(context, quote: q, cur: cur, prices: r['prices'] as Map?,
        what: 'Take your stake back before the host starts the room. Your seat is freed; you can take a seat again later.');
    if (!ok) return;
    setState(() => _busy = true);
    try {
      final res = await _api.withdraw(r['id'] as String, _wallet!);
      _snack('Refunded ${exlFmtAmt(res['refund'] as num, cur)} to your wallet');
    } catch (e) {
      if (!mounted) return;
      final again = await exlRetryDialog(context, title: 'WITHDRAW FAILED', message: '${e.toString().replaceFirst('Exception: ', '')}\n\nYour seat and payment are unchanged.');
      if (mounted) setState(() => _busy = false);
      await _load();
      if (again && mounted) { final fresh = _r; if (fresh != null) return _withdraw(fresh); }
      return;
    }
    finally { if (mounted) setState(() => _busy = false); _load(); }
  }

  /// Steps strip for the room flow.
  int _roomStep(String st, Map? mySeat, Map? me, bool finished) {
    if (finished) return 7;                        // paid / refunded → every step done (all green)
    if (st == 'settling') return 6;
    if (st == 'live') return me != null && (me['attemptsUsed'] as int) > 0 ? 5 : 3;
    if (mySeat == null) return 0;                  // take a seat
    if (mySeat['paid'] != true) return 1;          // pay
    return 2;                                      // wait for START
  }

  Widget _openSeatRow(Future<void> Function()? onTake) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Container(width: 34, height: 34, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: exlCyanDim.withOpacity(0.6), width: 2))),
        const SizedBox(width: 10),
        Expanded(child: Text('open seat', style: exlBody(12.5, color: exlCyanDim.withOpacity(0.8)))),
        if (onTake != null) SizedBox(width: 140, child: ExlButton3D('TAKE A SEAT', tone: ExlTone.cyan, height: 40, fontSize: 13, onTap: _busy ? null : onTake)),
      ]));

  // legacy (creator-pays-first) room rows
  Widget _entryRow(int i, Map e, String st, bool finished, List<Map> payouts, String cur) {
    final w = e['wallet'] as String;
    final mine = w == _wallet;
    final showScore = st == 'live' || finished;
    final prize = payouts.cast<Map?>().firstWhere((p) => p!['role'] == 'prize' && p['wallet'] == w, orElse: () => null);
    return Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Row(children: [
      ExlAvatar(w, me: mine),
      const SizedBox(width: 10),
      Text(mine ? 'you' : _short(w), style: exlT(14, color: mine ? exlCyan : exlIce)),
      const SizedBox(width: 6),
      if (e['verified'] == true) const Icon(Icons.verified, size: 13, color: exlGreenGo),
      const Spacer(),
      if (prize != null) Padding(padding: const EdgeInsets.only(right: 8), child: Text('+${exlFmtAmt(prize['amount'] as num, cur)}', style: exlT(12, color: exlGoldBright))),
      Text(showScore ? ((e['played'] == true) ? '${e['score']}' : (finished ? '—' : 'playing')) : 'ready',
          style: exlT(14, color: showScore && e['played'] == true ? exlIce : exlCyanDim)),
    ]));
  }

  Widget _panel(String title, List<Widget> children) => ExlPanel(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: exlT(12, color: exlCyan, spacing: 2)),
        const SizedBox(height: 6),
        ...children,
      ]));
}
