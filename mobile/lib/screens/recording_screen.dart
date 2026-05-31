// 녹음 화면 — 들어오면 '준비' 상태, 버튼 한 번 더 눌러야 녹음 시작, 다시 누르면 정지.
// 오리지널은 무조건 WAV. 정지 시 wavPath 를 pop 으로 반환.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../audio/recorder.dart';
import '../models/models.dart';
import '../theme/app_theme.dart';

/// 마이크 권한 상태 — UI 분기용.
enum _MicPermState { unknown, granted, denied, permanentlyDenied, restricted }

class RecordingScreen extends StatefulWidget {
  const RecordingScreen({super.key, required this.role});
  final TrackRole role;

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen> with WidgetsBindingObserver {
  final _rec = VoiceRecorder();
  Timer? _timer;
  StreamSubscription? _ampSub;
  final List<double> _levels = List.filled(48, 0.04); // 음량 바(좌→우 흐름)
  int _ms = 0;
  bool _ready = false; // 권한 OK, 시작 대기
  bool _recording = false;
  _MicPermState _permState = _MicPermState.unknown;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _prepare();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 설정 앱에서 권한 토글 후 복귀 시 자동 재확인.
    if (state == AppLifecycleState.resumed && !_recording && !_ready) {
      _prepare();
    }
  }

  /// 권한 상태 조회 + 필요 시 요청.
  /// record 6.x 의 hasPermission() 이 자동 요청을 겸하므로 한 번 호출.
  /// 이후 permission_handler 로 세분화 상태를 다시 조회해 영구거부/제한을 구분.
  Future<void> _prepare() async {
    // 1) record 패키지에 권한 요청 위임 (notDetermined → 시스템 팝업).
    final ok = await _rec.hasPermission();

    // 2) 세분화 상태 조회.
    final status = await Permission.microphone.status;
    final next = _mapStatus(status, fallbackGranted: ok);

    if (!mounted) return;
    setState(() {
      _permState = next;
      _ready = next == _MicPermState.granted;
    });
  }

  _MicPermState _mapStatus(PermissionStatus s, {required bool fallbackGranted}) {
    if (s.isGranted || s.isLimited) return _MicPermState.granted;
    if (s.isPermanentlyDenied) return _MicPermState.permanentlyDenied;
    if (s.isRestricted) return _MicPermState.restricted;
    if (s.isDenied) return _MicPermState.denied;
    // status 가 unknown 일 때는 record 결과로 폴백.
    return fallbackGranted ? _MicPermState.granted : _MicPermState.denied;
  }

  /// "권한 요청" 버튼 — 첫 거부 상태에서 재요청.
  Future<void> _requestPermission() async {
    final s = await Permission.microphone.request();
    if (!mounted) return;
    setState(() {
      _permState = _mapStatus(s, fallbackGranted: s.isGranted);
      _ready = _permState == _MicPermState.granted;
    });
  }

  /// "설정 열기" 버튼 — 영구 거부 시 OS 설정 앱으로.
  Future<void> _openSettings() async {
    await openAppSettings();
    // 복귀 시 didChangeAppLifecycleState 에서 _prepare() 재호출됨.
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
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _ampSub?.cancel();
    _rec.dispose();
    super.dispose();
  }

  String get _time {
    final s = _ms ~/ 1000;
    return '${(s ~/ 60)}:${(s % 60).toString().padLeft(2, '0')}';
  }

  /// 권한 거부 상태별 에러 블록.
  Widget _buildPermissionBlock() {
    String msg;
    Widget? action;
    switch (_permState) {
      case _MicPermState.denied:
        msg = '마이크 권한이 필요합니다. 다시 허용해주세요.';
        action = _permActionButton(label: '권한 요청', onTap: _requestPermission);
        break;
      case _MicPermState.permanentlyDenied:
        msg = '설정 > 개인정보 > 마이크에서 권한을 켜주세요.';
        action = _permActionButton(label: '설정 열기', onTap: _openSettings);
        break;
      case _MicPermState.restricted:
        msg = '이 기기에서는 마이크 사용이 제한되어 있어 녹음할 수 없습니다.';
        action = null;
        break;
      default:
        msg = '마이크 권한을 확인 중입니다…';
        action = null;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Symbols.mic_off, size: 56, color: AppColors.danger),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(msg, textAlign: TextAlign.center, style: T.body.copyWith(color: AppColors.danger)),
        ),
        if (action != null) ...[
          const SizedBox(height: 20),
          action,
        ],
      ],
    );
  }

  Widget _permActionButton({required String label, required VoidCallback onTap}) {
    return Material(
      color: AppColors.lime,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          child: Text(label, style: T.body.copyWith(color: AppColors.bg, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final showPermBlock = !_ready && _permState != _MicPermState.granted;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 16),
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
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    child: showPermBlock
                        ? _buildPermissionBlock()
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // 미터를 항상 같은 자리/크기로 유지해 녹음 시작 시 시각 점프 제거.
                              // 준비 상태에선 회색 정적 막대, 녹음 시작과 함께 lime 으로 흐름.
                              SizedBox(
                                height: 72,
                                width: 280,
                                child: CustomPaint(
                                  painter: _MeterPainter(_levels, active: _recording),
                                ),
                              ),
                              const SizedBox(height: 20),
                              Text(_recording ? _time : '0:00', style: T.h1.copyWith(fontSize: 56, fontWeight: FontWeight.w300)),
                              const SizedBox(height: 8),
                              Text(_recording ? '흥얼거리거나 노래해주세요' : '준비되면 아래 버튼을 누르세요', style: T.sub),
                            ],
                          ),
                  ),
                ),
              ),
              if (!showPermBlock) ...[
                Text(_recording ? '탭하면 녹음 종료' : (_ready ? '탭하면 녹음 시작' : ''), style: T.sub),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: _recording ? _stop : (_ready ? _start : null),
                  child: Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.danger, width: 3),
                    ),
                    child: Center(
                      child: _recording
                          ? Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(color: AppColors.danger, borderRadius: BorderRadius.circular(6)),
                            )
                          : Container(
                              width: 60,
                              height: 60,
                              decoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle),
                            ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 음량 바 미터 — 중앙 기준 대칭 막대.
/// [active] 가 false 면 회색 톤의 정적 막대로 표시 (녹음 전 placeholder).
class _MeterPainter extends CustomPainter {
  _MeterPainter(this.levels, {this.active = true});
  final List<double> levels;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final n = levels.length;
    final slot = size.width / n;
    final barW = slot * 0.5;
    final cy = size.height / 2;
    final paint = Paint()
      ..color = active ? AppColors.lime : AppColors.lime.withValues(alpha: 0.18);
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
