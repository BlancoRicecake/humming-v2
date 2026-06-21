"""Audition palette for the SoundLab sound-picker (Space B).

Builds the ordered, categorized list of sounds to audition PER TRACK TYPE
(melody / bass / drums), unifying three sources:

  * GM    — programs in the global SF2 (GeneralUser GS), bank 0 melodic / bank
            128 drum kits. Labels come live from ``render.list_presets()``.
  * catalog — downloaded soundfonts (backend/soundfonts/catalog.json), filtered
            by role. Empty today; tolerated.
  * sentinel — the app's two non-GM assets that live in their own .sf2 under
            mobile/assets/sounds/: the 808 sub-bass and the hip-hop kit.

Each item carries everything the frontend needs to display it (label/category),
request its render (sf_bank/sf_program/track_type + source routing), and record
it in the curation list. The render resolution itself lives in main.py
(``_resolve_audition_source``); this module only describes the catalog.

GM family boundaries mirror mobile/lib/looptap/music/instruments.dart
(kMelodyInstrumentCategories) — the documented Python↔Dart palette mirror.
"""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from . import render as render_mod
from . import soundfonts as soundfonts_mod

ROLES = ("melody", "bass", "drums")

# Sentinel sf2s live with the mobile assets, not in the backend catalog dir.
MOBILE_SOUNDS_DIR = (
    Path(__file__).resolve().parent.parent.parent / "mobile" / "assets" / "sounds"
)


@dataclass(frozen=True)
class GMFamily:
    label: str
    lo: int  # inclusive GM program
    hi: int  # inclusive GM program


# 12 standard-GM families (program ranges). Standard GM, so low maintenance.
MELODY_FAMILIES: List[GMFamily] = [
    GMFamily("Piano & Keys", 0, 7),
    GMFamily("Bells & Mallets", 8, 15),
    GMFamily("Organs & Reeds", 16, 23),
    GMFamily("Guitars", 24, 31),
    GMFamily("Bass", 32, 39),
    GMFamily("Strings & Orchestra", 40, 55),
    GMFamily("Brass", 56, 63),
    GMFamily("Woodwinds", 64, 79),
    GMFamily("Leads", 80, 87),
    GMFamily("Pads & Textures", 88, 103),
    GMFamily("World", 104, 111),
    GMFamily("Percussion & SFX", 112, 127),
]

# Dedicated bass GM programs (mirrors kBassInstruments' GM subset).
BASS_GM_PROGRAMS: List[int] = [32, 33, 34, 35, 36, 37, 38, 39, 43]

# GM drum kits at bank 128 (program, label) — mirrors kDrumKits.
GM_DRUM_KITS: List[Tuple[int, str]] = [
    (0, "Standard"), (8, "Room"), (16, "Power"), (24, "Electronic"),
    (25, "TR-808"), (32, "Jazz"), (40, "Brush"), (48, "Orchestra"),
]

# Non-GM app sentinels, keyed by their stable sentinel id.
SENTINELS: Dict[str, dict] = {
    "sentinel_808": {
        "role": "bass", "label": "808 Sub-Bass", "file": "808.sf2",
        "sf_bank": 0, "sf_program": 0,
    },
    "sentinel_hiphop": {
        "role": "drums", "label": "Hip-Hop Kit", "file": "hiphop_kit.sf2",
        "sf_bank": 128, "sf_program": 0,
    },
}


def sentinel_sf2_path(sentinel_id: str) -> Optional[Path]:
    """Filesystem path of a sentinel's .sf2, or None if id unknown / file gone."""
    meta = SENTINELS.get(sentinel_id)
    if meta is None:
        return None
    p = MOBILE_SOUNDS_DIR / str(meta["file"])
    return p if p.is_file() else None


def _live_name_lookup() -> Dict[Tuple[int, int], str]:
    """(bank, program) -> preset name from the currently loaded global SF2."""
    out: Dict[Tuple[int, int], str] = {}
    try:
        for p in render_mod.list_presets():
            out[(int(p["bank"]), int(p["program"]))] = str(p["name"])
    except Exception:
        pass
    return out


def _gm_item(program: int, category: str, track_type: str,
             names: Dict[Tuple[int, int], str]) -> dict:
    label = names.get((0, program), f"Program {program}")
    return {
        "key": f"gm:0:{program}",
        "source": "gm",
        "label": label,
        "category": category,
        "role": track_type,
        "sf_bank": 0,
        "sf_program": program,
        "track_type": track_type,
        "gm": {"bank": 0, "program": program},
        "soundfont_id": None,
        "sentinel_id": None,
    }


def _gm_kit_item(program: int, label: str,
                 names: Dict[Tuple[int, int], str]) -> dict:
    live = names.get((128, program))
    return {
        "key": f"gm:128:{program}",
        "source": "gm",
        "label": live or label,
        "category": "GM Kits",
        "role": "drums",
        "sf_bank": 128,
        "sf_program": program,
        "track_type": "drums",
        "gm": {"bank": 128, "program": program},
        "soundfont_id": None,
        "sentinel_id": None,
    }


def _sentinel_item(sentinel_id: str) -> dict:
    meta = SENTINELS[sentinel_id]
    return {
        "key": f"sentinel:{sentinel_id}",
        "source": "sentinel",
        "label": str(meta["label"]),
        "category": "Sentinel",
        "role": str(meta["role"]),
        "sf_bank": int(meta["sf_bank"]),
        "sf_program": int(meta["sf_program"]),
        "track_type": str(meta["role"]),
        "gm": None,
        "soundfont_id": None,
        "sentinel_id": sentinel_id,
    }


def _catalog_items(role: str) -> List[dict]:
    items: List[dict] = []
    for e in soundfonts_mod.load_catalog():
        if e.get("role") != role:
            continue
        items.append({
            "key": f"catalog:{e['id']}",
            "source": "catalog",
            "label": str(e.get("label", e["id"])),
            "category": str(e.get("category") or "Catalog"),
            "role": role,
            "sf_bank": int(e.get("sf_bank", 0)),
            "sf_program": int(e.get("sf_program", 0)),
            "track_type": role,
            "gm": None,
            "soundfont_id": str(e["id"]),
            "sentinel_id": None,
        })
    return items


def build_palette(role: str) -> List[dict]:
    """Ordered, categorized audition items for a track type.

    Order: GM sounds first (grouped by family / kit), then the role's sentinel,
    then any downloaded catalog sounds. Safe with an empty catalog.
    """
    if role not in ROLES:
        raise ValueError(f"role must be one of {ROLES}")
    names = _live_name_lookup()
    items: List[dict] = []

    if role == "melody":
        for fam in MELODY_FAMILIES:
            for prog in range(fam.lo, fam.hi + 1):
                items.append(_gm_item(prog, fam.label, "melody", names))
    elif role == "bass":
        for prog in BASS_GM_PROGRAMS:
            items.append(_gm_item(prog, "Bass (GM)", "bass", names))
        if sentinel_sf2_path("sentinel_808") is not None:
            items.append(_sentinel_item("sentinel_808"))
    else:  # drums
        for prog, label in GM_DRUM_KITS:
            items.append(_gm_kit_item(prog, label, names))
        if sentinel_sf2_path("sentinel_hiphop") is not None:
            items.append(_sentinel_item("sentinel_hiphop"))

    items.extend(_catalog_items(role))
    return items
