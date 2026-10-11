// ============================================================================
// EXL TOURNEY — shared UI kit (v1.3)
// Chunky 3D look inspired by the studio's "Ordular Savaşı" menus, in the EXL
// palette: cyan glass (#3EE0F0), gold (#FFC94D), deep navy outline (#07101F).
// Everything degrades gracefully: when an image asset (assets/ui/*.png) is
// missing, a code-drawn fallback (embossed text / Material icon) is used, so
// the games build before the artwork arrives.
// Identical file in every EXL game.  Apache-2.0 — github.com/excobalab/exl-tourney
// ============================================================================
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'exl_wallet.dart';

const Color exlGoldBright = Color(0xFFFFC94D);
const Color exlGoldDeep = Color(0xFFB8740A);
const Color exlInk = Color(0xFF07101F); // thick outline
const Color exlGreenGo = Color(0xFF55E08A);
const Color exlRed = Color(0xFFFF6B6B);
const String exlFont = 'Paytone'; // assets/fonts/PaytoneOne-Regular.ttf (OFL)

/// Paytone text style helper (single weight — never fake-bold it).
TextStyle exlT(double size, {Color color = exlIce, double spacing = 0.5, double height = 1.0}) =>
    TextStyle(fontFamily: exlFont, fontSize: size, color: color, letterSpacing: spacing, height: height, fontWeight: FontWeight.normal);

/// Body text (system font, bold-ish) for descriptions.
TextStyle exlBody(double size, {Color color = exlIce, double height = 1.35}) =>
    TextStyle(fontSize: size, color: color, fontWeight: FontWeight.w700, height: height);

// ---------------------------------------------------------------------------
// ExlUiImage — assets/ui/<name>.png with a graceful fallback
// ---------------------------------------------------------------------------
class ExlUiImage extends StatelessWidget {
  final String name; // e.g. 'ikon_duels'
  final double? width, height;
  final Widget fallback;
  const ExlUiImage(this.name, {super.key, this.width, this.height, required this.fallback});

  @override
  Widget build(BuildContext context) {
    return Image.asset('assets/ui/$name.png', width: width, height: height, fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => SizedBox(width: width, height: height, child: FittedBox(fit: BoxFit.contain, child: fallback)));
  }
}

/// Icon with the EXL 3D treatment (dark outline + drop) — used as fallback for image icons.
class ExlIcon3D extends StatelessWidget {
  final IconData icon;
  final double size;
  final Color color;
  const ExlIcon3D(this.icon, {super.key, this.size = 28, this.color = exlCyan});
  @override
  Widget build(BuildContext context) {
    final k = math.max(1.0, size * 0.06);
    return Icon(icon, size: size, color: color, shadows: [
      for (final o in [Offset(k, 0), Offset(-k, 0), Offset(0, k), Offset(0, -k), Offset(k * .7, k * .7), Offset(-k * .7, -k * .7), Offset(k * .7, -k * .7), Offset(-k * .7, k * .7)])
        Shadow(color: exlInk, offset: o),
      Shadow(color: const Color(0x88000000), offset: Offset(0, k * 2.2)),
    ]);
  }
}

// ---------------------------------------------------------------------------
// ExlEmboss — chunky 3D embossed text (outline + extruded depth + glossy face)
// ---------------------------------------------------------------------------
class ExlEmboss extends StatelessWidget {
  final String text;
  final double size;
  final List<Color> face; // top → bottom gradient of the letter face
  final Color depth; // extrusion colour
  final double spacing;
  final TextAlign align;
  const ExlEmboss(this.text, {super.key, this.size = 40, this.face = const [Color(0xFFFFFFFF), Color(0xFF3EE0F0), Color(0xFF1AA6C0)],
      this.depth = exlGoldDeep, this.spacing = 2, this.align = TextAlign.center});

