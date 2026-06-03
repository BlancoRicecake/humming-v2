// 공식 브랜드 가이드라인 준수 소셜 로그인 버튼.
//
// Apple HIG (Sign in with Apple Button):
//   https://developer.apple.com/design/human-interface-guidelines/sign-in-with-apple
//   - 최소 height 32 (권장 44+), corner radius ≤ height/2
//   - 로고와 텍스트 사이 padding: height * 0.18 ~ 0.43
//   - 폰트: SF Pro Display (시스템 기본), weight ≥ medium
//   - 색상: black / white / whiteOutline 3종만 허용
//   - 텍스트: "Sign in with Apple" / "Continue with Apple" / "Sign up with Apple"
//     (로컬라이즈 — 한국어는 "Apple로 계속하기"가 공식 번역)
//
// Google Identity Branding Guidelines:
//   https://developers.google.com/identity/branding-guidelines
//   - "G" 로고는 4색 공식 자산 (Blue #4285F4, Red #EA4335, Yellow #FBBC05, Green #34A853)
//   - 흰색 버튼: 텍스트 #1F1F1F (또는 #3C4043), 테두리 #DADCE0
//   - 다크 버튼: #131314 또는 #1F1F1F, 텍스트 #E3E3E3
//   - 폰트: Roboto Medium (없으면 시스템 sans-serif)
//   - 텍스트: "Sign in with Google" / "Continue with Google" (KR: "Google로 계속하기")
//
// 시안 ⑤ 일치를 위해:
//   - Apple: white 배경 + black 텍스트 (공식 HIG light variant)
//   - Google: dark 배경 변형 (시안과 매칭) + 공식 4색 G 로고
//   - 모서리 radius 14 (시안의 login-btn radius)

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 공통 spec: HIG 권장 높이 + 시안 14 radius.
const double _kButtonHeight = 50;
const double _kButtonRadius = 14;

/// ─── Apple Sign In 버튼 ──────────────────────────────────────────────
/// HIG light(white) variant — 시안 ⑤ 와 매칭.
class AppleSignInButton extends StatelessWidget {
  const AppleSignInButton({
    super.key,
    required this.onPressed,
    this.label = 'Apple로 계속하기',
  });

  final VoidCallback onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onPressed();
        },
        child: Container(
          height: _kButtonHeight,
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(_kButtonRadius),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Apple 로고 — HIG 비율 (height 약 44%).
              const _AppleLogo(size: 20),
              const SizedBox(width: 10),
              Text(
                label,
                // HIG: SF Pro Display, medium 이상. iOS 기본 폰트 우선.
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  fontFamily: '.SF Pro Display',
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Apple 로고 — HIG 공식 path (단색).
class _AppleLogo extends StatelessWidget {
  const _AppleLogo({this.size = 20});
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _AppleLogoPainter(Colors.black)),
    );
  }
}

class _AppleLogoPainter extends CustomPainter {
  _AppleLogoPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // SF Symbols 의 apple.logo 와 동등한 비율 path — 814x1000 viewBox 정규화.
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final s = size.width;
    final path = Path();
    // 단순화된 Apple 로고 path (잎 + 본체) — viewBox 24x24 기준 후 scale.
    final ref = Path()
      // body
      ..moveTo(17.05, 20.28)
      ..cubicTo(16.07, 21.23, 15.00, 21.08, 13.97, 20.63)
      ..cubicTo(12.88, 20.17, 11.88, 20.15, 10.73, 20.63)
      ..cubicTo(9.28, 21.25, 8.52, 21.07, 7.66, 20.28)
      ..cubicTo(2.79, 15.25, 3.51, 7.59, 9.05, 7.31)
      ..cubicTo(10.41, 7.38, 11.36, 8.05, 12.16, 8.11)
      ..cubicTo(13.35, 7.87, 14.49, 7.17, 15.76, 7.26)
      ..cubicTo(17.28, 7.38, 18.43, 7.98, 19.18, 9.06)
      ..cubicTo(16.04, 10.94, 16.78, 15.07, 19.66, 16.23)
      ..cubicTo(19.09, 17.74, 18.34, 19.23, 17.04, 20.29)
      ..lineTo(17.05, 20.28)
      ..close()
      // leaf
      ..moveTo(12.03, 7.25)
      ..cubicTo(11.88, 5.00, 13.71, 3.15, 15.81, 3.00)
      ..cubicTo(16.10, 5.60, 13.45, 7.54, 12.03, 7.25)
      ..close();
    final scale = s / 24.0;
    final matrix = Matrix4.identity()..scaleByDouble(scale, scale, 1.0, 1.0);
    path.addPath(ref, Offset.zero, matrix4: matrix.storage);
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant _AppleLogoPainter old) => old.color != color;
}

