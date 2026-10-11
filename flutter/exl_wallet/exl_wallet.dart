// ============================================================================
// EXL WALLET v2 — EXCOBALAB turnuva ödeme + imza modülü (çift raylı)
//   v2 (Eyl 2026, CLOCK IN): SPL token (SKR) ödeme rayı + showExlSignSheet (cüzdan imzalı skor)
// Card Deck Ex'te onaylanan _ortak/exl_premium.dart deseninin turnuva sürümü.
//   Ray 1: MWA 2.0 native köprü ("exl/mwa" MethodChannel — MainActivity.kt)
//          Seeker Wallet, Jupiter, Solflare, Backpack... (imza Uint8List döner)
//   Ray 2: Phantom şifreli deeplink (connect + signTransaction; app RPC ile gönderir)
//
// FARK (premium modülünden): tutar sabittir (turnuva ücreti), memo = tournamentId,
// başarıda premium açmak yerine PayResult(txSig, wallet) DÖNDÜRÜR (Navigator.pop).
// MWA rayında ödeyen cüzdan istemcide bilinmez -> wallet=null (sunucu /join türetir);
// Phantom rayında connect'ten bilinir -> wallet doldurulur.
//
// GEREKEN pubspec: solana ^0.31.2, http yok, shared_preferences (main.dart için),
//   url_launcher, app_links ^6.3.2, pinenacl ^0.6.0
// GEREKEN manifest: INTERNET izni + <data android:scheme="<phantomScheme>"/> intent-filter
// GEREKEN native: MainActivity.kt (MWA köprüsü, payPremium)
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pinenacl/x25519.dart' as nacl;
import 'package:solana/base58.dart';
import 'package:solana/encoder.dart';
import 'package:solana/solana.dart';
import 'package:url_launcher/url_launcher.dart';

// ---- EXCOBALAB sabitleri ----
const String exlSiteUrl = 'https://excobalab.com';
const String exlWeb3Url = 'https://web3.excobalab.com'; // v1.3: footer link → EXL Tourney web3 hub (proof, deck, rooms)
const String exlRpcUrl = 'https://solana-rpc.publicnode.com';
const String exlWsUrl = 'wss://solana-rpc.publicnode.com';
const MethodChannel exlMwa = MethodChannel('exl/mwa');

// ---- Seeker paleti (EXCOBALAB standardı) ----
const Color exlBgTop = Color(0xFF0E2A52);
const Color exlBgBottom = Color(0xFF060D1A);
const Color exlCyan = Color(0xFF3EE0F0);
const Color exlCyanDim = Color(0x663EE0F0);
const Color exlIce = Color(0xFFE8F4FF);
const Color exlPanel = Color(0xFF0C1C38);

// ---- SPL token tanımı (null = SOL) ----
class ExlToken {
  final String mint;            // ör. SKR mint
  final int decimals;           // SKR: 6
  final String symbol;          // 'SKR'
  final String destTokenAccount; // alıcının (havuzun) ATA'sı — sunucu /t'den verir
  const ExlToken({required this.mint, required this.decimals, required this.symbol, required this.destTokenAccount});
}

// ---- Ödeme sonucu ----
class PayResult {
  final String txSig;
  final String? wallet; // MWA rayında null; sunucu /join'de türetir
  final String rail;    // 'mwa' | 'phantom'
  const PayResult(this.txSig, [this.wallet, this.rail = 'mwa']);
}

// ---- İmza sonucu ----
class SignResult {
  final String signature; // base58, 64 bayt ed25519
  final String wallet;    // imzalayan cüzdan (base58)
  const SignResult(this.signature, this.wallet);
}

Future<PayResult?> showExlPaySheet(
  BuildContext context, {
  required String appName,
  required String phantomScheme,
  required int lamports,
  required String recipient,
  required String memo,
  required String title,
  required String subtitle,
  ExlToken? token, // null = SOL; dolu = SPL token (SKR) — lamports = token base units
}) {
  return showModalBottomSheet<PayResult>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    isDismissible: true,
    builder: (_) => _ExlPaySheet(
      appName: appName,
      phantomScheme: phantomScheme,
      lamports: lamports,
      recipient: recipient,
      memo: memo,
      title: title,
      subtitle: subtitle,
      token: token,
    ),
  );
}

