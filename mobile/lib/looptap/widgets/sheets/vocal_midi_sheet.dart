import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../audio/loop_audio.dart';
import '../../models/loop_models.dart';
import '../../music/theory.dart';
import '../../music/vocal_midi.dart';
import '../../theme/tokens.dart';

Future<VocalMidiResult?> showVocalMidiSheet(
  BuildContext context, {
  required VocalClip clip,
  required int bpm,
  required int bars,
  required String keyRoot,
  required String scale,
  required double swing,
  int initialProgram = 0,
}) => showDialog<VocalMidiResult>(
  context: context,
  barrierDismissible: false,
  builder:
      (_) => VocalMidiSheet(
        clip: clip.copy(),
        bpm: bpm,
        bars: bars,
        keyRoot: keyRoot,
        scale: scale,
        swing: swing,
        initialProgram: initialProgram,
      ),
);

class VocalMidiSheet extends StatefulWidget {
  const VocalMidiSheet({
    super.key,
    required this.clip,
    required this.bpm,
    required this.bars,
    required this.keyRoot,
    required this.scale,
    required this.swing,
    this.service,
    this.initialProgram = 0,
  });
  final VocalClip clip;
  final int bpm, bars;
  final String keyRoot, scale;
  final double swing;
  final VocalMidiService? service;
  final int initialProgram;
  @override
  State<VocalMidiSheet> createState() => _VocalMidiSheetState();
}

class _VocalMidiSheetState extends State<VocalMidiSheet> {
  VocalMidiAnalysis? _analysis;
  bool _busy = false;
  bool _previewing = false;
  int _previewEpoch = 0;
  String? _error;
  CancelToken? _cancelToken;
  late int _program = widget.initialProgram;
  int _octave = 0;
  bool _raw = false;
  final List<Timer> _timers = [];
  final _audio = LoopAudio.instance;

  List<PitchNote> get _notes => [
    for (final n in _analysis?.notes ?? <PitchNote>[])
      n.copyWith(
        midi: ((_raw ? n.sourceMidi ?? n.midi : n.midi) + _octave * 12).clamp(
          0,
          127,
        ),
        freq: midiToFreq(
          ((_raw ? n.sourceMidi ?? n.midi : n.midi) + _octave * 12).clamp(
            0,
            127,
          ),
        ),
      ),
  ];

