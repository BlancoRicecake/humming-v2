// Generates assets/sounds/808.sf2 — a minimal, single-preset SoundFont holding
// a synthetic 808 sub-bass (sine sub + amp envelope + a short downward pitch
// "punch" via the mod-envelope). Bundled so BOTH engines reach it:
//   - live: flutter_midi_pro loads it as a second soundfont (bank 0 / preset 0)
//   - export: dart_melty_soundfont (MeltySynth) loads it to render the bass lane
//
// Run once from mobile/:  dart run tool/gen_808_sf2.dart
//
// The SF2 layout follows the 2.04 spec: RIFF 'sfbk' { INFO, sdta{smpl}, pdta{
// phdr,pbag,pmod,pgen,inst,ibag,imod,igen,shdr} }. One instrument zone points at
// one looped sine sample; one preset zone points at that instrument.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const int sampleRate = 44100;
const int rootKey = 36; // C2 — generate the sine near this pitch to avoid heavy resampling

// SF2 generator opcodes used below.
const int genModEnvToPitch = 7;
const int genAttackModEnv = 26;
const int genHoldModEnv = 27;
const int genDecayModEnv = 28;
const int genSustainModEnv = 29;
const int genReleaseModEnv = 30;
const int genAttackVolEnv = 34;
const int genHoldVolEnv = 35;
const int genDecayVolEnv = 36;
const int genSustainVolEnv = 37;
const int genReleaseVolEnv = 38;
const int genInitialAttenuation = 48;
const int genSampleID = 53;
const int genSampleModes = 54;
const int genOverridingRootKey = 58;
const int genInstrument = 41;

// seconds -> timecents (1200*log2(sec)).
int tc(double sec) => (1200 * (math.log(sec) / math.ln2)).round();

double tanh(double x) {
  if (x > 20) return 1;
  if (x < -20) return -1;
  final e = math.exp(2 * x);
  return (e - 1) / (e + 1);
}

