// 업로드 / 다운로드 진행 모달.
// 시안 ⑧ 업로드 / ⑨ 다운로드 — cloud-sync-p3.html.
// onRun 콜백(uploadProject/downloadProject)과 진행 타이머를 병렬 실행.
// onRun 완료 시 progress 1.0으로 맞추고 0.5초 후 닫힘.
// onRun 실패 시 에러 메시지 표시 + 닫기 버튼 노출.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../state/local_storage.dart' show formatBytes;
import '../../theme/app_theme.dart';

enum SyncDirection { upload, download }

Future<bool> showSyncProgressSheet(
  BuildContext context, {
  required SyncDirection direction,
  required String projectTitle,
  required int totalBytes,
  required Future<void> Function() onRun,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black54,
    barrierDismissible: false,
    builder: (dctx) => _SyncProgressDialog(
      direction: direction,
      title: projectTitle,
      totalBytes: totalBytes,
      onRun: onRun,
    ),
  );
  return ok == true;
}

class _SyncProgressDialog extends StatefulWidget {
  const _SyncProgressDialog({
    required this.direction,
    required this.title,
    required this.totalBytes,
    required this.onRun,
  });
  final SyncDirection direction;
  final String title;
  final int totalBytes;
  final Future<void> Function() onRun;

  @override
  State<_SyncProgressDialog> createState() => _SyncProgressDialogState();
}

class _SyncProgressDialogState extends State<_SyncProgressDialog> {
  Timer? _ticker;
  double _progress = 0.0;
  bool _cancelled = false;
  bool _failed = false;
  String? _errorMessage;
  // onRun 완료 여부 — 실제 작업이 끝나면 true.
  bool _runCompleted = false;

  @override
  void initState() {
    super.initState();
    _startRun();
    _startTicker();
  }

  /// onRun을 즉시 실행. 완료/실패를 상태에 반영.
  void _startRun() {
    widget.onRun().then((_) {
      if (!mounted || _cancelled) return;
      setState(() {
        _runCompleted = true;
        _progress = 1.0;
      });
      // 완료 후 0.5초 뒤 닫기.
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted && !_cancelled) Navigator.pop(context, true);
      });
    }).catchError((Object err) {
      if (!mounted || _cancelled) return;
      _ticker?.cancel();
      setState(() {
        _failed = true;
        _errorMessage = err.toString().replaceFirst('Exception: ', '');
      });
    });
  }

  /// 5초 타이머로 0→90% 까지 진행. onRun 완료 시 100%로 즉시 점프.
  void _startTicker() {
    const total = 5000; // 5s 시뮬
    const stepMs = 80;
    var elapsed = 0;
    _ticker = Timer.periodic(const Duration(milliseconds: stepMs), (t) {
      if (_cancelled || _runCompleted) {
        t.cancel();
        return;
      }
      elapsed += stepMs;
      // 최대 90%까지만 — 나머지 10%는 onRun 완료 시 채움.
      final p = (elapsed / total * 0.9).clamp(0.0, 0.9);
      if (mounted) setState(() => _progress = p);
      if (elapsed >= total) t.cancel();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _fmtMB(double bytes) => formatBytes(bytes.toInt());

  @override
  Widget build(BuildContext context) {
    final isUp = widget.direction == SyncDirection.upload;
    final icon = isUp ? Symbols.cloud_upload : Symbols.cloud_download;
    final t = L10n.of(context);
    final title = isUp ? t.syncProgressUpload : t.syncProgressDownload;
    final loadedBytes = (widget.totalBytes * _progress);
    return Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _failed ? AppColors.danger.withValues(alpha: 0.15) : AppColors.activeLane,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                _failed ? Symbols.error : icon,
                color: _failed ? AppColors.danger : AppColors.lime,
                size: 22,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              _failed ? t.syncProgressFailed : title,
              style: T.title.copyWith(color: _failed ? AppColors.danger : null),
            ),
            const SizedBox(height: 6),
            Text(
              _failed
                  ? (_errorMessage ?? t.syncProgressFailedSub)
                  : widget.title,
              style: T.sub.copyWith(
                height: 1.4,
                color: _failed ? AppColors.textSecondary : null,
              ),
              maxLines: _failed ? 3 : 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (!_failed) ...[
              const SizedBox(height: 18),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: _progress,
                  minHeight: 6,
                  backgroundColor: AppColors.surface2,
                  valueColor: const AlwaysStoppedAnimation(AppColors.lime),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('${(_progress * 100).round()}%',
                      style: T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary)),
                  Text(
                    '${_fmtMB(loadedBytes)} / ${_fmtMB(widget.totalBytes.toDouble())}',
                    style: T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 18),
            GestureDetector(
              onTap: () {
                _cancelled = true;
                _ticker?.cancel();
                Navigator.pop(context, _failed ? false : false);
              },
              child: Container(
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _failed ? t.ok : t.cancel,
                  style: T.body.copyWith(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
