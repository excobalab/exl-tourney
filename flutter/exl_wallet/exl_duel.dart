// ============================================================================
// EXL TOURNEY — DUEL / ROOM MODE (client v1.2)
// Player-created rooms: currency, stake, players, joining/playing windows,
// prize distribution and visibility are fixed before anyone joins.
// Identical file in every EXL game; the game-specific bits arrive via DuelTab's
// constructor (apiBase, gameId, join/play callbacks).
// ============================================================================
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'exl_proof.dart';
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

/// "≈ $1.23" from the Worker's `prices` map, or null when no price is known.
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

  Future<Map<String, dynamic>> list(String game, String? wallet) =>
      _get('/duel/list?game=$game${wallet != null ? '&wallet=$wallet' : ''}');
  Future<Map<String, dynamic>> get(String id, String? wallet) =>
      _get('/duel/get?id=${Uri.encodeComponent(id)}${wallet != null ? '&wallet=$wallet' : ''}');
  Future<Map<String, dynamic>> byCode(String game, String code, String? wallet) =>
      _get('/duel/get?game=$game&code=${Uri.encodeComponent(code)}${wallet != null ? '&wallet=$wallet' : ''}');
  Future<Map<String, dynamic>> create(Map body) => _post('/duel/create', body);
}

/// Called when a player wants to pay the stake and enter a room. Returns true on success.
/// `t` looks like a tournament map: {id, type:'x', currency, feeLamports, attemptsMax}.
typedef DuelJoinFn = Future<bool> Function(Map<String, dynamic> t, Map? skr, String poolAddress);
typedef DuelPlayFn = Future<void> Function(Map<String, dynamic> t);
typedef DuelRanksFn = void Function(String tournamentId);

Map<String, dynamic> _asTournament(Map room) => {
      'id': room['id'], 'type': 'x', 'currency': room['currency'] ?? 'SOL',
      'feeLamports': room['stake'], 'attemptsMax': 1, 'endsAt': room['endsAt'] ?? room['joinEndsAt'],
    };

// ============================== DUEL TAB ==============================

