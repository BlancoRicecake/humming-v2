import 'dart:io';
import 'song_util.dart';

class ExportedFile {
  const ExportedFile(this.file, this.modified, this.size);
  final File file;
  final DateTime modified;
  final int size;
  String get name => file.uri.pathSegments.last;
  String get mimeType =>
      name.toLowerCase().endsWith('.mid') ? 'audio/midi' : 'audio/wav';
}

/// Read the existing export directory rather than keeping a second index.
/// Old exports and exports produced before a cancelled share remain accessible.
Future<List<ExportedFile>> listExportedFiles({Directory? directory}) async {
  final folder = directory ?? await exportsFolder();
  if (!await folder.exists()) return [];
  final files = <ExportedFile>[];
  await for (final entity in folder.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = entity.path.toLowerCase();
    if (!name.endsWith('.mid') && !name.endsWith('.wav')) continue;
    try {
      final stat = await entity.stat();
      if (stat.type == FileSystemEntityType.file && stat.size > 0) {
        files.add(ExportedFile(entity, stat.modified, stat.size));
      }
    } on FileSystemException {
      // A file removed while enumerating must not hide the remaining exports.
    }
  }
  files.sort((a, b) => b.modified.compareTo(a.modified));
  return files;
}
