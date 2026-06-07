"""End-to-end eval of the note-sequence selector (cache-only, no rebuild).

For each cached file: generate enriched candidates, score them with the trained
keep-model, run a max-weight non-overlapping DP (weighted interval scheduling)
to emit a note sequence, then match against the reference with a per-file global
pitch shift (mirrors eval_humtrans --normalize-key) and report micro
precision/recall/note_f1 plus onset_f1 / onset_pitch_acc.

Compare the note_f1 here against the pYIN baseline (full dev 0.517) to see
whether the selector lifts segmentation end-to-end.
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

from eval_humtrans import note_from_dict, read_cache_file
from seq_candidates import FEATURES, gen_candidates


def _load_model(path: Path):
    d = np.load(path, allow_pickle=True)
    return d["mean"], d["std"], d["weights"], float(d["threshold"])


def _score(cands: list[dict], mean, std, w) -> np.ndarray:
    if not cands:
        return np.zeros(0)
    x = np.array([[c[f] for f in FEATURES] for c in cands], dtype=np.float32)
    z = (x - mean) / std
    zb = np.concatenate([z, np.ones((z.shape[0], 1), dtype=np.float32)], axis=1)
    return 1.0 / (1.0 + np.exp(-np.clip(zb @ w, -40, 40)))


def _dp_select(cands: list[dict], weights: np.ndarray) -> list[dict]:
    """Max-weight non-overlapping interval selection (touching allowed)."""
    n = len(cands)
    if n == 0:
        return []
    order = sorted(range(n), key=lambda i: cands[i]["end"])
    ends = np.array([cands[i]["end"] for i in order])
    starts = [cands[i]["start"] for i in order]
    w = [float(weights[i]) for i in order]
    # p[k] = largest index m<k with ends[m] <= starts[k]
    dp = [0.0] * (n + 1)
    take = [False] * n
    p = [0] * n
    for k in range(n):
        p[k] = int(np.searchsorted(ends, starts[k] + 1e-9, "right"))  # count ends <= start
    best = [0.0] * (n + 1)
    choice = [False] * n
    for k in range(1, n + 1):
        wk = w[k - 1]
        incl = wk + best[p[k - 1]]
        if incl > best[k - 1] and wk > 0:
            best[k] = incl
            choice[k - 1] = True
        else:
            best[k] = best[k - 1]
    # backtrack
    sel = []
    k = n
    while k > 0:
        if choice[k - 1] and (w[k - 1] + best[p[k - 1]] == best[k]) and w[k - 1] > 0:
            sel.append(order[k - 1])
            k = p[k - 1]
        else:
            k -= 1
    return [cands[i] for i in sorted(sel, key=lambda i: cands[i]["start"])]


def _best_shift_match(notes, ref, onset_tol, offset_tol):
    """Per-file global pitch shift maximizing full matches; return (matches, shift)."""
    if not notes or not ref:
        return 0, 0
    best_m, best_s = 0, 0
    for s in range(-12, 13):
        used_r = set()
        m = 0
        # greedy nearest
        cand = []
        for ni, n in enumerate(notes):
            for ri, r in enumerate(ref):
                if (abs(n["start"] - r.start) <= onset_tol
                        and abs(n["end"] - r.end) <= offset_tol
                        and int(n["pitch"]) + s == int(r.pitch)):
                    cand.append((abs(n["start"] - r.start), ni, ri))
        cand.sort()
        used_n = set()
        for _, ni, ri in cand:
            if ni in used_n or ri in used_r:
                continue
            used_n.add(ni); used_r.add(ri); m += 1
        if m > best_m:
            best_m, best_s = m, s
    return best_m, best_s


def _onset_match(notes, ref, onset_tol, shift):
    cand = []
    for ni, n in enumerate(notes):
        for ri, r in enumerate(ref):
            if abs(n["start"] - r.start) <= onset_tol:
                cand.append((abs(n["start"] - r.start), ni, ri))
    cand.sort()
    un, ur = set(), set()
    om = 0
    pitch_ok = 0
    for _, ni, ri in cand:
        if ni in un or ri in ur:
            continue
        un.add(ni); ur.add(ri); om += 1
        if int(notes[ni]["pitch"]) + shift == int(ref[ri].pitch):
            pitch_ok += 1
    return om, pitch_ok


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache-dir", type=Path, required=True)
    ap.add_argument("--split", default="dev")
    ap.add_argument("--model", type=Path, required=True)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--offset", type=int, default=0)
    ap.add_argument("--tau", type=float, default=None, help="DP weight = score - tau (default: model threshold)")
    ap.add_argument("--onset-tol", type=float, default=0.12)
    ap.add_argument("--offset-tol", type=float, default=0.18)
    ap.add_argument("--max-dur", type=float, default=1.30)
    args = ap.parse_args()

    mean, std, w, thr = _load_model(args.model)
    tau = args.tau if args.tau is not None else thr

    files = sorted((args.cache_dir / args.split).glob("*.json.gz"))
    if args.offset:
        files = files[args.offset:]
    if args.limit:
        files = files[: args.limit]

    M = R = P = 0  # matches, ref count, pred count
    OM = OPH = 0   # onset matches, onset pitch hits
    sel_total = 0
    for f in files:
        data = read_cache_file(f)
        ref = [note_from_dict(x) for x in data.get("ref_notes", [])]
        pred = [note_from_dict(x) for x in data.get("pred_notes", [])]
        meta = dict(data.get("analysis_meta", {}))
        if not ref:
            continue
        cands = gen_candidates(meta, pred, max_dur=args.max_dur)
        scores = _score(cands, mean, std, w)
        weights = scores - tau
        sel = _dp_select(cands, weights)
        sel_total += len(sel)
        R += len(ref)
        P += len(sel)
        m, shift = _best_shift_match(sel, ref, args.onset_tol, args.offset_tol)
        M += m
        om, oph = _onset_match(sel, ref, args.onset_tol, shift)
        OM += om; OPH += oph

    prec = M / P if P else 0.0
    rec = M / R if R else 0.0
    f1 = 2 * prec * rec / (prec + rec) if prec + rec else 0.0
    print(f"=== sequence-selector end-to-end ({args.split}, {len(files)} files, tau={tau:.3f}) ===")
    print(f"  ref={R} pred(selected)={P} (~{sel_total/max(len(files),1):.1f}/file)")
    print(f"  note precision = {prec:.3f}")
    print(f"  note recall    = {rec:.3f}")
    print(f"  note f1        = {f1:.3f}   (pYIN baseline full-dev 0.517)")
    print(f"  onset_f1(approx)= {2*(OM/P)*(OM/R)/((OM/P)+(OM/R)) if P and R and OM else 0:.3f}")
    print(f"  onset_pitch_acc = {OPH/OM if OM else 0:.3f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