class DuelTab extends StatefulWidget {
  final String apiBase, gameId, appName;
  final String? wallet;
  final bool busy;
  final DuelJoinFn onJoin;
  final DuelPlayFn onPlay;
  final DuelRanksFn onRanks;
  const DuelTab({
    super.key, required this.apiBase, required this.gameId, required this.appName, required this.wallet,
    required this.busy, required this.onJoin, required this.onPlay, required this.onRanks,
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
  void didUpdateWidget(covariant DuelTab old) {
    super.didUpdateWidget(old);
    if (old.wallet != widget.wallet) load();
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
            apiBase: widget.apiBase, gameId: widget.gameId, appName: widget.appName, roomId: id, wallet: widget.wallet,
            onJoin: widget.onJoin, onPlay: widget.onPlay, onRanks: widget.onRanks,
            onRematch: (settings) => _create(prefill: settings))));
    load();
  }

  Future<void> _joinWithCode() async {
    final ctrl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: exlPanel,
        title: const Text('JOIN WITH CODE', style: TextStyle(color: exlCyan, fontSize: 15, letterSpacing: 2, fontWeight: FontWeight.w800)),
        content: TextField(
          controller: ctrl, autofocus: true, textCapitalization: TextCapitalization.characters, maxLength: 6,
          style: const TextStyle(color: exlIce, fontSize: 22, letterSpacing: 6, fontWeight: FontWeight.w800, fontFamily: 'monospace'),
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

  Future<void> _create({Map? prefill}) async {
    final limits = _data?['limits'] as Map?;
    if (limits == null) { _snack('Loading room limits, try again'); return; }
    final settings = await showModalBottomSheet<Map<String, dynamic>>(
      context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (_) => _CreateRoomSheet(limits: limits, prices: _data?['prices'] as Map?, skrAvailable: _data?['skr'] != null, prefill: prefill),
    );
    if (settings == null) return;
    try {
      final r = await _api.create({...settings, 'game': widget.gameId, 'wallet': widget.wallet ?? 'new'});
      final t = {
        'id': r['id'], 'type': 'x', 'currency': r['currency'], 'feeLamports': r['stake'], 'attemptsMax': 1,
        'title': 'OPEN ROOM ${r['code']}', 'subtitle': 'Your stake opens the room. Share the code — the room starts when it is full or when the joining window closes.',
      };
      final ok = await widget.onJoin(t, r['skr'] as Map?, r['poolAddress'] as String);
      if (ok) await _openRoom(r['id'] as String);
      else _snack('Room reserved as ${r['code']} but not paid — it expires in 15 minutes.');
    } catch (e) { _snack(e.toString().replaceFirst('Exception: ', '')); }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFFF6B6B), fontSize: 14, height: 1.5)),
        const SizedBox(height: 14),
        TextButton(onPressed: load, child: const Text('RETRY', style: TextStyle(color: exlCyan))),
      ])));
    }
    if (_data == null) return const Center(child: CircularProgressIndicator(strokeWidth: 2, color: exlCyan));
    final mine = (_data!['mine'] as List).cast<Map>();
    final pub = (_data!['public'] as List).cast<Map>();
    final prices = _data!['prices'] as Map?;
    return RefreshIndicator(
      color: exlCyan, backgroundColor: exlPanel, onRefresh: load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          // ---- hero
          Container(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: exlCyanDim),
              gradient: LinearGradient(colors: [exlCyan.withOpacity(0.10), exlPanel.withOpacity(0.6)]),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('CHALLENGE ANYONE', style: TextStyle(color: exlCyan, fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: 3)),
              const SizedBox(height: 4),
              const Text('Set the stake, the clock and the payout. Same run for everyone in the room — winner takes the pot.',
                  style: TextStyle(color: exlIce, fontSize: 12.5, height: 1.45)),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(child: _btn('CREATE ROOM', filled: true, onTap: widget.busy ? null : () => _create())),
                const SizedBox(width: 8),
                Expanded(child: _btn('JOIN WITH CODE', filled: false, onTap: widget.busy ? null : _joinWithCode)),
              ]),
            ]),
          ),
          const SizedBox(height: 18),
          _section('YOUR ROOMS'),
          if (mine.isEmpty) _empty(widget.wallet == null ? 'Rooms you create or join show up here.' : 'No rooms yet — create one or join with a code.'),
          for (final r in mine) _roomCard(r, prices, mine: true),
          const SizedBox(height: 10),
          _section('OPEN ROOMS'),
          if (pub.isEmpty) _empty('No public rooms right now. Be the first — create one and leave it public.'),
          for (final r in pub) _roomCard(r, prices, mine: false),
          const SizedBox(height: 14),
          Center(child: Text('Service fee 3% (SOL) · 5% (SKR) · prizes paid on-chain, automatically',
              textAlign: TextAlign.center, style: TextStyle(color: exlCyanDim.withOpacity(0.8), fontSize: 10.5, height: 1.4))),
        ],
      ),
    );
  }

  Widget _section(String t) => Padding(padding: const EdgeInsets.only(bottom: 8, left: 2),
      child: Text(t, style: const TextStyle(color: exlCyanDim, fontSize: 11, letterSpacing: 2.5, fontWeight: FontWeight.w800)));

  Widget _empty(String t) => Container(
      margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: exlCyanDim.withOpacity(0.5))),
      child: Text(t, style: const TextStyle(color: exlCyanDim, fontSize: 12.5, height: 1.4)));

  Widget _roomCard(Map r, Map? prices, {required bool mine}) {
    final cur = r['currency'] as String? ?? 'SOL';
    final accent = cur == 'SKR' ? exlGold : exlCyan;
    final st = r['status'] as String;
    final me = r['me'] as Map?;
    final players = r['players'] as int, max = r['maxPlayers'] as int;
    final canJoin = !mine && me == null && st == 'open' && players < max;
    return GestureDetector(
      onTap: () => _openRoom(r['id'] as String),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        decoration: BoxDecoration(
          color: exlPanel.withOpacity(0.8), borderRadius: BorderRadius.circular(16),
          border: Border.all(color: st == 'live' ? exlGreen.withOpacity(0.7) : (mine ? accent.withOpacity(0.5) : exlCyanDim)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(r['code'] as String, style: TextStyle(color: accent, fontSize: 17, fontWeight: FontWeight.w900, letterSpacing: 3, fontFamily: 'monospace')),
            const SizedBox(width: 8),
            _chip(cur, cur == 'SKR' ? exlGold : exlCyanDim),
            const SizedBox(width: 6),
            _statusChip(r),
            const Spacer(),
            Text(_countFor(r), style: TextStyle(color: st == 'live' ? exlOrange : exlIce, fontSize: 12.5, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 10),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            _stat('STAKE', exlFmtAmt(r['stake'] as num, cur), exlUsd(prices, r['stake'] as num, cur), accent, flex: 4),
            _stat('PLAYERS', '$players / $max', null, exlIce, flex: 3),
            _stat('PAYOUT', (r['distLabel'] as String).split(' · ').first, null, exlIce, flex: 5),
          ]),
          if (canJoin) ...[
            const SizedBox(height: 12),
            _btn('ENTER — ${exlFmtAmt(r['stake'] as num, cur)}', filled: true, accent: accent,
                onTap: widget.busy ? null : () async {
                  final ok = await widget.onJoin(_asTournament(r), _data?['skr'] as Map?, _data!['poolAddress'] as String);
                  if (ok) await _openRoom(r['id'] as String);
                }),
          ],
          if (mine && st == 'live' && me != null && (me['attemptsUsed'] as int) == 0) ...[
            const SizedBox(height: 12),
            _btn('PLAY NOW', filled: true, accent: exlGreen, onTap: widget.busy ? null : () => widget.onPlay(_asTournament(r))),
          ],
        ]),
      ),
    );
  }

  String _countFor(Map r) {
    final st = r['status'] as String;
    if (st == 'open') return '⏱ ${exlCountdown(r['joinEndsAt'] as int)}';
    if (st == 'live') return '▶ ${exlCountdown(r['endsAt'] as int)}';
    return '';
  }
}

