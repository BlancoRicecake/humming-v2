// LoopTap — Vocal track surface (audio only, no MIDI). README §5.
// Big red record ring + the recorded take's pink peak strip. Capture itself
// lives in the loop-aligned record modal (sheets/vocal_record_modal.dart) —
// the single recording path: count-in, backing loop, WAV, downbeat alignment.
// This surface just shows the committed clip and triggers the modal.
import 'package:flutter/material.dart';

import '../../theme/atoms.dart';
import '../../theme/tokens.dart';

class VocalSurface extends StatelessWidget {
  const VocalSurface({
    super.key,
    required this.clip,
    required this.onRecord,
    required this.onClear,
    this.onAutotune,
    this.onRevert,
    this.onEdit,
    this.onRecordSong,
    this.onClearSong,
  });

  /// Peaks of the committed take (null when nothing is recorded).
  final List<double>? clip;
  /// Opens the loop-aligned record modal.
  final VoidCallback onRecord;
  final VoidCallback onClear;
  /// Opens the autotune presets (shown when a clip exists).
  final VoidCallback? onAutotune;
  /// Swaps back to the pre-autotune take (shown when one exists).
  final VoidCallback? onRevert;
  /// Opens the clip editor (trim/fade/gain + sound processing). Shown when a
  /// clip exists.
  final VoidCallback? onEdit;
  /// Records ONE continuous take over the whole song. Shown only when the
  /// arrangement spans more than one section instance.
  final VoidCallback? onRecordSong;
  /// Clears the song-level take. Non-null only when one exists.
  final VoidCallback? onClearSong;

  @override
  Widget build(BuildContext context) {
    final wave = (clip != null && clip!.isNotEmpty) ? clip! : List.filled(64, 0.05);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          // record button
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: onRecord,
                child: Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: LT.danger, width: 3),
                  ),
                  child: Center(
                    child: Container(
                      width: 62,
                      height: 62,
                      decoration: const BoxDecoration(color: LT.danger, shape: BoxShape.circle),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                clip != null ? 'Recorded' : 'Tap to record',
                style: LTType.mono(size: 13, weight: FontWeight.w700, color: LT.t2),
              ),
              if (onRecordSong != null) ...[
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: onRecordSong,
                  child: Text(
                    onClearSong != null ? 'Re-rec over song' : 'Rec over song',
                    style: LTType.mono(size: 11, weight: FontWeight.w700, color: LT.pink),
                  ),
                ),
              ],
              if (onClearSong != null) ...[
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: onClearSong,
                  child: Text(
                    'Clear song vocal',
                    style: LTType.mono(size: 10, weight: FontWeight.w600, color: LT.t3),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(width: 24),
          // waveform
          Expanded(
            child: Container(
              height: 96,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: LT.bg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: LT.border),
              ),
              child: Row(
                children: [
                  for (final l in wave)
                    Expanded(
                      child: Container(
                        height: (l * 80).clamp(4, 80),
                        margin: const EdgeInsets.symmetric(horizontal: 0.75),
                        decoration: BoxDecoration(
                          color: clip != null ? LT.pink : LT.surface3,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (clip != null) ...[
            const SizedBox(width: 24),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onEdit != null) ...[
                  IconBtn(icon: LtIcons.edit, tooltip: 'Edit', size: 40, onTap: onEdit!),
                  const SizedBox(height: 8),
                ],
                if (onAutotune != null)
                  IconBtn(icon: LtIcons.autoFix, tooltip: 'Autotune', size: 40, onTap: onAutotune!),
                if (onRevert != null) ...[
                  const SizedBox(height: 8),
                  IconBtn(icon: LtIcons.restore, tooltip: 'Original', size: 40, onTap: onRevert!),
                ],
                if (onAutotune != null || onRevert != null) const SizedBox(height: 8),
                IconBtn(icon: LtIcons.delete, tooltip: 'Clear', size: 40, onTap: onClear),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