  void _stop() {
    _previewEpoch++;
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    _audio.stopAll();
    _audio.stopVocal();
    if (mounted && _previewing) setState(() => _previewing = false);
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
    _previewEpoch++;
    for (final timer in _timers) {
      timer.cancel();
    }
    _audio.stopAll();
    _audio.stopVocal();
    unawaited(_analysis?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  Future<void> _convert() async {
    if (_busy) return;
    _stop();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _cancelToken = CancelToken();
      final result = await (widget.service ??
              VocalMidiService(cancelToken: _cancelToken))
          .convert(
            widget.clip,
            bpm: widget.bpm,
            bars: widget.bars,
            keyRoot: widget.keyRoot,
            scale: widget.scale,
            swing: widget.swing,
          );
      if (!mounted) {
        await result.dispose();
        return;
      }
      setState(() => _analysis = result);
    } catch (error) {
      if (!mounted) return;
      final l = L10n.of(context);
      final message =
          error is VocalMidiException
              ? switch (error.reason) {
                VocalMidiFailure.invalidAudio => l.ltMidiInvalidAudio,
                VocalMidiFailure.outsideSection => l.ltMidiOutsideSection,
                VocalMidiFailure.tooLong => l.ltEditorHumErrTooLong,
                VocalMidiFailure.noNotes => l.ltEditorHumErrNoNotes,
              }
              : error is DioException && error.response?.statusCode == 413
              ? l.ltEditorHumErrTooLong
              : error is DioException && error.response?.statusCode == 429
              ? l.ltEditorHumErrBusy
              : l.ltMidiFailed;
      setState(() => _error = message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _preview(bool original) async {
    _stop();
    final epoch = _previewEpoch;
    try {
      await _audio.ensure();
      if (!mounted || epoch != _previewEpoch) return;
      final analysis = _analysis!;
      if (original) {
        await _audio.prepareVocal(analysis.preview.path);
        if (!mounted || epoch != _previewEpoch) return;
        await _audio.playVocal(analysis.preview.path);
      } else {
        final stepSeconds = 60 / widget.bpm / kStepsPerBeat;
        final notes = _notes;
        for (final n in notes) {
          final delay = ((n.step + (n.step.isOdd ? widget.swing * .5 : 0)) *
                      stepSeconds -
                  analysis.audio.offsetSeconds)
              .clamp(0.0, 60.0);
          _timers.add(
            Timer(Duration(milliseconds: (delay * 1000).round()), () {
              if (!mounted || epoch != _previewEpoch) return;
              _audio.playPitch(
                15,
                n.midi,
                program: _program,
                durSec: n.dur * stepSeconds,
              );
            }),
          );
        }
      }
      if (!mounted || epoch != _previewEpoch) return;
      setState(() => _previewing = true);
      _timers.add(
        Timer(
          Duration(milliseconds: ((analysis.audio.duration + 1) * 1000).ceil()),
          () {
            if (mounted && epoch == _previewEpoch) _stop();
          },
        ),
      );
    } catch (_) {
      if (mounted && epoch == _previewEpoch) {
        _stop();
        setState(() => _error = L10n.of(context).ltMidiPreviewFailed);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    return AlertDialog(
      backgroundColor: LT.surface,
      title: Text(l.ltMidiTitle),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l.ltMidiHint),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (final instrument in [
                    (0, l.ltMidiPiano),
                    (24, l.ltMidiGuitar),
                    (80, l.ltMidiSynth),
                    if (![0, 24, 80].contains(widget.initialProgram))
                      (widget.initialProgram, l.ltMidiTargetSound),
                  ])
                    ChoiceChip(
                      label: Text(instrument.$2),
                      selected: _program == instrument.$1,
                      onSelected:
                          _busy
                              ? null
                              : (_) {
                                _stop();
                                setState(() => _program = instrument.$1);
                              },
                    ),
                ],
              ),
              if (_busy) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
                Text(l.ltMidiAnalyzing),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Semantics(liveRegion: true, child: Text(_error!)),
                ),
              if (_analysis != null) ...[
                const SizedBox(height: 12),
                Text(l.ltEditorHumAdded(_analysis!.notes.length)),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.ltMidiRawPitch),
                  value: _raw,
                  onChanged: (v) {
                    _stop();
                    setState(() => _raw = v);
                  },
                ),
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    IconButton(
                      tooltip: l.ltMidiOctaveDown,
                      icon: const Icon(Icons.remove),
                      onPressed:
                          _octave > -2
                              ? () {
                                _stop();
                                setState(() => _octave--);
                              }
                              : null,
                    ),
                    Text(l.ltMidiOctave(_octave)),
                    IconButton(
                      tooltip: l.ltMidiOctaveUp,
                      icon: const Icon(Icons.add),
                      onPressed:
                          _octave < 2
                              ? () {
                                _stop();
                                setState(() => _octave++);
                              }
                              : null,
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => _preview(true),
                      child: Text(l.ltMidiOriginal),
                    ),
                    TextButton(
                      onPressed: () => _preview(false),
                      child: Text(l.ltMidiInstrument),
                    ),
                    if (_previewing)
                      TextButton(onPressed: _stop, child: Text(l.ltMidiStop)),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            _stop();
            Navigator.of(context).pop();
          },
          child: Text(l.cancel),
        ),
        if (_analysis == null)
          FilledButton(
            onPressed: _busy ? null : _convert,
            child: Text(_error == null ? l.ltMidiConvert : l.retry),
          )
        else
          FilledButton(
            onPressed: () {
              _stop();
              Navigator.of(context).pop(VocalMidiResult(_notes, _program));
            },
            child: Text(l.ltMidiAddTrack),
          ),
      ],
    );
  }
}
