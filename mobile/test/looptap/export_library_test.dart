import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/music/export_library.dart';

void main() {
  test(
    'exports remain discoverable on restart, excluding drafts and empty files',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'humtrack_exports_test_',
      );
      try {
        await File('${root.path}/song.wav').writeAsBytes([1, 2, 3]);
        await File('${root.path}/melody.mid').writeAsBytes([1, 2]);
        await File('${root.path}/melody.mid').setLastModified(DateTime(2030));
        await File('${root.path}/draft.tmp').writeAsBytes([1]);
        await File('${root.path}/empty.wav').writeAsBytes([]);
        final first = await listExportedFiles(directory: root);
        final reopened = await listExportedFiles(
          directory: Directory(root.path),
        );
        expect(first.map((f) => f.name), ['melody.mid', 'song.wav']);
        expect(reopened.map((f) => f.name), first.map((f) => f.name));
        expect(reopened.first.mimeType, 'audio/midi');
        expect(reopened.last.size, 3);
        expect(await reopened.last.file.readAsBytes(), [1, 2, 3]);
      } finally {
        expect(
          root.absolute.path.startsWith(Directory.systemTemp.absolute.path),
          isTrue,
        );
        await root.delete(recursive: true);
      }
    },
  );
}
