"""Runtime soundfont catalog — validation + endpoints.

Points HUMMING_SOUNDFONTS_DIR at a temp dir so tests own the catalog without
touching the shipped one.
"""
import importlib
import json

import pytest
from fastapi.testclient import TestClient


@pytest.fixture()
def catalog_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUMMING_SOUNDFONTS_DIR", str(tmp_path))
    import app.soundfonts as sf

    importlib.reload(sf)
    return tmp_path, sf


def write_catalog(d, rows):
    (d / "catalog.json").write_text(json.dumps(rows), encoding="utf-8")


def make_sf2(d, name="inst.sf2", size=2048):
    # not a real SoundFont — the catalog only checks presence/size/sha here
    (d / name).write_bytes(b"SF2\x00" + b"\x01" * (size - 4))


def test_empty_catalog_is_empty_list(catalog_dir):
    d, sf = catalog_dir
    assert sf.load_catalog() == []


def test_valid_entry_round_trips_with_hash_and_size(catalog_dir):
    d, sf = catalog_dir
    make_sf2(d, "warm.sf2", size=4096)
    write_catalog(d, [{
        "id": "warm", "slot": 1001, "label": "Warm Rhodes", "role": "melody",
        "category": "Keys", "file": "warm.sf2", "midi_fallback": 4, "license": "CC0",
    }])
    cat = sf.load_catalog()
    assert len(cat) == 1
    e = cat[0]
    assert e["id"] == "warm" and e["slot"] == 1001 and e["bytes"] == 4096
    assert len(e["sha256"]) == 64
    assert e["midi_fallback"] == 4 and e["sf_bank"] == 0


def test_invalid_rows_are_skipped(catalog_dir):
    d, sf = catalog_dir
    make_sf2(d, "ok.sf2")
    write_catalog(d, [
        {"id": "ok", "slot": 1002, "label": "OK", "role": "bass", "file": "ok.sf2"},
        {"id": "low_slot", "slot": 200, "label": "X", "role": "melody", "file": "ok.sf2"},
        {"id": "bad_role", "slot": 1003, "label": "X", "role": "synth", "file": "ok.sf2"},
        {"id": "missing_file", "slot": 1004, "label": "X", "role": "melody", "file": "nope.sf2"},
        {"id": "missing_fields", "slot": 1005},
    ])
    cat = sf.load_catalog()
    assert [e["id"] for e in cat] == ["ok"]


def test_duplicate_id_and_slot_dropped(catalog_dir):
    d, sf = catalog_dir
    make_sf2(d, "a.sf2")
    make_sf2(d, "b.sf2")
    write_catalog(d, [
        {"id": "a", "slot": 1001, "label": "A", "role": "melody", "file": "a.sf2"},
        {"id": "a", "slot": 1009, "label": "A dup id", "role": "melody", "file": "b.sf2"},
        {"id": "c", "slot": 1001, "label": "C dup slot", "role": "melody", "file": "b.sf2"},
    ])
    assert [e["id"] for e in sf.load_catalog()] == ["a"]


def test_entry_file_resolves_only_validated(catalog_dir):
    d, sf = catalog_dir
    make_sf2(d, "warm.sf2")
    write_catalog(d, [{
        "id": "warm", "slot": 1001, "label": "Warm", "role": "melody", "file": "warm.sf2",
    }])
    assert sf.entry_file("warm") is not None
    assert sf.entry_file("ghost") is None


def test_endpoints(tmp_path, monkeypatch):
    monkeypatch.setenv("HUMMING_SOUNDFONTS_DIR", str(tmp_path))
    make_sf2(tmp_path, "warm.sf2", size=4096)
    write_catalog(tmp_path, [{
        "id": "warm", "slot": 1001, "label": "Warm Rhodes", "role": "melody", "file": "warm.sf2",
    }])
    # reload the module the app imported so it picks up the env-pointed dir
    import app.soundfonts as sf
    importlib.reload(sf)
    import app.main as main
    importlib.reload(main)

    client = TestClient(main.app)
    r = client.get("/soundfonts")
    assert r.status_code == 200
    body = r.json()
    assert len(body) == 1 and body[0]["id"] == "warm"

    r2 = client.get("/soundfonts/warm")
    assert r2.status_code == 200
    assert r2.content[:4] == b"SF2\x00"
    assert len(r2.content) == 4096

    assert client.get("/soundfonts/ghost").status_code == 404
