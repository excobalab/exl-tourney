// ============================================================================
// EXL PREMIUM — EXCOBALAB ortak Solana Pay modülü (v1)
// Dice Ex'te cihazda doğrulanan çift raylı ödeme sistemi:
//   Ray 1: MWA 2.0 native köprü ("exl/mwa" MethodChannel — MainActivity.kt)
//          Seeker Wallet, Jupiter, Solflare, Backpack...
//   Ray 2: Phantom şifreli deeplink (connect + signTransaction; app RPC ile gönderir)
//
// KULLANIM (uygulama main.dart'ında):
//   import 'exl_premium.dart';
//   const kExlConfig = ExlPremiumConfig(
//     appName: 'Card Deck Ex',
//     memo: 'cardex:premium:v1',
//     phantomScheme: 'cardex',            // AndroidManifest intent-filter ile AYNI
//     unlockLine: 'Unlock jokers & multi-deck — forever.',
//   );
//   final unlocked = await ExlPremium.isUnlocked();
//   showExlPremiumSheet(context, config: kExlConfig, onUnlocked: () {...});
//   Footer: ExlSiteLink()
//
// GEREKEN pubspec bağımlılıkları:
//   solana ^0.31.2, http, shared_preferences, url_launcher,
//   app_links ^6.3.2, pinenacl ^0.6.0
// GEREKEN manifest: INTERNET izni + <data android:scheme="<phantomScheme>"/> intent-filter
// GEREKEN native: MainActivity.kt (şablon: _ortak/MainActivity.template.kt)
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:pinenacl/x25519.dart' as nacl;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:solana/base58.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';
import 'package:url_launcher/url_launcher.dart';

// ---- EXCOBALAB sabitleri (tüm uygulamalarda ortak) ----
const String exlMerchantAddress =
    'YOUR_MERCHANT_WALLET_PUBLIC_KEY';
const double exlPriceUsd = 2.99;
const String exlSiteUrl = 'https://excobalab.com';
const String exlRpcUrl = 'https://solana-rpc.publicnode.com';
const String exlWsUrl = 'wss://solana-rpc.publicnode.com';
const MethodChannel exlMwa = MethodChannel('exl/mwa');

// ---- Seeker paleti ----
const Color exlBgTop = Color(0xFF0E2A52);
const Color exlBgBottom = Color(0xFF060D1A);
const Color exlCyan = Color(0xFF3EE0F0);
const Color exlCyanDim = Color(0x663EE0F0);
const Color exlIce = Color(0xFFE8F4FF);
const Color exlPanel = Color(0xFF0C1C38);

class ExlPremiumConfig {
  final String appName; // 'Card Deck Ex'
  final String memo; // 'cardex:premium:v1'
  final String phantomScheme; // 'cardex' (manifest ile aynı)
  final String unlockLine; // 'Unlock X — forever.'
  const ExlPremiumConfig({
    required this.appName,
    required this.memo,
    required this.phantomScheme,
    required this.unlockLine,
  });
}

class ExlPremium {
  static Future<bool> isUnlocked() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('premium') ?? false;
  }
}

void showExlPremiumSheet(
  BuildContext context, {
  required ExlPremiumConfig config,
  required VoidCallback onUnlocked,
}) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _ExlPremiumSheet(config: config, onUnlocked: onUnlocked),
  );
}

// ---------------------------------------------------------------------------

enum _Stage { idle, price, wallet, approve, confirm, done }

class _ExlPremiumSheet extends StatefulWidget {
  final ExlPremiumConfig config;
  final VoidCallback onUnlocked;
  const _ExlPremiumSheet({required this.config, required this.onUnlocked});

  @override
  State<_ExlPremiumSheet> createState() => _ExlPremiumSheetState();
}

class _ExlPremiumSheetState extends State<_ExlPremiumSheet> {
  _Stage _stage = _Stage.idle;
  String? _error;

  late final nacl.PrivateKey _phSecret;
  late final Uint8List _phPub;
  nacl.Box? _phBox;
  String? _phSession;
  String? _phWallet;
  int? _phPendingLamports;
  StreamSubscription<Uri>? _phSub;

  ExlPremiumConfig get cfg => widget.config;

  @override
  void initState() {
    super.initState();
    _phSecret = nacl.PrivateKey.generate();
    _phPub = Uint8List.fromList(_phSecret.publicKey.toList());
    _phSub = AppLinks().uriLinkStream.listen(_onPhantomLink, onError: (_) {});
  }

  @override
  void dispose() {
    _phSub?.cancel();
    super.dispose();
  }