void main() {
  // 1. synth the sine sub. Integer-sample cycle so the loop is seamless;
  // period 674 ~= 65.43Hz ~= C2.
  const period = 674;
  const cycles = 12;
  final body = period * cycles;
  final loopStart = period * 2; // a couple cycles of lead-in for interpolation
  final loopEnd = period * (cycles - 2);

  final pcm = Int16List(body + 46); // +46 zero guard samples (spec)
  // Additive harmonics + soft saturation: a pure sine reads as weak/dull on a
  // phone speaker, so we add a few integer harmonics (loop stays seamless) and
  // tanh-saturate for body and punch — closer to a real 808's growl.
  const weights = [1.0, 0.5, 0.33, 0.16, 0.08]; // h1..h5
  final norm = weights.reduce((a, b) => a + b);
  for (var i = 0; i < body; i++) {
    final ph = 2 * math.pi * (i % period) / period;
    var s = 0.0;
    for (var h = 0; h < weights.length; h++) {
      s += weights[h] * math.sin((h + 1) * ph);
    }
    s = tanh((s / norm) * 1.8);
    pcm[i] = (s * 31000).round().clamp(-32768, 32767);
  }
  final smpl = Uint8List(pcm.length * 2);
  final smplBd = ByteData.sublistView(smpl);
  for (var i = 0; i < pcm.length; i++) {
    smplBd.setInt16(i * 2, pcm[i], Endian.little);
  }

  // ---- byte helpers ----
  void u32(BytesBuilder b, int v) {
    final d = ByteData(4)..setUint32(0, v, Endian.little);
    b.add(d.buffer.asUint8List());
  }

  void u16(BytesBuilder b, int v) {
    final d = ByteData(2)..setUint16(0, v & 0xffff, Endian.little);
    b.add(d.buffer.asUint8List());
  }

  void u8(BytesBuilder b, int v) => b.add(Uint8List.fromList([v & 0xff]));
  void s8(BytesBuilder b, int v) {
    final d = ByteData(1)..setInt8(0, v);
    b.add(d.buffer.asUint8List());
  }

  void writeName(BytesBuilder b, String name, int len) {
    final bytes = Uint8List(len);
    for (var i = 0; i < name.length && i < len - 1; i++) {
      bytes[i] = name.codeUnitAt(i);
    }
    b.add(bytes);
  }

  Uint8List ascii(String s) => Uint8List.fromList(s.codeUnits);

  // null-terminated, even-length INFO string (a trailing pad on the last field
  // would otherwise be misread as the next chunk id).
  Uint8List zstr(String s) {
    final b = <int>[...s.codeUnits, 0];
    if (b.length.isOdd) b.add(0);
    return Uint8List.fromList(b);
  }

  Uint8List chunk(String id, Uint8List data) {
    final b = BytesBuilder();
    b.add(ascii(id));
    u32(b, data.length);
    b.add(data);
    if (data.length.isOdd) b.add(Uint8List(1));
    return b.toBytes();
  }

  // 2. pdta records.
  // shdr: the sample + terminal EOS record (46 bytes each).
  final shdr = BytesBuilder();
  writeName(shdr, '808 sine', 20);
  u32(shdr, 0); // start
  u32(shdr, body); // end
  u32(shdr, loopStart);
  u32(shdr, loopEnd);
  u32(shdr, sampleRate);
  u8(shdr, rootKey); // originalPitch
  s8(shdr, 0); // pitchCorrection
  u16(shdr, 0); // sampleLink
  u16(shdr, 1); // sampleType = monoSample
  writeName(shdr, 'EOS', 20);
  u32(shdr, 0);
  u32(shdr, 0);
  u32(shdr, 0);
  u32(shdr, 0);
  u32(shdr, 0);
  u8(shdr, 0);
  s8(shdr, 0);
  u16(shdr, 0);
  u16(shdr, 0);

  // igen: the instrument zone's generators, terminated by sampleID (must be last).
  final igen = BytesBuilder();
  void gen(int op, int amount) {
    u16(igen, op);
    u16(igen, amount);
  }

  gen(genAttackVolEnv, tc(0.002));
  gen(genHoldVolEnv, tc(0.001));
  gen(genDecayVolEnv, tc(1.6)); // slow decay -> rings out, but stays present
  gen(genSustainVolEnv, 40); // hold near full (~-4dB) so it's audible on phones
  gen(genReleaseVolEnv, tc(0.8)); // long tail after note-off
  gen(genAttackModEnv, tc(0.001));
  gen(genHoldModEnv, tc(0.001));
  gen(genDecayModEnv, tc(0.10)); // the "dow" glide time
  gen(genSustainModEnv, 1000); // env decays fully -> pitch returns to base
  gen(genReleaseModEnv, tc(0.10));
  gen(genModEnvToPitch, 1800); // +1.5oct punch that glides down (trap 808)
  gen(genInitialAttenuation, 0);
  gen(genOverridingRootKey, rootKey);
  gen(genSampleModes, 1); // loop continuously
  gen(genSampleID, 0); // sampleID — the real last generator
  final igenRealCount = igen.length ~/ 4; // count BEFORE the terminal record
  gen(0, 0); // terminal generator record (readers drop the final record)

  // ibag: one zone + terminal. Terminal genNdx = real generator count.
  final ibag = BytesBuilder();
  u16(ibag, 0);
  u16(ibag, 0);
  u16(ibag, igenRealCount);
  u16(ibag, 0);

  // imod: terminal only.
  final imod = BytesBuilder();
  for (var i = 0; i < 10; i++) {
    u8(imod, 0);
  }

  // inst: one instrument + terminal.
  final inst = BytesBuilder();
  writeName(inst, '808 Bass', 20);
  u16(inst, 0);
  writeName(inst, 'EOI', 20);
  u16(inst, 1);

  // pgen: preset zone -> instrument 0, plus a terminal record.
  final pgen = BytesBuilder();
  u16(pgen, genInstrument);
  u16(pgen, 0);
  final pgenRealCount = pgen.length ~/ 4; // count BEFORE the terminal record
  u16(pgen, 0); // terminal generator record
  u16(pgen, 0);
  // pbag: one zone + terminal. Terminal genNdx = real generator count.
  final pbag = BytesBuilder();
  u16(pbag, 0);
  u16(pbag, 0);
  u16(pbag, pgenRealCount);
  u16(pbag, 0);
  // pmod: terminal only.
  final pmod = BytesBuilder();
  for (var i = 0; i < 10; i++) {
    u8(pmod, 0);
  }

  // phdr: one preset (bank 0 / preset 0) + terminal EOP.
  final phdr = BytesBuilder();
  writeName(phdr, '808 Bass', 20);
  u16(phdr, 0); // preset
  u16(phdr, 0); // bank
  u16(phdr, 0); // presetBagNdx
  u32(phdr, 0);
  u32(phdr, 0);
  u32(phdr, 0);
  writeName(phdr, 'EOP', 20);
  u16(phdr, 0);
  u16(phdr, 0);
  u16(phdr, 1);
  u32(phdr, 0);
  u32(phdr, 0);
  u32(phdr, 0);

  // 3. assemble RIFF.
  final info = BytesBuilder();
  final ifil = ByteData(4)
    ..setUint16(0, 2, Endian.little)
    ..setUint16(2, 4, Endian.little);
  info.add(chunk('ifil', ifil.buffer.asUint8List()));
  info.add(chunk('isng', zstr('EMU8000')));
  info.add(chunk('INAM', zstr('HumTrack 808')));
  final infoList = BytesBuilder()
    ..add(ascii('INFO'))
    ..add(info.toBytes());

  final sdta = BytesBuilder()
    ..add(ascii('sdta'))
    ..add(chunk('smpl', smpl));

  final pdta = BytesBuilder()
    ..add(ascii('pdta'))
    ..add(chunk('phdr', phdr.toBytes()))
    ..add(chunk('pbag', pbag.toBytes()))
    ..add(chunk('pmod', pmod.toBytes()))
    ..add(chunk('pgen', pgen.toBytes()))
    ..add(chunk('inst', inst.toBytes()))
    ..add(chunk('ibag', ibag.toBytes()))
    ..add(chunk('imod', imod.toBytes()))
    ..add(chunk('igen', igen.toBytes()))
    ..add(chunk('shdr', shdr.toBytes()));

  final sfbk = BytesBuilder()
    ..add(ascii('sfbk'))
    ..add(chunk('LIST', infoList.toBytes()))
    ..add(chunk('LIST', sdta.toBytes()))
    ..add(chunk('LIST', pdta.toBytes()));

  final riff = BytesBuilder()
    ..add(ascii('RIFF'))
    ..add((ByteData(4)..setUint32(0, sfbk.length, Endian.little)).buffer.asUint8List())
    ..add(sfbk.toBytes());

  final out = File('assets/sounds/808.sf2');
  out.writeAsBytesSync(riff.toBytes());
  stdout.writeln('wrote ${out.path}: ${riff.length} bytes '
      '(sample $body frames, loop $loopStart..$loopEnd, root $rootKey)');
}
