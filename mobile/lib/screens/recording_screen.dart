// 녹음 화면 — 들어오면 '준비' 상태, 버튼 한 번 더 눌러야 녹음 시작, 다시 누르면 정지.
// 오리지널은 무조건 WAV. 정지 시 wavPath 를 pop 으로 반환.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path_provider/path_provider.dart';
import '../audio/recorder.dart';
import '../models/models.dart';
import '../theme/app_theme.dart';

class RecordingScreen extends StatefulWidget {
  const RecordingScreen({super.key, required this.role});
  final TrackRole role;

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen> {
  final _rec = VoiceRecorder();
  Timer? _timer;
  StreamSubscription? _ampSub;
  final List<double> _levels = List.filled(48, 0.04); // 음량 바(좌→우 흐름)
  int _ms = 0;
  bool _ready = false; // 권한 OK, 시작 대기
  bool _recording = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    final ok = await _rec.hasPermission();
    setState(() {
      _ready = ok;
      if (!ok) _err = '마이크 권한이 필요합니다';
    });
  }

  Future<void> _start() async {
    if (!_ready || _recording) return;
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/rec_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _rec.start(path);
    setState(() => _recording = true);
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => setState(() => _ms += 100));
    _ampSub = _rec.amplitude().listen((a) {
      // dBFS(약 -45..0)를 0..1로 정규화 후 좌→우로 흘려보냄.
      final level = ((a.current + 45) / 45).clamp(0.04, 1.0);
      if (!mounted) return;
      setState(() {
        _levels.removeAt(0);
        _levels.add(level.toDouble());
      });
    });
  }

  Future<void> _stop() async {
    _timer?.cancel();
    _ampSub?.cancel();
    final path = await _rec.stop();
    if (mounted) Navigator.of(context).pop(path);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ampSub?.cancel();
    _rec.dispose();
    super.dispose();
  }

  String get _time {
    final s = _ms ~/ 1000;
    return '${(s ~/ 60)}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_recording)
                    Container(width: 8, height: 8, decoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle)),
                  if (_recording) const SizedBox(width: 8),
                  Text(
                    _recording ? 'Recording · ${widget.role.label.toUpperCase()}' : '${widget.role.label.toUpperCase()} 녹음',
                    style: T.title,
                  ),
                ],
              ),
            ),
            const Spacer(),
            if (_err != null)
              Text(_err!, style: T.body.copyWith(color: AppColors.danger))
            else ...[
              if (_recording)
                SizedBox(
                  height: 72,
                  width: 280,
                  child: CustomPaint(painter: _MeterPainter(_levels)),
                )
              else
                const Icon(Symbols.mic, size: 64, color: AppColors.lime),
              const SizedBox(height: 20),
              Text(_recording ? _time : '0:00', style: T.h1.copyWith(fontSize: 56, fontWeight: FontWeight.w300)),
              const SizedBox(height: 8),
              Text(_recording ? '흥얼거리거나 노래해주세요' : '준비되면 아래 버튼을 누르세요', style: T.sub),
            ],
            const Spacer(),
            Text(_recording ? '탭하면 녹음 종료' : (_ready ? '탭하면 녹음 시작' : ''), style: T.sub),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: _recording ? _stop : (_ready ? _start : null),
              child: Container(
                width: 80,
                height: 80,
                margin: const EdgeInsets.only(bottom: 28),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.danger, width: 3),
                ),
                child: Center(
                  child: _recording
                      // 녹음 중: 정지(사각형)
                      ? Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(color: AppColors.danger, borderRadius: BorderRadius.circular(6)),
                        )
                      // 준비: 시작(원)
                      : Container(
                          width: 60,
                          height: 60,
                          decoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 음량 바 미터 — 중앙 기준 대칭 막대.
class _MeterPainter extends CustomPainter {
  _MeterPainter(this.levels);
  final List<double> levels;

  @override
  void paint(Canvas canvas, Size size) {
    final n = levels.length;
    final slot = size.width / n;
    final barW = slot * 0.5;
    final cy = size.height / 2;
    final paint = Paint()..color = AppColors.lime;
    for (int i = 0; i < n; i++) {
      final h = (levels[i] * size.height).clamp(3.0, size.height);
      final x = i * slot + (slot - barW) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, cy - h / 2, barW, h), const Radius.circular(2)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _MeterPainter old) => true;
}
