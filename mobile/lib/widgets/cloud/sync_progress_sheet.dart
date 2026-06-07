// 업로드 / 다운로드 진행 모달 (mock).
// 시안 ⑧ 업로드 / ⑨ 다운로드 — cloud-sync-p3.html.
// 실 동작은 없음 — 5초 타이머로 0→100% 시뮬 후 onComplete 콜백 + 닫힘.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../l10n/generated/app_localizations.dart';
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

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    const total = 5000; // 5s mock
    final stepMs = 80;
    var elapsed = 0;
    _ticker = Timer.periodic(Duration(milliseconds: stepMs), (t) async {
      if (_cancelled) {
        t.cancel();
        return;
      }
      elapsed += stepMs;
      final p = (elapsed / total).clamp(0.0, 1.0);
      setState(() => _progress = p);
      if (p >= 1.0) {
        t.cancel();
        try {
          await widget.onRun();
        } catch (_) {}
        if (mounted) Navigator.pop(context, true);
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _fmtMB(double bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

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
                color: AppColors.activeLane,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: AppColors.lime, size: 22),
            ),
            const SizedBox(height: 14),
            Text(title, style: T.title),
            const SizedBox(height: 6),
            Text(
              widget.title,
              style: T.sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
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
            const SizedBox(height: 18),
            GestureDetector(
              onTap: () {
                _cancelled = true;
                Navigator.pop(context, false);
              },
              child: Container(
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.surface2,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(t.cancel,
                    style: T.body.copyWith(fontWeight: FontWeight.w600, fontSize: 13)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
