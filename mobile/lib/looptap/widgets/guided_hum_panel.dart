import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../models/loop_models.dart';
import '../music/theory.dart' show kBeatsPerBar, kStepsPerBeat;
import '../theme/tokens.dart';

/// The guided start (2026-11-02 layout):
/// 1. two ways in — a melody from a hum, or the voice as it is;
/// 2. after a hum: the converted melody drawn like a MIDI clip, my hum and the
///    melody side by side to compare, the instrument and the key (a key change
///    is heard: "hear the new key"), then "make a song with this melody"
///    (→ editor); after a voice take: listen, then make a song with it.
/// No listen / save / undo / saved bar: the editor takes over from there.
///
/// [addTrack] (the editor's logo button, 2026-11-02): the hum becomes a NEW
/// track of the song — pick its instrument, hum (the song plays along),
/// compare / hear it with the song, hum again, then "add this track".
class GuidedHumPanel extends StatelessWidget {
  const GuidedHumPanel({
    super.key,
    required this.hasNotes,
    this.hasMelody,
    required this.playing,
    this.playingTake = false,
    required this.onBack,
    required this.onRecord,
    required this.onListen,
    required this.onInstrument,
    required this.onEdit,
    this.onKey,
    this.onPlayTake,
    this.onSample,
    this.onRecordVocal,
    this.notes = const [],
    this.steps = 64,
    this.playhead,
    this.keyLabel,
    this.keyChanged = false,
    this.instrumentName,
    this.addTrack = false,
  });
  final bool hasNotes, playing, playingTake;
  final bool? hasMelody;
  final VoidCallback onBack, onRecord, onListen, onInstrument, onEdit;
  final VoidCallback? onKey, onPlayTake, onSample, onRecordVocal;

  /// The melody drawn in the clip, its length in steps and the playhead step.
  final List<PitchNote> notes;
  final int steps;
  final ValueListenable<double>? playhead;

  /// The current key and instrument, shown on their buttons.
  final String? keyLabel, instrumentName;

  /// The key was changed after the hum: the melody button plays the new key.
  final bool keyChanged;

  /// Hum into a new track of an existing song (see the class doc).
  final bool addTrack;

  Widget _title(String text) => Text(
    text,
    style: const TextStyle(color: LT.t1, fontSize: 21, fontWeight: FontWeight.bold),
  );

