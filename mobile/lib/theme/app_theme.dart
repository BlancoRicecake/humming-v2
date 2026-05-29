// Humming 디자인 토큰 + 테마 (humming-UI.pen 에서 추출)
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// 디자인 토큰 — humming-UI.pen 의 색/간격을 단일 소스로.
class AppColors {
  static const bg = Color(0xFF0A0A0F); // 배경
  static const surface = Color(0xFF16161E); // 카드/표면
  static const surfaceAlt = Color(0xFF0A0A0F);
  static const lime = Color(0xFFA3E635); // 액센트
  static const activeLane = Color(0xFF1F2A0F); // 활성 레인 배경
  static const textPrimary = Color(0xFFFAFAFA);
  static const textSecondary = Color(0xFF71717A);
  static const textTertiary = Color(0xFF52525B);
  static const border = Color(0xFF27272A);
  static const danger = Color(0xFFEF4444);
  static const dangerBorder = Color(0xFF3F1D1D);
}

class AppRadius {
  static const card = 16.0;
  static const chip = 11.0;
  static const sheet = 28.0;
  static const phone = 48.0;
}

ThemeData hummingTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.lime,
      surface: AppColors.surface,
      onPrimary: AppColors.bg,
      onSurface: AppColors.textPrimary,
    ),
    textTheme: GoogleFonts.interTextTheme(base.textTheme).apply(
      bodyColor: AppColors.textPrimary,
      displayColor: AppColors.textPrimary,
    ),
    splashColor: AppColors.lime.withValues(alpha: 0.08),
    highlightColor: Colors.transparent,
  );
}

/// 자주 쓰는 텍스트 스타일 헬퍼.
class T {
  static TextStyle h1 = GoogleFonts.inter(fontSize: 28, fontWeight: FontWeight.w700, color: AppColors.textPrimary);
  static TextStyle h2 = GoogleFonts.inter(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.textPrimary);
  static TextStyle title = GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary);
  static TextStyle body = GoogleFonts.inter(fontSize: 14, color: AppColors.textPrimary);
  static TextStyle sub = GoogleFonts.inter(fontSize: 12, color: AppColors.textSecondary);
  static TextStyle label = GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.5, color: AppColors.textTertiary);
}
