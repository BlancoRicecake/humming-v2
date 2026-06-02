"""Pitch Assistant — context-aware in-key correction with per-note candidates.

Operates on already-extracted notes (each carries ``pitch_raw``), so it never
re-runs pitch tracking. For every pitched note it:

1. computes ``pitch_original = round(pitch_raw)`` and whether it is in-key,
2. builds candidate pitches (nearest in-key below/above + the original),
3. if enabled and the note is off-scale, picks a recommendation by voice
   leading (closest to neighbours) and applies it.

Reuses ``scale_pitch_classes`` from scales.py for the in-key set.
"""
from __future__ import annotations

import math
from typing import List, Optional, Tuple

from .scales import scale_pitch_classes
from .key_detect import (
    build_pc_histogram, detect_key, key_weight, score_keys,
    KEY_CONF_HIGH, KEY_CONF_LOW,
)

# --- assistant tuning constants (adjust after reviewing diagnose.py dumps) ---
W_RAW = 1.0          # keep close to what the user sang (highest priority)
W_PREV = 0.35        # voice-leading to the already-chosen previous note
W_NEXT = 0.25        # voice-leading to the next note's raw pitch
# 보정 상한을 느슨하게: 0.7st 이내(음정 슬립/플랫·샤프)만 교정하고, 그보다 큰
# 이탈(≈1st 반음 = 의도한 다른 음)은 건드리지 않음 → "실수만 잡고 의도는 유지".
MAX_CORRECTION_ST = 0.7   # hard cap on auto-correction (semitones)
WEAK_MAX_ST = 0.5         # mid-confidence tier cap
AGGRESSIVE_MAX_ST = 99.0  # aggressive mode: effectively no cap → snap every off-scale note to scale
LOW_PITCH_CONF = 0.2      # below this note confidence → don't trust the pitch

# 오토키는 곡의 시작/초반부를 더 신뢰(보통 토닉·조성을 여기서 제시).
KEY_EARLY_EMPHASIS = 0.9  # t=0 노트 가중 (1 + 이 값)배
KEY_EARLY_TAU = 1.6       # 초 — 가중이 1/e 로 줄어드는 시간상수


def _midi_to_hz(midi: int) -> float:
    return float(440.0 * (2.0 ** ((midi - 69) / 12.0)))


def nearest_in_key(midi: int, pcs: List[int]) -> Tuple[int, int]:
    """Nearest in-key MIDI pitch at or below, and at or above, ``midi``."""
    below = above = None
    for d in range(0, 13):
        if below is None and (midi - d) % 12 in pcs:
            below = midi - d
        if above is None and (midi + d) % 12 in pcs:
            above = midi + d
        if below is not None and above is not None:
            break
    if below is None:
        below = midi
    if above is None:
        above = midi
    return below, above


def candidate_cost(c: int, raw: float, prev_chosen: Optional[float],
                   next_raw: Optional[float]) -> float:
    """Cost of choosing candidate ``c``: raw proximity first, context second.

    Keeps the result close to what the user actually sang (``W_RAW`` dominant),
    using neighbours only as a tiebreaker-strength influence.
    """
    cost = W_RAW * abs(c - raw)
    if prev_chosen is not None:
        cost += W_PREV * abs(c - prev_chosen)
    if next_raw is not None:
        cost += W_NEXT * abs(c - next_raw)
    return cost