/// ─── Google Sign In 버튼 ─────────────────────────────────────────────
/// 시안 ⑤ 와 매칭하는 dark variant. 4색 공식 G 로고 + Identity 가이드 텍스트.
class GoogleSignInButton extends StatelessWidget {
  const GoogleSignInButton({
    super.key,
    required this.onPressed,
    this.label = 'Google로 계속하기',
  });

  final VoidCallback onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onPressed();
        },
        child: Container(
          height: _kButtonHeight,
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            // Identity guideline dark variant: #131314.
            color: const Color(0xFF131314),
            borderRadius: BorderRadius.circular(_kButtonRadius),
            border: Border.all(color: const Color(0xFF8E918F), width: 1),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const _GoogleGLogo(size: 18),
              const SizedBox(width: 10),
              Text(
                label,
                // Identity: Roboto Medium. 미설치 시 시스템 sans-serif fallback.
                style: const TextStyle(
                  color: Color(0xFFE3E3E3),
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  fontFamily: 'Roboto',
                  letterSpacing: 0.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 공식 4색 Google "G" 로고.
class _GoogleGLogo extends StatelessWidget {
  const _GoogleGLogo({this.size = 18});
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _GoogleGPainter()),
    );
  }
}

class _GoogleGPainter extends CustomPainter {
  // 공식 브랜드 색상.
  static const _blue = Color(0xFF4285F4);
  static const _red = Color(0xFFEA4335);
  static const _yellow = Color(0xFFFBBC05);
  static const _green = Color(0xFF34A853);

  @override
  void paint(Canvas canvas, Size size) {
    // viewBox 48x48 기준 4색 G 로고 — Google Identity 공식 SVG.
    final scale = size.width / 48.0;
    canvas.save();
    canvas.scale(scale, scale);

    final blue = Paint()..color = _blue..style = PaintingStyle.fill;
    final red = Paint()..color = _red..style = PaintingStyle.fill;
    final yellow = Paint()..color = _yellow..style = PaintingStyle.fill;
    final green = Paint()..color = _green..style = PaintingStyle.fill;

    // Blue (right side of G + horizontal stroke).
    canvas.drawPath(
      Path()
        ..moveTo(47.532, 24.5528)
        ..cubicTo(47.532, 22.9214, 47.3997, 21.2811, 47.1175, 19.6761)
        ..lineTo(24.48, 19.6761)
        ..lineTo(24.48, 28.9181)
        ..lineTo(37.4434, 28.9181)
        ..cubicTo(36.9055, 31.8988, 35.177, 34.5356, 32.6461, 36.2111)
        ..lineTo(32.6461, 42.2078)
        ..lineTo(40.3801, 42.2078)
        ..cubicTo(44.9217, 38.0282, 47.532, 31.8547, 47.532, 24.5528)
        ..close(),
      blue,
    );
    // Green (bottom).
    canvas.drawPath(
      Path()
        ..moveTo(24.48, 48.0016)
        ..cubicTo(30.9529, 48.0016, 36.4116, 45.8764, 40.3888, 42.2078)
        ..lineTo(32.6549, 36.2111)
        ..cubicTo(30.5031, 37.675, 27.7252, 38.5039, 24.4888, 38.5039)
        ..cubicTo(18.2275, 38.5039, 12.9187, 34.2798, 11.0139, 28.6006)
        ..lineTo(3.03298, 28.6006)
        ..lineTo(3.03298, 34.7825)
        ..cubicTo(7.10044, 42.8868, 15.4055, 48.0016, 24.48, 48.0016)
        ..close(),
      green,
    );
    // Yellow (left).
    canvas.drawPath(
      Path()
        ..moveTo(11.0051, 28.6006)
        ..cubicTo(9.99973, 25.6199, 9.99973, 22.3922, 11.0051, 19.4115)
        ..lineTo(11.0051, 13.2296)
        ..lineTo(3.03298, 13.2296)
        ..cubicTo(-0.371021, 20.0112, -0.371021, 28.0009, 3.03298, 34.7825)
        ..lineTo(11.0051, 28.6006)
        ..close(),
      yellow,
    );
    // Red (top).
    canvas.drawPath(
      Path()
        ..moveTo(24.48, 9.49932)
        ..cubicTo(27.9016, 9.44641, 31.2086, 10.7339, 33.6866, 13.0973)
        ..lineTo(40.5387, 6.24523)
        ..cubicTo(36.2 , 2.17 , 30.4435, -0.0651905, 24.48, 0.00161217)
        ..cubicTo(15.4055, 0.00161217, 7.10044, 5.11644, 3.03298, 13.2296)
        ..lineTo(11.0051, 19.4115)
        ..cubicTo(12.9099, 13.7235, 18.2275, 9.49932, 24.48, 9.49932)
        ..close(),
      red,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _GoogleGPainter old) => false;
}
