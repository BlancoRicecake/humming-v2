// Soundfont catalog — pure-logic units (slot range, manifest parse/cache,
// midi fallback). The download/file path is device-only and not covered here.
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/music/soundfont_catalog.dart';

void main() {
  test('isDynamicSlot only fires at/above the catalog base (1000)', () {
    expect(isDynamicSlot(0), isFalse); // GM grand piano
    expect(isDynamicSlot(127), isFalse);
    expect(isDynamicSlot(128), isFalse); // 808 sentinel
    expect(isDynamicSlot(200), isFalse); // hip-hop sentinel
    expect(isDynamicSlot(999), isFalse);
    expect(isDynamicSlot(1000), isTrue);
    expect(isDynamicSlot(1042), isTrue);
  });

  test('SoundfontEntry.fromJson maps the manifest row + defaults', () {
    final e = SoundfontEntry.fromJson({
      'id': 'warm_rhodes',
      'slot': 1001,
      'label': 'Warm Rhodes',
      'role': 'melody',
      'category': 'Keys',
      'bytes': 4096,
      'sha256': 'abc',
      'sf_bank': 0,
      'sf_program': 0,
      'midi_fallback': 4,
    });
    expect(e.slot, 1001);
    expect(e.label, 'Warm Rhodes');
    expect(e.role, 'melody');
    expect(e.midiFallback, 4);

    // defaults when optional fields are absent
    final m = SoundfontEntry.fromJson({'id': 'x', 'slot': 1009, 'label': 'X', 'role': 'bass'});
    expect(m.sfBank, 0);
    expect(m.sfProgram, 0);
    expect(m.midiFallback, 0);
    expect(m.category, '');
  });

  test('toCache round-trips through fromJson', () {
    final e = SoundfontEntry.fromJson({
      'id': 'kit', 'slot': 1100, 'label': 'Trap Kit', 'role': 'drums',
      'category': 'Electronic', 'bytes': 8192, 'sha256': 'd', 'midi_fallback': 25,
    });
    final r = SoundfontEntry.fromJson(e.toCache());
    expect(r.id, e.id);
    expect(r.slot, e.slot);
    expect(r.role, e.role);
    expect(r.midiFallback, e.midiFallback);
  });

  test('unknown slot resolves to a benign midi fallback (0)', () {
    // empty catalog (no warm/refresh in a unit test) → fallback 0 (grand piano),
    // never a crash, so .mid export of a missing slot stays valid.
    expect(SoundfontCatalog.instance.midiFallback(1234), 0);
    expect(SoundfontCatalog.instance.bySlot(1234), isNull);
    expect(SoundfontCatalog.instance.localPath(1234), isNull);
    expect(SoundfontCatalog.instance.isDownloaded(1234), isFalse);
  });
}
