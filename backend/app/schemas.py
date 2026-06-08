"""Schemas for the SoundLab — minimal MVP, one shape per stage.

Each section below corresponds to one of the 9 pipeline stages described in
``analyze.py``. Adding a feature later = extend the relevant model only.
"""
from typing import List, Literal, Optional
from pydantic import BaseModel, Field


# --- Stage 7 inputs (key/scale/instrument) ------------------------------------
Scale = Literal[
    "major", "minor", "harmonic_minor", "melodic_minor",
    "dorian", "phrygian", "lydian", "mixolydian", "locrian",
    "major_pentatonic", "minor_pentatonic", "blues", "chromatic",
]


class AnalyzeOptions(BaseModel):
    """User-facing knobs. Stage numbers in comments map back to analyze.py."""
    # Stage 2 — preprocessing
    fmin_hz: float = 65.0
    fmax_hz: float = 1000.0

    # Stage 3 — voice region detection
    enter_ratio: float = Field(0.20, ge=0.0, le=1.0)
    exit_ratio: float = Field(0.12, ge=0.0, le=1.0)
    exit_hold_sec: float = Field(0.025, gt=0.0)

    # Stage 4 — chunk segmentation
    min_chunk_dur_sec: float = Field(0.06, gt=0.0)
    merge_gap_sec: float = Field(0.04, ge=0.0)
    # Optional internal subdivision (already-validated on samples 1/2/3)
    rms_dip_split: bool = True
    pitch_split: bool = True
    # rms-dip splitter targets "same note repeated softly" — only apply it when
    # the chunk's pitch is roughly flat (robust p90-p10 span ≤ this many
    # semitones). A moving/legato contour is owned by pitch_split; firing
    # rms-dip there chops a smooth glide into choppy false repeats (observed on
    # raw phone humming with amplitude tremolo). 1.2 keeps all 5 samples intact.
    rms_dip_max_pitch_span_st: float = Field(1.2, ge=0.0)

    # Stage 4b — drum mode (onset-based; bypasses the pitch gate, classifies by timbre)
    # Set true by the client when the track role is "drum". Notes come from onsets,
    # not pYIN pitch locks, so unpitched percussion (hi-hats) no longer vanishes.
    as_drums: bool = False

    # Stage 5 — per-chunk analysis
    voiced_prob_threshold: float = Field(0.45, ge=0.0, le=1.0)
    # Pitch tracker backend. "pyin" (librosa, default) or "crepe" (pretrained
    # CNN tracker, opt-in). CREPE is more octave-robust on low humming but
    # heavier; kept opt-in so the default path stays unchanged. Both expose the
    # same (times, hz, voiced_flag, voiced_prob) contract, so downstream is
    # untouched. voiced_prob_threshold above doubles as the CREPE confidence gate.
    pitch_model: Literal["pyin", "crepe"] = "pyin"

    # Stage 7 — key/scale (instrument lives client-side in Stage 8)
    auto_key: bool = True                 # detect key from the hummed pitches
    pitch_assistant: bool = True          # auto-correct off-scale notes to in-key
    learned_pitch_correction: bool = True # conservative HumTrans-trained +/-1 semitone fixer
    learned_offset_correction: bool = False # opt-in until full-dev validation passes
    # Aggressive mode: when a key is present, snap EVERY off-scale note to the
    # nearest in-key pitch (raises the correction cap past a semitone). Default
    # True because HumTrack currently favors usable MIDI over raw transcription.
    # False = "only fix small slips, keep intent".
    assist_aggressive: bool = True
    key_tonic: Optional[str] = None       # "C", "F#", ... (used when auto_key=False)
    scale: Optional[Scale] = None         # used when auto_key=False

    # Stage 6b — timing refinement / musical quantize
    # These shape note timing only; pitch analysis is unchanged. The client
    # sends the project BPM and track grid so backend note starts already land
    # close to the same grid used by playback/export.
    timing_refine: bool = True
    bass_cleanup: bool = False
    tempo_bpm: float = Field(90.0, ge=20.0, le=320.0)
    quantize_grid: int = Field(16, ge=1, le=128)
    timing_grid_quantize: bool = False
    quantize_strength: float = Field(0.45, ge=0.0, le=1.0)

    # Stage 6c — loop-grid mode (LoopTap). When enabled, notes are HARD-snapped to
    # a fixed bar×step grid (not the soft partial-quantize HumTrack uses), de-swung
    # before snapping, deduped per step, constrained to the loop length, and each
    # note carries integer ``step`` / ``dur_steps`` so the client never re-rounds.
    # Off by default so the portrait HumTrack timeline path is unaffected.
    loop_quantize: bool = False
    loop_bars: Optional[int] = Field(None, ge=1, le=16)  # total bars in the loop (2 or 4)
    steps_per_bar: int = Field(16, ge=1, le=64)          # LoopTap kBeatsPerBar*kStepsPerBeat
    swing: float = Field(0.0, ge=0.0, le=0.75)           # song swing; odd 16ths shifted by swing*0.5
    # Hummed/sung notes often become pitch-stable after the audible attack.
    # Search backward for attack evidence so MIDI notes start with the syllable,
    # not only after pYIN has settled on a stable pitch.
    timing_attack_lookback_sec: float = Field(0.24, ge=0.0, le=0.60)
    timing_max_advance_sec: float = Field(0.28, ge=0.0, le=0.60)
    timing_max_delay_sec: float = Field(0.06, ge=0.0, le=0.20)
    timing_fill_gaps: bool = True
    timing_fill_max_gap_sec: float = Field(0.50, ge=0.0, le=0.50)


