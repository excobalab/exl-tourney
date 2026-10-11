// ============================================================================
// EXL PROOF — turnuva şeffaflık ekranı (7 Tourney oyununda ortak dosya)
// GET /proof?tournamentId= çıktısını gösterir: seed taahhüdü/açıklaması, katılımcılar,
// sıralama (✓ verified rozetli), payout'lar (Solscan linkli), ücret dökümü.
// Kullanım: Navigator.push(... ProofScreen(apiBase: kApiBase, tournamentId: id))
// ============================================================================

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'exl_ui.dart';
import 'exl_wallet.dart';

class ProofScreen extends StatefulWidget {
  final String apiBase;
  final String tournamentId;
  const ProofScreen({super.key, required this.apiBase, required this.tournamentId});

  @override
  State<ProofScreen> createState() => _ProofScreenState();
}

class _ProofScreenState extends State<ProofScreen> {
  Map<String, dynamic>? _d;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _d = null;
      _error = null;
    });
    try {
      final r = await http
          .get(Uri.parse('${widget.apiBase}/proof?tournamentId=${Uri.encodeComponent(widget.tournamentId)}'))
          .timeout(const Duration(seconds: 20));
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode >= 400) throw Exception(j['error'] ?? 'Server error');
      if (mounted) setState(() => _d = j);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  String _short(String w) => w.length > 10 ? '${w.substring(0, 4)}…${w.substring(w.length - 4)}' : w;

  String _amt(num v, String cur) =>
      cur == 'SKR' ? '${(v / 1e6).toStringAsFixed(v % 1e6 == 0 ? 0 : 2)} SKR' : '${(v / 1e9).toStringAsFixed(3)} SOL';

  String _when(int? ms) {
    if (ms == null) return '—';
    final t = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')} UTC';
  }

  Future<void> _open(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  void _copy(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$label copied'), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        centerTitle: true,
        title: const ExlEmboss('PROOF', size: 20, spacing: 3),
        actions: [
          IconButton(
              onPressed: () => _open('https://web3.excobalab.com/proof/?id=${Uri.encodeComponent(widget.tournamentId)}'),
              tooltip: 'Open in browser',
              icon: const Icon(Icons.open_in_browser, color: exlCyanDim)),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh, color: exlCyanDim)),
        ],
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(center: Alignment(0, -0.6), radius: 1.5, colors: [exlBgTop, exlBgBottom]),
        ),
        child: SafeArea(
          child: _error != null
              ? Center(
                  child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFFF6B6B))),
                        TextButton(onPressed: _load, child: const Text('RETRY', style: TextStyle(color: exlCyan))),
                      ])))
              : _d == null
                  ? const Center(child: CircularProgressIndicator(strokeWidth: 2, color: exlCyan))
                  : _body(),
        ),
      ),
    );
  }

  Widget _body() {
    final d = _d!;
    final t = d['tournament'] as Map;
    final cur = (t['currency'] as String?) ?? 'SOL';
    final status = t['status'] as String;
    final ranking = (d['ranking'] as List).cast<Map>();
    final payouts = (d['payouts'] as List).cast<Map>();
    final seed = d['seed'] as String?;
    final commit = d['seedCommitment'] as String;
    final pool = d['pool'] as num;
    final feePct = t['feePct'] as num;
    final type = t['type'] as String;
    final typeName = type == 'd'
        ? 'DAILY'
        : (type == 'w' ? 'WEEKLY' : (type == 'm' ? 'MONTHLY' : (type == 'x' ? 'DUEL ROOM' : type.toUpperCase())));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
      children: [
        _panel([
          Row(children: [
            Text(typeName,
                style: const TextStyle(color: exlCyan, fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 3)),
            const SizedBox(width: 8),
            _chip(cur, cur == 'SKR' ? const Color(0xFFD4B26A) : exlCyan),
            const Spacer(),
            _chip(status.toUpperCase(),
                status == 'paid' ? const Color(0xFF7FE0A8) : (status == 'open' ? exlCyan : exlCyanDim)),
          ]),
          const SizedBox(height: 6),
          GestureDetector(
            onTap: () => _copy(widget.tournamentId, 'Tournament id'),
            child: Text(widget.tournamentId, style: const TextStyle(color: exlCyanDim, fontSize: 11.5, letterSpacing: .5)),
          ),
          const SizedBox(height: 12),
          Row(children: [
            _stat('POOL', _amt(pool, cur)),
            _stat('PLAYERS', '${d['participants']}'),
            _stat('ENTRY', _amt(t['feeAmount'] as num, cur)),
            _stat('FEE', '$feePct%'),
          ]),
          const SizedBox(height: 8),
          Text('${_when(t['startsAt'] as int?)} → ${_when(t['endsAt'] as int?)}',
              style: const TextStyle(color: exlCyanDim, fontSize: 11)),
        ]),
        _panel([
          _h('SAME RUN FOR EVERYONE'),
          const SizedBox(height: 6),
          const Text(
              'Every participant plays the run generated from one server seed. The seed is committed (SHA-256) while the tournament is open and revealed after settlement.',
              style: TextStyle(color: exlIce, fontSize: 12.5, height: 1.5)),
          const SizedBox(height: 10),
          _kv('Seed commitment', commit, copy: true),
          if (seed != null) _kv('Revealed seed', seed, copy: true) else const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Seed is revealed once the tournament is paid out.',
                style: TextStyle(color: exlCyanDim, fontSize: 11.5)),
          ),
        ]),
        _panel([
          _h('RANKING'),
          const SizedBox(height: 6),
          if (ranking.isEmpty)
            const Text('No participants yet.', style: TextStyle(color: exlCyanDim, fontSize: 13))
          else
            for (final r in ranking) _rankRow(r, cur),
        ]),
        _panel([
          _h('PAYOUTS'),
          const SizedBox(height: 6),
          if (payouts.isEmpty)
            Text(status == 'paid' ? 'No prizes were due (no valid scores).' : 'Paid automatically when the tournament ends.',
                style: const TextStyle(color: exlCyanDim, fontSize: 13))
          else
            for (final p in payouts) _payoutRow(p, cur),
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.account_balance_wallet_outlined, color: exlCyanDim, size: 14),
            const SizedBox(width: 6),
            Expanded(
              child: GestureDetector(
                onTap: () => _open('https://solscan.io/account/${d['poolAddress']}'),
                child: Text('Prize pool wallet ${_short(d['poolAddress'] as String)} → Solscan',
                    style: const TextStyle(
                        color: exlCyan, fontSize: 11.5, decoration: TextDecoration.underline, decorationColor: exlCyan)),
              ),
            ),
          ]),
        ]),
        _panel([
          _h('RULES'),
          const SizedBox(height: 6),
          Text(d['rules'] as String? ?? '', style: const TextStyle(color: exlIce, fontSize: 12.5, height: 1.5)),
          const SizedBox(height: 8),
          const Text('Open source: github.com/excobalab/exl-tourney',
              style: TextStyle(color: exlCyanDim, fontSize: 11.5)),
        ]),
      ],
    );
  }

  Widget _rankRow(Map r, String cur) {
    final rank = r['rank'] as int?;
    final verified = r['verified'] == true;
    final score = r['score'] as num;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: exlBgBottom.withOpacity(0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: (rank ?? 99) <= 3 ? exlCyan.withOpacity(0.4) : exlCyanDim),
      ),
      child: Row(children: [
        SizedBox(
            width: 36,
            child: Text(rank == null ? '—' : '#$rank',
                style: const TextStyle(color: exlIce, fontSize: 13, fontWeight: FontWeight.w800))),
        Expanded(
          child: GestureDetector(
            onTap: () => _open('https://solscan.io/tx/${r['entryTx']}'),
            child: Text(_short(r['wallet'] as String),
                style: const TextStyle(color: exlCyanDim, fontSize: 12.5, letterSpacing: 1,
                    decoration: TextDecoration.underline, decorationColor: exlCyanDim)),
          ),
        ),
        if (verified) ...[
          const Icon(Icons.verified, color: Color(0xFF7FE0A8), size: 15),
          const SizedBox(width: 6),
        ],
        Text(score == 0 ? 'no score' : '$score',
            style: TextStyle(
                color: score == 0 ? exlCyanDim : exlCyan, fontSize: 14, fontWeight: FontWeight.w800)),
      ]),
    );
  }

  Widget _payoutRow(Map p, String cur) {
    final role = p['role'] as String;
    final explorer = p['explorer'] as String?;
    final label = role == 'service_fee' ? 'Service fee' : 'Prize #${p['rank']}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        SizedBox(
            width: 92,
            child: Text(label,
                style: TextStyle(
                    color: role == 'service_fee' ? exlCyanDim : exlIce, fontSize: 12.5, fontWeight: FontWeight.w700))),
        Expanded(
            child: Text(_short(p['wallet'] as String),
                style: const TextStyle(color: exlCyanDim, fontSize: 12, letterSpacing: 1))),
        Text(_amt(p['amount'] as num, cur),
            style: const TextStyle(color: exlCyan, fontSize: 13, fontWeight: FontWeight.w800)),
        const SizedBox(width: 8),
        if (explorer != null)
          GestureDetector(
            onTap: () => _open(explorer),
            child: const Text('TX ↗',
                style: TextStyle(color: Color(0xFF7FE0A8), fontSize: 11, fontWeight: FontWeight.w800)),
          )
        else
          const Text('dry-run', style: TextStyle(color: exlCyanDim, fontSize: 10.5)),
      ]),
    );
  }

  Widget _panel(List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: exlPanel.withOpacity(0.8),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: exlCyanDim),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  Widget _h(String s) =>
      Text(s, style: const TextStyle(color: exlCyan, fontSize: 12.5, fontWeight: FontWeight.w800, letterSpacing: 2));

  Widget _chip(String s, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: c)),
        child: Text(s, style: TextStyle(color: c, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1)),
      );

  Widget _stat(String label, String value) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: exlCyanDim, fontSize: 10, letterSpacing: 1.5)),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(color: exlIce, fontSize: 13.5, fontWeight: FontWeight.w700)),
        ]),
      );

  Widget _kv(String k, String v, {bool copy = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: GestureDetector(
          onTap: copy ? () => _copy(v, k) : null,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(k, style: const TextStyle(color: exlCyanDim, fontSize: 10.5, letterSpacing: 1)),
            Text(v, style: const TextStyle(color: exlIce, fontSize: 11, fontFamily: 'monospace', height: 1.4)),
          ]),
        ),
      );
}
