// arrangement-001: linked sections + Make unique.
// docs/specs/arrangement/ar-001-linked-sections.md
//
// Sections with the same `linkId` share one `tracks` map and one `fillKinds`
// list at runtime (and keep the same `bars`), so editing one edits all. Saved
// files still hold every section's full content; [relinkSections] restores
// the sharing after loading or after an undo snapshot (deep copies).
import '../models/loop_models.dart';

/// Re-establish sharing: for each `linkId`, the first section in the list is
/// the source; the others become [Section.linkedTo] copies of it (same
/// `tracks` / `fillKinds` instances, its `bars`), keeping their own id, name,
/// repeats, track list and groove overrides. A `linkId` used by one section
/// only is cleared. Unlinked sections are returned as they are.
List<Section> relinkSections(List<Section> sections) {
  final count = <String, int>{};
  for (final s in sections) {
    if (s.linkId != null) count[s.linkId!] = (count[s.linkId!] ?? 0) + 1;
  }
  final sources = <String, Section>{};
  return [
    for (final s in sections)
      if (s.linkId == null)
        s
      else if (count[s.linkId!]! < 2)
        s..linkId = null
      else if (sources[s.linkId!] case final src?)
        identical(src.tracks, s.tracks) &&
                identical(src.fillKinds, s.fillKinds) &&
                src.bars == s.bars
            ? s
            : Section.linkedTo(
              src,
              id: s.id,
              name: s.name,
              autoName: s.autoName,
              repeats: s.repeats,
              extras: s.extras,
              order: s.order,
              grooveOverrides: s.grooveOverrides,
            )
      else
        (sources[s.linkId!] = s),
  ];
}

/// A new link id (unique enough within one song).
String newLinkId() => 'link${DateTime.now().microsecondsSinceEpoch}';

/// Linked duplicate of [src] with id [newId]: gives [src] a link id when it
/// has none, and returns a section sharing its content.
Section duplicateLinked(Section src, String newId) {
  src.linkId ??= newLinkId();
  return Section.linkedTo(
    src,
    id: newId,
    name: src.name,
    autoName: src.autoName,
    repeats: src.repeats,
  );
}

/// Make unique: an independent deep copy of [s] (same audio file references
/// for vocal clips), out of its link group.
Section makeUnique(Section s) => s.deepCopy()..linkId = null;

/// Indices of the sections linked with `sections[idx]` (itself included).
Iterable<int> linkedIndices(List<Section> sections, int idx) sync* {
  final id = sections[idx].linkId;
  if (id == null) {
    yield idx;
    return;
  }
  for (var i = 0; i < sections.length; i++) {
    if (sections[i].linkId == id) yield i;
  }
}

/// Display number (1, 2, …) of each link group in list order.
Map<String, int> linkGroupNumbers(List<Section> sections) {
  final out = <String, int>{};
  for (final s in sections) {
    final id = s.linkId;
    if (id != null && !out.containsKey(id)) out[id] = out.length + 1;
  }
  return out;
}