  /// Gold variant (titles like "WEEK 3", prize amounts).
  const ExlEmboss.gold(this.text, {super.key, this.size = 40, this.spacing = 2, this.align = TextAlign.center})
      : face = const [Color(0xFFFFF4C2), Color(0xFFFFC94D), Color(0xFFE08E12)], depth = const Color(0xFF7A4A05);

  @override
  Widget build(BuildContext context) {
    final k = math.max(1.5, size * 0.07); // outline thickness
    final d = math.max(2.0, size * 0.10); // depth
    final base = TextStyle(fontFamily: exlFont, fontSize: size, letterSpacing: spacing, height: 1.0, fontWeight: FontWeight.normal);
    Widget t(TextStyle s, [Offset off = Offset.zero]) => Transform.translate(offset: off, child: Text(text, textAlign: align, style: s));
    return Stack(alignment: Alignment.center, children: [
      // soft drop shadow
      t(base.copyWith(color: const Color(0x66000000)), Offset(0, d + k + 2)),
      // extrusion: outline + depth colour stacked downwards
      for (double y = d; y > 0; y -= 1)
        t(base.copyWith(foreground: Paint()..style = PaintingStyle.stroke..strokeWidth = k * 2..color = exlInk..strokeJoin = StrokeJoin.round), Offset(0, y)),
      for (double y = d; y > 0; y -= 1) t(base.copyWith(color: depth), Offset(0, y)),
      // face outline
      t(base.copyWith(foreground: Paint()..style = PaintingStyle.stroke..strokeWidth = k * 2..color = exlInk..strokeJoin = StrokeJoin.round)),
      // face gradient
      ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (r) => LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: face, stops: const [0.0, 0.55, 1.0]).createShader(r),
        child: t(base.copyWith(color: Colors.white)),
      ),
      // glass highlight on the upper half
      ClipRect(
        clipper: _TopHalf(),
        child: t(base.copyWith(color: const Color(0x55FFFFFF))),
      ),
    ]);
  }
}

class _TopHalf extends CustomClipper<Rect> {
  @override
  Rect getClip(Size s) => Rect.fromLTWH(0, 0, s.width, s.height * 0.42);
  @override
  bool shouldReclip(covariant CustomClipper<Rect> old) => false;
}

/// Game title: assets/ui/baslik.png if present, otherwise the embossed text.
class ExlGameTitle extends StatelessWidget {
  final String text;
  final double width;
  const ExlGameTitle({super.key, required this.text, this.width = 300});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Image.asset('assets/ui/baslik.png', fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => Column(mainAxisSize: MainAxisSize.min, children: [
                ExlEmboss(text.split(' ').first, size: 22, spacing: 6),
                const SizedBox(height: 2),
                ExlEmboss(text.split(' ').skip(1).join(' '), size: 46, spacing: 4),
              ])),
    );
  }
}

// ---------------------------------------------------------------------------
// ExlButton3D — glossy 3D button with a dark bottom lip
// ---------------------------------------------------------------------------
enum ExlTone { gold, cyan, green, ghost, danger, orange }

class ExlButton3D extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;
  final ExlTone tone;
  final double height;
  final double fontSize;
  final Widget? leading; // icon / image
  final bool expand;
  final String? sub; // small line under the label
  const ExlButton3D(this.label, {super.key, required this.onTap, this.tone = ExlTone.gold, this.height = 52, this.fontSize = 17, this.leading, this.expand = true, this.sub});

  @override
  State<ExlButton3D> createState() => _ExlButton3DState();
}

class _ExlButton3DState extends State<ExlButton3D> {
  bool _down = false;