  Widget _body(String text) =>
      Text(text, style: const TextStyle(color: LT.t2, height: 1.4));

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final melody = hasMelody ?? hasNotes;
    final Widget content;
    if (!hasNotes && addTrack) {
      content = Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: LT.surface2,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: LT.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _title(l.ltHumAddTitle),
            const SizedBox(height: 8),
            _body(l.ltHumAddPrepare),
            const SizedBox(height: 12),
            _SettingButton(
              key: const ValueKey('guided-instrument'),
              icon: Icons.piano_outlined,
              label: l.ltHumAddInstrument,
              value: instrumentName,
              onTap: onInstrument,
            ),
            const SizedBox(height: 8),
            _Choice(
              key: const ValueKey('guided-choice-hum'),
              primary: true,
              icon: Icons.mic,
              title: l.ltHumAddRecord,
              description: l.ltHumAddRecordDesc,
              onTap: onRecord,
            ),
          ],
        ),
      );
    } else if (!hasNotes) {
      content = Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: LT.surface2,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: LT.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _title(l.ltGuidedTitle),
            const SizedBox(height: 8),
            _body(l.ltGuidedPrepare),
            const SizedBox(height: 12),
            _Choice(
              key: const ValueKey('guided-choice-hum'),
              primary: true,
              icon: Icons.music_note,
              title: l.ltGuidedHumTitle,
              description: l.ltGuidedHumDesc,
              onTap: onRecord,
            ),
            if (onRecordVocal != null || onSample != null) ...[
              const SizedBox(height: 8),
              _Choice(
                key: const ValueKey('guided-choice-voice'),
                icon: Icons.mic_none,
                title: l.ltGuidedVoiceTitle,
                description: l.ltGuidedVoiceDesc,
                onTap: onRecordVocal ?? onSample!,
                extra:
                    onSample == null || onRecordVocal == null
                        ? null
                        : TextButton.icon(
                          key: const ValueKey('guided-voice-import'),
                          onPressed: onSample,
                          icon: const Icon(Icons.file_open_outlined, size: 18),
                          label: Text(l.ltGuidedVoiceImport),
                        ),
              ),
            ],
          ],
        ),
      );
    } else if (melody) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, color: LT.lime, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: _title(addTrack ? l.ltHumAddReady : l.ltGuidedMelodyReady),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _body(
            addTrack
                ? l.ltHumAddHint
                : (onPlayTake != null ? l.ltGuidedCompareHint : l.ltGuidedMelodyHint),
          ),
          const SizedBox(height: 14),
          // the converted melody, like a MIDI clip
          Container(
            key: const ValueKey('guided-melody-roll'),
            // taller on a tall phone screen, compact in a short window
            height: (MediaQuery.sizeOf(context).height * .3).clamp(120.0, 260.0),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: LT.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: LT.border),
            ),
            child: CustomPaint(
              size: Size.infinite,
              painter: _MelodyRollPainter(
                notes: notes,
                steps: steps,
                playhead: playing ? playhead : null,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (onPlayTake != null) ...[
                Expanded(
                  child: _PlayButton(
                    key: const ValueKey('guided-play-take'),
                    icon: Icons.mic,
                    label: l.ltGuidedPlayTake,
                    on: playingTake,
                    onTap: onPlayTake!,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: _PlayButton(
                  key: const ValueKey('guided-play-melody'),
                  icon: Icons.piano,
                  label:
                      addTrack
                          ? l.ltHumAddPlaySong
                          : (keyChanged ? l.ltGuidedPlayNewKey : l.ltGuidedPlayMelody),
                  on: playing,
                  accent: true,
                  onTap: onListen,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _SettingButton(
                  key: const ValueKey('guided-instrument'),
                  icon: Icons.piano_outlined,
                  label: l.ltGuidedSound,
                  value: instrumentName,
                  onTap: onInstrument,
                ),
              ),
              if (addTrack) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: _SettingButton(
                    key: const ValueKey('guided-retake'),
                    icon: Icons.mic,
                    label: l.ltHumAddRetake,
                    onTap: onRecord,
                  ),
                ),
              ] else if (onKey != null) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: _SettingButton(
                    key: const ValueKey('guided-key'),
                    icon: Icons.tune,
                    label: l.ltGuidedKey,
                    value: keyLabel,
                    highlight: keyChanged,
                    onTap: onKey!,
                  ),
                ),
              ],
            ],
          ),
        ],
      );
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _title(l.ltGuidedVoiceReady),
          const SizedBox(height: 14),
          _PlayButton(
            key: const ValueKey('guided-play-melody'),
            icon: Icons.mic,
            label: l.ltGuidedPlayVoice,
            on: playing,
            accent: true,
            onTap: onListen,
          ),
        ],
      );
    }
    return ColoredBox(
      color: LT.bg,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                IconButton(
                  onPressed: onBack,
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  icon: const Icon(Icons.arrow_back, color: LT.t1),
                ),
                Expanded(
                  child: Text(
                    addTrack ? l.ltHumAddSteps : l.ltGuidedSteps,
                    style: const TextStyle(color: LT.t2, fontSize: 13),
                  ),
                ),
                if (!hasNotes && !addTrack)
                  TextButton(onPressed: onEdit, child: Text(l.ltGuidedDirect)),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: content,
                ),
              ),
            ),
          ),
          if (hasNotes)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Align(
                alignment: Alignment.center,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton.icon(
                      key: const ValueKey('guided-make-song'),
                      onPressed: onEdit,
                      style: FilledButton.styleFrom(
                        backgroundColor: LT.lime,
                        foregroundColor: LT.bg,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(LTRadius.pill),
                        ),
                        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                      ),
                      icon: const Icon(Icons.arrow_forward),
                      label: Text(
                        addTrack
                            ? l.ltHumAddConfirm
                            : (melody ? l.ltGuidedMakeSong : l.ltGuidedMakeSongVoice),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A rounded play / stop button; [accent] = the melody (lime when playing).
class _PlayButton extends StatelessWidget {
  const _PlayButton({
    super.key,
    required this.icon,
    required this.label,
    required this.on,
    required this.onTap,
    this.accent = false,
  });
  final IconData icon;
  final String label;
  final bool on, accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = on ? (accent ? LT.lime : LT.pink) : LT.t1;
    return Material(
      color: on ? color.withValues(alpha: .12) : LT.surface2,
      borderRadius: BorderRadius.circular(LTRadius.pill),
      child: InkWell(
        borderRadius: BorderRadius.circular(LTRadius.pill),
        onTap: onTap,
        child: AnimatedContainer(
          duration: LTMotion.state,
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(LTRadius.pill),
            border: Border.all(color: on ? color : LT.border),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: on ? color : (accent ? LT.lime : LT.surface3),
                ),
                child: Icon(
                  on ? Icons.stop_rounded : Icons.play_arrow_rounded,
                  color: on || accent ? LT.bg : LT.t1,
                  size: 22,
                ),
              ),
              const SizedBox(width: 10),
              Icon(icon, size: 16, color: on ? color : LT.t2),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: on ? color : LT.t1,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Change instrument · Piano ›": what it changes and what it is now.
class _SettingButton extends StatelessWidget {
  const _SettingButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.value,
    this.highlight = false,
  });
  final IconData icon;
  final String label;
  final String? value;
  final bool highlight;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: LT.surface,
    borderRadius: BorderRadius.circular(LTRadius.card),
    child: InkWell(
      borderRadius: BorderRadius.circular(LTRadius.card),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(LTRadius.card),
          border: Border.all(color: highlight ? LT.lime : LT.border),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: LT.lime),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: LT.t2, fontSize: 12),
                  ),
                  if (value != null)
                    Text(
                      value!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: LT.t1,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 18, color: LT.t3),
          ],
        ),
      ),
    ),
  );
}

