// LoopTap design tokens — ported 1:1 from prototype/shared.jsx (APP).
// Near-black canvas + single neon-lime accent. "Game-like" tactile feedback.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Color tokens (README §Color).
class LT {
  static const bg = Color(0xFF0E0E0E); // app background
  static const surface = Color(0xFF161616); // cards / sheets
  static const surface2 = Color(0xFF1E1E1E); // raised controls, pads (idle)
  static const surface3 = Color(0xFF262626); // hover / nested
  static const lime = Color(0xFFA3E635); // primary accent, active, CTAs, playhead
  static const limeDim = Color(0xFF7FB52A); // pressed lime
  static const border = Color(0xFF2A2A2A); // hairline borders
  static const borderStrong = Color(0xFF3A3A3A); // hover borders
  static const t1 = Color(0xFFFAFAFA); // primary text
  static const t2 = Color(0xFFA1A1AA); // secondary text
  static const t3 = Color(0xFF71717A); // tertiary / captions
  static const danger = Color(0xFFEF4444); // record, destructive, sign-out
  static const blue = Color(0xFF60A5FA); // Bass + Hi-hat
  static const amber = Color(0xFFF59E0B); // Drums + Kick
  static const pink = Color(0xFFF472B6); // Vocal
}

/// Radius tokens (README §Radius).
class LTRadius {
  static const chip = 8.0; // chips / grid-cells
  static const control = 12.0; // controls / rows / shelf-cards
  static const card = 16.0; // cards & pads
  static const sheet = 22.0; // sheets / modals
  static const phone = 46.0; // phone bezel
  static const pill = 999.0; // pills / toggles / FAB
}

/// Motion tokens (README §Spacing & motion).
class LTMotion {
  static const fast = Duration(milliseconds: 100); // .06–.16s state changes
  static const state = Duration(milliseconds: 150);
  static const pop = Duration(milliseconds: 200); // tap "pop"
  static const flash = Duration(milliseconds: 220); // white flash overlay
  static const popCurve = Cubic(0.2, 0.8, 0.2, 1);
}

/// Typography — Inter (sans) + JetBrains Mono (numeric/technical).
class LTType {
  static TextStyle inter({
    double size = 13,
    FontWeight weight = FontWeight.w400,
    Color color = LT.t1,
    double? letterSpacing,
    double? height,
  }) =>
      GoogleFonts.inter(
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: letterSpacing,
        height: height,
      );

  static TextStyle mono({
    double size = 12,
    FontWeight weight = FontWeight.w500,
    Color color = LT.t2,
    double? letterSpacing,
  }) =>
      GoogleFonts.jetBrainsMono(
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: letterSpacing,
      );

  /// 9/800 uppercase letter-spacing 1px micro-label.
  static TextStyle microLabel(Color color) => GoogleFonts.inter(
        fontSize: 9,
        fontWeight: FontWeight.w800,
        color: color,
        letterSpacing: 1,
      );
}

/// Neon glow used by active pads / lanes:
/// box-shadow: 0 0 44px accent(cc), inset 0 0 26px accent(66).
/// Flutter can't do an inset box-shadow, so the outer glow is reproduced here
/// and the inset is approximated with an inner gradient where it matters.
List<BoxShadow> neonGlow(Color accent, {double blur = 44}) => [
      BoxShadow(color: accent.withValues(alpha: 0.8), blurRadius: blur, spreadRadius: 1),
    ];

ThemeData loopTapTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: LT.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: LT.lime,
      surface: LT.surface,
      onPrimary: LT.bg,
      onSurface: LT.t1,
    ),
    textTheme: GoogleFonts.interTextTheme(base.textTheme)
        .apply(bodyColor: LT.t1, displayColor: LT.t1),
    splashColor: LT.lime.withValues(alpha: 0.08),
    highlightColor: Colors.transparent,
  );
}