  List<Color> get _face {
    switch (widget.tone) {
      case ExlTone.gold: return const [Color(0xFFFFF0B8), Color(0xFFFFC94D), Color(0xFFE39A14)];
      case ExlTone.cyan: return const [Color(0xFFBFF6FF), Color(0xFF3EE0F0), Color(0xFF17A3BD)];
      case ExlTone.green: return const [Color(0xFFC9FFE0), Color(0xFF55E08A), Color(0xFF1E9E55)];
      case ExlTone.danger: return const [Color(0xFFFFD0D0), Color(0xFFFF6B6B), Color(0xFFB83A3A)];
      case ExlTone.ghost: return const [Color(0xFF1B3560), Color(0xFF12264A), Color(0xFF0C1C38)];
      case ExlTone.orange: return const [Color(0xFFFFE0B8), Color(0xFFFFA24A), Color(0xFFD9641A)];
    }
  }

  Color get _lip {
    switch (widget.tone) {
      case ExlTone.gold: return const Color(0xFF8A5406);
      case ExlTone.cyan: return const Color(0xFF0E6A7C);
      case ExlTone.green: return const Color(0xFF136B3A);
      case ExlTone.danger: return const Color(0xFF7A2222);
      case ExlTone.ghost: return const Color(0xFF07101F);
      case ExlTone.orange: return const Color(0xFF8A3A08);
    }
  }

  Color get _text => widget.tone == ExlTone.ghost ? exlCyan : exlInk;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final lip = 5.0;
    final pressed = _down && enabled;
    final body = AnimatedContainer(
      duration: const Duration(milliseconds: 70),
      height: widget.height,
      margin: EdgeInsets.only(top: pressed ? lip : 0, bottom: pressed ? 0 : lip),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.height * 0.3),
        border: Border.all(color: exlInk, width: 2.2),
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: enabled ? _face : _face.map((c) => Color.lerp(c, const Color(0xFF3A4A66), 0.6)!).toList(), stops: const [0.0, 0.55, 1.0]),
        boxShadow: pressed ? null : [BoxShadow(color: _lip, offset: Offset(0, lip)), BoxShadow(color: exlInk, offset: Offset(0, lip + 2))],
      ),
      child: Stack(children: [
        // glass highlight
        Positioned(left: 6, right: 6, top: 3, height: widget.height * 0.36,
            child: DecoratedBox(decoration: BoxDecoration(borderRadius: BorderRadius.circular(widget.height * 0.25),
                gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x80FFFFFF), Color(0x10FFFFFF)])))),
        Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: widget.leading != null && widget.expand ? 14 : 0),
            child: Row(mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
                mainAxisAlignment: widget.leading != null && widget.expand ? MainAxisAlignment.start : MainAxisAlignment.center, children: [
            if (widget.leading != null) ...[widget.leading!, const SizedBox(width: 12)],
            Flexible(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: widget.leading != null && widget.expand ? CrossAxisAlignment.start : CrossAxisAlignment.center, children: [
                Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: widget.leading != null && widget.expand ? TextAlign.left : TextAlign.center,
                    style: TextStyle(fontFamily: exlFont, fontSize: widget.fontSize, color: enabled ? _text : (widget.tone == ExlTone.ghost ? exlCyanDim : const Color(0xFF2A3A55)), letterSpacing: 1,
                        shadows: widget.tone == ExlTone.ghost ? null : const [Shadow(color: Color(0x66FFFFFF), offset: Offset(0, 1))])),
                if (widget.sub != null) Text(widget.sub!, maxLines: 1, overflow: TextOverflow.ellipsis, style: exlBody(10, color: enabled ? _text.withOpacity(0.75) : const Color(0xFF2A3A55))),
              ]),
            ),
          ]),
          ),
        ),
      ]),
    );
    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _down = true) : null,
      onTapUp: enabled ? (_) => setState(() => _down = false) : null,
      onTapCancel: () => setState(() => _down = false),
      onTap: enabled ? () { HapticFeedback.selectionClick(); widget.onTap!(); } : null,
      child: SizedBox(height: widget.height + lip, child: body),
    );
  }
}