/// Cüzdan imzalı skor: `message` (ör. exl:score:<token>:<score>:<durationMs>) cüzdana
/// imzalatılır. Kullanıcı atlayabilir (null döner) — skor yine gönderilir, rozet alınmaz.
Future<SignResult?> showExlSignSheet(
  BuildContext context, {
  required String appName,
  required String phantomScheme,
  required String message,
  required int score,
  String preferRail = 'mwa',
  String? title,      // v1.3: reuse the sheet for non-score signatures (e.g. "SIGN TO TAKE A SEAT")
  String? body,
  String? skipLabel,  // null → default "SUBMIT WITHOUT SIGNATURE"; '' → no skip link (signature required)
}) {
  return showModalBottomSheet<SignResult>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    isDismissible: true,
    builder: (_) => _ExlSignSheet(
        appName: appName, phantomScheme: phantomScheme, message: message, score: score, preferRail: preferRail,
        title: title, body: body, skipLabel: skipLabel),
  );
}

// ---------------------------------------------------------------------------

enum _Stage { idle, wallet, approve, confirm }

class _ExlPaySheet extends StatefulWidget {
  final String appName, phantomScheme, recipient, memo, title, subtitle;
  final int lamports;
  final ExlToken? token;
  const _ExlPaySheet({
    required this.appName,
    required this.phantomScheme,
    required this.recipient,
    required this.memo,
    required this.title,
    required this.subtitle,
    required this.lamports,
    this.token,
  });

  @override
  State<_ExlPaySheet> createState() => _ExlPaySheetState();
}

class _ExlPaySheetState extends State<_ExlPaySheet> {
  _Stage _stage = _Stage.idle;
  String? _error;

  late final nacl.PrivateKey _phSecret;
  late final Uint8List _phPub;
  nacl.Box? _phBox;
  String? _phSession;
  String? _phWallet;
  bool _phPending = false;
  StreamSubscription<Uri>? _phSub;

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

  String get _amountText {
    final t = widget.token;
    if (t != null) {
      final v = widget.lamports / math.pow(10, t.decimals);
      return '${v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(2)} ${t.symbol}';
    }
    return '${(widget.lamports / lamportsPerSol).toStringAsFixed(widget.lamports >= lamportsPerSol ? 2 : 4)} SOL';
  }