  String get _stageText {
    switch (_stage) {
      case _Stage.price:
        return 'Fetching SOL price...';
      case _Stage.wallet:
        return 'Connecting to your wallet...';
      case _Stage.approve:
        return 'Approve the payment in your wallet';
      case _Stage.confirm:
        return 'Confirming on Solana...';
      default:
        return '';
    }
  }

  Future<T> _withNetRetry<T>(Future<T> Function() fn) async {
    Object? lastErr;
    for (var i = 0; i < 4; i++) {
      try {
        return await fn();
      } catch (e) {
        lastErr = e;
        final s = e.toString();
        final transient = s.contains('SocketException') ||
            s.contains('host lookup') ||
            s.contains('Connection');
        if (!transient) rethrow;
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    throw lastErr!;
  }

  Future<int> _fetchLamports() async {
    final resp = await http
        .get(Uri.parse(
            'https://api.coingecko.com/api/v3/simple/price?ids=solana&vs_currencies=usd'))
        .timeout(const Duration(seconds: 15));
    final price =
        ((jsonDecode(resp.body) as Map)['solana']['usd'] as num).toDouble();
    if (price <= 0) throw Exception('Invalid price');
    return (exlPriceUsd / price * lamportsPerSol).round();
  }

  SolanaClient _rpc() => SolanaClient(
        rpcUrl: Uri.parse(exlRpcUrl),
        websocketUrl: Uri.parse(exlWsUrl),
      );

  Uint8List _buildUnsignedTx({
    required Ed25519HDPublicKey payer,
    required int lamports,
    required String blockhash,
  }) {
    final merchant = Ed25519HDPublicKey.fromBase58(exlMerchantAddress);
    final message = Message(instructions: [
      SystemInstruction.transfer(
        fundingAccount: payer,
        recipientAccount: merchant,
        lamports: lamports,
      ),
      MemoInstruction(signers: [payer], memo: cfg.memo),
    ]);
    final compiled =
        message.compile(recentBlockhash: blockhash, feePayer: payer);
    final unsignedTx = SignedTx(
      compiledMessage: compiled,
      signatures: [Signature(List.filled(64, 0), publicKey: payer)],
    );
    return Uint8List.fromList(unsignedTx.toByteArray().toList());
  }

  // ---------------- RAY 1: MWA (Seeker/Jupiter/Solflare/Backpack) ----------------

  Future<void> _buyMwa() async {
    setState(() {
      _stage = _Stage.price;
      _error = null;
    });
    var step = 'price';
    try {
      final lamports = await _fetchLamports();

      step = 'blockhash';
      final rpc = _rpc();
      final blockhash = await _withNetRetry(() => rpc.rpcClient
          .getLatestBlockhash()
          .then((it) => it.value.blockhash));

      step = 'wallet';
      if (mounted) setState(() => _stage = _Stage.approve);
      final sigBytes = await exlMwa.invokeMethod<Uint8List>('payPremium', {
        'recipient': exlMerchantAddress,
        'lamports': lamports,
        'memo': cfg.memo,
        'blockhash': blockhash,
      });
      if (sigBytes == null) throw Exception('Payment was not approved');
      final sig = base58encode(sigBytes.toList());

      step = 'confirm';
      await _confirmAndUnlock(rpc, sig);
    } catch (e) {
      _fail(e, step);
    }
  }

  // ---------------- RAY 2: Phantom deeplink ----------------

  Uint8List _phNonce() {
    final r = math.Random.secure();
    return Uint8List.fromList(List.generate(24, (_) => r.nextInt(256)));
  }

  Future<void> _buyPhantom() async {
    setState(() {
      _stage = _Stage.price;
      _error = null;
    });
    try {
      _phPendingLamports = await _fetchLamports();
      if (_phSession == null) {
        if (mounted) setState(() => _stage = _Stage.wallet);
        final uri = Uri.https('phantom.app', '/ul/v1/connect', {
          'app_url': exlSiteUrl,
          'dapp_encryption_public_key': base58encode(_phPub.toList()),
          'redirect_link': '${cfg.phantomScheme}://phconnect',
          'cluster': 'mainnet-beta',
        });
        final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (!ok) throw Exception('Phantom is not installed on this device');
      } else {
        await _phantomSign();
      }
    } catch (e) {
      _fail(e, 'phantom');
    }
  }

  Future<void> _onPhantomLink(Uri uri) async {
    final p = uri.queryParameters;
    if (p.containsKey('errorCode')) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.idle;
        _error = p['errorCode'] == '4001'
            ? 'Payment cancelled. You can try again anytime.'
            : 'Phantom error: ${p['errorMessage'] ?? p['errorCode']}';
      });
      return;
    }
    try {
      switch (uri.host.toLowerCase()) {
        case 'phconnect':
          final phantomPub =
              base58decode(p['phantom_encryption_public_key']!);
          final nonce = base58decode(p['nonce']!);
          final data = base58decode(p['data']!);
          _phBox = nacl.Box(
            myPrivateKey: _phSecret,
            theirPublicKey: nacl.PublicKey(Uint8List.fromList(phantomPub)),
          );
          final plain = _phBox!.decrypt(nacl.EncryptedMessage(
            nonce: Uint8List.fromList(nonce),
            cipherText: Uint8List.fromList(data),
          ));
          final json = jsonDecode(utf8.decode(plain)) as Map;
          _phSession = json['session'] as String;
          _phWallet = json['public_key'] as String;
          if (_phPendingLamports != null) await _phantomSign();
          break;
        case 'phsign':
          await _phantomFinish(p);
          break;
      }
    } catch (e) {
      _fail(e, 'phantom');
    }
  }

  Future<void> _phantomSign() async {
    if (mounted) setState(() => _stage = _Stage.approve);
    final rpc = _rpc();
    final blockhash = await _withNetRetry(() => rpc.rpcClient
        .getLatestBlockhash()
        .then((it) => it.value.blockhash));
    final payer = Ed25519HDPublicKey.fromBase58(_phWallet!);
    final txBytes = _buildUnsignedTx(
      payer: payer,
      lamports: _phPendingLamports!,
      blockhash: blockhash,
    );
    final payload = utf8.encode(jsonEncode({
      'transaction': base58encode(txBytes.toList()),
      'session': _phSession,
    }));
    final nonce = _phNonce();
    final sealed = _phBox!.encrypt(Uint8List.fromList(payload), nonce: nonce);
    final cipher = Uint8List.fromList(sealed.cipherText);
    final uri = Uri.https('phantom.app', '/ul/v1/signTransaction', {
      'dapp_encryption_public_key': base58encode(_phPub.toList()),
      'nonce': base58encode(nonce.toList()),
      'redirect_link': '${cfg.phantomScheme}://phsign',
      'payload': base58encode(cipher.toList()),
    });
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _phantomFinish(Map<String, String> p) async {
    final nonce = base58decode(p['nonce']!);
    final data = base58decode(p['data']!);
    final plain = _phBox!.decrypt(nacl.EncryptedMessage(
      nonce: Uint8List.fromList(nonce),
      cipherText: Uint8List.fromList(data),
    ));
    final json = jsonDecode(utf8.decode(plain)) as Map;
    final signedB58 = json['transaction'] as String;
    final rpc = _rpc();
    final sig = await _withNetRetry(() =>
        rpc.rpcClient.sendTransaction(base64Encode(base58decode(signedB58))));
    await _confirmAndUnlock(rpc, sig);
  }

  // ---------------- Ortak son: zincir onayı + kalıcılık ----------------

  Future<void> _confirmAndUnlock(SolanaClient rpc, String sig) async {
    if (mounted) setState(() => _stage = _Stage.confirm);
    var confirmed = false;
    for (var i = 0; i < 45 && !confirmed; i++) {
      await Future.delayed(const Duration(seconds: 2));
      dynamic s;
      try {
        final st = await rpc.rpcClient
            .getSignatureStatuses([sig], searchTransactionHistory: true);
        s = st.value.isNotEmpty ? st.value.first : null;
      } catch (_) {
        continue;
      }
      if (s != null) {
        if (s.err != null) throw Exception('Transaction failed on-chain');
        final cs = s.confirmationStatus?.toString() ?? '';
        if (cs.contains('confirmed') || cs.contains('finalized')) {
          confirmed = true;
        }
      }
    }
    if (!confirmed) {
      throw Exception(
          'Confirmation timed out. If SOL left your wallet, contact info@excobalab.com with tx: $sig');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('premium', true);
    await prefs.setString('premium_tx', sig);
    if (mounted) setState(() => _stage = _Stage.done);
    widget.onUnlocked();
  }

  void _fail(Object e, String step) {
    if (!mounted) return;
    final raw = e is PlatformException
        ? '${e.code}: ${e.message ?? ''}'
        : e.toString();
    final String msg;
    if (raw.contains('NOWALLET')) {
      msg =
          'No compatible wallet found. Please install Seeker Wallet, Jupiter or Solflare.';
    } else if (raw.contains('did not authorize') ||
        raw.contains('cancel') ||
        raw.contains('declined') ||
        raw.contains('interrupted') ||
        raw.contains('not approved')) {
      msg = 'Payment cancelled. You can try again anytime.';
    } else if (raw.contains('SocketException') ||
        raw.contains('host lookup') ||
        raw.contains('TimeoutException')) {
      msg = 'Network error. Please check your connection and try again.';
    } else {
      msg = raw.replaceFirst('Exception: ', '');
    }
    setState(() {
      _stage = _Stage.idle;
      _error = msg;
    });
  }

  Future<void> _contactSupport() async {
    try {
      await launchUrl(
        Uri.parse(
            'mailto:info@excobalab.com?subject=${Uri.encodeComponent(cfg.appName)}%20Premium%20Restore'),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final busy = _stage != _Stage.idle && _stage != _Stage.done;
    return Container(
      padding: EdgeInsets.fromLTRB(
          28, 26, 28, 34 + MediaQuery.of(context).viewInsets.bottom),
      decoration: const BoxDecoration(
        color: exlPanel,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(top: BorderSide(color: exlCyanDim)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 42,
            height: 4,
            decoration: BoxDecoration(
              color: exlCyanDim,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 22),
          const ExBadge(size: 54),
          const SizedBox(height: 16),
          Text(
            _stage == _Stage.done
                ? 'PREMIUM UNLOCKED!'
                : '${cfg.appName.toUpperCase()} PREMIUM',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: exlCyan,
              fontSize: 17,
              fontWeight: FontWeight.w700,
              letterSpacing: 4,
            ),
          ),
          const SizedBox(height: 10),
          if (_stage == _Stage.done) ...[
            const Text(
              'Thank you for supporting EXCOBALAB!',
              textAlign: TextAlign.center,
              style: TextStyle(color: exlIce, fontSize: 15, height: 1.5),
            ),
            const SizedBox(height: 22),
            GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: exlCyan,
                ),
                child: const Text(
                  'CONTINUE',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: exlBgBottom,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
              ),
            ),
          ] else ...[
            Text(
              cfg.unlockLine,
              textAlign: TextAlign.center,
              style: const TextStyle(color: exlIce, fontSize: 15),
            ),
            const SizedBox(height: 6),
            Text(
              '\$${exlPriceUsd.toStringAsFixed(2)} · one-time · paid in SOL',
              style: const TextStyle(
                color: exlCyan,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 22),
            GestureDetector(
              onTap: busy ? null : _buyMwa,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: busy ? Colors.transparent : exlCyan,
                  border: Border.all(color: exlCyan),
                ),
                child: busy
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: exlCyan,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            _stageText,
                            style: const TextStyle(
                              color: exlCyan,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1,
                            ),
                          ),
                        ],
                      )
                    : const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'PAY WITH MWA WALLET',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: exlBgBottom,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 2,
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            'Seeker Wallet · Jupiter · Solflare · Backpack',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: exlBgBottom,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              letterSpacing: .3,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: busy ? null : _buyPhantom,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: exlCyanDim),
                ),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'PAY WITH PHANTOM',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: exlCyan,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      'in-app approval · encrypted link',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: exlCyanDim,
                        fontSize: 10,
                        letterSpacing: .3,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Color(0xFFFF8A8A), fontSize: 12, height: 1.4),
              ),
            ],
            const SizedBox(height: 14),
            GestureDetector(
              onTap: _contactSupport,
              child: const Text(
                'Already purchased on another install? Contact support.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: exlCyanDim,
                  fontSize: 11,
                  decoration: TextDecoration.underline,
                  decorationColor: exlCyanDim,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// EX marka rozeti (EXCOBALAB standardı)

class ExBadge extends StatelessWidget {
  final double size;
  const ExBadge({super.key, this.size = 24});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF0B1B38),
        border: Border.all(color: exlCyan, width: size * 0.06),
        boxShadow: [
          BoxShadow(color: exlCyan.withOpacity(0.25), blurRadius: size * 0.3),
        ],
      ),
      child: Text(
        'EX',
        style: TextStyle(
          color: exlIce,
          fontSize: size * 0.4,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
    );
  }
}

// Alt bilgi: EX rozeti + excobalab.com linki (her uygulamanın altına konur)

class ExlSiteLink extends StatelessWidget {
  const ExlSiteLink({super.key});

  Future<void> _open() async {
    try {
      await launchUrl(Uri.parse(exlSiteUrl),
          mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _open,
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExBadge(size: 18),
            SizedBox(width: 8),
            Text(
              'EXCOBALAB.COM',
              style: TextStyle(
                color: exlCyanDim,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