// ---------------------------------------------------------------------------
// ExlPanel — chunky card with thick dark outline
// ---------------------------------------------------------------------------
class ExlPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final Color? glow;
  final Color fill;
  const ExlPanel({super.key, required this.child, this.padding = const EdgeInsets.all(14), this.glow, this.fill = const Color(0xFF0F2246)});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: exlInk, width: 2.2),
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color.lerp(fill, Colors.white, 0.10)!, fill, Color.lerp(fill, exlInk, 0.35)!]),
        boxShadow: [
          if (glow != null) BoxShadow(color: glow!.withOpacity(0.35), blurRadius: 18, spreadRadius: 1),
          const BoxShadow(color: Color(0x88000000), offset: Offset(0, 4), blurRadius: 6),
        ],
      ),
      child: child,
    );
  }
}

/// Small 3D pill (status chips: PAID / WAITING / HOST / LIVE …).
class ExlPill extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  final String? asset; // rozet_<x>
  const ExlPill(this.text, {super.key, this.color = exlCyan, this.icon, this.asset});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: exlInk, width: 1.6),
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color.lerp(color, Colors.white, 0.35)!, color, Color.lerp(color, exlInk, 0.3)!]),
        boxShadow: const [BoxShadow(color: Color(0x88000000), offset: Offset(0, 2))],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (asset != null || icon != null) ...[
          SizedBox(width: 14, height: 14, child: asset != null ? ExlUiImage(asset!, fallback: Icon(icon ?? Icons.circle, size: 14, color: exlInk)) : Icon(icon, size: 14, color: exlInk)),
          const SizedBox(width: 5),
        ],
        Text(text, style: TextStyle(fontFamily: exlFont, fontSize: 11, color: exlInk, letterSpacing: 1)),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// ExlAccordion — big-title collapsible section with a summary of the chosen value
// ---------------------------------------------------------------------------
class ExlAccordion extends StatelessWidget {
  final String title;
  final String summary; // shown when collapsed (the chosen value)
  final bool open;
  final VoidCallback onToggle;
  final Widget child;
  final Color accent;
  final Widget? leading;
  const ExlAccordion({super.key, required this.title, required this.summary, required this.open, required this.onToggle, required this.child, this.accent = exlCyan, this.leading});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: open ? accent : exlInk, width: 2),
        color: open ? const Color(0xFF13284F) : const Color(0xFF0F2246),
        boxShadow: const [BoxShadow(color: Color(0x66000000), offset: Offset(0, 3), blurRadius: 4)],
      ),
      child: Column(children: [
        InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: Row(children: [
              if (leading != null) ...[leading!, const SizedBox(width: 10)],
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: exlT(17, color: open ? accent : exlIce, spacing: 1.5)),
                  const SizedBox(height: 2),
                  Text(summary, maxLines: 1, overflow: TextOverflow.ellipsis, style: exlBody(12.5, color: open ? exlIce : accent)),
                ]),
              ),
              AnimatedRotation(turns: open ? 0.5 : 0, duration: const Duration(milliseconds: 180), child: Icon(Icons.expand_more, color: accent, size: 26)),
            ]),
          ),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 180),
          crossFadeState: open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          firstChild: const SizedBox(width: double.infinity),
          secondChild: Padding(padding: const EdgeInsets.fromLTRB(14, 0, 14, 14), child: child),
        ),
      ]),
    );
  }
}

/// Choice chip used inside accordions.
class ExlChoice extends StatelessWidget {
  final String text;
  final bool on;
  final VoidCallback? onTap;
  final Color accent;
  final String? sub;
  const ExlChoice(this.text, {super.key, required this.on, required this.onTap, this.accent = exlCyan, this.sub});
  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? exlInk : (enabled ? exlCyanDim : const Color(0x332A3A55)), width: on ? 2 : 1.4),
          gradient: on ? LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color.lerp(accent, Colors.white, 0.35)!, accent, Color.lerp(accent, exlInk, 0.25)!]) : null,
          color: on ? null : const Color(0x330C1C38),
          boxShadow: on ? const [BoxShadow(color: Color(0x88000000), offset: Offset(0, 2))] : null,
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(text, style: TextStyle(fontFamily: exlFont, fontSize: 13, color: on ? exlInk : (enabled ? exlIce : const Color(0xFF3A4A66)), letterSpacing: 0.5)),
          if (sub != null) Text(sub!, style: exlBody(9.5, color: on ? exlInk.withOpacity(0.7) : exlCyanDim)),
        ]),
      ),
    );
  }
}