  String get _stageText {
    switch (_stage) {
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

  SolanaClient _rpc() => SolanaClient(
        rpcUrl: Uri.parse(exlRpcUrl),
        websocketUrl: Uri.parse(exlWsUrl),
      );

  Future<Uint8List> _buildUnsignedTx({
    required Ed25519HDPublicKey payer,
    required String blockhash,
  }) async {
    final merchant = Ed25519HDPublicKey.fromBase58(widget.recipient);
    final t = widget.token;
    final Instruction transferIx;
    if (t == null) {
      transferIx = SystemInstruction.transfer(
        fundingAccount: payer,
        recipientAccount: merchant,
        lamports: widget.lamports,
      );
    } else {
      // SPL TransferChecked (payer'ın ATA'sı → havuz ATA'sı)
      final mint = Ed25519HDPublicKey.fromBase58(t.mint);
      final sourceAta = await findAssociatedTokenAddress(owner: payer, mint: mint);
      transferIx = TokenInstruction.transferChecked(
        amount: widget.lamports,
        decimals: t.decimals,
        source: sourceAta,
        mint: mint,
        destination: Ed25519HDPublicKey.fromBase58(t.destTokenAccount),
        owner: payer,
      );
    }
    final message = Message(instructions: [
      transferIx,
      MemoInstruction(signers: [payer], memo: widget.memo),
    ]);
    final compiled = message.compile(recentBlockhash: blockhash, feePayer: payer);
    final unsignedTx = SignedTx(
      compiledMessage: compiled,
      signatures: [Signature(List.filled(64, 0), publicKey: payer)],
    );
    return Uint8List.fromList(unsignedTx.toByteArray().toList());
  }

  // ---------------- RAY 1: MWA ----------------

  Future<void> _payMwa() async {
    setState(() {
      _stage = _Stage.approve;
      _error = null;
    });
    var step = 'blockhash';
    try {
      final rpc = _rpc();
      final blockhash = await _withNetRetry(
          () => rpc.rpcClient.getLatestBlockhash().then((it) => it.value.blockhash));

      step = 'wallet';
      final t = widget.token;
      final sigBytes = await exlMwa.invokeMethod<Uint8List>('payPremium', {
        'recipient': widget.recipient,
        'lamports': widget.lamports,
        'memo': widget.memo,
        'blockhash': blockhash,
        if (t != null) 'mint': t.mint,
        if (t != null) 'decimals': t.decimals,
        if (t != null) 'destTokenAccount': t.destTokenAccount,
      });
      if (sigBytes == null) throw Exception('Payment was not approved');
      final sig = base58encode(sigBytes.toList());

      step = 'confirm';
      await _confirmAndFinish(rpc, sig, null, 'mwa'); // wallet: sunucu türetir
    } catch (e) {
      _fail(e, step);
    }
  }

  // ---------------- RAY 2: Phantom ----------------

  Uint8List _phNonce() {
    final r = math.Random.secure();
    return Uint8List.fromList(List.generate(24, (_) => r.nextInt(256)));
  }

  Future<void> _payPhantom() async {
    setState(() {
      _stage = _Stage.wallet;
      _error = null;
      _phPending = true;
    });
    try {
      if (_phSession == null) {
        final uri = Uri.https('phantom.app', '/ul/v1/connect', {
          'app_url': exlSiteUrl,
          'dapp_encryption_public_key': base58encode(_phPub.toList()),
          'redirect_link': '${widget.phantomScheme}://phconnect',
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
        _phPending = false;
        _error = p['errorCode'] == '4001'
            ? 'Payment cancelled. You can try again anytime.'
            : 'Phantom error: ${p['errorMessage'] ?? p['errorCode']}';
      });
      return;
    }
    try {
      switch (uri.host.toLowerCase()) {
        case 'phconnect':
          final phantomPub = base58decode(p['phantom_encryption_public_key']!);
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
          if (_phPending) await _phantomSign();
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
    final blockhash = await _withNetRetry(
        () => rpc.rpcClient.getLatestBlockhash().then((it) => it.value.blockhash));
    final payer = Ed25519HDPublicKey.fromBase58(_phWallet!);
    final txBytes = await _buildUnsignedTx(payer: payer, blockhash: blockhash);
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
      'redirect_link': '${widget.phantomScheme}://phsign',
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
    final sig = await _withNetRetry(
        () => rpc.rpcClient.sendTransaction(base64Encode(base58decode(signedB58))));
    _phPending = false;
    await _confirmAndFinish(rpc, sig, _phWallet, 'phantom');
  }

  // ---------------- Ortak son: zincir onayı + PayResult döndür ----------------

  Future<void> _confirmAndFinish(SolanaClient rpc, String sig, String? wallet, String rail) async {
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
        if (cs.contains('confirmed') || cs.contains('finalized')) confirmed = true;
      }
    }
    if (!confirmed) {
      throw Exception(
          'Confirmation timed out. If funds left your wallet, contact info@excobalab.com with tx: $sig');
    }
    if (!mounted) return;
    Navigator.of(context).pop(PayResult(sig, wallet, rail));
  }

  void _fail(Object e, String step) {
    if (!mounted) return;
    final raw = e is PlatformException
        ? '${e.code}: ${e.message ?? ''}'
        : e.toString();
    final String msg;
    if (raw.contains('NOWALLET')) {
      msg = 'No compatible wallet found. Install Seeker Wallet, Jupiter or Solflare — or use Phantom.';
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
      _phPending = false;
      _error = msg;
    });
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final busy = _stage != _Stage.idle;
    return Container(
      padding: EdgeInsets.fromLTRB(
          28, 22, 28, 30 + MediaQuery.of(context).viewInsets.bottom),
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
                color: exlCyanDim, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(height: 20),
          const ExBadge(size: 48),
          const SizedBox(height: 14),
          Text(widget.title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: exlCyan,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2)),
          const SizedBox(height: 8),
          Text(widget.subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: exlIce, fontSize: 13.5, height: 1.5)),
          const SizedBox(height: 10),
          Text('$_amountText · entry fee',
              style: const TextStyle(
                  color: exlCyan,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1)),
          const SizedBox(height: 20),
          // Ray 1: MWA
          GestureDetector(
            onTap: busy ? null : _payMwa,
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
                                strokeWidth: 2, color: exlCyan)),
                        const SizedBox(width: 12),
                        Text(_stageText,
                            style: const TextStyle(
                                color: exlCyan,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 1)),
                      ],
                    )
                  : const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('PAY WITH MWA WALLET',
                            style: TextStyle(
                                color: exlBgBottom,
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 2)),
                        SizedBox(height: 3),
                        Text('Seeker Wallet · Jupiter · Solflare · Backpack',
                            style: TextStyle(
                                color: exlBgBottom,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                letterSpacing: .3)),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 10),
          // Ray 2: Phantom
          GestureDetector(
            onTap: busy ? null : _payPhantom,
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
                  Text('PAY WITH PHANTOM',
                      style: TextStyle(
                          color: exlCyan,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5)),
                  SizedBox(height: 3),
                  Text('in-app approval · encrypted link',
                      style: TextStyle(
                          color: exlCyanDim, fontSize: 10, letterSpacing: .3)),
                ],
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 14),
            Text(_error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: Color(0xFFFF8A8A), fontSize: 12, height: 1.4)),
          ],
          const SizedBox(height: 12),
          GestureDetector(
            onTap: busy ? null : () => Navigator.of(context).pop(),
            child: const Text('CANCEL',
                style: TextStyle(
                    color: exlCyanDim, fontSize: 12, letterSpacing: 1.5)),
          ),
          const SizedBox(height: 6),
          const Text('Entry fee goes to the on-chain prize pool.',
              textAlign: TextAlign.center,
              style: TextStyle(color: exlCyanDim, fontSize: 10.5, height: 1.5)),
        ],
      ),
    );
  }
}