// ---- small shared widgets ----
Widget _chip(String t, Color c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), border: Border.all(color: c)),
    child: Text(t, style: TextStyle(color: c, fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 1)));

Widget _statusChip(Map r) {
  final st = r['status'] as String;
  switch (st) {
    case 'open': return _chip('WAITING', exlCyan);
    case 'live': return _chip('LIVE', exlGreen);
    case 'paid': return _chip('PAID', exlGold);
    case 'cancelled': return _chip('REFUNDED', exlCyanDim);
    case 'settling': return _chip('SETTLING', exlOrange);
    default: return _chip(st.toUpperCase(), exlCyanDim);
  }
}

Widget _stat(String label, String value, String? sub, Color color, {int flex = 1}) => Expanded(
    flex: flex,
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(color: exlCyanDim, fontSize: 10, letterSpacing: 1.5)),
      const SizedBox(height: 2),
      Text(value, style: TextStyle(color: color, fontSize: 14, fontWeight: FontWeight.w800)),
      if (sub != null) Text(sub, style: const TextStyle(color: exlCyanDim, fontSize: 10)),
    ]));

Widget _btn(String label, {required bool filled, required VoidCallback? onTap, Color accent = exlCyan}) {
  final enabled = onTap != null;
  return GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: filled && enabled ? accent : Colors.transparent,
        border: Border.all(color: enabled ? accent : exlCyanDim),
        boxShadow: filled && enabled ? [BoxShadow(color: accent.withOpacity(0.35), blurRadius: 14, offset: const Offset(0, 4))] : null,
      ),
      child: Text(label, textAlign: TextAlign.center,
          style: TextStyle(color: filled && enabled ? exlBgBottom : (enabled ? accent : exlCyanDim), fontSize: 12.5, fontWeight: FontWeight.w800, letterSpacing: 1)),
    ),
  );
}

// ============================== CREATE ROOM SHEET ==============================

