import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../../../audio/headset.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../music/wav_codec.dart';
import '../../state/sample_library.dart';
import '../../theme/tokens.dart';
import 'vocal_record_modal.dart';

class SampleWorkbench extends StatefulWidget {
  const SampleWorkbench({
    super.key,
    required this.bpm,
    required this.bars,
    required this.onAdd,
  });
  final int bpm, bars;
  final Future<bool> Function(List<double>, String, int) onAdd;
  @override
  State<SampleWorkbench> createState() => _SampleWorkbenchState();
}

class _SampleWorkbenchState extends State<SampleWorkbench> {
  final _library = SampleLibrary();
  final _player = AudioPlayer();
  List<File> _files = [];
  File? _selected;
  WavData? _wave;
  RangeValues _range = const RangeValues(0, 1);
  bool _busy = false, _loop = false;
  String? _error;
  File? _preview;
  @override
  void initState() {
    super.initState();
    _run(_reload);
  }

  @override
  void dispose() {
    _player.dispose();
    final file = _preview;
    if (file != null) file.delete().ignore();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() fn) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await fn();
    } catch (_) {
      if (mounted) setState(() => _error = L10n.of(context).ltSampleError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reload() async {
    final files = await _library.list();
    if (mounted) setState(() => _files = files);
  }

  Future<void> _select(File file) async {
    await _player.stop();
    final wave = await _library.read(file);
    if (mounted) {
      setState(() {
        _selected = file;
        _wave = wave;
        _range = const RangeValues(0, 1);
      });
    }
  }

  Future<void> _import() async {
    final picked = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'WAV',
          extensions: ['wav'],
          mimeTypes: ['audio/wav', 'audio/x-wav'],
          uniformTypeIdentifiers: ['com.microsoft.waveform-audio'],
        ),
      ],
    );
    if (picked == null || !mounted) return;
    final added = await _library.import(File(picked.path));
    await _reload();
    await _select(added);
  }

  Future<void> _record() async {
    await _player.stop();
    if (!mounted) return;
    await showVocalRecordModal(
      context,
      accent: LT.lime,
      bpm: widget.bpm,
      bars: widget.bars,
      headset: HeadsetRoute.none,
      keyTonic: 'C',
      scale: 'major',
      latencyMs: 0,
      onDone: (peaks, path) async {
        try {
          final added = await _library.import(File(path));
          await _reload();
          await _select(added);
          return true;
        } catch (_) {
          return false;
        }
      },
    );
  }

  Future<File> _selectionFile() async {
    final wave = _wave!;
    final dir = await getTemporaryDirectory();
    await _player.stop();
    if (_preview != null && await _preview!.exists()) await _preview!.delete();
    final file = File(
      '${dir.path}/humtrack_sample_preview_${DateTime.now().microsecondsSinceEpoch}.wav',
    );
    await file.writeAsBytes(
      encodeWavMono16(
        selectSample(wave, _range.start, _range.end),
        wave.sampleRate,
      ),
    );
    _preview = file;
    return file;
  }

  Future<void> _play() async {
    final file = await _selectionFile();
    if (!mounted) return;
    await _player.setReleaseMode(_loop ? ReleaseMode.loop : ReleaseMode.stop);
    await _player.play(DeviceFileSource(file.path));
  }

  Future<void> _add() async {
    final file = await _selectionFile();
    final peaks = peaksFromPcm(
      selectSample(_wave!, _range.start, _range.end),
      buckets: 64,
    );
    if (!mounted) return;
    final seconds =
        (_range.end - _range.start) * _wave!.samples.length / _wave!.sampleRate;
    final steps = (seconds * widget.bpm / 60 * 4).ceil().clamp(
      1,
      widget.bars * 16,
    );
    final ok = await widget.onAdd(peaks, file.path, steps);
    if (!mounted) return;
    if (ok) {
      setState(() => _busy = false);
      Navigator.pop(context);
    } else {
      setState(() => _error = L10n.of(context).ltSampleError);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final wave = _wave;
    final loopSeconds = widget.bars * 4 * 60 / widget.bpm;
    final seconds = wave == null ? 0.0 : wave.samples.length / wave.sampleRate;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        backgroundColor: LT.bg,
        appBar: AppBar(
          title: Text(l.ltSampleTitle),
          automaticallyImplyLeading: !_busy,
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l.ltSampleHint, style: const TextStyle(color: LT.t2)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : () => _run(_record),
                      icon: const Icon(Icons.mic),
                      label: Text(l.ltSampleRecord),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _run(_import),
                      icon: const Icon(Icons.file_open),
                      label: Text(l.ltSampleImport),
                    ),
                  ],
                ),
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ),
                if (_files.isEmpty && !_busy)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(l.ltSampleEmpty),
                  ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < _files.length; i++)
                      ChoiceChip(
                        label: Text('${l.ltSampleItem} ${_files.length - i}'),
                        selected: _selected?.path == _files[i].path,
                        onSelected:
                            _busy
                                ? null
                                : (_) => _run(() => _select(_files[i])),
                      ),
                  ],
                ),
                if (wave != null) ...[
                  Text(
                    l.ltSampleLimit(loopSeconds.toStringAsFixed(1)),
                    style: const TextStyle(color: LT.t2),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 70,
                    child: CustomPaint(
                      painter: _WavePainter(
                        peaksFromPcm(wave.samples, buckets: 100),
                        _range,
                      ),
                    ),
                  ),
                  Text(
                    '${(_range.start * seconds).toStringAsFixed(2)} – ${(_range.end * seconds).toStringAsFixed(2)} s',
                    style: const TextStyle(color: LT.t1),
                  ),
                  RangeSlider(
                    values: _range,
                    onChanged:
                        _busy
                            ? null
                            : (v) {
                              if ((v.end - v.start) * seconds < 0.01) return;
                              _player.stop();
                              setState(() => _range = v);
                            },
                  ),
                  SwitchListTile(
                    title: Text(l.ltSampleLoop),
                    value: _loop,
                    onChanged:
                        _busy
                            ? null
                            : (v) {
                              _player.stop();
                              setState(() => _loop = v);
                            },
                  ),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton(
                        onPressed: _busy ? null : () => _run(_play),
                        child: Text(l.ltSamplePreview),
                      ),
                      OutlinedButton(
                        onPressed: () => _player.stop(),
                        child: Text(l.ltGuidedStop),
                      ),
                      OutlinedButton(
                        onPressed:
                            _busy
                                ? null
                                : () => _run(() async {
                                  final added = await _library.save(
                                    selectSample(
                                      wave,
                                      _range.start,
                                      _range.end,
                                    ),
                                    wave.sampleRate,
                                  );
                                  await _reload();
                                  await _select(added);
                                }),
                        child: Text(l.ltSampleSaveCut),
                      ),
                      FilledButton(
                        onPressed:
                            _busy ||
                                    (_range.end - _range.start) * seconds >
                                        loopSeconds + 0.001
                                ? null
                                : () => _run(_add),
                        child: Text(l.ltSampleAdd),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.peaks, this.range);
  final List<double> peaks;
  final RangeValues range;
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..strokeWidth = 3;
    for (var i = 0; i < peaks.length; i++) {
      final t = i / peaks.length;
      p.color = t >= range.start && t <= range.end ? LT.lime : LT.t3;
      final h = peaks[i].clamp(0.03, 1.0) * size.height / 2;
      canvas.drawLine(
        Offset(t * size.width, size.height / 2 - h),
        Offset(t * size.width, size.height / 2 + h),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.peaks != peaks || old.range != range;
}
