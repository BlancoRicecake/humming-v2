import 'package:flutter/foundation.dart';
import '../models/loop_models.dart';

/// Song-editor clipboard shared by tracks and sections. Snapshots keep source
/// notes independent from subsequent editing, including mutable step/dur fields.
class PitchClipboard extends ChangeNotifier {
  List<PitchNote> _notes = [];
  bool get isEmpty => _notes.isEmpty;

  void copy(Iterable<PitchNote> notes) {
    final selected = notes.toList();
    if (selected.isEmpty) return;
    final origin = selected.map((n) => n.step).reduce((a, b) => a < b ? a : b);
    _notes = [for (final n in selected) n.copyWith(step: n.step - origin)];
    notifyListeners();
  }

  List<PitchNote> paste({required int atStep, required int steps}) {
    if (atStep < 0 || _notes.any((n) => n.endSteps + atStep > steps)) return [];
    return [for (final n in _notes) n.copyWith(step: n.step + atStep)];
  }
}