// ---------------------------------------------------------------------------
// İMZA SAYFASI — cüzdan imzalı skor (MWA signMessages / Phantom signMessage)

class _ExlSignSheet extends StatefulWidget {
  final String appName, phantomScheme, message, preferRail;
  final int score;
  final String? title, body, skipLabel;
  const _ExlSignSheet(
      {required this.appName, required this.phantomScheme, required this.message, required this.score, required this.preferRail,
       this.title, this.body, this.skipLabel});
  @override
  State<_ExlSignSheet> createState() => _ExlSignSheetState();
}

class _ExlSignSheetState extends State<_ExlSignSheet> {
  bool _busy = false;
  String? _error;
  late final nacl.PrivateKey _phSecret;
  late final Uint8List _phPub;
  nacl.Box? _phBox;
  String? _phSession, _phWallet;
  StreamSubscription<Uri>? _phSub;

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

  Future<void> _signMwa() async {
    setState(() { _busy = true; _error = null; });
    try {
      final r = await exlMwa.invokeMethod<Map>('signScore', {'message': widget.message});
      if (r == null) throw Exception('Signing was not approved');
      if (!mounted) return;
      Navigator.of(context).pop(SignResult(r['signature'] as String, r['wallet'] as String));
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _signPhantom() async {
    setState(() { _busy = true; _error = null; });
    try {
      final uri = Uri.https('phantom.app', '/ul/v1/connect', {
        'app_url': exlSiteUrl,
        'dapp_encryption_public_key': base58encode(_phPub.toList()),
        'redirect_link': '${widget.phantomScheme}://phsignconnect',
        'cluster': 'mainnet-beta',
      });
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) throw Exception('Phantom is not installed on this device');
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _onPhantomLink(Uri uri) async {
    final p = uri.queryParameters;
    if (p.containsKey('errorCode')) {
      _fail(Exception(p['errorCode'] == '4001' ? 'cancelled' : 'Phantom error: ${p['errorMessage'] ?? p['errorCode']}'));
      return;
    }
    try {
      switch (uri.host.toLowerCase()) {
        case 'phsignconnect':
          final phantomPub = base58decode(p['phantom_encryption_public_key']!);
          _phBox = nacl.Box(myPrivateKey: _phSecret, theirPublicKey: nacl.PublicKey(Uint8List.fromList(phantomPub)));
          final plain = _phBox!.decrypt(nacl.EncryptedMessage(
              nonce: Uint8List.fromList(base58decode(p['nonce']!)), cipherText: Uint8List.fromList(base58decode(p['data']!))));
          final json = jsonDecode(utf8.decode(plain)) as Map;
          _phSession = json['session'] as String;
          _phWallet = json['public_key'] as String;
          // signMessage
          final payload = utf8.encode(jsonEncode({
            'message': base58encode(utf8.encode(widget.message)),
            'session': _phSession,
            'display': 'utf8',
          }));
          final r = math.Random.secure();
          final nonce = Uint8List.fromList(List.generate(24, (_) => r.nextInt(256)));
          final sealed = _phBox!.encrypt(Uint8List.fromList(payload), nonce: nonce);
          final u = Uri.https('phantom.app', '/ul/v1/signMessage', {
            'dapp_encryption_public_key': base58encode(_phPub.toList()),
            'nonce': base58encode(nonce.toList()),
            'redirect_link': '${widget.phantomScheme}://phsigned',
            'payload': base58encode(Uint8List.fromList(sealed.cipherText).toList()),
          });
          await launchUrl(u, mode: LaunchMode.externalApplication);
          break;
        case 'phsigned':
          final plain = _phBox!.decrypt(nacl.EncryptedMessage(
              nonce: Uint8List.fromList(base58decode(p['nonce']!)), cipherText: Uint8List.fromList(base58decode(p['data']!))));
          final json = jsonDecode(utf8.decode(plain)) as Map;
          final sig = json['signature'] as String; // base58
          if (!mounted) return;
          Navigator.of(context).pop(SignResult(sig, _phWallet!));
          break;
      }
    } catch (e) {
      _fail(e);
    }
  }

  void _fail(Object e) {
    if (!mounted) return;
    final raw = e is PlatformException ? '${e.code}: ${e.message ?? ''}' : e.toString();
    setState(() {
      _busy = false;
      _error = raw.contains('NOWALLET')
          ? 'No compatible wallet found. Use Phantom or skip.'
          : (raw.contains('cancel') || raw.contains('declined') || raw.contains('not approved'))
              ? 'Signing cancelled. You can still submit without a badge.'
              : raw.replaceFirst('Exception: ', '');
    });
  }

  Widget _btn(String title, String sub, bool filled, VoidCallback? onTap) => GestureDetector(
        onTap: _busy ? null : onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: filled && !_busy ? exlCyan : Colors.transparent,
            border: Border.all(color: filled ? exlCyan : exlCyanDim),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(title,
                style: TextStyle(
                    color: filled && !_busy ? exlBgBottom : exlCyan, fontSize: 13, fontWeight: FontWeight.w800, letterSpacing: 2)),
            const SizedBox(height: 3),
            Text(sub, style: TextStyle(color: filled && !_busy ? exlBgBottom : exlCyanDim, fontSize: 10)),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final mwaFirst = widget.preferRail != 'phantom';
    final mwa = _btn('SIGN WITH MWA WALLET', 'Seeker Wallet · Jupiter · Solflare · Backpack', mwaFirst, _signMwa);
    final ph = _btn('SIGN WITH PHANTOM', 'in-app approval · encrypted link', !mwaFirst, _signPhantom);
    return Container(
      padding: EdgeInsets.fromLTRB(28, 22, 28, 30 + MediaQuery.of(context).viewInsets.bottom),
      decoration: const BoxDecoration(
        color: exlPanel,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(top: BorderSide(color: exlCyanDim)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 42, height: 4, decoration: BoxDecoration(color: exlCyanDim, borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 20),
        const ExBadge(size: 48),
        const SizedBox(height: 14),
        Text(widget.title ?? 'SIGN YOUR SCORE',
            style: const TextStyle(color: exlCyan, fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 2)),
        const SizedBox(height: 8),
        Text(widget.body ?? ('Score ${widget.score} — your wallet signs it so nobody can submit on your behalf. '
            'Verified scores get a ✓ badge on the leaderboard and in the tournament proof.'),
            textAlign: TextAlign.center, style: const TextStyle(color: exlIce, fontSize: 13, height: 1.5)),
        const SizedBox(height: 18),
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: exlCyan)),
              SizedBox(width: 12),
              Text('Approve in your wallet…', style: TextStyle(color: exlCyan, fontSize: 13, letterSpacing: 1)),
            ]),
          ),
        mwaFirst ? mwa : ph,
        const SizedBox(height: 10),
        mwaFirst ? ph : mwa,
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFFF8A8A), fontSize: 12, height: 1.4)),
        ],
        const SizedBox(height: 14),
        if (widget.skipLabel != '')
          GestureDetector(
            onTap: _busy ? null : () => Navigator.of(context).pop(),
            child: Text(widget.skipLabel ?? 'SUBMIT WITHOUT SIGNATURE', style: const TextStyle(color: exlCyanDim, fontSize: 12, letterSpacing: 1.5)),
          ),
      ]),
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
      child: Text('EX',
          style: TextStyle(
              color: exlIce,
              fontSize: size * 0.4,
              fontWeight: FontWeight.w800,
              height: 1)),
    );
  }
}

// Alt bilgi: EX rozeti + excobalab.com linki

class ExlSiteLink extends StatelessWidget {
  const ExlSiteLink({super.key});

  Future<void> _open() async {
    try {
      await launchUrl(Uri.parse(exlWeb3Url), mode: LaunchMode.externalApplication);
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
            Text('WEB3.EXCOBALAB.COM',
                style: TextStyle(
                    fontFamily: 'Paytone',
                    color: exlCyanDim,
                    fontSize: 11,
                    letterSpacing: 2.5)),
          ],
        ),
      ),
    );
  }
}
