"""A/B audition renders: TimGM6mb (current app bank) vs GeneralUser GS v2 (candidate).

Renders the SoundLab audition phrase through FluidSynth — the same engine the
app's live path uses (flutter_midi_pro wraps FluidSynth) — for the instruments
the LoopTap picker actually features, plus the 8 GM drum kits, with BOTH banks.
Also reports which requested presets are missing from each bank (a missing
bank-128 kit would silently fall back on device).

The export-engine counterpart (dart_melty_soundfont) is
``mobile/tool/sf2_ab_melty.dart`` — listen to both: live and export must both
pass before swapping the app bank.

Run:
    .venv\\Scripts\\python.exe diag_sf2_ab.py [--out DIR]

Output:
    <out>/fluidsynth/<bank>/<NN label>.wav  (default out: ../../sf2_ab)
"""
from __future__ import annotations

import argparse
from pathlib import Path

from app import render as render_mod

REPO = Path(__file__).resolve().parent.parent  # "Humming V2"

BANKS = {
    "timgm": REPO / "mobile" / "assets" / "sounds" / "TimGM6mb.sf2",
    "gugs": Path(
        r"C:\Users\jlion\Downloads\GeneralUser_GS_v2.0.3--doc_r6"
        r"\GeneralUser-GS\GeneralUser-GS.sf2"
    ),
}

# LoopTap picker mainstays: defaults (0 piano, 33 fingered bass, kit 0) +
# the most-used melodic voices across the Recommended/Keys/Synth categories.
MELODIC = [
    (0, "Grand Piano"), (4, "Electric Piano"), (16, "Drawbar Organ"),
    (24, "Nylon Guitar"), (25, "Steel Guitar"), (33, "Fingered Bass"),
    (38, "Synth Bass 1"), (48, "String Ensemble"), (52, "Choir Aahs"),
    (56, "Trumpet"), (73, "Flute"), (80, "Square Lead"), (81, "Saw Lead"),
    (88, "New Age Pad"), (89, "Warm Pad"),
]
# kDrumKits in mobile/lib/looptap/music/instruments.dart (GM kits, bank 128).
KITS = [
    (0, "Standard"), (8, "Room"), (16, "Power"), (24, "Electronic"),
    (25, "TR-808"), (32, "Jazz"), (40, "Brush"), (48, "Orchestra"),
]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(REPO.parent / "sf2_ab"))
    args = ap.parse_args()

    render_mod.initialize()
    state = render_mod.get_state()
    if state.fluidsynth_module is None:
        raise SystemExit(f"fluidsynth unavailable: {state.error}")

    for bank_id, sf2 in BANKS.items():
        if not sf2.is_file():
            print(f"[{bank_id}] MISSING SF2: {sf2}")
            continue
        state.sf2_path = str(sf2)  # repoint the singleton per bank
        state.error = None
        presets = {
            (p["bank"], p["program"]): p["name"] for p in render_mod.list_presets()
        }
        out_dir = Path(args.out) / "fluidsynth" / bank_id
        out_dir.mkdir(parents=True, exist_ok=True)
        print(f"\n[{bank_id}] {sf2.name} — {len(presets)} presets")

        for sf_bank, wanted in ((0, MELODIC), (128, KITS)):
            for prog, label in wanted:
                present = (sf_bank, prog) in presets
                mark = "ok" if present else "MISSING (renders fallback)"
                wav = render_mod.render_demo_to_wav(bank=sf_bank, program=prog)
                kind = "kit" if sf_bank == 128 else "mel"
                name = f"{kind}{prog:03d} {label}.wav"
                (out_dir / name).write_bytes(wav)
                print(f"  {kind} {prog:3d} {label:16s} {mark}")

    print(f"\ndone → {Path(args.out).resolve()}\\fluidsynth\\<bank>\\*.wav")


if __name__ == "__main__":
    main()
