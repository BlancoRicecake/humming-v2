from __future__ import annotations

from copy import deepcopy

import pytest
from fastapi.testclient import TestClient

from app.arrangement import ArrangementRequest, SongSpec, enforce_locks
from app.main import app


def _song() -> dict:
    return {
        "schema": "humtrack.song-spec",
        "version": 1,
        "title": "Locked idea",
        "tonic": "C",
        "scale": "major",
        "bpm": 100,
        "swing": 0.0,
        "locks": {"melody": True},
        "sections": [
            {
                "id": "a",
                "name": "A",
                "bars": 1,
                "repeats": 1,
                "tracks": {
                    "melody": {
                        "notes": [
                            {
                                "midi": 60,
                                "step": 0,
                                "duration": 4,
                                "sourceMidi": 59,
                                "confidence": 0.8,
                                "locked": True,
                            }
                        ]
                    }
                },
            }
        ],
    }


def test_song_spec_and_locked_melody_invariant() -> None:
    source = SongSpec.model_validate(_song())
    generated = deepcopy(_song())
    generated["sections"][0]["tracks"]["bass"] = {
        "notes": [{"midi": 36, "step": 0, "duration": 4}]
    }
    enforce_locks(source, [SongSpec.model_validate(generated)])

    generated["sections"][0]["tracks"]["melody"]["notes"][0]["midi"] = 61
    with pytest.raises(ValueError, match="locked melody"):
        enforce_locks(source, [SongSpec.model_validate(generated)])


def test_bad_note_beyond_section_is_rejected() -> None:
    song = _song()
    song["sections"][0]["tracks"]["melody"]["notes"][0]["step"] = 15
    song["sections"][0]["tracks"]["melody"]["notes"][0]["duration"] = 2
    with pytest.raises(ValueError, match="exceeds section"):
        SongSpec.model_validate(song)


def test_feature_flag_is_off_by_default() -> None:
    with TestClient(app) as client:
        caps = client.get("/arrangements/capabilities")
        assert caps.status_code == 200
        assert caps.json()["enabled"] is False
        response = client.post(
            "/arrangements/generate",
            json=ArrangementRequest(song=SongSpec.model_validate(_song())).model_dump(
                by_alias=True
            ),
        )
        assert response.status_code == 503