class _CreateRoomSheet extends StatefulWidget {
  final Map limits;
  final Map? prices;
  final bool skrAvailable;
  final Map? prefill;
  const _CreateRoomSheet({required this.limits, required this.prices, required this.skrAvailable, this.prefill});
  @override
  State<_CreateRoomSheet> createState() => _CreateRoomSheetState();
}

class _CreateRoomSheetState extends State<_CreateRoomSheet> {
  String cur = 'SOL';
  int stake = 50000000;       // base units
  int players = 2;
  int joinMin = 60, playMin = 60;
  String dist = 'wta';
  bool isPublic = false;
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

  @override
  Widget build(BuildContext context) {
    final min = (_lim['min'] as num).toInt(), max = (_lim['max'] as num).toInt();
    final stakeOk = stake >= min && stake <= max;
    final pool = stake * players;
    final payable = pool * (100 - _feePct) / 100;
    final w = _weights();
    final windows = (widget.limits['windowsMin'] as List).cast<num>().map((e) => e.toInt()).toList();
    final accent = cur == 'SKR' ? exlGold : exlCyan;
    return Container(
      padding: EdgeInsets.fromLTRB(20, 14, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      decoration: const BoxDecoration(color: exlPanel, borderRadius: BorderRadius.vertical(top: Radius.circular(24)), border: Border(top: BorderSide(color: exlCyanDim))),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(child: Container(width: 42, height: 4, decoration: BoxDecoration(color: exlCyanDim, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 14),
          const Center(child: Text('CREATE ROOM', style: TextStyle(color: exlCyan, fontSize: 15, fontWeight: FontWeight.w900, letterSpacing: 3))),
          const SizedBox(height: 14),
          _label('CURRENCY'),
          Row(children: [
            _choice('SOL', cur == 'SOL', exlCyan, () => setState(() { cur = 'SOL'; stake = solPresets[1]; })),
            const SizedBox(width: 8),
            _choice('SKR', cur == 'SKR', exlGold, widget.skrAvailable ? () => setState(() { cur = 'SKR'; stake = skrPresets[1]; }) : null),
          ]),
          const SizedBox(height: 12),
          _label('STAKE PER PLAYER'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final p in _presets) _choice(exlFmtAmt(p, cur), stake == p, accent, () => setState(() => stake = p)),
            SizedBox(
              width: 110,
              child: TextField(
                controller: _custom, keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: _setCustom,
                style: const TextStyle(color: exlIce, fontSize: 13),
                decoration: InputDecoration(
                  isDense: true, hintText: 'custom', hintStyle: const TextStyle(color: exlCyanDim, fontSize: 12),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: exlCyanDim)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: accent)),
                ),
              ),
            ),
          ]),
          Padding(padding: const EdgeInsets.only(top: 6), child: Row(children: [
            exlUsdText(widget.prices, stake, cur, size: 11),
            const Spacer(),
            Text(stakeOk ? 'range ${exlFmtAmt(min, cur)} – ${exlFmtAmt(max, cur)}' : 'must be ${exlFmtAmt(min, cur)} – ${exlFmtAmt(max, cur)}',
                style: TextStyle(color: stakeOk ? exlCyanDim : const Color(0xFFFF6B6B), fontSize: 10.5)),
          ])),
          const SizedBox(height: 12),
          _label('PLAYERS'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (var n = 2; n <= 10; n++) _choice('$n', players == n, accent, () => setState(() { players = n; if (!_distOk(dist)) dist = 'wta'; }), compact: true),
          ]),
          const SizedBox(height: 12),
          _label('JOINING WINDOW'),
          Wrap(spacing: 8, runSpacing: 8, children: [for (final m in windows) _choice(_win(m), joinMin == m, accent, () => setState(() => joinMin = m))]),
          const SizedBox(height: 12),
          _label('PLAYING WINDOW  (starts when the room is full or the joining window closes)'),
          Wrap(spacing: 8, runSpacing: 8, children: [for (final m in windows) _choice(_win(m), playMin == m, accent, () => setState(() => playMin = m))]),
          const SizedBox(height: 12),
          _label('PAYOUT'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in (widget.limits['dist'] as Map).entries)
              _choice(e.value as String, dist == e.key, accent, _distOk(e.key as String) ? () => setState(() => dist = e.key as String) : null),
          ]),
          const SizedBox(height: 12),
          _label('VISIBILITY'),
          Row(children: [
            _choice('PRIVATE · invite code', !isPublic, accent, () => setState(() => isPublic = false)),
            const SizedBox(width: 8),
            _choice('PUBLIC · open list', isPublic, accent, () => setState(() => isPublic = true)),
          ]),
          const SizedBox(height: 16),
          // ---- summary
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: accent.withOpacity(0.5)), color: exlBgBottom.withOpacity(0.5)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('FULL ROOM POT', style: TextStyle(color: exlCyanDim, fontSize: 10, letterSpacing: 1.5)),
                const Spacer(),
                Text(exlFmtAmt(pool, cur), style: TextStyle(color: accent, fontSize: 16, fontWeight: FontWeight.w900)),
                const SizedBox(width: 6),
                exlUsdText(widget.prices, pool, cur, size: 11),
              ]),
              const SizedBox(height: 6),
              for (var i = 0; i < w.length; i++)
                Padding(padding: const EdgeInsets.only(top: 3), child: Row(children: [
                  Text('#${i + 1}', style: const TextStyle(color: exlIce, fontSize: 12, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  Text('${w[i].toStringAsFixed(0)}%', style: const TextStyle(color: exlCyanDim, fontSize: 11)),
                  const Spacer(),
                  Text(exlFmtAmt(payable * w[i] / 100, cur), style: const TextStyle(color: exlIce, fontSize: 12.5, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 6),
                  exlUsdText(widget.prices, payable * w[i] / 100, cur),
                ])),
              const SizedBox(height: 6),
              Text('Service fee $_feePct% · fewer than 2 players or no valid score → full refund (minus network fee) · one attempt each · same seed for everyone',
                  style: TextStyle(color: exlCyanDim.withOpacity(0.9), fontSize: 10.5, height: 1.4)),
            ]),
          ),
          const SizedBox(height: 14),
          _btn('CREATE & PAY ${exlFmtAmt(stake, cur)}', filled: true, accent: accent,
              onTap: stakeOk ? () => Navigator.pop(context, {
                    'currency': cur, 'stake': stake, 'players': players, 'joinMin': joinMin, 'playMin': playMin,
                    'dist': dist, 'visibility': isPublic ? 'public' : 'private',
                  }) : null),
        ]),
      ),
    );
  }

  Widget _label(String t) => Padding(padding: const EdgeInsets.only(bottom: 7),
      child: Text(t, style: const TextStyle(color: exlCyanDim, fontSize: 10, letterSpacing: 1.5, fontWeight: FontWeight.w700)));

  Widget _choice(String t, bool on, Color accent, VoidCallback? onTap, {bool compact = false}) => GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: compact ? 13 : 12, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: on ? accent.withOpacity(0.18) : Colors.transparent,
          border: Border.all(color: on ? accent : (onTap == null ? exlCyanDim.withOpacity(0.4) : exlCyanDim)),
        ),
        child: Text(t, style: TextStyle(color: on ? accent : (onTap == null ? exlCyanDim.withOpacity(0.5) : exlIce), fontSize: 12, fontWeight: FontWeight.w700)),
      ));
}

