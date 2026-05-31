// 악기(GM program) → 아이콘 위젯 매핑.
//
// 우선순위: Material Icons → Game Icons SVG 자산 (CC BY 3.0) 폴백.
// 이모지 사용 금지. 단일 함수 `instrumentIcon(program, ...)` 으로 모든 사용처 통일.
//
// SVG 파일은 모두 `fill="currentColor"` 로 정규화되어 있으므로
// `colorFilter: ColorFilter.mode(color, BlendMode.srcIn)` 로 틴트 적용.
//
// 라이선스 고지: docs/credits.md 참조.
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

// drum kit / vocal 가상 program — GM 외 내부 표기.
const int kDrumKitProgram = -1; // TrackRole.drum
const int kVocalProgram = -2; // TrackRole.vocal

enum _IconKind { material, svg }

class _IconSpec {
  final _IconKind kind;
  final IconData? icon;
  final String? assetPath;
  const _IconSpec.material(this.icon)
      : kind = _IconKind.material,
        assetPath = null;
  const _IconSpec.svg(this.assetPath)
      : kind = _IconKind.svg,
        icon = null;
}

// GM program → 아이콘. 매핑 없는 program 은 _fallback 사용.
_IconSpec _specFor(int program) {
  switch (program) {
    // Piano family + organ.
    case 0: // Acoustic Grand Piano
    case 4: // Electric Piano
    case 16: // Drawbar Organ
      return const _IconSpec.material(Icons.piano);

    // Guitars (nylon / acoustic / electric).
    case 24:
    case 25:
    case 27:
      return const _IconSpec.material(Icons.music_note);

    // Bass.
    case 32:
    case 33:
      return const _IconSpec.material(Icons.audiotrack);

    // Synth bass / synth leads / pads.
    case 39:
    case 80:
    case 81:
    case 90:
      return const _IconSpec.svg('assets/icons/instruments/synthesizer.svg');

    // Violin / strings.
    case 40:
    case 48:
      return const _IconSpec.svg('assets/icons/instruments/violin.svg');

    // Choir.
    case 52:
      return const _IconSpec.material(Icons.groups);

    // Trumpet.
    case 56:
      return const _IconSpec.svg('assets/icons/instruments/trumpet.svg');

    // Flute.
    case 73:
      return const _IconSpec.svg('assets/icons/instruments/flute.svg');

    // 가상 program.
    case kDrumKitProgram:
      return const _IconSpec.svg('assets/icons/instruments/drum.svg');
    case kVocalProgram:
      return const _IconSpec.material(Icons.mic);

    default:
      return const _IconSpec.material(Icons.music_note);
  }
}

/// GM program 번호로 악기 아이콘 위젯을 반환.
Widget instrumentIcon(int program, {double size = 20, Color? color}) {
  final spec = _specFor(program);
  switch (spec.kind) {
    case _IconKind.material:
      return Icon(spec.icon, size: size, color: color);
    case _IconKind.svg:
      final effective = color ?? const Color(0xFFE5E5E7);
      return SvgPicture.asset(
        spec.assetPath!,
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(effective, BlendMode.srcIn),
      );
  }
}
