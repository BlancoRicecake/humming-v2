// 바텀 시트 모음 (라이브러리). 자연 경계를 따라 `sheets/` 하위 part 파일로 분할.
//
// Public API (호출처에서 사용):
//  - showHelpSheet
//  - showPendingRecordingSheet
//  - showAddTrackSheet / maybeConfirmAnchorKey
//  - showInstrumentPicker
//  - showKeyPicker
//  - showNoteCandidate
//  - showChordPicker
//  - showExportShare
//  - showMetronomeSheet
//  - showQuantizeSheet
//
// 분할 후에도 import 경로 변경 없음 — 호출처는 `widgets/sheets.dart` 그대로 사용.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:material_symbols_icons/symbols.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../audio/player.dart';
import '../audio/synth.dart';
import '../audio/synth_player.dart';
import '../l10n/generated/app_localizations.dart';
import '../models/models.dart';
import '../music/chord_expand.dart';
import '../services/analytics_service.dart';
import '../services/recording_library.dart';
import '../music/instrument_icons.dart';
import '../music/strum.dart';
import '../state/project_store.dart';
import '../theme/app_theme.dart';
import 'common.dart';

part 'sheets/help_sheet.dart';
part 'sheets/pending_recording_sheet.dart';
part 'sheets/add_track_sheet.dart';
part 'sheets/instrument_picker_sheet.dart';
part 'sheets/key_picker_sheet.dart';
part 'sheets/note_candidate_sheet.dart';
part 'sheets/chord_picker_sheet.dart';
part 'sheets/export_sheet.dart';
part 'sheets/metronome_sheet.dart';
part 'sheets/quantize_sheet.dart';
part 'sheets/recording_library_sheet.dart';
part 'sheets/track_input_source_sheet.dart';

// ─── 공통 헬퍼 ─────────────────────────────────────────────────────────
BoxDecoration _sheetDeco() => const BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
    );

Widget _grabber() => Center(
      child: Container(
        width: 40,
        height: 4,
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(color: const Color(0xFF3F3F46), borderRadius: BorderRadius.circular(2)),
      ),
    );
