// EXL Tourney — v1.2.1 · offline-safe score submission.
// If /attempt/submit cannot be reached (no network, timeout, 5xx), the finished
// run is stored on the device and re-sent automatically the next time the game
// opens online (attempt tokens stay valid 24h server-side). A server-side
// rejection (invalid/used/expired token, bad score) is final and is NOT retried.
// Apache-2.0 — github.com/excobalab/exl-tourney
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

typedef ExlSubmitFn = Future<Map<String, dynamic>> Function(String token, int score, int durationMs, int taps,
    {String? signature, String? wallet});

class ExlPendingSaved implements Exception {
  final String message;
  ExlPendingSaved(this.message);
  @override
  String toString() => message;
}

class ExlPending {
  static const _key = 'exl_pending_submits';
  static const _maxAgeMs = 24 * 60 * 60 * 1000;
  static bool _flushing = false;

  /// Network-ish failure → worth retrying later. Anything else is a server verdict.
  static bool isTransient(Object e) =>
      e is SocketException || e is TimeoutException || e is http.ClientException || e is FormatException || e is HttpException;

  /// Submit now; on a transient failure store the run and throw [ExlPendingSaved].
  static Future<Map<String, dynamic>> submitOrQueue(ExlSubmitFn submit, String token, int score, int durationMs, int taps,
      {String? signature, String? wallet}) async {
    try {
      return await submit(token, score, durationMs, taps, signature: signature, wallet: wallet);
    } catch (e) {
      if (!isTransient(e)) rethrow;
      await save(token: token, score: score, durationMs: durationMs, taps: taps, signature: signature, wallet: wallet);
      throw ExlPendingSaved(
          'No connection — your run is saved on this device and will be submitted automatically when the game opens online (within 24h).');
    }
  }

  static Future<void> save(
      {required String token, required int score, required int durationMs, required int taps, String? signature, String? wallet}) async {
    final p = await SharedPreferences.getInstance();
    final list = _read(p)..removeWhere((m) => m['token'] == token);
    list.add({
      'token': token, 'score': score, 'dur': durationMs, 'taps': taps,
      if (signature != null) 'sig': signature, if (wallet != null) 'wallet': wallet,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
    await p.setString(_key, jsonEncode(list));
  }

  static Future<void> remove(String token) async {
    final p = await SharedPreferences.getInstance();
    final list = _read(p)..removeWhere((m) => m['token'] == token);
    await p.setString(_key, jsonEncode(list));
  }

  static Future<int> count() async => _read(await SharedPreferences.getInstance()).length;

  /// Re-send everything stored. Returns how many were accepted by the server.
  static Future<int> flush(ExlSubmitFn submit) async {
    if (_flushing) return 0;
    _flushing = true;
    try {
      final p = await SharedPreferences.getInstance();
      final list = _read(p);
      if (list.isEmpty) return 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      final keep = <Map<String, dynamic>>[];
      var ok = 0;
      for (final m in list) {
        if (now - (m['ts'] as int) > _maxAgeMs) continue; // token expired server-side anyway
        try {
          final r = await submit(m['token'] as String, m['score'] as int, m['dur'] as int, m['taps'] as int,
              signature: m['sig'] as String?, wallet: m['wallet'] as String?);
          if (r['accepted'] == true) ok++;
          // accepted or rejected — either way the server has spoken; drop it
        } catch (e) {
          if (isTransient(e)) keep.add(m); // still offline → try again next launch
          // non-transient (used/expired/invalid token) → drop
        }
      }
      await p.setString(_key, jsonEncode(keep));
      return ok;
    } finally {
      _flushing = false;
    }
  }

  static List<Map<String, dynamic>> _read(SharedPreferences p) {
    try {
      final raw = p.getString(_key);
      if (raw == null || raw.isEmpty) return [];
      return (jsonDecode(raw) as List).cast<Map>().map((e) => e.cast<String, dynamic>()).toList();
    } catch (_) {
      return [];
    }
  }
}
