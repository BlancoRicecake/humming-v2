"""Runtime SoundFont catalog — instruments the mobile app downloads on demand
instead of bundling at build time. Adding a sound needs NO app release: drop a
.sf2 into the soundfonts dir and add a row to catalog.json.

Layout (HUMMING_SOUNDFONTS_DIR, default backend/soundfonts/):
    soundfonts/
      catalog.json          # the curated manifest (list of entries)
      warm_rhodes.sf2       # the SoundFont files referenced by entries

catalog.json entry shape (see SoundfontEntry):
    {
      "id": "warm_rhodes",          # stable id (also the download path segment)
      "slot": 1001,                 # unique program slot >= 1000 the app stores
      "label": "Warm Rhodes",       # picker label
      "role": "melody",             # melody | bass | drums
      "category": "Keys",           # picker sub-group
      "file": "warm_rhodes.sf2",    # file in this dir
      "sf_bank": 0,                 # bank/program WITHIN the sf2 (usually 0/0)
      "sf_program": 0,
      "midi_fallback": 4,           # nearest GM program for .mid export
      "license": "CC0"              # must be CC0 / royalty-free (commercial app)
    }

The app stores `slot` as the track's program; live playback loads the file via
flutter_midi_pro, WAV export renders it through dart_melty_soundfont, and .mid
export substitutes `midi_fallback` (a Standard MIDI File can't carry a patch).
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
from typing import Dict, List, Optional

DEFAULT_DIR = str(Path(__file__).resolve().parent.parent / "soundfonts")


def soundfonts_dir() -> Path:
    return Path(os.environ.get("HUMMING_SOUNDFONTS_DIR", DEFAULT_DIR))


# Slot numbering: GM 0-127, 808=128, hip-hop=200 are reserved by the app; the
# runtime catalog owns slot >= 1000 so a downloaded sound never collides.
MIN_SLOT = 1000

_REQUIRED = {"id", "slot", "label", "role", "file"}
_ROLES = {"melody", "bass", "drums"}


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _read_catalog_file() -> List[dict]:
    cat = soundfonts_dir() / "catalog.json"
    if not cat.is_file():
        return []
    try:
        data = json.loads(cat.read_text(encoding="utf-8"))
    except Exception:
        return []
    return data if isinstance(data, list) else data.get("soundfonts", [])


def load_catalog() -> List[dict]:
    """Validated, download-ready manifest. Skips malformed rows, rows whose
    file is missing, duplicate ids/slots, and slots below MIN_SLOT — so a typo
    can never ship a broken entry to clients."""
    out: List[dict] = []
    seen_ids: set[str] = set()
    seen_slots: set[int] = set()
    base = soundfonts_dir()
    for raw in _read_catalog_file():
        if not isinstance(raw, dict) or not _REQUIRED.issubset(raw):
            continue
        sid = str(raw["id"])
        role = str(raw["role"])
        try:
            slot = int(raw["slot"])
        except (TypeError, ValueError):
            continue
        if role not in _ROLES or slot < MIN_SLOT:
            continue
        if sid in seen_ids or slot in seen_slots:
            continue
        path = base / str(raw["file"])
        if not path.is_file():
            continue
        seen_ids.add(sid)
        seen_slots.add(slot)
        out.append({
            "id": sid,
            "slot": slot,
            "label": str(raw["label"]),
            "role": role,
            "category": str(raw.get("category", "")),
            "bytes": path.stat().st_size,
            "sha256": _sha256(path),
            "sf_bank": int(raw.get("sf_bank", 0)),
            "sf_program": int(raw.get("sf_program", 0)),
            "midi_fallback": int(raw.get("midi_fallback", 0)),
            "license": str(raw.get("license", "")),
        })
    return out


def entry_file(entry_id: str) -> Optional[Path]:
    """The .sf2 path for a catalog id, or None if not in the validated catalog."""
    for e in load_catalog():
        if e["id"] == entry_id:
            p = soundfonts_dir() / _catalog_filename(entry_id)
            return p if p and p.is_file() else None
    return None


def _catalog_filename(entry_id: str) -> Optional[str]:
    for raw in _read_catalog_file():
        if isinstance(raw, dict) and str(raw.get("id")) == entry_id:
            return str(raw.get("file", ""))
    return None
