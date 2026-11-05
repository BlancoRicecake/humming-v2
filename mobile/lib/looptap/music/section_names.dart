// Section names (2026-11-02): auto-named sections read A, B, C… by position;
// a duplicate keeps its source's name with " #2", " #3"… in song order, so
// copies of one section ("a family") read A, A #2, A #3 wherever they sit.
import '../models/loop_models.dart';

final _copySuffix = RegExp(r' #\d+$');

/// A duplicate's name without its number: 'A #2' → 'A'.
String sectionBaseName(String name) => name.replaceFirst(_copySuffix, '');

/// Re-names [sections] in place after an add / duplicate / move / delete.
/// The first section of each family takes the family's name — the next
/// position letter when auto-named, else its own (custom) name — and the
/// later ones the same name with " #n". A section outside any family is its
/// own family, so a song without copies reads as before (A, B, C…, custom
/// names kept, their letter skipped).
void relabelSections(List<Section> sections) {
  final seen = <String, (String, int)>{};
  var letter = 0;
  for (final s in sections) {
    final family = s.family ?? s.id;
    final hit = seen[family];
    if (hit != null) {
      final n = hit.$2 + 1;
      seen[family] = (hit.$1, n);
      s.name = '${hit.$1} #$n';
      continue;
    }
    final base =
        s.autoName
            ? String.fromCharCode(65 + letter % 26)
            : (s.family == null ? s.name : sectionBaseName(s.name));
    letter++;
    seen[family] = (base, 1);
    s.name = base;
  }
}
