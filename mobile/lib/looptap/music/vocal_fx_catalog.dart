import '../models/loop_models.dart';

class VocalEffectChoice {
  const VocalEffectChoice(this.type, this.ko, this.en, this.params);
  final String type, ko, en;
  final Map<String, dynamic> params;
  String label(bool korean) => korean ? ko : en;
  FxNode node({double mix = 1}) =>
      FxNode(type: type, params: {...params, 'mix': mix});
}

/// These effects render locally; the existing six server effects remain valid.
const localVocalEffects = [
  VocalEffectChoice('gate', '노이즈 게이트', 'Noise gate', {'threshold': -42.0}),
  VocalEffectChoice('deess', '치찰음 완화', 'De-esser', {
    'threshold': -28.0,
    'reduction': .7,
  }),
  VocalEffectChoice('saturation', '따뜻한 질감', 'Warm saturation', {'drive': 2.0}),
  VocalEffectChoice('chorus', '코러스', 'Chorus', {
    'rate': .8,
    'depth': 3.0,
    'wet': .35,
  }),
  VocalEffectChoice('doubler', '더블링', 'Doubler', {'depth': 1.8, 'wet': .4}),
  VocalEffectChoice('flanger', '플랜저', 'Flanger', {
    'rate': .3,
    'depth': 1.6,
    'wet': .5,
  }),
  VocalEffectChoice('telephone', '전화기', 'Telephone', {
    'low': 350.0,
    'high': 3200.0,
  }),
  VocalEffectChoice('lofi', '로파이', 'Lo-fi', {'bits': 8.0, 'rate': 8000.0}),
  VocalEffectChoice('tremolo', '트레몰로', 'Tremolo', {'rate': 4.0, 'depth': .65}),
  // Ring modulation gives a metallic robot tone; this is not a speech vocoder.
  VocalEffectChoice('robot', '로봇톤', 'Robot tone', {'rate': 65.0, 'wet': .8}),
];

class VocalEffectPreset {
  const VocalEffectPreset(this.id, this.ko, this.en, this.effects);
  final String id, ko, en;
  final List<Map<String, dynamic>> effects;
  String label(bool korean) => korean ? ko : en;
  List<FxNode> nodes() => [
    for (final f in effects)
      FxNode(
        type: f['type'] as String,
        params: Map<String, dynamic>.from(f)..remove('type'),
      ),
  ];
}

/// Presets replace the sound-design chain while retaining recorded autotune.
const vocalEffectPresets = [
  VocalEffectPreset('clean', '깔끔한 보컬', 'Clean vocal', [
    {'type': 'gate', 'threshold': -44.0},
    {'type': 'deess', 'threshold': -28.0, 'reduction': .6},
  ]),
  VocalEffectPreset('warm', '따뜻한 보컬', 'Warm vocal', [
    {'type': 'deess', 'threshold': -26.0, 'reduction': .5},
    {'type': 'saturation', 'drive': 1.6, 'mix': .6},
  ]),
  VocalEffectPreset('double', '두꺼운 더블링', 'Thick double', [
    {'type': 'doubler', 'wet': .5, 'depth': 2.4},
    {'type': 'saturation', 'drive': 1.5, 'mix': .3},
  ]),
  VocalEffectPreset('choral', '풍성한 코러스', 'Rich chorus', [
    {'type': 'doubler', 'wet': .25, 'depth': 1.5},
    {'type': 'chorus', 'wet': .35, 'depth': 3.5, 'rate': .65},
  ]),
  VocalEffectPreset('phone', '전화 속 목소리', 'Phone call', [
    {'type': 'telephone', 'low': 400.0, 'high': 3000.0},
    {'type': 'saturation', 'drive': 2.5, 'mix': .5},
  ]),
  VocalEffectPreset('cassette', '낡은 테이프', 'Old tape', [
    {'type': 'telephone', 'low': 100.0, 'high': 5000.0, 'mix': .65},
    {'type': 'lofi', 'bits': 10.0, 'rate': 12000.0, 'mix': .65},
    {'type': 'tremolo', 'rate': 1.2, 'depth': .12},
  ]),
  VocalEffectPreset('robot', '로봇 보컬', 'Robot vocal', [
    {'type': 'robot', 'rate': 110.0, 'wet': 1.0},
    {'type': 'telephone', 'low': 180.0, 'high': 4200.0, 'mix': .7},
  ]),
  VocalEffectPreset('underwater', '물속 목소리', 'Underwater', [
    {'type': 'telephone', 'low': 100.0, 'high': 1100.0},
    {'type': 'chorus', 'wet': .45, 'depth': 4.0, 'rate': .45},
  ]),
];

List<FxNode> vocalPresetChain(VocalClip clip, VocalEffectPreset preset) => [
  for (final fx in clip.fx.where((f) => f.type == 'autotune')) fx.copy(),
  ...preset.nodes(),
];