def apply_assistant(
    notes: List["object"],
    tonic: Optional[str],
    scale: Optional[str],
    enabled: bool,
    key_confidence: float = 1.0,
    aggressive: bool = False,
    debug_out: Optional[list] = None,
) -> int:
    """Annotate + (optionally) correct notes in place. Returns applied count.

    Goal is "don't make it worse when uncertain": correction is gated by key
    confidence tier and a hard correction limit, and judged on the float raw
    pitch (``pitch_raw``) so a value sitting between two semitones isn't
    mis-decided by ``round``.

    Sets on each note: ``pitch_original``, ``in_key``, ``candidates``, ``pitch``,
    ``pitch_hz``, ``assisted``, ``source``, ``correction_cents``. ``debug_out``
    (if a list) gets a per-note dict incl. ``suppressed_reason``.
    """
    has_key = bool(tonic) and bool(scale) and scale != "chromatic"
    pcs = scale_pitch_classes(tonic, scale) if has_key else []
    # confidence tier → correction strength
    if not has_key:
        max_correction = 0.0
    elif key_confidence < KEY_CONF_LOW:
        max_correction = -1.0  # key too unreliable to correct against (even when aggressive)
    elif aggressive:
        # snap every off-scale note to the nearest in-key pitch (tone-deaf safety
        # net once the project key is locked). Still gated by pitch confidence.
        max_correction = AGGRESSIVE_MAX_ST
    elif key_confidence < KEY_CONF_HIGH:
        max_correction = WEAK_MAX_ST
    else:
        max_correction = MAX_CORRECTION_ST
    applied = 0

    prev_chosen: Optional[float] = None
    for i, n in enumerate(notes):
        if getattr(n, "kind", "pitched") != "pitched":
            n.pitch_original = int(n.pitch)
            n.in_key = True
            n.candidates = [int(n.pitch)]
            n.assisted = False
            n.source = "raw"
            n.correction_cents = 0.0
            if debug_out is not None:
                debug_out.append({"idx": i, "raw_float": float(n.pitch_raw),
                                  "kind": "percussive", "suppressed_reason": "percussive"})
            continue

        raw = float(n.pitch_raw)
        original = int(round(raw))
        n.pitch_original = original
        in_key = (not has_key) or (original % 12 in pcs)
        n.in_key = bool(in_key)

        if has_key:
            below, above = nearest_in_key(original, pcs)
            candidates = sorted({original, below, above})
        else:
            candidates = [original]
        n.candidates = [int(c) for c in candidates]

        next_raw = None
        for m in notes[i + 1:]:
            if getattr(m, "kind", "pitched") == "pitched":
                next_raw = float(m.pitch_raw)  # float — neighbour's sung pitch
                break

        in_key_cands = [c for c in candidates if (not has_key) or c % 12 in pcs] or candidates
        costs = {c: candidate_cost(c, raw, prev_chosen, next_raw) for c in in_key_cands}
        best = min(in_key_cands, key=lambda c: (costs[c], abs(c - raw), c))
        correction = abs(best - raw)

        # --- decide whether to auto-apply ---
        reason: Optional[str] = None
        if not enabled:
            reason = "assistant_off"
        elif not has_key:
            reason = "no_key"
        elif in_key:
            reason = "in_key"
        elif key_confidence < KEY_CONF_LOW:
            reason = "low_key_confidence"
        elif float(getattr(n, "confidence", 1.0)) < LOW_PITCH_CONF:
            reason = "low_pitch_confidence"
        elif correction > max_correction:
            reason = "correction_too_large"

        if reason is None:
            n.pitch = int(best)
            n.assisted = True
            n.source = "assistant"
            applied += 1
        else:
            n.pitch = original
            n.assisted = False
            n.source = "raw"

        n.correction_cents = round((n.pitch - raw) * 100.0, 1)
        n.pitch_hz = _midi_to_hz(n.pitch)

        if debug_out is not None:
            debug_out.append({
                "idx": i, "raw_float": round(raw, 3), "raw_note": original,
                "in_key": n.in_key, "candidates": list(n.candidates),
                "candidate_costs": {int(c): round(v, 2) for c, v in costs.items()},
                "selected": int(n.pitch), "correction_cents": n.correction_cents,
                "source": n.source, "suppressed_reason": reason,
            })

        prev_chosen = float(n.pitch)

    return applied


def run_key_and_assistant(
    notes: List["object"],
    auto_key: bool,
    pitch_assistant: bool,
    key_tonic: Optional[str],
    scale: Optional[str],
    assist_aggressive: bool = False,
    debug_out: Optional[list] = None,
) -> dict:
    """Single source of truth for Stage 7 (key detect + assistant).

    Called by analyze_audio, the /assist endpoint, and diagnose.py so all
    three behave identically. Returns ``{tonic, scale, confidence, applied,
    hist, n_pitched}``. (v1 internals; key_weight / guards / confidence tiers
    are wired into the marked spots in later steps.)
    """
    pitched = [n for n in notes if getattr(n, "kind", "pitched") == "pitched"]
    hist = None
    tonic: Optional[str] = None
    scl: Optional[str] = None
    conf = 0.0
    if pitched:
        midis = [round(float(n.pitch_raw)) for n in pitched]
        # 초반부 가중: 시작 시각이 이를수록 키 히스토그램에 더 크게 기여.
        weights = [
            key_weight(n.duration, n.confidence, n.voiced_ratio)
            * (1.0 + KEY_EARLY_EMPHASIS * math.exp(-float(getattr(n, "start", 0.0)) / KEY_EARLY_TAU))
            for n in pitched
        ]
        hist = build_pc_histogram(midis, weights)
        total_dur = sum(float(n.duration) for n in pitched)
        if auto_key:
            tonic, scl, conf = detect_key(hist, n_notes=len(pitched), total_dur=total_dur)
        else:
            tonic, scl = key_tonic, scale
            conf = 1.0 if (key_tonic and scale) else 0.0
    applied = apply_assistant(
        notes, tonic, scl, pitch_assistant, key_confidence=conf,
        aggressive=assist_aggressive, debug_out=debug_out,
    )

    if tonic is None:
        key_tier = None
    elif conf >= KEY_CONF_HIGH:
        key_tier = "high"
    elif conf >= KEY_CONF_LOW:
        key_tier = "mid"
    else:
        key_tier = "low"
    # key was actually used to auto-correct (not suppressed for low confidence)
    key_applied = bool(pitch_assistant and tonic and conf >= KEY_CONF_LOW)
    top3 = [
        {"tonic": t, "scale": m, "correlation": round(c, 4)}
        for c, t, m in (score_keys(hist)[:3] if hist is not None else [])
    ]
    return {
        "tonic": tonic, "scale": scl, "confidence": conf,
        "applied": applied, "hist": hist, "n_pitched": len(pitched),
        "key_tier": key_tier, "key_applied": key_applied, "top3": top3,
    }
