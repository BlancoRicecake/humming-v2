from typing import List, Optional

NOTE_TO_PC = {
    "C": 0, "C#": 1, "DB": 1, "D": 2, "D#": 3, "EB": 3, "E": 4,
    "F": 5, "F#": 6, "GB": 6, "G": 7, "G#": 8, "AB": 8, "A": 9,
    "A#": 10, "BB": 10, "B": 11,
}

SCALE_INTERVALS = {
    "major": [0, 2, 4, 5, 7, 9, 11],
    "minor": [0, 2, 3, 5, 7, 8, 10],
    "harmonic_minor": [0, 2, 3, 5, 7, 8, 11],
    "melodic_minor": [0, 2, 3, 5, 7, 9, 11],
    "dorian": [0, 2, 3, 5, 7, 9, 10],
    "phrygian": [0, 1, 3, 5, 7, 8, 10],
    "lydian": [0, 2, 4, 6, 7, 9, 11],
    "mixolydian": [0, 2, 4, 5, 7, 9, 10],
    "locrian": [0, 1, 3, 5, 6, 8, 10],
    "major_pentatonic": [0, 2, 4, 7, 9],
    "minor_pentatonic": [0, 3, 5, 7, 10],
    "blues": [0, 3, 5, 6, 7, 10],
    "chromatic": list(range(12)),
}


def tonic_to_pc(tonic: str) -> int:
    key = tonic.strip().upper().replace("♯", "#").replace("♭", "B")
    if key not in NOTE_TO_PC:
        raise ValueError(f"unknown tonic: {tonic}")
    return NOTE_TO_PC[key]


def scale_pitch_classes(tonic: str, scale: str) -> List[int]:
    if scale not in SCALE_INTERVALS:
        raise ValueError(f"unknown scale: {scale}")
    root_pc = tonic_to_pc(tonic)
    return sorted({(root_pc + i) % 12 for i in SCALE_INTERVALS[scale]})


def quantize_midi_to_scale(
    midi_pitch_float: float,
    tonic: Optional[str],
    scale: Optional[str],
    strength: float = 1.0,
) -> int:
    """Snap a float MIDI value to the nearest scale degree.

    strength=1.0 = full snap, 0.0 = no snap (just round).
    """
    if tonic is None or scale is None or scale == "chromatic":
        return int(round(midi_pitch_float))

    pcs = scale_pitch_classes(tonic, scale)
    base_round = int(round(midi_pitch_float))
    base_pc = base_round % 12

    # find nearest scale pitch class in either direction (within an octave)
    best = base_round
    best_dist = 1e9
    for octave_shift in (-1, 0, 1):
        for pc in pcs:
            candidate = base_round - base_pc + pc + 12 * octave_shift
            dist = abs(candidate - midi_pitch_float)
            if dist < best_dist:
                best_dist = dist
                best = candidate

    if strength >= 0.999:
        return int(best)
    # partial snap toward `best`
    blended = midi_pitch_float * (1 - strength) + best * strength
    return int(round(blended))
