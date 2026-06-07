// 빈 트랙 입력 진입점 시트 — 3가지 입력 방식 선택.
//
// 빈 트랙의 "● 녹음 시작" pill 을 탭하면 카운트다운 → 녹음으로 바로 가지 않고
// 먼저 이 시트를 띄운다. 사용자는 다음 중 하나를 고른다:
//   1) 직접 녹음   — 기존 인라인 녹음 흐름 (콜백)
//   2) 라이브러리에서 선택 — showRecordingLibrarySheet 으로 위임
//   3) 파일에서 가져오기 — file_picker → 30초 제한 검사 → recordAnalyzed
//
// 파일 가져오기는 길이 검증만 클라이언트에서 한다 (audioplayers.getDuration).
// 30초 초과면 토스트로 거부, 그 외 에러는 errorToast.
//
// part of '../sheets.dart' — 같은 라이브러리 묶음.
part of '../sheets.dart';

void showTrackInputSourceSheet(
  BuildContext context,
  ProjectStore store, {
  required VoidCallback onRecord,
}) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (_) => _TrackInputSourceSheetBody(store: store, onRecord: onRecord),
  );
}

class _TrackInputSourceSheetBody extends StatelessWidget {
  const _TrackInputSourceSheetBody({required this.store, required this.onRecord});
  final ProjectStore store;
  final VoidCallback onRecord;

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final mq = MediaQuery.of(context);
    return Container(
      decoration: _sheetDeco(),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + mq.viewPadding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _grabber(),
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(l.trackInputSourceTitle, style: T.h2.copyWith(fontSize: 18)),
          ),
          _option(
            context,
            icon: Symbols.mic,
            title: l.trackInputSourceRecord,
            subtitle: l.trackInputSourceRecordSub,
            onTap: () {
              Navigator.pop(context);
              onRecord();
            },
          ),
          const SizedBox(height: 10),
          _option(
            context,
            icon: Symbols.library_music,
            title: l.trackInputSourceLibrary,
            subtitle: l.trackInputSourceLibrarySub,
            onTap: () {
              Navigator.pop(context);
              showRecordingLibrarySheet(context, store);
            },
          ),
          const SizedBox(height: 10),
          _option(
            context,
            icon: Symbols.folder_open,
            title: l.trackInputSourceUpload,
            subtitle: l.trackInputSourceUploadSub,
            onTap: () async {
              Navigator.pop(context);
              await _pickAudioFile(context, store);
            },
          ),
        ],
      ),
    );
  }

  Widget _option(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        decoration: BoxDecoration(
          color: AppColors.bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.surface,
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.border),
              ),
              child: Icon(icon, size: 20, color: AppColors.lime),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: T.body.copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary)),
                ],
              ),
            ),
            const Icon(Symbols.chevron_right, size: 20, color: AppColors.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// 파일 선택 → 30초 검증 → recordAnalyzed.
///
/// audioplayers 의 setSource + getDuration() 으로 클라이언트 측 길이 검사를 한다.
/// 백엔드 호출(analyze/processVocal)은 무겁기 때문에 30초 초과 거부는 업로드 전에
/// 끝낸다. 정상이면 ProjectStore.recordAnalyzed 한 번에 위임 — 보컬/멜로딕 분기 +
/// RecordingLibrary saveTemp 까지 동일 경로로 처리된다.
Future<void> _pickAudioFile(BuildContext context, ProjectStore store) async {
  final l = L10n.of(context);
  try {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      allowMultiple: false,
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.first;
    final path = picked.path;
    if (path == null) {
      if (context.mounted) errorToast(context, l.trackInputFileError);
      return;
    }
    if (!File(path).existsSync()) {
      if (context.mounted) errorToast(context, l.trackInputFileError);
      return;
    }
    // 1차: 30초 길이 검사 — audioplayers.getDuration 로 짧게.
    final probe = AudioPlayer();
    Duration? dur;
    try {
      await probe.setSource(DeviceFileSource(path));
      // setSource 완료 후에도 metadata 가 천천히 도착할 수 있어 짧게 재시도.
      for (var i = 0; i < 10; i++) {
        dur = await probe.getDuration();
        if (dur != null && dur > Duration.zero) break;
        await Future.delayed(const Duration(milliseconds: 60));
      }
    } finally {
      try {
        await probe.release();
      } catch (_) {}
      try {
        await probe.dispose();
      } catch (_) {}
    }
    if (dur != null && dur > const Duration(seconds: 30)) {
      if (context.mounted) errorToast(context, l.trackInputFileTooLong);
      return;
    }
    // 검증 통과 → 기존 녹음 후처리 경로와 동일.
    await store.recordAnalyzed(path);
  } catch (e) {
    debugPrint('[track-input] pickAudioFile FAILED: $e');
    if (context.mounted) errorToast(context, '${l.trackInputFileError}: $e');
  }
}
