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
import threading
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


# Hashing a soundfont is O(file size); the guitar-lab fonts are hundreds of MB
# and load_catalog() runs on every audition/render request. Cache by
# (path, size, mtime_ns) so a file is only re-hashed when it actually changes.
#
# The in-memory cache alone meant every machine boot paid ~50s on the first
# /soundfonts request (1GB of hashing), and Fly stops the idle machine daily.
# So the digests are ALSO persisted to SIDECAR next to the fonts — written at
# image build time (Dockerfile) and after any computation — keyed the same
# way, so an unchanged file is never hashed twice across restarts either.
_HASH_CACHE: Dict[str, str] = {}
SIDECAR = ".sha256.json"
_sidecar_loaded_for: Optional[Path] = None


def _key(path: Path) -> Optional[str]:
    try:
        st = path.stat()
    except OSError:
        return None
    # name + size only. mtime is deliberately NOT part of the key: it does not
    # survive the Docker layer round-trip (tar stores seconds; the build-time
    # stat had nanoseconds), which is exactly why the first sidecar shipped in
    # v33 never matched and every boot still hashed 1GB. Fonts are immutable
    # inside an image and the manifest sha256 is what the client verifies, so
    # a same-size silent edit is not a failure mode we need to detect here.
    return f"{path.name}:{st.st_size}"


def _load_sidecar(base: Path) -> None:
    global _sidecar_loaded_for
    if _sidecar_loaded_for == base:
        return
    _sidecar_loaded_for = base
    try:
        data = json.loads((base / SIDECAR).read_text(encoding="utf-8"))
        if isinstance(data, dict):
            _HASH_CACHE.update({str(k): str(v) for k, v in data.items()
                                if isinstance(v, str) and len(v) == 64})
    except (OSError, ValueError):
        pass


def _save_sidecar(base: Path) -> None:
    """Best-effort persist. The image dir is owned by the app user, so this
    works in production; a read-only mount just keeps the in-memory cache."""
    try:
        tmp = base / (SIDECAR + ".tmp")
        tmp.write_text(json.dumps(_HASH_CACHE, indent=0, sort_keys=True), encoding="utf-8")
        tmp.replace(base / SIDECAR)
    except OSError:
        pass


_HASH_LOCK = threading.Lock()


def _sha256(path: Path) -> str:
    _load_sidecar(path.parent)
    key = _key(path)
    if key is not None and key in _HASH_CACHE:
        return _HASH_CACHE[key]
    # One hasher at a time. Without this the startup warm-up thread and the
    # first request both chewed through the same 1GB on one shared CPU.
    with _HASH_LOCK:
        if key is not None and key in _HASH_CACHE:  # computed while we waited
            return _HASH_CACHE[key]
        h = hashlib.sha256()
        with path.open("rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        digest = h.hexdigest()
        if key is not None:
            _HASH_CACHE[key] = digest
            _save_sidecar(path.parent)
    return digest


def warm_hashes() -> int:
    """Hash every catalog font now (populating the sidecar). Returns the number
    of entries. Called at image build time and, as a fallback, in a background
    thread at startup so the first request never waits on 1GB of hashing."""
    return len(load_catalog())


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