/// Section label (small caps).
Widget exlLabel(String t, {Color color = exlCyanDim}) => Padding(padding: const EdgeInsets.only(bottom: 7, top: 2), child: Text(t, style: TextStyle(fontFamily: exlFont, fontSize: 11, color: color, letterSpacing: 2)));

/// Avatar circle for a wallet (deterministic colour from the address).
class ExlAvatar extends StatelessWidget {
  final String wallet;
  final double size;
  final bool me;
  const ExlAvatar(this.wallet, {super.key, this.size = 34, this.me = false});
  @override
  Widget build(BuildContext context) {
    final h = wallet.codeUnits.fold<int>(0, (a, c) => (a * 31 + c) & 0xffffff);
    final c = HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.55, 0.55).toColor();
    return Container(
      width: size, height: size, alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: me ? exlGoldBright : exlInk, width: 2),
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color.lerp(c, Colors.white, 0.3)!, c, Color.lerp(c, exlInk, 0.4)!]),
          boxShadow: const [BoxShadow(color: Color(0x88000000), offset: Offset(0, 2))]),
      child: Text(wallet.isEmpty ? '?' : wallet.substring(0, math.min(2, wallet.length)).toUpperCase(), style: TextStyle(fontFamily: exlFont, fontSize: size * 0.36, color: exlInk)),
    );
  }
}

// ---------------------------------------------------------------------------
// ExlSteps — "how this works" strip for rooms: numbered steps, the current one lit.
// steps: short labels; current: index of the step the player is at (done < current).
// ---------------------------------------------------------------------------
class ExlSteps extends StatelessWidget {
  final List<String> steps;
  final int current;
  final Color accent;
  final String? title;
  /// v1.3: when set, the strip is tappable (ⓘ shown at the right) — usually opens [showExlHowItWorks].
  final VoidCallback? onTap;
  /// Steps that were passed without happening (e.g. score submitted unsigned) — drawn as a grey dash, never as a tick.
  final Set<int> skipped;
  const ExlSteps({super.key, required this.steps, required this.current, this.accent = exlCyan, this.title, this.onTap, this.skipped = const {}});

  @override
  Widget build(BuildContext context) {
    final box = Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: exlInk.withOpacity(0.35), border: Border.all(color: exlCyanDim.withOpacity(0.5))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (title != null || onTap != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              Expanded(child: Text(title ?? '', style: TextStyle(fontFamily: exlFont, fontSize: 10.5, color: exlCyanDim, letterSpacing: 2))),
              if (onTap != null) Text('ⓘ  details', style: TextStyle(color: accent.withOpacity(0.9), fontSize: 10.5, letterSpacing: 0.5)),
            ]),
          ),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < steps.length; i++) ...[
            Expanded(child: _step(i)),
            if (i < steps.length - 1)
              Padding(padding: const EdgeInsets.only(top: 9), child: Container(width: 8, height: 2, color: i < current ? accent : exlCyanDim.withOpacity(0.5))),
          ],
        ]),
      ]),
    );
    return onTap == null ? box : GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: box);
  }

  Widget _step(int i) {
    final skip = skipped.contains(i);
    final done = i < current && !skip, now = i == current;
    final c = done ? exlGreenGo : (now ? accent : exlCyanDim);
    return Column(children: [
      Container(
        width: 20, height: 20,
        decoration: BoxDecoration(shape: BoxShape.circle, color: now ? accent : (done ? exlGreenGo.withOpacity(0.25) : Colors.transparent), border: Border.all(color: c, width: 1.6),
            boxShadow: now ? [BoxShadow(color: accent.withOpacity(0.6), blurRadius: 8)] : null),
        child: Center(child: done ? const Icon(Icons.check, size: 12, color: exlGreenGo) : (skip ? const Icon(Icons.remove, size: 12, color: exlCyanDim) : Text('${i + 1}', style: TextStyle(fontFamily: exlFont, fontSize: 10, color: now ? exlInk : c)))),
      ),
      const SizedBox(height: 3),
      Text(steps[i], textAlign: TextAlign.center, maxLines: 2, style: TextStyle(fontSize: 8.5, height: 1.1, color: now ? exlIce : c, fontWeight: now ? FontWeight.w800 : FontWeight.w600)),
    ]);
  }
}

