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

    # Stage 5 — per-chunk analysis
    voiced_prob_threshold: float = Field(0.45, ge=0.0, le=1.0)

    # Stage 7 — key/scale (instrument lives client-side in Stage 8)
    auto_key: bool = True                 # detect key from the hummed pitches
    pitch_assistant: bool = True          # auto-correct off-scale notes to in-key
    key_tonic: Optional[str] = None       # "C", "F#", ... (used when auto_key=False)
    scale: Optional[Scale] = None         # used when auto_key=False
    quantize_strength: float = Field(1.0, ge=0.0, le=1.0)


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
    source: Literal["raw", "assistant", "user"] = "raw"  # provenance of `pitch`
    in_key: bool = True                     # pitch_original is in the detected key
    correction_cents: float = 0.0           # (pitch - pitch_raw) * 100, for diagnostics


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
    """Stage 5 raw pyin output, kept so the UI can overlay it."""
    times: List[float]
    hz: List[float]
    midi: List[float]
    voiced_prob: List[float]


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
