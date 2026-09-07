"""Catalog sha256 sidecar (.sha256.json).

Every machine boot used to hash every .sf2 (1GB in production) on the first
/soundfonts request — ~50s, and Fly stops the idle machine daily. The digest
is now persisted next to the fonts and reloaded, so an unchanged file is never
hashed twice across restarts, and the lifespan hook warms it off-path.
"""
import hashlib
import json

import pytest

from app import soundfonts as sf


@pytest.fixture
def catalog_dir(tmp_path, monkeypatch):
    (tmp_path / "a.sf2").write_bytes(b"A" * 5000)
    (tmp_path / "b.sf2").write_bytes(b"B" * 7000)
    (tmp_path / "catalog.json").write_text(json.dumps([
        {"id": "a", "slot": 1001, "label": "A", "role": "melody", "file": "a.sf2"},
        {"id": "b", "slot": 1002, "label": "B", "role": "bass", "file": "b.sf2"},
    ]), encoding="utf-8")
    monkeypatch.setenv("HUMMING_SOUNDFONTS_DIR", str(tmp_path))
    sf._HASH_CACHE.clear()
    sf._sidecar_loaded_for = None
    yield tmp_path
    sf._HASH_CACHE.clear()
    sf._sidecar_loaded_for = None


def test_first_load_writes_sidecar_with_correct_digests(catalog_dir):
    cat = sf.load_catalog()
    assert [e["id"] for e in cat] == ["a", "b"]
    assert cat[0]["sha256"] == hashlib.sha256(b"A" * 5000).hexdigest()

    side = json.loads((catalog_dir / sf.SIDECAR).read_text())
    assert len(side) == 2
    assert all(len(v) == 64 for v in side.values())
    # keyed by name:size:mtime, not by absolute path
    assert all(k.startswith(("a.sf2:", "b.sf2:")) for k in side)


def test_restart_uses_sidecar_without_hashing(catalog_dir, monkeypatch):
    sf.load_catalog()  # populate
    sf._HASH_CACHE.clear()  # simulate a fresh process
    sf._sidecar_loaded_for = None

    calls = []
    real = hashlib.sha256

    def spy(*a, **k):
        calls.append(1)
        return real(*a, **k)

    monkeypatch.setattr(sf.hashlib, "sha256", spy)
    cat = sf.load_catalog()
    assert len(cat) == 2
    assert calls == [], "digests must come from the sidecar, not be recomputed"


def test_changed_file_is_rehashed(catalog_dir):
    before = sf.load_catalog()[0]["sha256"]
    p = catalog_dir / "a.sf2"
    p.write_bytes(b"C" * 5000)  # same size, new content and mtime
    import os
    os.utime(p, ns=(p.stat().st_atime_ns, p.stat().st_mtime_ns + 10_000_000))
    after = sf.load_catalog()[0]["sha256"]
    assert after != before
    assert after == hashlib.sha256(b"C" * 5000).hexdigest()


def test_corrupt_sidecar_is_ignored(catalog_dir):
    (catalog_dir / sf.SIDECAR).write_text("{not json", encoding="utf-8")
    cat = sf.load_catalog()
    assert cat[0]["sha256"] == hashlib.sha256(b"A" * 5000).hexdigest()


def test_readonly_dir_still_serves(catalog_dir, monkeypatch):
    """A mount we cannot write to keeps the in-memory cache and no error."""
    def boom(self, *a, **k):
        raise OSError("read-only")
    monkeypatch.setattr(type(catalog_dir / "x"), "write_text", boom)
    cat = sf.load_catalog()
    assert len(cat) == 2
    assert not (catalog_dir / sf.SIDECAR).exists()


def test_warm_hashes_reports_count(catalog_dir):
    assert sf.warm_hashes() == 2