/// Error dialog with a RETRY button — every failed money action gets one (Berkay rule: the user must always be able to retry).
Future<bool> exlRetryDialog(BuildContext context, {required String title, required String message, String retryLabel = 'TRY AGAIN'}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: exlPanel, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: exlInk, width: 2)),
      title: Text(title, style: TextStyle(fontFamily: exlFont, fontSize: 16, color: exlRed, letterSpacing: 1.5)),
      content: Text(message, style: exlBody(13, color: exlIce)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CLOSE', style: TextStyle(color: exlCyanDim))),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(retryLabel, style: const TextStyle(color: exlCyan, fontWeight: FontWeight.w800))),
      ],
    ),
  );
  return r == true;
}

// ---------------------------------------------------------------------------
// HOW IT WORKS sheet — the same step strip plus one line per step. Opened from the
// ⓘ on any ExlSteps strip, from the DUELS panel and from the TOURNAMENTS grid.
// ---------------------------------------------------------------------------
class ExlHowStep {
  final String label;   // short label for the strip ('Pay\nentry')
  final String detail;  // one or two sentences: the rule and what the player can do
  const ExlHowStep(this.label, this.detail);
}

Future<void> showExlHowItWorks(BuildContext context, {
  required String title,
  required List<ExlHowStep> steps,
  Color accent = exlCyan,
  String? footer,
  String? moreLabel,
  VoidCallback? onMore,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => Container(
      padding: EdgeInsets.fromLTRB(20, 14, 20, 24 + MediaQuery.of(ctx).padding.bottom),
      decoration: const BoxDecoration(
        color: exlPanel,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: exlCyanDim)),
      ),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(child: Container(width: 42, height: 4, decoration: BoxDecoration(color: exlCyanDim, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 14),
          Center(child: ExlEmboss(title, size: 20, spacing: 2.5)),
          const SizedBox(height: 12),
          ExlSteps(accent: accent, current: -1, steps: [for (final st in steps) st.label]),
          const SizedBox(height: 12),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  width: 22, height: 22, margin: const EdgeInsets.only(top: 1),
                  decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: accent, width: 1.6)),
                  child: Center(child: Text('${i + 1}', style: TextStyle(fontFamily: exlFont, fontSize: 10.5, color: accent))),
                ),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(steps[i].label.replaceAll('\n', ' ').toUpperCase(), style: TextStyle(fontFamily: exlFont, fontSize: 11, color: exlIce, letterSpacing: 1.5)),
                  const SizedBox(height: 2),
                  Text(steps[i].detail, style: exlBody(12, color: exlCyanDim)),
                ])),
              ]),
            ),
          if (footer != null) ...[
            const SizedBox(height: 2),
            Text(footer, style: TextStyle(color: exlCyanDim.withOpacity(0.9), fontSize: 11, height: 1.4)),
          ],
          if (onMore != null) ...[
            const SizedBox(height: 12),
            Center(child: GestureDetector(
              onTap: () { Navigator.pop(ctx); onMore(); },
              child: Text(moreLabel ?? 'Full rules →', style: TextStyle(color: accent, fontSize: 12.5, decoration: TextDecoration.underline, decorationColor: accent)),
            )),
          ],
        ]),
      ),
    ),
  );
}
