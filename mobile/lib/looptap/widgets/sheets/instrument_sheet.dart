// Instrument picker (melody / bass). Mirrors key_sheet.dart: a centered modal
// with a grid of selectable instruments. Picking is live — the host swaps the
// program + plays a preview note via onPick, so the user can audition several
// before closing. The chosen GM program persists on the song.
import 'package:flutter/material.dart';

import '../../music/instruments.dart';
import '../../music/soundfont_catalog.dart';
import '../../state/loop_prefs.dart';
import '../../theme/atoms.dart';
import '../../theme/tokens.dart';
import 'lt_modal.dart';

Future<void> showInstrumentSheet(
  BuildContext context, {
  required String trackId,
  required String trackLabel,
  required int currentProgram,
  required void Function(int program) onPick,
}) {
  return showLtModal(
    context,
    child: _InstrumentSheet(
      trackId: trackId,
      trackLabel: trackLabel,
      currentProgram: currentProgram,
      onPick: onPick,
    ),
  );
}

class _InstrumentSheet extends StatefulWidget {
  const _InstrumentSheet({
    required this.trackId,
    required this.trackLabel,
    required this.currentProgram,
    required this.onPick,
  });
  final String trackId;
  final String trackLabel;
  final int currentProgram;
  final void Function(int program) onPick;

  @override
  State<_InstrumentSheet> createState() => _InstrumentSheetState();
}

class _InstrumentSheetState extends State<_InstrumentSheet> {
  late int _program = widget.currentProgram;
  late int _categoryIndex;
  late Set<int> _favorites;

  String get _favoriteKey => instrumentFavoriteKeyForTrack(widget.trackId);

  @override
  void initState() {
    super.initState();
    _favorites =
        LoopPrefs.instance.favoritesForInstrumentRole(_favoriteKey).toSet();
    _categoryIndex = _initialCategoryIndex();
  }

  int _initialCategoryIndex() {
    final categories = _categories();
    final i = categories.indexWhere(
      (category) => category.instruments.any(
        (inst) => inst.program == widget.currentProgram,
      ),
    );
    return i < 0 ? 0 : i;
  }

  void _pick(int program) {
    // Non-blocking: the host applies immediately for GM / already-downloaded
    // sounds, or kicks off a background download and applies when ready for a
    // not-yet-downloaded catalog sound (progress shows on the cell; the sheet
    // can be closed meanwhile). See edit_screen onPick.
    setState(() => _program = program);
    widget.onPick(program);
  }

  // Catalog `category` values that fold into an existing GM picker group, so a
  // downloaded sound shows up next to its GM siblings (e.g. the FreePats
  // guitars land in the "Guitars" tab) instead of a generic bucket.
  static const Map<String, String> _catalogToGmCategory = {'Guitar': 'Guitars'};

  List<InstrumentCategory> _categories() {
    final gm = instrumentCategoriesForTrack(widget.trackId);
    final gmNames = {for (final c in gm) c.label};
    // Group catalog instruments: those whose category maps onto a GM group name
    // merge into it; the rest collect into a single "Cloud sounds" group.
    final merged = <String, List<InstrumentDef>>{};
    final cloud = <InstrumentDef>[];
    for (final inst in _catalogInstruments()) {
      final e = SoundfontCatalog.instance.bySlot(inst.program);
      final target = _catalogToGmCategory[e?.category] ?? e?.category ?? '';
      if (gmNames.contains(target)) {
        (merged[target] ??= <InstrumentDef>[]).add(inst);
      } else {
        cloud.add(inst);
      }
    }
    final base = <InstrumentCategory>[
      for (final c in gm)
        if (merged.containsKey(c.label))
          InstrumentCategory(c.label, [...c.instruments, ...merged[c.label]!])
        else
          c,
      if (cloud.isNotEmpty) InstrumentCategory('Cloud sounds', cloud),
    ];
    if (_favorites.isEmpty) return base;
    final favorites = [
      for (final inst in instrumentsForTrack(widget.trackId))
        if (_favorites.contains(inst.program)) inst,
      for (final inst in _catalogInstruments())
        if (_favorites.contains(inst.program)) inst,
    ];
    if (favorites.isEmpty) return base;
    return [InstrumentCategory('Favorites', favorites), ...base];
  }

