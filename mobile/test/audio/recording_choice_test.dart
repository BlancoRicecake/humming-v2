// QA 2026-10-30 P1-01: the hum take's codec and container are chosen together
// per platform (Windows has no Opus output in record_windows 1.0.7).
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/audio/container.dart';
import 'package:record/record.dart';

void main() {
  RecordingChoice pick(RecordingPlatform p, [int? sdk]) =>
      selectHumRecording(platform: p, androidSdkInt: sdk);

  test('Windows records WAV (.wav), never Opus', () {
    final c = pick(RecordingPlatform.windows);
    expect(c.codec, RecordingCodec.wav);
    expect(c.extension, '.wav');
    expect(c.encoder, AudioEncoder.wav);
    expect(pick(RecordingPlatform.windows, 34).codec, isNot(RecordingCodec.opus));
  });

  test('iOS and Android keep their codecs; Android below API 29 keeps AAC-LC', () {
    expect(pick(RecordingPlatform.ios), const RecordingChoice(RecordingCodec.opus, '.caf'));
    expect(pick(RecordingPlatform.android, 29), const RecordingChoice(RecordingCodec.opus, '.ogg'));
    expect(pick(RecordingPlatform.android, 34), const RecordingChoice(RecordingCodec.opus, '.ogg'));
    expect(pick(RecordingPlatform.android, 28), const RecordingChoice(RecordingCodec.aacLc, '.m4a'));
    expect(pick(RecordingPlatform.android), const RecordingChoice(RecordingCodec.opus, '.ogg'), reason: 'SDK unknown');
    // the older helpers agree
    expect(opusSupported(28), isFalse);
    expect(takeContainerExt(opus: false), '.m4a');
  });

  test('macOS / Linux are unchanged (Opus, not verified on those machines yet)', () {
    expect(pick(RecordingPlatform.macos).codec, RecordingCodec.opus);
    expect(pick(RecordingPlatform.linux).codec, RecordingCodec.opus);
  });

  test('every choice maps to the matching encoder', () {
    expect(const RecordingChoice(RecordingCodec.aacLc, '.m4a').encoder, AudioEncoder.aacLc);
    expect(const RecordingChoice(RecordingCodec.opus, '.ogg').encoder, AudioEncoder.opus);
  });
}
