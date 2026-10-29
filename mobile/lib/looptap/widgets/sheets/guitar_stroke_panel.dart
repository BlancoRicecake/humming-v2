// gt-001 expanded guitar stroke controls: spread (ms), falloff and accent
// per direction, plus "일반으로 되돌리기". Values live in LoopPrefs so the
// basic ↓ / ↑ / pattern chips in the piano roll use the last settings.
// gt-002 adds the string section: "줄 배정", "울림 아르페지오", "울림 되돌리기",
// the string number view, a manual string choice and the limitation hints.
// gt-003 adds the "연주법" row: 일반 / 짧게 / 팜뮤트 근사 / 하모닉스 근사, with
// the approximation labels and the last apply's counts.
// gt-004 adds "줄별 울림 유지" next to the string actions, with its last
// result line ("연장 N · 그대로 M" plus reasons).
import 'package:flutter/material.dart';
import '../../theme/tokens.dart';

import '../../models/loop_models.dart'
    show
        ArticulationKind,
        StrokeDir,
        kHarmonicToneHi,
        kHarmonicToneLo,
        kPalmToneHi,
        kPalmToneLo;
import '../../music/guitar_articulation.dart' show ArtRole;
import '../../music/guitar_stroke.dart';
import '../../state/loop_prefs.dart';

/// The stroke the user's saved settings describe for [dir].
StrokeSpec currentStrokeSpec(StrokeDir dir) {
  final p = LoopPrefs.instance;
  final down = dir == StrokeDir.down;
  return StrokeSpec(
    dir: dir,
    spreadMs: (down ? p.strokeDownSpread : p.strokeUpSpread).value.toDouble(),
    falloff: p.strokeFalloff.value / 100,
    accent: (down ? p.strokeDownAccent : p.strokeUpAccent).value / 100,
  ).clamped;
}

/// What the expanded panel asked for.
enum GuitarStrokeAction {
  down,
  up,
  pattern,
  revert,
  // gt-002
  assignStrings,
  ring,
  revertRing,
  toggleStringView,
  setString,
  autoString,
  // gt-003: [GuitarPanelResult.kind] null = 일반으로
  articulation,
  // gt-004 줄별 울림 유지
  sustain,
}

/// The panel's choice; [string] is set for [GuitarStrokeAction.setString],
/// [kind] for [GuitarStrokeAction.articulation] (null = back to normal).
typedef GuitarPanelResult =
    ({GuitarStrokeAction action, int? string, ArticulationKind? kind});

