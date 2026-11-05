// HumTrack mixer pan (spec mixer-001). Pure Dart: shared by the live synth
// path, the MIDI/WAV exporters and the mixer UI.
//
// Stored value p is in [-1, 1] (-1 = hard left, 0 = centre, 1 = hard right).

/// Clamp a stored/incoming pan to [-1, 1] (non-finite -> centre).
double clampPan(num? p) {
  if (p == null) return 0;
  final v = p.toDouble();
  if (!v.isFinite) return 0;
  return v < -1 ? -1 : (v > 1 ? 1 : v);
}

/// MIDI CC10 value for pan [p]: -1 -> 0, 0 -> 64, 1 -> 127.
int panToCc(double p) {
  final v = clampPan(p);
  final cc = v <= 0 ? (64 + 64 * v).round() : (64 + 63 * v).round();
  return cc < 0 ? 0 : (cc > 127 ? 127 : cc);
}

/// Balance law for audio (vocal) lanes: gL = min(1, 1 - p), gR = min(1, 1 + p).
/// Centre keeps both sides at unity, so a centred lane is exactly today's
/// level on each channel.
({double left, double right}) panBalance(double p) {
  final v = clampPan(p);
  return (left: v > 0 ? 1 - v : 1.0, right: v < 0 ? 1 + v : 1.0);
}

/// Readout text: "L23", "C", "R40" (display = round(|p| * 100)).
String panLabel(double p) {
  final n = (clampPan(p).abs() * 100).round();
  if (n == 0) return 'C';
  return p < 0 ? 'L$n' : 'R$n';
}
