import 'dart:math' as math;

/// Container-relative sizing for tap surfaces.
///
/// The harmony rule: size a pad/cell's leaf content (label, sub, icon) from the
/// slot's *measured short side* — not from fixed dp. As the surface area splits
/// (arrangement:surface flex 2:3) or the device changes, the pad box changes and
/// its content scales with it. Clamps keep the extremes readable: text never
/// shrinks below legibility on a tiny phone nor balloons on a tablet.
class PadScale {
  PadScale(double shortSide) : s = math.max(0, shortSide);

  /// The constraining (shorter) side of the pad/cell box.
  final double s;

  /// Primary label (note name, drum short tag).
  double get title => (s * 0.26).clamp(14.0, 30.0);

  /// Secondary label (degree, drum long name).
  double get sub => (s * 0.12).clamp(8.0, 15.0);

  /// Inline icon paired with a label.
  double get icon => (s * 0.22).clamp(12.0, 26.0);

  /// Gap between stacked/inline label elements.
  double get gap => (s * 0.04).clamp(2.0, 8.0);
}

/// How many pads fit across [availableWidth] (landscape DAW). Keeps each pad near
/// a comfortable [target] width so small phones stay at [min] and wide tablets
/// fan out to [max] — instead of stretching a fixed count to any width.
int padCountForWidth(
  double availableWidth, {
  int min = 8,
  int max = 12,
  double target = 92,
}) {
  if (availableWidth <= 0) return min;
  return (availableWidth / target).round().clamp(min, max);
}
