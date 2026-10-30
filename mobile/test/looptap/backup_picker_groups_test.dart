// Codex backup review B5: the `.humtrack` picker filter per platform, through
// each platform's REAL file_selector Dart adapter with a fake native host
// (no device, no system picker). A UTI-only group made file_selector_android
// throw before the picker opened; Android now asks for `*/*` (content is
// validated after picking), iOS for `public.data`, desktop for `.humtrack`.
// A cancel (no path) comes back as null on each. Real phone pickers remain a
// device check.
// ignore_for_file: depend_on_referenced_packages, implementation_imports
import 'package:file_selector_android/file_selector_android.dart';
import 'package:file_selector_android/src/file_selector_api.g.dart' as android;
import 'package:file_selector_ios/file_selector_ios.dart';
import 'package:file_selector_ios/src/messages.g.dart' as ios;
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:file_selector_windows/file_selector_windows.dart';
import 'package:file_selector_windows/src/messages.g.dart' as windows;
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/widgets/project_backup_actions.dart';

class _AndroidHost extends android.FileSelectorApi {
  android.FileTypes? asked;
  @override
  Future<android.FileResponse?> openFile(
    String? initialDirectory,
    android.FileTypes allowedTypes,
  ) async {
    asked = allowedTypes;
    return null; // cancelled
  }
}

class _IosHost extends ios.FileSelectorApi {
  ios.FileSelectorConfig? asked;
  @override
  Future<List<String>> openFile(ios.FileSelectorConfig config) async {
    asked = config;
    return const []; // cancelled
  }
}

class _WindowsHost extends windows.FileSelectorApi {
  windows.SelectionOptions? asked;
  @override
  Future<windows.FileDialogResult> showOpenDialog(
    windows.SelectionOptions options,
    String? initialDirectory,
    String? confirmButtonText,
  ) async {
    asked = options;
    return windows.FileDialogResult(paths: const []); // cancelled
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Android: all-files MIME reaches the native picker; cancel is null', () async {
    final host = _AndroidHost();
    final picker = FileSelectorAndroid(api: host);
    final picked = await picker.openFile(
      acceptedTypeGroups: backupTypeGroups(BackupPickerPlatform.android),
    );
    expect(picked, isNull);
    expect(host.asked!.mimeTypes, ['*/*']);
    // the old group (UTI only) never got that far
    final before = _AndroidHost();
    await expectLater(
      FileSelectorAndroid(api: before).openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'HumTrack', uniformTypeIdentifiers: ['public.data']),
        ],
      ),
      throwsArgumentError,
    );
    expect(before.asked, isNull);
  });

  test('iOS: public.data reaches the native picker; cancel is null', () async {
    final host = _IosHost();
    final picked = await FileSelectorIOS(api: host).openFile(
      acceptedTypeGroups: backupTypeGroups(BackupPickerPlatform.ios),
    );
    expect(picked, isNull);
    expect(host.asked!.utis, ['public.data']);
  });

  test('desktop (Windows adapter): filtered to .humtrack; cancel is null', () async {
    final host = _WindowsHost();
    final picked = await FileSelectorWindows(api: host).openFile(
      acceptedTypeGroups: backupTypeGroups(BackupPickerPlatform.desktop),
    );
    expect(picked, isNull);
    expect(host.asked!.allowedTypes.single.extensions, ['humtrack']);
  });
}
