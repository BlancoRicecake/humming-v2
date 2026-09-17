import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import '../music/wav_codec.dart';

/// Separate from song vocals: song cleanup never removes reusable samples.
class SampleLibrary {
  SampleLibrary({this.root});
  final Directory? root;
  Future<Directory> folder() async {
    final base = root ?? await getApplicationDocumentsDirectory();
    return Directory(
      '${base.path}${Platform.pathSeparator}looptap${Platform.pathSeparator}samples',
    )..createSync(recursive: true);
  }

  Future<List<File>> list() async {
    final files =
        await (await folder())
            .list()
            .where((e) => e is File && e.path.endsWith('.wav'))
            .cast<File>()
            .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  Future<WavData> read(File file) async {
    if (await file.length() > 24 * 1024 * 1024) {
      throw const FormatException('sampleTooLarge');
    }
    final wave = parseWav(await file.readAsBytes());
    if (wave == null ||
        wave.sampleRate < 8000 ||
        wave.sampleRate > 96000 ||
        wave.samples.length < wave.sampleRate / 100 ||
        wave.samples.length > wave.sampleRate * 60) {
      throw const FormatException('sampleFormat');
    }
    return wave;
  }

  Future<File> import(File source) async {
    final wave = await read(source);
    return save(wave.samples, wave.sampleRate);
  }

  Future<File> save(Float32List samples, int rate) async {
    final file = File(
      '${(await folder()).path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(encodeWavMono16(samples, rate), flush: true);
    return tmp.rename(file.path);
  }
}

/// Range selection is non-destructive; a tiny edge fade avoids cut clicks.
Float32List selectSample(WavData wave, double start, double end) {
  final n = wave.samples.length;
  final a = (start.clamp(0, 1) * n).floor().clamp(0, n - 1);
  final b = (end.clamp(0, 1) * n).ceil().clamp(a + 1, n);
  final selected = Float32List.fromList(wave.samples.sublist(a, b));
  final fade = (wave.sampleRate * 0.005).round().clamp(0, selected.length ~/ 2);
  for (var i = 0; i < fade; i++) {
    selected[i] *= i / fade;
    selected[selected.length - 1 - i] *= i / fade;
  }
  return selected;
}
