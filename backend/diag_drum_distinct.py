"""Objectively measure whether the 9 drum kits actually SOUND different.

Per-kit spectral centroid (kick<snare<hat) only proves note 36/38/42 trigger the
right *type* WITHIN a kit. It does NOT tell you whether Standard-kick and
Jazz-kick differ from EACH OTHER. This renders each kit's K(36)/S(38)/H(42) one
note through FluidSynth (same engine as the app's live path) and reports, per
voice, the cross-kit waveform correlation -- 1.000 == byte-identical sound.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
from app import render as render_mod

# The app's actual drum font (NOT render.py's GUGS default).
TIMGM = Path(__file__).resolve().parent.parent / "mobile" / "assets" / "sounds" / "TimGM6mb.sf2"

KITS = [
    (0, "Standard"), (8, "Room"), (16, "Power"), (24, "Electronic"),
    (25, "TR-808"), (32, "Jazz"), (40, "Brush"), (48, "Orchestra"),
]
VOICES = [("K", 36), ("S", 38), ("H", 42)]
SR = 44100


def render_note(synth, sfid, program, note, secs=0.6):
    synth.program_select(9, sfid, 128, int(program))
    synth.noteon(9, note, 100)
    buf = np.asarray(synth.get_samples(int(secs * SR)), dtype=np.int16)
    synth.noteoff(9, note)
    # flush a short tail then reset note state
    synth.get_samples(int(0.05 * SR))
    mono = buf.reshape(-1, 2).mean(axis=1).astype(np.float64)
    return mono


def centroid(x):
    x = x - x.mean()
    if np.allclose(x, 0):
        return 0.0
    spec = np.abs(np.fft.rfft(x))
    freqs = np.fft.rfftfreq(len(x), 1.0 / SR)
    s = spec.sum()
    return float((freqs * spec).sum() / s) if s else 0.0


def corr(a, b):
    n = min(len(a), len(b))
    a, b = a[:n] - a[:n].mean(), b[:n] - b[:n].mean()
    da, db = np.linalg.norm(a), np.linalg.norm(b)
    if da == 0 or db == 0:
        return 0.0
    return float(np.dot(a, b) / (da * db))


def main():
    render_mod.initialize()
    st = render_mod.get_state()
    if st.fluidsynth_module is None:
        raise SystemExit(f"fluidsynth unavailable: {st.error}")
    fs = st.fluidsynth_module
    synth = fs.Synth(samplerate=float(SR), gain=0.5)
    sfid = synth.sfload(str(TIMGM))
    if sfid == -1:
        raise SystemExit(f"sfload failed for {TIMGM}")

    # render every kit x voice
    wav = {}      # (kit, voice) -> mono
    cent = {}
    for prog, name in KITS:
        for vlabel, note in VOICES:
            m = render_note(synth, sfid, prog, note)
            wav[(name, vlabel)] = m
            cent[(name, vlabel)] = centroid(m)

    print(f"SF2: {st.sf2_path}")
    print("\n== per-kit spectral centroid (Hz) — should rise K<S<H within a kit ==")
    print(f"{'kit':<11} {'K(36)':>8} {'S(38)':>8} {'H(42)':>8}")
    for _, name in KITS:
        print(f"{name:<11} {cent[(name,'K')]:>8.0f} {cent[(name,'S')]:>8.0f} {cent[(name,'H')]:>8.0f}")

    for vlabel, note in VOICES:
        print(f"\n== cross-kit correlation for voice {vlabel} (note {note}) — 1.000=identical ==")
        names = [n for _, n in KITS]
        hdr = "".join(f"{n[:6]:>8}" for n in names)
        print(f"{'':<11}{hdr}")
        for ni in names:
            row = "".join(f"{corr(wav[(ni,vlabel)], wav[(nj,vlabel)]):>8.3f}" for nj in names)
            print(f"{ni:<11}{row}")

    # summarize clusters of identical kits per voice
    print("\n== identical-sound clusters (corr >= 0.999) ==")
    for vlabel, _ in VOICES:
        names = [n for _, n in KITS]
        seen, groups = set(), []
        for i, ni in enumerate(names):
            if ni in seen:
                continue
            grp = [ni]
            for nj in names[i+1:]:
                if nj not in seen and corr(wav[(ni,vlabel)], wav[(nj,vlabel)]) >= 0.999:
                    grp.append(nj); seen.add(nj)
            seen.add(ni)
            groups.append(grp)
        dup = [g for g in groups if len(g) > 1]
        print(f"  {vlabel}: {len(groups)} distinct sounds across 8 kits"
              + (f" | identical: {dup}" if dup else ""))


if __name__ == "__main__":
    main()