  // Runtime-catalog instruments matching this track's role.
  List<InstrumentDef> _catalogInstruments() {
    final role = instrumentFavoriteKeyForTrack(widget.trackId); // melody|bass|drums
    return [
      for (final e in SoundfontCatalog.instance.all)
        if (e.role == role) InstrumentDef(e.id, e.label, e.slot),
    ];
  }

  void _toggleFavorite(int program) {
    setState(() {
      if (_favorites.contains(program)) {
        _favorites.remove(program);
        if (_categoryIndex == 0 && _favorites.isEmpty) _categoryIndex = 0;
      } else {
        _favorites.add(program);
      }
    });
    LoopPrefs.instance.toggleInstrumentFavorite(_favoriteKey, program);
  }

  @override
  Widget build(BuildContext context) {
    final categories = _categories();
    final categoryIndex =
        _categoryIndex.clamp(0, categories.length - 1).toInt();
    final category = categories[categoryIndex];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${widget.trackLabel} instrument',
          style: LTType.inter(size: 15, weight: FontWeight.w800, color: LT.t1),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 34,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            itemCount: categories.length,
            separatorBuilder: (_, __) => const SizedBox(width: 6),
            itemBuilder:
                (context, i) => _CategoryChip(
                  label: categories[i].label,
                  selected: i == categoryIndex,
                  onTap: () => setState(() => _categoryIndex = i),
                ),
          ),
        ),
        const SizedBox(height: 12),
        // Non-scrolling grid: the modal's own SingleChildScrollView (lt_modal)
        // handles scrolling, so every item in the category renders — otherwise
        // a nested scroll clipped tall categories (16 items) in landscape.
        ValueListenableBuilder<Map<int, double>>(
          valueListenable: SoundfontCatalog.instance.downloadProgress,
          builder: (context, prog, _) => GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 3.6,
            children: [
              for (final inst in category.instruments)
                _PickButton(
                  label: inst.label,
                  favorite: _favorites.contains(inst.program),
                  selected: inst.program == _program,
                  onTap: () => _pick(inst.program),
                  onFavorite: () => _toggleFavorite(inst.program),
                  // cloud sounds: download icon / progress ring / ready check
                  cloud: isDynamicSlot(inst.program),
                  progress: prog[inst.program],
                  downloaded: SoundfontCatalog.instance.isDownloaded(inst.program),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = selected ? LT.lime : LT.surface2;
    final fg = selected ? LT.bg : LT.t2;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        constraints: const BoxConstraints(minWidth: 72),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? LT.lime : LT.border),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: LTType.inter(size: 12, weight: FontWeight.w800, color: fg),
        ),
      ),
    );
  }
}

class _PickButton extends StatelessWidget {
  const _PickButton({
    required this.label,
    required this.favorite,
    required this.selected,
    required this.onTap,
    required this.onFavorite,
    this.cloud = false,
    this.progress,
    this.downloaded = false,
  });
  final String label;
  final bool favorite;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onFavorite;
  // Runtime-catalog ("cloud") sound state for the leading status glyph.
  final bool cloud;
  // 0..1 while downloading (progress ring), null otherwise.
  final double? progress;
  final bool downloaded;

  @override
  Widget build(BuildContext context) {
    final bg = selected ? LT.lime : LT.surface2;
    final fg = selected ? LT.bg : LT.t1;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? LT.lime : LT.border),
        ),
        child: Row(
          children: [
            if (cloud) ...[
              progress != null
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      // determinate ring so a 200–400MB download reads as real
                      // progress, not a stuck spinner
                      child: CircularProgressIndicator(
                          value: progress,
                          strokeWidth: 2,
                          color: selected ? LT.bg : LT.t3),
                    )
                  : Ms(
                      downloaded ? LtIcons.checkCircle : LtIcons.download,
                      size: 15,
                      color: downloaded
                          ? (selected ? LT.bg : LT.lime)
                          : (selected ? LT.bg : LT.t3),
                    ),
              const SizedBox(width: 5),
            ],
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: LTType.inter(
                  size: 13,
                  weight: FontWeight.w700,
                  color: fg,
                ),
              ),
            ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onFavorite,
              child: Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Ms(
                  favorite ? LtIcons.star : LtIcons.starBorder,
                  size: 17,
                  color: favorite ? LT.amber : (selected ? LT.bg : LT.t3),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
