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

  // catalog slots currently downloading (spinner in the grid)
  final Set<int> _downloading = {};

  Future<void> _pick(int program) async {
    // Runtime-catalog sound: fetch the SF2 first so the preview + playback use
    // the real instrument (not the piano fallback). Offline → toast, no select.
    if (isDynamicSlot(program) && !SoundfontCatalog.instance.isDownloaded(program)) {
      setState(() => _downloading.add(program));
      final path = await SoundfontCatalog.instance.ensureDownloaded(program);
      if (!mounted) return;
      setState(() => _downloading.remove(program));
      if (path == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Couldn\'t download that sound — check your connection'),
              duration: Duration(milliseconds: 1600)),
        );
        return;
      }
    }
    setState(() => _program = program);
    widget.onPick(program); // host swaps the live program + previews a note
  }

  List<InstrumentCategory> _categories() {
    final base = [
      ...instrumentCategoriesForTrack(widget.trackId),
      ..._catalogCategories(),
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

  // Runtime-catalog instruments matching this track's role, as a single
  // "Cloud sounds" category (empty when the catalog has none for the role).
  List<InstrumentDef> _catalogInstruments() {
    final role = instrumentFavoriteKeyForTrack(widget.trackId); // melody|bass|drums
    return [
      for (final e in SoundfontCatalog.instance.all)
        if (e.role == role) InstrumentDef(e.id, e.label, e.slot),
    ];
  }

  List<InstrumentCategory> _catalogCategories() {
    final list = _catalogInstruments();
    return list.isEmpty ? const [] : [InstrumentCategory('Cloud sounds', list)];
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
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 410),
          child: GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            shrinkWrap: true,
            physics: const ClampingScrollPhysics(),
            childAspectRatio: 3.6,
            children: [
              for (final inst in category.instruments)
                _PickButton(
                  label: inst.label,
                  favorite: _favorites.contains(inst.program),
                  selected: inst.program == _program,
                  onTap: () => _pick(inst.program),
                  onFavorite: () => _toggleFavorite(inst.program),
                  // cloud sounds: show download / downloading / ready state
                  cloud: isDynamicSlot(inst.program),
                  downloading: _downloading.contains(inst.program),
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
    this.downloading = false,
    this.downloaded = false,
  });
  final String label;
  final bool favorite;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onFavorite;
  // Runtime-catalog ("cloud") sound state for the leading status glyph.
  final bool cloud;
  final bool downloading;
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
              downloading
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: selected ? LT.bg : LT.t3))
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
