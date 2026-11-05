/// Shared projection for notes, ruler, playhead, seeking and clip dragging.
/// Zoom changes the viewport; song steps and MIDI data remain unchanged.
class TimelineView {
  const TimelineView(this.start, this.end) : assert(end > start);
  final double start, end;
  double get length => end - start;
  double fraction(num step) => (step - start) / length;
  double stepAt(double fraction) => start + fraction.clamp(0, 1) * length;
}
