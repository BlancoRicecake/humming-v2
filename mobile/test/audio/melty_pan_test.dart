// mixer-001: the live MeltySynth path remembers each channel's CC10 and
// re-sends it when the channel moves to another soundfont's synth, and the
// output block is interleaved stereo with the same gain/limiter per side.
import 'package:dart_melty_soundfont/dart_melty_soundfont.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/audio/melty_synth_backend.dart';

class _FakeSynth implements Synthesizer {
  _FakeSynth([this.l = 0, this.r = 0]);
  final double l, r;
  final List<List<int>> messages = [];

  @override
  void processMidiMessage({
    required int channel,
    required int command,
    required int data1,
    required int data2,
  }) => messages.add([channel, command, data1, data2]);

  @override
  void render(Float32List left, Float32List right) {
    left.fillRange(0, left.length, l);
    right.fillRange(0, right.length, r);
  }

  @override
  void noteOffAll({int? channel, bool immediate = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;

  List<List<int>> get pans =>
      messages.where((m) => m[1] == 0xB0 && m[2] == 0x0A).toList();
}

void main() {
  final engine = MeltyEngine();
  setUp(engine.debugReset);
  tearDown(engine.debugReset);

  test('CC10 is re-sent to the new synth when a channel is rebound', () {
    final main = _FakeSynth(), s808 = _FakeSynth();
    engine.debugSetMain(main);
    engine.controlChange(0, 10, 32);
    expect(main.pans, [
      [0, 0xB0, 0x0A, 32],
    ]);
    engine.debugBind(0, s808); // instrument swap to the 808 soundfont
    expect(s808.pans, [
      [0, 0xB0, 0x0A, 32],
    ]);
    // rebinding to the same synth doesn't spam it
    engine.debugBind(0, s808);
    expect(s808.pans, hasLength(1));
    // later changes go to the bound synth only
    engine.controlChange(0, 10, 100);
    expect(s808.pans.last, [0, 0xB0, 0x0A, 100]);
    expect(main.pans, hasLength(1));
    // a channel with no pan set sends nothing on bind
    engine.debugBind(1, s808);
    expect(s808.pans.where((m) => m[0] == 1), isEmpty);
  });

  test('pan set before load is held and sent on bind', () {
    engine.controlChange(9, 10, 127); // nothing loaded yet: no crash
    final kit = _FakeSynth();
    engine.debugBind(9, kit);
    expect(kit.pans, [
      [9, 0xB0, 0x0A, 127],
    ]);
  });

  test('output block is interleaved L/R with the same limiter per side', () {
    final out = engine.debugRenderBlock(_FakeSynth(0.1, -0.2));
    expect(out.length.isEven, isTrue);
    expect(out[0], MeltyEngine.pcm16(0.1 * 1.5));
    expect(out[1], MeltyEngine.pcm16(-0.2 * 1.5));
    expect(out[out.length - 2], out[0]);
    expect(out[out.length - 1], out[1]);
    // a centred source (L == R) yields identical sides at the old mono level
    final c = engine.debugRenderBlock(_FakeSynth(0.25, 0.25));
    expect(c[0], c[1]);
    expect(c[0], MeltyEngine.pcm16((0.25 + 0.25) / 2 * 1.5));
  });
}