// ============================== ROOM SCREEN ==============================

class RoomScreen extends StatefulWidget {
  final String apiBase, gameId, appName, roomId;
  final String? wallet;
  final DuelJoinFn onJoin;
  final DuelPlayFn onPlay;
  final DuelRanksFn onRanks;
  final void Function(Map settings) onRematch;
  const RoomScreen({
    super.key, required this.apiBase, required this.gameId, required this.appName, required this.roomId, required this.wallet,
    required this.onJoin, required this.onPlay, required this.onRanks, required this.onRematch,
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
  int _skew = 0; // server now − device now

  @override
  void initState() {
    super.initState();
    _load();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); });
    _poll = Timer.periodic(const Duration(seconds: 6), (_) { final st = _r?['status']; if (st == 'open' || st == 'live' || st == 'settling' || st == 'pending') _load(); });
  }

  @override
  void dispose() { _clock?.cancel(); _poll?.cancel(); super.dispose(); }

  Future<void> _load() async {
    try {
      final r = await _api.get(widget.roomId, widget.wallet);
      if (mounted) setState(() { _r = r; _error = null; _skew = (r['now'] as int) - DateTime.now().millisecondsSinceEpoch; });
    } catch (e) { if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', '')); }
  }

  int get _now => DateTime.now().millisecondsSinceEpoch + _skew;
  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 3)));

  Future<void> _share() async {
    final r = _r!;
    final text = 'Duel me in ${widget.appName}! Room code ${r['code']} · stake ${exlFmtAmt(r['stake'] as num, r['currency'] as String)} · ${r['distLabel']}. '
        'Open ${widget.appName} on your Seeker → TOURNEY → DUELS → JOIN WITH CODE.';
    await Clipboard.setData(ClipboardData(text: text));
    _snack('Invite copied — paste it anywhere');
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent, centerTitle: true,
        title: const Text('DUEL ROOM', style: TextStyle(color: exlCyan, fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: 4)),
        actions: [
          if (r != null) IconButton(onPressed: _share, tooltip: 'Share invite', icon: const Icon(Icons.ios_share, color: exlCyanDim)),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh, color: exlCyanDim)),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(gradient: RadialGradient(center: Alignment(0, -0.6), radius: 1.5, colors: [Color(0xFF0E2A52), exlBgBottom])),
        child: SafeArea(
          child: _error != null && r == null
              ? Center(child: Text(_error!, style: const TextStyle(color: Color(0xFFFF6B6B))))
              : r == null
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2, color: exlCyan))
                  : _body(r),
        ),
      ),
    );
  }

  Widget _body(Map<String, dynamic> r) {
    final cur = r['currency'] as String? ?? 'SOL';
    final accent = cur == 'SKR' ? exlGold : exlCyan;
    final st = r['status'] as String;
    final me = r['me'] as Map?;
    final entries = (r['entries'] as List).cast<Map>();
    final prices = r['prices'] as Map?;
    final players = r['players'] as int, max = r['maxPlayers'] as int;
    final pool = r['pool'] as num;
    final payable = pool * (100 - (r['feePct'] as num)) / 100;
    final weights = (r['weights'] as List).cast<num>();
    final payouts = (r['payouts'] as List).cast<Map>();
    final canJoin = me == null && st == 'open' && players < max;
    final canPlay = me != null && st == 'live' && (me['attemptsUsed'] as int) == 0 && (r['endsAt'] as int) > _now;
    final finished = st == 'paid' || st == 'cancelled';

    String headline, sub;
    switch (st) {
      case 'pending': headline = 'WAITING FOR PAYMENT'; sub = 'The creator\'s stake has not arrived yet.'; break;
      case 'open': headline = 'WAITING FOR PLAYERS'; sub = 'Starts when full or in ${exlCountdown(r['joinEndsAt'] as int, nowMs: _now)}'; break;
      case 'live': headline = 'LIVE — PLAY NOW'; sub = 'Everyone\'s clock ends in ${exlCountdown(r['endsAt'] as int, nowMs: _now)}'; break;
      case 'settling': headline = 'SETTLING'; sub = 'Paying out on-chain…'; break;
      case 'paid': headline = 'FINISHED'; sub = 'Prizes paid on-chain.'; break;
      default: headline = 'CANCELLED'; sub = 'Stakes refunded (minus network fee).';
    }

    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 28), children: [
      // ---- code + status
      Container(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(18), border: Border.all(color: st == 'live' ? exlGreen : accent.withOpacity(0.6)),
            color: exlPanel.withOpacity(0.8), boxShadow: [BoxShadow(color: (st == 'live' ? exlGreen : accent).withOpacity(0.15), blurRadius: 18)]),
        child: Column(children: [
          Row(children: [_chip(cur, cur == 'SKR' ? exlGold : exlCyanDim), const SizedBox(width: 6), _statusChip(r), const Spacer(),
            Text(r['visibility'] == 'public' ? 'PUBLIC' : 'PRIVATE', style: const TextStyle(color: exlCyanDim, fontSize: 10, letterSpacing: 1.5))]),
          const SizedBox(height: 10),
          GestureDetector(onTap: _share, child: Text(r['code'] as String,
              style: TextStyle(color: accent, fontSize: 34, fontWeight: FontWeight.w900, letterSpacing: 8, fontFamily: 'monospace'))),
          const SizedBox(height: 2),
          Text(headline, style: TextStyle(color: st == 'live' ? exlGreen : exlIce, fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 2)),
          const SizedBox(height: 2),
          Text(sub, style: const TextStyle(color: exlCyanDim, fontSize: 12)),
          const SizedBox(height: 14),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            _stat('POT', exlFmtAmt(pool, cur), exlUsd(prices, pool, cur), accent, flex: 4),
            _stat('STAKE', exlFmtAmt(r['stake'] as num, cur), exlUsd(prices, r['stake'] as num, cur), exlIce, flex: 4),
            _stat('PLAYERS', '$players / $max', null, exlIce, flex: 3),
          ]),
          const SizedBox(height: 14),
          if (canJoin) _btn('ENTER — ${exlFmtAmt(r['stake'] as num, cur)}', filled: true, accent: accent, onTap: _busy ? null : () async {
            setState(() => _busy = true);
            final ok = await widget.onJoin(_asTournament(r), r['skr'] as Map?, r['poolAddress'] as String);
            if (mounted) setState(() => _busy = false);
            if (ok) _load();
          }),
          if (canPlay) _btn('PLAY YOUR RUN', filled: true, accent: exlGreen, onTap: _busy ? null : () async { await widget.onPlay(_asTournament(r)); _load(); }),
          if (me != null && st == 'live' && (me['attemptsUsed'] as int) > 0)
            Text('Run submitted · score ${me['bestScore']} · waiting for the clock', style: const TextStyle(color: exlGreen, fontSize: 12, fontWeight: FontWeight.w700)),
          if (me != null && st == 'open')
            Padding(padding: const EdgeInsets.only(top: 4), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Expanded(child: _btn('SHARE INVITE', filled: false, accent: accent, onTap: _share)),
            ])),
          if (finished) Row(children: [
            Expanded(child: _btn('RANKS', filled: false, onTap: () => widget.onRanks(r['id'] as String))),
            const SizedBox(width: 8),
            Expanded(child: _btn('REMATCH', filled: true, accent: accent, onTap: () {
              Navigator.pop(context);
              widget.onRematch({'currency': cur, 'stake': r['stake'], 'players': max, 'joinMin': _nearestWin((r['joinMs'] as int?) ?? 3600000),
                  'playMin': _nearestWin(r['playMs'] as int), 'dist': r['dist'], 'visibility': r['visibility']});
            })),
          ]),
        ]),
      ),
      const SizedBox(height: 12),
      // ---- players
      _panel('PLAYERS', [
        if (entries.isEmpty) const Text('Nobody yet.', style: TextStyle(color: exlCyanDim, fontSize: 12)),
        for (var i = 0; i < entries.length; i++) _entryRow(i, entries[i], st, finished, payouts, cur, prices),
        for (var i = entries.length; i < max; i++) Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: Row(children: [
          Container(width: 22, height: 22, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: exlCyanDim.withOpacity(0.5)))),
          const SizedBox(width: 10),
          Text('open seat', style: TextStyle(color: exlCyanDim.withOpacity(0.7), fontSize: 12)),
        ])),
      ]),
      const SizedBox(height: 12),
      // ---- payout table
      _panel(finished ? 'PAYOUTS' : 'PAYOUT · ${r['distLabel']}', [
        if (!finished) for (var i = 0; i < weights.length; i++) Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(children: [
          Text('#${i + 1}', style: const TextStyle(color: exlIce, fontSize: 12.5, fontWeight: FontWeight.w800)),
          const SizedBox(width: 8),
          Text('${weights[i].toStringAsFixed(0)}%', style: const TextStyle(color: exlCyanDim, fontSize: 11)),
          const Spacer(),
          Text(exlFmtAmt(payable * weights[i] / 100, cur), style: const TextStyle(color: exlIce, fontSize: 12.5, fontWeight: FontWeight.w700)),
          const SizedBox(width: 6), exlUsdText(prices, payable * weights[i] / 100, cur),
        ])),
        if (!finished) Padding(padding: const EdgeInsets.only(top: 4), child: Text(
            'Based on the current pot · service fee ${r['feePct']}% · ties split equally · fewer than 2 players or no valid score → refund',
            style: TextStyle(color: exlCyanDim.withOpacity(0.9), fontSize: 10.5, height: 1.4))),
        if (finished && payouts.isEmpty) const Text('No payouts recorded.', style: TextStyle(color: exlCyanDim, fontSize: 12)),
        for (final p in payouts) Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(children: [
          Text(p['role'] == 'prize' ? '#${p['rank']}' : (p['role'] == 'refund' ? 'refund' : 'fee'),
              style: TextStyle(color: p['role'] == 'prize' ? exlIce : exlCyanDim, fontSize: 12, fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          Text(_short(p['wallet'] as String), style: const TextStyle(color: exlCyanDim, fontSize: 11.5)),
          const Spacer(),
          Text(exlFmtAmt(p['amount'] as num, cur), style: const TextStyle(color: exlIce, fontSize: 12.5, fontWeight: FontWeight.w700)),
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
    ]);
  }

  int _nearestWin(int ms) { const opts = [15, 60, 360, 1440]; final m = ms ~/ 60000; return opts.reduce((a, b) => (a - m).abs() <= (b - m).abs() ? a : b); }

  Widget _entryRow(int i, Map e, String st, bool finished, List<Map> payouts, String cur, Map? prices) {
    final w = e['wallet'] as String;
    final mine = w == widget.wallet;
    final showScore = st == 'live' || finished;
    final prize = payouts.cast<Map?>().firstWhere((p) => p!['role'] == 'prize' && p['wallet'] == w, orElse: () => null);
    return Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: Row(children: [
      Container(width: 22, height: 22, alignment: Alignment.center,
          decoration: BoxDecoration(shape: BoxShape.circle, color: mine ? exlCyan.withOpacity(0.2) : exlPanel, border: Border.all(color: mine ? exlCyan : exlCyanDim)),
          child: Text(showScore && (e['score'] as int) > 0 ? '${i + 1}' : '·', style: TextStyle(color: mine ? exlCyan : exlCyanDim, fontSize: 11, fontWeight: FontWeight.w800))),
      const SizedBox(width: 10),
      Text(mine ? 'you' : _short(w), style: TextStyle(color: mine ? exlCyan : exlIce, fontSize: 12.5, fontWeight: FontWeight.w700)),
      const SizedBox(width: 6),
      if (e['verified'] == true) const Icon(Icons.verified, size: 12, color: exlGreen),
      const Spacer(),
      if (prize != null) Padding(padding: const EdgeInsets.only(right: 8), child: Text('+${exlFmtAmt(prize['amount'] as num, cur)}', style: const TextStyle(color: exlGold, fontSize: 12, fontWeight: FontWeight.w800))),
      Text(showScore ? ((e['played'] == true) ? '${e['score']}' : (finished ? '—' : 'playing')) : 'ready',
          style: TextStyle(color: showScore && e['played'] == true ? exlIce : exlCyanDim, fontSize: 13, fontWeight: FontWeight.w800)),
    ]));
  }

  Widget _panel(String title, List<Widget> children) => Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(color: exlPanel.withOpacity(0.7), borderRadius: BorderRadius.circular(16), border: Border.all(color: exlCyanDim)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: exlCyan, fontSize: 11, letterSpacing: 2, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        ...children,
      ]));
}