# --- Stage 6 output -----------------------------------------------------------
class Note(BaseModel):
    start: float
    end: float
    duration: float
    pitch: int            # current MIDI note (0-127) after assistant/edits
    pitch_raw: float      # median MIDI float before any correction
    pitch_hz: float
    velocity: int         # 1-127
    confidence: float     # mean pyin voiced_prob inside the chunk
    voiced_ratio: float
    # When the analyzer falls back to "percussive" mode (e.g. beatbox samples
    # where chunks are clearly present but pyin can't lock a pitch), every note
    # is tagged ``"percussive"`` and pitch carries a generic drum value
    # (default 38 = GM Acoustic Snare on channel 10).
    kind: Literal["pitched", "percussive"] = "pitched"
    # --- Pitch Assistant metadata (Stage 7) ---
    pitch_original: int = 0                 # round(pitch_raw) before correction
    assisted: bool = False                  # assistant changed pitch from original
    candidates: List[int] = Field(default_factory=list)  # in-key options for editing
    source: Literal["raw", "assistant", "user", "model"] = "raw"  # provenance of `pitch`
    in_key: bool = True                     # pitch_original is in the detected key
    correction_cents: float = 0.0           # (pitch - pitch_raw) * 100, for diagnostics
    # --- Loop-grid placement (Stage 6c; only populated when loop_quantize=True) ---
    # Integer grid coordinates so the LoopTap client places notes directly instead
    # of re-rounding seconds (which discarded the engine's grid phase). null in the
    # HumTrack timeline path.
    step: Optional[int] = None              # 0-based 16th-step index in the loop
    dur_steps: Optional[int] = None         # duration in grid steps (>=1)
    # --- Drum timbre classification (Stage 6 add-on; see drums.py) ---
    # Computed for EVERY note from its onset segment's spectrum so a drum-role
    # track maps to a real GM kit by SOUND, not pitch. Always populated for
    # debug visibility; the client applies `drum` only when role == "drum".
    drum: Optional[int] = None              # GM percussion note (36 Kick / 38 Snare / 42 HiHat)
    drum_name: Optional[str] = None         # "Kick" | "Snare" | "HiHat"
    drum_centroid: float = 0.0              # spectral centroid (Hz) — debug
    drum_low_ratio: float = 0.0             # energy fraction < 150Hz — debug (phone-stripped; not used in decision)
    drum_high_ratio: float = 0.0            # energy fraction > 5kHz — debug
    drum_zcr: float = 0.0                   # zero-crossing rate (0-1) — debug
    drum_rolloff: float = 0.0               # spectral rolloff 85% (Hz) — debug (hi-hat high / kick low)
    drum_flatness: float = 0.0              # spectral flatness 0-1 — debug (snare noisy / kick tonal: kick↔snare axis)
    drum_lowmid_ratio: float = 0.0          # energy fraction 200-2kHz — debug (kick/snare body; classifier input)
    drum_mid_ratio: float = 0.0             # energy fraction 500-3kHz — debug (classifier input)
    drum_vhigh_ratio: float = 0.0           # energy fraction > 8kHz — debug (hi-hat air; classifier input)
    drum_sustain_ratio: float = 0.0         # 2nd-half/1st-half RMS over 120ms — debug (hat sustains, snare decays; classifier input)
    onset_strength: float = 0.0             # spectral-flux onset envelope at the hit — debug (0 for melodic notes)


# --- Debug surfaces (one per inspectable stage) -------------------------------
class Waveform(BaseModel):
    sample_rate: int
    duration: float
    peaks: List[float]            # Stage 2: downsampled |x|


class EnvelopeInfo(BaseModel):
    """Stage 3 output exposed for the debug overlay."""
    times: List[float]
    rms: List[float]
    noise_floor: float
    peak_level: float
    enter_threshold: float
    exit_threshold: float


class Chunk(BaseModel):
    """Stage 4 output (post-split, pre-pitch-analysis)."""
    start: float
    end: float
    peak_rms: float


class PitchTrack(BaseModel):
    """Stage 5 raw pitch-tracker output, kept so the UI can overlay it."""
    times: List[float]
    hz: List[float]
    midi: List[float]
    voiced_prob: List[float]
    model: str = "pyin"   # which tracker produced this contour ("pyin" | "crepe")


class DetectedKey(BaseModel):
    """Auto Key result (Stage 7)."""
    tonic: Optional[str] = None       # "C", "F#", ... or None if undetected
    scale: Optional[str] = None       # "major" | "minor" | None
    confidence: float = 0.0
    key_tier: Optional[Literal["high", "mid", "low"]] = None
    key_applied: bool = False         # was the key actually used to auto-correct


class KeyCandidate(BaseModel):
    tonic: str
    scale: str
    correlation: float


class AnalyzeResponse(BaseModel):
    notes: List[Note]
    chunks: List[Chunk]
    envelope: EnvelopeInfo
    pitch_track: PitchTrack
    waveform: Waveform
    options: AnalyzeOptions
    audio_id: str
    detected_key: Optional[DetectedKey] = None
    assist_applied_count: int = 0
    key_candidates: List[KeyCandidate] = Field(default_factory=list)
    # --- Decoder debug surface (Opus integration) ---
    # All optional for backwards compatibility with existing clients.
    input_codec: Optional[str] = None        # 'wav' | 'opus' | 'm4a' | 'caf' | 'aac' | 'unknown'
    input_sr: Optional[int] = None           # original sample rate, before TARGET_SR resample
    input_channels: Optional[int] = None
    input_bitrate_kbps: Optional[int] = None # populated for lossy (Opus/AAC)
    decoded_via: Optional[Literal["soundfile", "ffmpeg"]] = None