/// The melody as a MIDI clip: lime note bars over beat / bar lines and
/// darker black-key rows, with the playhead while it plays.
class _MelodyRollPainter extends CustomPainter {
  _MelodyRollPainter({required this.notes, required this.steps, this.playhead})
    : super(repaint: playhead);
  final List<PitchNote> notes;
  final int steps;
  final ValueListenable<double>? playhead;

  static const _black = {1, 3, 6, 8, 10};

  @override
  void paint(Canvas canvas, Size size) {
    const padX = 10.0, padY = 12.0;
    final w = size.width - padX * 2, h = size.height - padY * 2;
    if (w <= 0 || h <= 0) return;
    final total = math.max(1, steps).toDouble();
    var lo = 60, hi = 72;
    if (notes.isNotEmpty) {
      lo = notes.map((n) => n.midi).reduce(math.min) - 2;
      hi = notes.map((n) => n.midi).reduce(math.max) + 2;
    }
    if (hi - lo < 12) {
      final mid = (hi + lo) ~/ 2;
      lo = mid - 6;
      hi = mid + 6;
    }
    final rows = hi - lo + 1;
    final rowH = h / rows;
    double y(int midi) => padY + (hi - midi) * rowH;
    double x(double step) => padX + step / total * w;

    // black-key rows
    final shade = Paint()..color = LT.bg.withValues(alpha: .55);
    for (var m = lo; m <= hi; m++) {
      if (_black.contains(m % 12)) {
        canvas.drawRect(Rect.fromLTWH(padX, y(m), w, rowH), shade);
      }
    }
    // beat and bar lines
    const perBeat = kStepsPerBeat, perBar = kBeatsPerBar * kStepsPerBeat;
    final beat = Paint()..color = LT.border.withValues(alpha: .6);
    final bar = Paint()
      ..color = LT.borderStrong
      ..strokeWidth = 1.2;
    for (var s = 0; s <= total; s += perBeat) {
      canvas.drawLine(
        Offset(x(s.toDouble()), padY),
        Offset(x(s.toDouble()), padY + h),
        s % perBar == 0 ? bar : beat,
      );
    }
    // notes
    final fill = Paint()..color = LT.lime;
    final glow = Paint()
      ..color = LT.lime.withValues(alpha: .25)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    final noteH = math.max(3.0, math.min(rowH - 1, 14.0));
    for (final n in notes) {
      if (n.muted) continue;
      final start = n.step + n.offsetSteps;
      final left = x(start), right = x(start + n.soundingSteps);
      final top = y(n.midi) + (rowH - noteH) / 2;
      final r = RRect.fromRectAndRadius(
        Rect.fromLTRB(left + .5, top, math.max(left + 3, right - .5), top + noteH),
        const Radius.circular(3),
      );
      canvas.drawRRect(r, glow);
      canvas.drawRRect(r, fill);
    }
    // playhead
    final p = playhead?.value;
    if (p != null) {
      final px = x(p % total);
      canvas.drawLine(
        Offset(px, 4),
        Offset(px, size.height - 4),
        Paint()
          ..color = LT.t1
          ..strokeWidth = 1.5,
      );
    }
  }

  // the notes list is edited in place (a key change): always repaint
  @override
  bool shouldRepaint(_MelodyRollPainter old) => true;
}

/// One way to start: a title saying what to do and one line saying what you
/// end up with (2026-11-02).
class _Choice extends StatelessWidget {
  const _Choice({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
    this.primary = false,
    this.extra,
  });
  final IconData icon;
  final String title, description;
  final VoidCallback onTap;
  final bool primary;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final accent = primary ? LT.lime : LT.t1;
    return Material(
      color: primary ? LT.lime.withValues(alpha: .08) : LT.bg,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: primary ? LT.lime : LT.border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: accent,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: const TextStyle(color: LT.t2, fontSize: 12.5, height: 1.4),
                    ),
                    if (extra != null) extra!,
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