Future<GuitarPanelResult?> showGuitarStrokePanel(
  BuildContext context, {
  required bool canApply,
  required bool canRevert,
  bool canAssign = false,
  bool canRing = false,
  bool canRevertRing = false,
  bool canChooseString = false,
  Set<int> playableStrings = const {},
  bool stringView = false,
  bool grooved = false,
  int selectedCount = 0,
  bool canArticulate = false,
  String? articulationResult,
  List<ArtRole> articulationShort = const [],
  String? naturalHarmonicInfo,
  bool canSustain = false,
  String? sustainResult,
}) {
  final prefs = LoopPrefs.instance;
  final ko = Localizations.localeOf(context).languageCode == 'ko';
  Widget slider(
    StateSetter setSheet,
    String key,
    String label,
    ValueNotifier<int> value,
    int min,
    int max,
    String unit,
    Future<void> Function(int v) save,
  ) => Row(
    children: [
      SizedBox(
        width: 150,
        child: Text('$label ${value.value}$unit'),
      ),
      Expanded(
        child: Slider(
          key: ValueKey(key),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: max - min,
          value: value.value.clamp(min, max).toDouble(),
          onChanged: (v) => setSheet(() => value.value = v.round()),
          onChangeEnd: (v) => save(v.round()),
        ),
      ),
    ],
  );
  GuitarPanelResult pick(
    GuitarStrokeAction a, [
    int? string,
    ArticulationKind? kind,
  ]) => (action: a, string: string, kind: kind);
  const small = TextStyle(fontSize: 11);
  return showModalBottomSheet<GuitarPanelResult>(
    context: context,
    isScrollControlled: true,
    builder:
        (context) => StatefulBuilder(
          builder:
              (context, setSheet) => SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(ko ? '기타 스트로크' : 'Guitar stroke'),
                    Text(
                      key: const ValueKey('guitar-panel-scope'),
                      selectedCount > 0
                          ? (ko
                              ? '선택한 노트 $selectedCount개에 적용'
                              : 'Applies to $selectedCount selected notes')
                          : (ko
                              ? '선택 없음 = 트랙 전체에 적용'
                              : 'Nothing selected = whole track'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    slider(
                      setSheet,
                      'stroke-down-spread',
                      ko ? '↓ 간격' : '↓ Spread',
                      prefs.strokeDownSpread,
                      5,
                      60,
                      ' ms',
                      (v) => prefs.setStroke(downSpread: v),
                    ),
                    slider(
                      setSheet,
                      'stroke-up-spread',
                      ko ? '↑ 간격' : '↑ Spread',
                      prefs.strokeUpSpread,
                      5,
                      60,
                      ' ms',
                      (v) => prefs.setStroke(upSpread: v),
                    ),
                    slider(
                      setSheet,
                      'stroke-falloff',
                      ko ? '줄별 감쇠' : 'Falloff',
                      prefs.strokeFalloff,
                      0,
                      40,
                      '%',
                      (v) => prefs.setStroke(falloff: v),
                    ),
                    slider(
                      setSheet,
                      'stroke-down-accent',
                      ko ? '↓ 세기' : '↓ Accent',
                      prefs.strokeDownAccent,
                      50,
                      130,
                      '%',
                      (v) => prefs.setStroke(downAccent: v),
                    ),
                    slider(
                      setSheet,
                      'stroke-up-accent',
                      ko ? '↑ 세기' : '↑ Accent',
                      prefs.strokeUpAccent,
                      50,
                      130,
                      '%',
                      (v) => prefs.setStroke(upAccent: v),
                    ),
                    Text(
                      ko
                          ? '간격은 현재 BPM에서 박자 단위로 저장됩니다. '
                              'BPM을 바꾼 뒤 다시 적용하면 다시 계산됩니다.'
                          : 'Spread is stored in beats at the current BPM. '
                              'Re-apply after a tempo change to recompute it.',
                      style: const TextStyle(fontSize: 11),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton(
                          key: const ValueKey('stroke-panel-revert'),
                          onPressed:
                              canRevert
                                  ? () => Navigator.of(
                                    context,
                                  ).pop(pick(GuitarStrokeAction.revert))
                                  : null,
                          child: Text(ko ? '일반으로 되돌리기' : 'Back to normal'),
                        ),
                        FilledButton(
                          key: const ValueKey('stroke-panel-down'),
                          onPressed:
                              canApply
                                  ? () => Navigator.of(
                                    context,
                                  ).pop(pick(GuitarStrokeAction.down))
                                  : null,
                          child: Text(ko ? '↓ 적용' : 'Apply ↓'),
                        ),
                        FilledButton(
                          key: const ValueKey('stroke-panel-up'),
                          onPressed:
                              canApply
                                  ? () => Navigator.of(
                                    context,
                                  ).pop(pick(GuitarStrokeAction.up))
                                  : null,
                          child: Text(ko ? '↑ 적용' : 'Apply ↑'),
                        ),
                        FilledButton(
                          key: const ValueKey('stroke-panel-pattern'),
                          onPressed:
                              canApply
                                  ? () => Navigator.of(
                                    context,
                                  ).pop(pick(GuitarStrokeAction.pattern))
                                  : null,
                          child: Text(
                            '${ko ? '패턴 적용' : 'Apply pattern'} '
                            '${strokePatternById(prefs.strokePattern.value).label}',
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 24),
                    Text(ko ? '연주법' : 'Technique'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final (key, label, kind) in [
                          ('articulation-normal', ko ? '일반' : 'Normal', null),
                          (
                            'articulation-staccato',
                            ko ? '짧게' : 'Short',
                            ArticulationKind.staccato,
                          ),
                          (
                            'articulation-palm',
                            ko ? '팜뮤트 근사' : 'Palm-mute tone (approx.)',
                            ArticulationKind.palmTone,
                          ),
                          (
                            'articulation-harmonic',
                            ko ? '하모닉스 근사' : 'Harmonic tone (approx.)',
                            ArticulationKind.harmonicTone,
                          ),
                        ])
                          OutlinedButton(
                            key: ValueKey(key),
                            onPressed:
                                canArticulate
                                    ? () => Navigator.of(context).pop(
                                      pick(
                                        GuitarStrokeAction.articulation,
                                        null,
                                        kind,
                                      ),
                                    )
                                    : null,
                            child: Text(label),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      key: const ValueKey('articulation-labels'),
                      ko
                          ? '짧게: 같은 기타 소리를 '
                              '${prefs.articulationStaccatoMs.value} ms로 짧게 '
                              '(팜뮤트 아님).\n'
                              '팜뮤트 근사: GM 뮤트 기타 음색(일렉) — 실제 나일론 '
                              '팜뮤트 녹음 아님. 음역 MIDI '
                              '$kPalmToneLo–$kPalmToneHi.\n'
                              '하모닉스 근사: GM 하모닉스 음색. 소리 나는 음 MIDI '
                              '$kHarmonicToneLo–$kHarmonicToneHi만 지원 '
                              '(범위 밖은 바꾸지 않음).'
                          : 'Short: the same guitar sound, cut to '
                              '${prefs.articulationStaccatoMs.value} ms (not '
                              'palm mute).\n'
                              'Palm-mute tone: approximation with the GM muted '
                              '(electric) guitar tone, not a recorded nylon palm '
                              'mute. Range MIDI $kPalmToneLo–$kPalmToneHi.\n'
                              'Harmonic tone: approximation with the GM '
                              'harmonics tone, sounding pitch MIDI '
                              '$kHarmonicToneLo–$kHarmonicToneHi only (others '
                              'are not changed).',
                      style: small,
                    ),
                    if (naturalHarmonicInfo != null)
                      Text(
                        key: const ValueKey('articulation-natural-info'),
                        naturalHarmonicInfo,
                        style: small,
                      ),
                    if (articulationShort.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          key: const ValueKey('articulation-short-badge'),
                          ko
                              ? '음색 근사 불가 (채널 부족): 이 트랙의 '
                                  '${articulationShort.map((r) => r == ArtRole.muteVoice ? '팜뮤트' : '하모닉스').join('·')}'
                                  ' 노트는 일반 음으로 재생됩니다.'
                              : 'Tone approximation unavailable (no free '
                                  'channel): those notes play as normal.',
                          style: const TextStyle(
                            fontSize: 11,
                            color: LT.amber,
                          ),
                        ),
                      ),
                    if (articulationResult != null)
                      Text(
                        key: const ValueKey('articulation-result'),
                        articulationResult,
                        style: small,
                      ),
                    const Divider(height: 24),
                    Text(
                      ko
                          ? '기타 줄 (표준 튜닝, 1번 = 높은 E)'
                          : 'Guitar strings (standard tuning, 1 = high E)',
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton(
                          key: const ValueKey('guitar-assign'),
                          onPressed:
                              canAssign
                                  ? () => Navigator.of(context).pop(
                                    pick(GuitarStrokeAction.assignStrings),
                                  )
                                  : null,
                          child: Text(ko ? '줄 배정' : 'Assign strings'),
                        ),
                        FilledButton(
                          key: const ValueKey('guitar-ring'),
                          onPressed:
                              canRing
                                  ? () => Navigator.of(
                                    context,
                                  ).pop(pick(GuitarStrokeAction.ring))
                                  : null,
                          child: Text(ko ? '울림 아르페지오' : 'Ringing arpeggio'),
                        ),
                        FilledButton(
                          key: const ValueKey('guitar-sustain'),
                          onPressed:
                              canSustain
                                  ? () => Navigator.of(
                                    context,
                                  ).pop(pick(GuitarStrokeAction.sustain))
                                  : null,
                          child: Text(ko ? '줄별 울림 유지' : 'Keep strings ringing'),
                        ),
                        OutlinedButton(
                          key: const ValueKey('guitar-ring-revert'),
                          onPressed:
                              canRevertRing
                                  ? () => Navigator.of(
                                    context,
                                  ).pop(pick(GuitarStrokeAction.revertRing))
                                  : null,
                          child: Text(ko ? '울림 되돌리기' : 'Undo ringing'),
                        ),
                        OutlinedButton(
                          key: const ValueKey('guitar-string-view'),
                          onPressed:
                              () => Navigator.of(
                                context,
                              ).pop(pick(GuitarStrokeAction.toggleStringView)),
                          child: Text(
                            stringView
                                ? (ko ? '줄 번호 숨기기' : 'Hide string numbers')
                                : (ko ? '줄 번호 보기' : 'Show string numbers'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      key: const ValueKey('guitar-sustain-info'),
                      ko
                          ? '줄별 울림 유지: 같은 화음을 다시 칠 때까지 각 줄을 '
                              '자연스럽게 이어 줍니다. 화음이 바뀌거나 쉼이 있으면 '
                              '그대로 둡니다.'
                          : 'Keep strings ringing: each string rings until the '
                              'same chord is struck again. Chord changes and rests '
                              'are left as they are.',
                      style: small,
                    ),
                    if (sustainResult != null)
                      Text(
                        key: const ValueKey('guitar-sustain-result'),
                        sustainResult,
                        style: small,
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(ko ? '줄 직접 지정' : 'Set string'),
                        for (var string = 1; string <= 6; string++)
                          OutlinedButton(
                            key: ValueKey('guitar-string-$string'),
                            onPressed:
                                canChooseString &&
                                        playableStrings.contains(string)
                                    ? () => Navigator.of(context).pop(
                                      pick(GuitarStrokeAction.setString, string),
                                    )
                                    : null,
                            child: Text('$string'),
                          ),
                        OutlinedButton(
                          key: const ValueKey('guitar-string-auto'),
                          onPressed:
                              canChooseString
                                  ? () => Navigator.of(
                                    context,
                                  ).pop(pick(GuitarStrokeAction.autoString))
                                  : null,
                          child: Text(ko ? '자동' : 'Auto'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      ko
                          ? '같은 줄을 다시 치면 앞 음이 끊기고, 다른 줄은 계속 울립니다. '
                              '같은 음 높이를 두 줄에서 겹쳐 치면(유니즌) 한 MIDI '
                              '채널에서 함께 울릴 수 없어 앞 음이 뒤 음의 시작에서 '
                              '끝납니다. 놓을 수 없는 음은 옮기지 않고 표시만 합니다.'
                          : 'Striking a string again stops its previous note; '
                              'other strings keep ringing. The same pitch on two '
                              'strings (unison) cannot overlap on one MIDI '
                              'channel, so the earlier note ends where the later '
                              'one starts. Notes that do not fit are marked, '
                              'never moved.',
                      style: const TextStyle(fontSize: 11),
                    ),
                    if (grooved)
                      Padding(
                        key: const ValueKey('guitar-groove-hint'),
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          ko
                              ? '이 트랙에는 그루브가 있습니다. 울림과 줄 끊김은 노트 '
                                  '데이터로 계산되고 그루브는 재생·내보내기 때 시작점을 '
                                  '옮기므로, 끊기는 지점이 그루브 이동량만큼 어긋날 수 '
                                  '있습니다.'
                              : 'This track has a groove. Ring and string stops '
                                  'are computed on the note data, and the groove '
                                  'moves onsets at playback and export, so a stop '
                                  "can shift by up to the groove's offset.",
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                  ],
                ),
              ),
        ),
  );
}
