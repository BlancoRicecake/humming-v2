import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/models/models.dart' as eng;
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/vocal_midi.dart';
import 'package:humming/looptap/music/wav_codec.dart';

eng.AnalyzeResponse response(List<Map<String, dynamic>> notes) =>
    eng.AnalyzeResponse.fromJson({
      'notes': notes,
      'waveform': <String, dynamic>{},
    });
Map<String, dynamic> note(int step, {int pitch = 64, int dur = 4}) => {
  'pitch': pitch,
  'pitch_original': pitch,
  'kind': 'pitched',
  'step': step,
  'dur_steps': dur,
  'confidence': .9,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Uint8List source() => encodeWavMono16(
    Float32List.fromList(List.generate(32000, (i) => i < 16000 ? .25 : .5)),
    16000,
  );
  Map<String, Object> input(VocalClip clip, {double swing = 0}) => {
    'bytes': source(),
    'clip': clip,
    'bpm': 120,
    'bars': 2,
    'swing': swing,
  };

  test(
    'only trimmed samples enter the upload, at the original section position',
    () {
      final clip = VocalClip(
        path: 'source.wav',
        trimStart: 16000,
        trimEnd: 24000,
        startStep: 3,
      );
      final audio = prepareVocalMidiAudio(input(clip, swing: .4));
      final decoded = parseWav(audio.wav)!;
      expect(audio.duration, .5);
      expect(audio.offsetSeconds, closeTo(.375, .00001));
      expect(decoded.samples.length, 14000);
      expect(decoded.samples.take(6000).every((v) => v == 0), isTrue);
      expect(decoded.samples[6000], closeTo(.5, .0001));
      expect(clip.trimStart, 16000);
      expect(clip.startStep, 3);
    },
  );

  test(
    'out-of-section selection is rejected instead of silently dropping audio',
    () {
      expect(
        () => prepareVocalMidiAudio(
          input(VocalClip(path: 'source.wav', startStep: 30)),
        ),
        throwsA(
          isA<VocalMidiException>().having(
            (e) => e.reason,
            'reason',
            VocalMidiFailure.outsideSection,
          ),
        ),
      );
      expect(
        () => prepareVocalMidiAudio(
          input(
            VocalClip(path: 'source.wav', trimStart: 16000, trimEnd: 16000),
          ),
        ),
        throwsA(
          isA<VocalMidiException>().having(
            (e) => e.reason,
            'reason',
            VocalMidiFailure.invalidAudio,
          ),
        ),
      );
    },
  );

  test(
    'mapped notes respect section position and end, and reject empty results',
    () {
      final notes = vocalMidiNotes(
        response([
          note(0),
          note(3),
          note(3),
          note(31, dur: 8),
          note(32),
          {...note(4), 'kind': 'drum'},
        ]),
        bpm: 120,
        bars: 2,
        startStep: 3,
      );
      expect(notes.map((n) => n.step), [3, 31]);
      expect(notes.last.dur, 1);
      expect(notes.first.sourceMidi, 64);
      expect(
        () => vocalMidiNotes(response([]), bpm: 120, bars: 2, startStep: 0),
        throwsA(isA<VocalMidiException>()),
      );
    },
  );

  test(
    'new track preserves existing vocal/notes and round-trips with every section',
    () {
      final sections = [
        Section(id: 'a', name: 'A'),
        Section(id: 'b', name: 'B'),
      ];
      final vocal = TrackData(clips: [VocalClip(path: 'original.wav')]);
      sections[1].tracks['vocal'] = vocal;
      sections[1].tracks['melody'] = TrackData(
        notes: [PitchNote(midi: 60, freq: 261.6, step: 0)],
      );
      final before = sections.map((s) => s.deepCopy()).toList();
      final result = VocalMidiResult(
        vocalMidiNotes(response([note(3)]), bpm: 120, bars: 2, startStep: 3),
        24,
      );
      addVocalMidiTrack(sections, 'b', 'melody_new', result);
      expect(identical(sections[1].tracks['vocal'], vocal), isTrue);
      expect(sections[1].tracks['melody']!.pitchNotes.single.midi, 60);
      expect(sections[0].tracks['melody_new']!.pitchNotes, isEmpty);
      expect(sections[1].tracks['melody_new']!.pitchNotes.single.step, 3);
      final saved = sections.map((s) => Section.fromJson(s.toJson())).toList();
      expect(
        saved[1].tracks['vocal']!.effectiveClips.single.path,
        'original.wav',
      );
      expect(saved[1].extras.single.id, 'melody_new');
      expect(saved[1].tracks['melody_new']!.pitchNotes.single.midi, 64);
      expect(before[1].tracks.containsKey('melody_new'), isFalse);
      expect(
        before[1].tracks['vocal']!.effectiveClips.single.path,
        'original.wav',
      );
      expect(
        () => addVocalMidiTrack(sections, 'missing', 'bad', result),
        throwsStateError,
      );
      expect(sections.every((s) => !s.tracks.containsKey('bad')), isTrue);
    },
  );

  test(
    'guidance uses only an empty melody lane, preserving an existing melody',
    () {
      final section = Section(id: 'a', name: 'A');
      section.tracks['vocal'] = TrackData(
        clips: [VocalClip(path: 'original.wav')],
      );
      final result = VocalMidiResult(
        vocalMidiNotes(response([note(3)]), bpm: 120, bars: 2, startStep: 3),
        24,
      );
      expect(
        addVocalMidiTrack(
          [section],
          'a',
          'first',
          result,
          useEmptyMelodyLane: true,
        ),
        'melody',
      );
      expect(section.extras, isEmpty);
      expect(
        section.tracks['vocal']!.effectiveClips.single.path,
        'original.wav',
      );
      expect(section.tracks['melody']!.pitchNotes.single.step, 3);
      final second = VocalMidiResult([
        PitchNote(midi: 70, freq: 466, step: 8),
      ], 80);
      expect(
        addVocalMidiTrack(
          [section],
          'a',
          'second',
          second,
          useEmptyMelodyLane: true,
        ),
        'second',
      );
      expect(section.tracks['melody']!.pitchNotes.single.step, 3);
      expect(section.tracks['second']!.pitchNotes.single.midi, 70);
    },
  );

  test('preview omits placement silence while preserving fade and gain', () {
    final audio = prepareVocalMidiAudio(
      input(
        VocalClip(
          path: 'source.wav',
          trimStart: 16000,
          trimEnd: 24000,
          startStep: 3,
          gain: .5,
          fadeInMs: 10,
        ),
      ),
    );
    final preview = parseWav(audio.previewWav!)!;
    final upload = parseWav(audio.wav)!;
    expect(preview.samples.length, 8000);
    expect(upload.samples.length, 14000);
    expect(preview.samples.first, closeTo(0, .0001));
    expect(preview.samples[1000], closeTo(.25, .0001));
  });

  for (final mode in ['success', 'failure', 'no_notes']) {
    test('source file survives $mode; temporary upload is cleaned', () async {
      final root = await Directory.systemTemp.createTemp(
        'humtrack_vocal_midi_test_',
      );
      try {
        final file = File('${root.path}/original.wav');
        final bytes = source();
        await file.writeAsBytes(bytes);
        String? uploadedPath;
        final service = VocalMidiService(
          temporaryDirectory: root,
          analyze: (path, options) async {
            uploadedPath = path;
            expect(path, isNot(file.path));
            expect(options.loopBars, 2);
            expect(options.loopQuantize, isTrue);
            expect(options.scale, 'minor_pentatonic');
            if (mode == 'failure') throw const SocketException('offline');
            return response(mode == 'no_notes' ? [] : [note(3)]);
          },
        );
        final future = service.convert(
          VocalClip(
            path: file.path,
            trimStart: 16000,
            trimEnd: 24000,
            startStep: 3,
          ),
          bpm: 120,
          bars: 2,
          keyRoot: 'C',
          scale: 'pentatonic',
          swing: .4,
        );
        if (mode == 'success') {
          final result = await future;
          expect(result.notes.single.step, 3);
          expect(await result.preview.exists(), isTrue);
          await result.dispose();
        } else {
          await expectLater(future, throwsA(isA<Exception>()));
        }
        expect(await file.readAsBytes(), bytes);
        expect(uploadedPath, isNotNull);
        expect(await File(uploadedPath!).exists(), isFalse);
        expect(await root.list().where((e) => e is Directory).length, 0);
      } finally {
        expect(
          root.absolute.path.startsWith(Directory.systemTemp.absolute.path),
          isTrue,
        );
        await root.delete(recursive: true);
      }
    });
  }
}
