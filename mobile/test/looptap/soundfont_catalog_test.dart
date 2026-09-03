// Soundfont catalog — pure-logic units (slot range, manifest parse/cache,
// midi fallback) plus the file-level pieces that don't need a device: the
// streamed sha256 used to verify downloads and delete(). The network download
// itself is device-only and not covered here.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/music/soundfont_catalog.dart';

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sf_catalog_test_');
    SoundfontCatalog.instance.debugSetDirectory(tmp);
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('fileSha256 streams the same digest crypto computes in one shot', () async {
    // > one stream chunk so the incremental path is actually exercised
    final bytes = List<int>.generate(200 * 1024, (i) => (i * 31 + 7) & 0xff);
    final f = File('${tmp.path}/blob.bin');
    await f.writeAsBytes(bytes);
    expect(await SoundfontCatalog.fileSha256(f), sha256.convert(bytes).toString());
    // and a known vector, so the hex/lower-case format is pinned
    final hello = File('${tmp.path}/hello.txt');
    await hello.writeAsString('hello');
    expect(
      await SoundfontCatalog.fileSha256(hello),
      '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
    );
    expect(sha256.convert(utf8.encode('hello')).toString(), startsWith('2cf24dba'));
  });

  test('delete removes the .sf2 and any stale .part; false when nothing there', () async {
    final sf = File('${tmp.path}/warm_rhodes.sf2');
    final part = File('${tmp.path}/warm_rhodes.sf2.part');
    await sf.writeAsBytes([1, 2, 3]);
    await part.writeAsBytes([4]);
    expect(await SoundfontCatalog.instance.delete('warm_rhodes'), isTrue);
    expect(await sf.exists(), isFalse);
    expect(await part.exists(), isFalse);
    // idempotent: second delete finds nothing
    expect(await SoundfontCatalog.instance.delete('warm_rhodes'), isFalse);
    // unrelated id never touches other files
    final other = File('${tmp.path}/other.sf2');
    await other.writeAsBytes([9]);
    expect(await SoundfontCatalog.instance.delete('warm_rhodes'), isFalse);
    expect(await other.exists(), isTrue);
  });

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
