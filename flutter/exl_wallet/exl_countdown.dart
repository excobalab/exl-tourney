// EXL Tourney — v1.3 · "TAP TO START → 3-2-1-GO" overlay for tournament / duel runs.
// v1.3 fix: two AnimationControllers need TickerProviderStateMixin (Single… asserted in debug → red screen on PLAY).
// Shown when a paid run screen opens. The player taps when ready; the countdown
// runs; on GO the overlay closes and the game starts by itself (caller starts it).
// Returns true when the countdown completed; false if the player backed out before tapping.
// Apache-2.0 — github.com/excobalab/exl-tourney
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<bool> showExlCountdown(BuildContext context) async {
  final r = await Navigator.of(context).push<bool>(PageRouteBuilder(
    opaque: false,
    barrierDismissible: false,
    transitionDuration: const Duration(milliseconds: 120),
    reverseTransitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (_, __, ___) => const _ExlCountdown(),
    transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
  ));
  return r == true;
}

class _ExlCountdown extends StatefulWidget {
  const _ExlCountdown();
  @override
  State<_ExlCountdown> createState() => _ExlCountdownState();
}

class _ExlCountdownState extends State<_ExlCountdown> with TickerProviderStateMixin {
  bool _armed = false; // false = waiting for the player's tap
  int _n = 3;
  Timer? _t;
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
  late final AnimationController _breathe =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);

  void _arm() {
    if (_armed) return;
    HapticFeedback.mediumImpact();
    setState(() => _armed = true);
    _pulse.forward(from: 0);
    _t = Timer.periodic(const Duration(milliseconds: 800), (_) {
      if (!mounted) return;
      if (_n <= 0) {
        _t?.cancel();
        if (mounted) Navigator.of(context).pop(true);
        return;
      }
      setState(() => _n--);
      _pulse.forward(from: 0);
      HapticFeedback.lightImpact();
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    _pulse.dispose();
    _breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = _n > 0 ? '$_n' : 'GO';
    return PopScope(
      canPop: !_armed, // back is allowed until the player taps; once the countdown runs it is locked
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _arm,
        child: Material(
          color: const Color(0xD907101F),
          child: Center(
            child: !_armed
                ? Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('READY?',
                        style: TextStyle(color: Color(0xFF3CE0FF), fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: 5)),
                    const SizedBox(height: 26),
                    FadeTransition(
                      opacity: Tween(begin: 0.55, end: 1.0).animate(_breathe),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 16),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFF3CE0FF), width: 2),
                        ),
                        child: const Text('TAP TO START',
                            style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 3)),
                      ),
                    ),
                    const SizedBox(height: 22),
                    const Text('3-2-1 then the run begins on its own',
                        style: TextStyle(color: Color(0xFF8FA3BF), fontSize: 13, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    const Text('Same course for everyone · your attempt is used on GO · score signed by your wallet',
                        textAlign: TextAlign.center, style: TextStyle(color: Color(0xFF5E7190), fontSize: 11)),
                  ])
                : Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('GET READY',
                        style: TextStyle(color: Color(0xFF3CE0FF), fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 4)),
                    const SizedBox(height: 18),
                    ScaleTransition(
                      scale: Tween(begin: 1.35, end: 1.0).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeOutBack)),
                      child: Text(label,
                          style: TextStyle(
                              color: _n > 0 ? Colors.white : const Color(0xFF7FE0A8),
                              fontSize: _n > 0 ? 120 : 84,
                              fontWeight: FontWeight.w900,
                              height: 1)),
                    ),
                  ]),
          ),
        ),
      ),
    );
  }
}
