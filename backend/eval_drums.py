"""Evaluate HumTrack drum onset/classification on labeled drum datasets.

Supported inputs:
  * --manifest-csv with columns: key,wav,labels
    labels may point to CSV/TXT/XML/SVL/MID/MIDI files.
  * --root auto-discovery for simple WAV + annotation/MIDI layouts.

The metric to watch for the current drum work is ``drum_f1``:
onset must match within tolerance AND the normalized class must match one of
Kick/Snare/HiHat. This keeps drum work separate from HumTrans pitch metrics.
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import math
import statistics
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

import mido

from app.analyze import analyze_audio
from app.schemas import AnalyzeOptions


CANON = ("kick", "snare", "hihat")
DEFAULT_COLLAPSE_PRIORITY = ("kick", "snare", "hihat")
GM_TO_CLASS = {
    35: "kick",
    36: "kick",
    37: "snare",
    38: "snare",
    40: "snare",
    42: "hihat",
    44: "hihat",
    46: "hihat",
    22: "hihat",
    26: "hihat",
}
TEXT_TO_CLASS = {
    "bd": "kick",
    "bass": "kick",
    "bassdrum": "kick",
    "bass_drum": "kick",
    "kick": "kick",
    "kd": "kick",
    "sd": "snare",
    "snare": "snare",
    "snaredrum": "snare",
    "snare_drum": "snare",
    "hh": "hihat",
    "hat": "hihat",
    "hihat": "hihat",
    "hi_hat": "hihat",
    "hi-hat": "hihat",
    "closedhihat": "hihat",
    "closed_hi_hat": "hihat",
    "open_hihat": "hihat",
    "openhihat": "hihat",
}


@dataclass(frozen=True)
class DrumEvent:
    time: float
    cls: str
    velocity: int = 100


@dataclass(frozen=True)
class DrumPair:
    key: str
    wav: Path
    labels: Path


def _norm_label(value: object) -> str | None:
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return GM_TO_CLASS.get(int(value))
    raw = str(value).strip()
    if not raw:
        return None
    try:
        return GM_TO_CLASS.get(int(float(raw)))
    except ValueError:
        pass
    compact = "".join(ch for ch in raw.lower() if ch.isalnum() or ch in "_-")
    compact = compact.replace("-", "_")
    if compact in TEXT_TO_CLASS:
        return TEXT_TO_CLASS[compact]
    for key, cls in TEXT_TO_CLASS.items():
        if key in compact:
            return cls
    return None


def _float_or_none(value: object) -> float | None:
    if value is None:
        return None
    try:
        out = float(str(value).strip())
    except ValueError:
        return None
    return out if math.isfinite(out) else None


def read_midi_events(path: Path, min_dur: float = 0.005) -> list[DrumEvent]:
    mid = mido.MidiFile(file=io.BytesIO(path.read_bytes()))
    tempo = 500000
    sec_per_tick = tempo / 1_000_000.0 / mid.ticks_per_beat
    events: list[DrumEvent] = []
    active: dict[int, list[float]] = {}
    t = 0.0
    for msg in mido.merge_tracks(mid.tracks):
        t += msg.time * sec_per_tick
        if msg.type == "set_tempo":
            tempo = msg.tempo
            sec_per_tick = tempo / 1_000_000.0 / mid.ticks_per_beat
            continue
        if not hasattr(msg, "note"):
            continue
        note = int(msg.note)
        if msg.type == "note_on" and int(getattr(msg, "velocity", 0)) > 0:
            cls = GM_TO_CLASS.get(note)
            if cls is not None:
                events.append(DrumEvent(t, cls, int(msg.velocity)))
            active.setdefault(note, []).append(t)
        elif msg.type in ("note_off", "note_on"):
            starts = active.get(note)
            if starts:
                start = starts.pop(0)
                if t - start < min_dur:
                    continue
    events.sort(key=lambda e: (e.time, e.cls))
    return events


def read_text_events(path: Path) -> list[DrumEvent]:
    events: list[DrumEvent] = []
    text = path.read_text(encoding="utf-8", errors="ignore")
    sample = "\n".join(line for line in text.splitlines()[:20] if line.strip())
    dialect = csv.Sniffer().sniff(sample, delimiters=",;\t ") if sample else csv.excel
    rows = csv.reader(io.StringIO(text), dialect)
    for row in rows:
        if not row or row[0].strip().startswith("#"):
            continue
        vals = [x.strip() for x in row if x.strip()]
        if len(vals) < 2:
            continue
        time = _float_or_none(vals[0])
        cls = None
        for value in vals[1:]:
            cls = _norm_label(value)
            if cls is not None:
                break
        if time is not None and cls in CANON:
            events.append(DrumEvent(time, cls))
    events.sort(key=lambda e: (e.time, e.cls))
    return events


def read_xml_events(path: Path, sample_rate: int = 44100) -> list[DrumEvent]:
    root = ET.fromstring(path.read_text(encoding="utf-8", errors="ignore"))
    events: list[DrumEvent] = []
    for event in root.iter():
        if event.tag.lower().split("}")[-1] != "event":
            continue
        fields = {child.tag.lower().split("}")[-1]: (child.text or "") for child in event}
        cls = _norm_label(fields.get("instrument") or fields.get("class") or fields.get("label"))
        time = (
            _float_or_none(fields.get("onsetsec"))
            or _float_or_none(fields.get("onset"))
            or _float_or_none(fields.get("time"))
        )
        if cls in CANON and time is not None:
            events.append(DrumEvent(time, cls))
    if events:
        events.sort(key=lambda e: (e.time, e.cls))
        return events

    for node in root.iter():
        attrs = {str(k).lower(): v for k, v in node.attrib.items()}
        label = (
            attrs.get("label")
            or attrs.get("class")
            or attrs.get("name")
            or attrs.get("value")
            or node.text
            or path.stem
        )
        cls = _norm_label(label)
        if cls not in CANON:
            continue
        time = (
            _float_or_none(attrs.get("time"))
            or _float_or_none(attrs.get("start"))
            or _float_or_none(attrs.get("onset"))
        )
        if time is None:
            frame = _float_or_none(attrs.get("frame") or attrs.get("sample"))
            if frame is not None:
                time = frame / sample_rate
        if time is not None:
            events.append(DrumEvent(time, cls))
    events.sort(key=lambda e: (e.time, e.cls))
    return events


def _class_from_name(name: str) -> str | None:
    """IDMT single-instrument suffix in the stem: ``#HH`` / ``#KD`` / ``#SD``.

    The single-instrument annotations carry the drum class in the FILENAME, not
    in the per-point label (every point is labelled ``New Point``), so the class
    has to be recovered from the stem here.
    """
    up = name.upper()
    if "#HH" in up:
        return "hihat"
    if "#KD" in up:
        return "kick"
    if "#SD" in up:
        return "snare"
    return None


def read_svl_events(path: Path, sample_rate: int = 44100) -> list[DrumEvent]:
    """Sonic Visualiser ``.svl`` reader.

    IDMT single-instrument files store onset frames as ``<point frame=...>`` with
    a useless ``New Point`` label and the class in the filename. We read frames
    against the model's own ``sampleRate`` and assign the filename class. If a
    file instead carries real per-point class labels, those win. Falls back to
    the generic XML reader when no usable points are found.
    """
    root = ET.fromstring(path.read_text(encoding="utf-8", errors="ignore"))
    model_sr = sample_rate
    model = root.find(".//model")
    if model is not None:
        sr = _float_or_none(model.attrib.get("sampleRate"))
        if sr and sr > 0:
            model_sr = int(sr)
    name_cls = _class_from_name(path.stem)
    events: list[DrumEvent] = []
    for pt in root.iter("point"):
        frame = _float_or_none(pt.attrib.get("frame"))
        if frame is None:
            continue
        cls = _norm_label(pt.attrib.get("label")) or name_cls
        if cls in CANON:
            events.append(DrumEvent(frame / model_sr, cls))
    if events:
        events.sort(key=lambda e: (e.time, e.cls))
        return events
    return read_xml_events(path, sample_rate=sample_rate)


def read_events(path: Path, sample_rate: int = 44100) -> list[DrumEvent]:
    suffix = path.suffix.lower()
    if suffix in {".mid", ".midi"}:
        return read_midi_events(path)
    if suffix == ".svl":
        return read_svl_events(path, sample_rate=sample_rate)
    if suffix == ".xml":
        return read_xml_events(path, sample_rate=sample_rate)
    return read_text_events(path)


def predicted_events(wav: Path) -> list[DrumEvent]:
    opts = AnalyzeOptions(
        as_drums=True,
        auto_key=False,
        pitch_assistant=False,
        timing_refine=False,
        timing_grid_quantize=False,
        quantize_strength=0.0,
    )
    res = analyze_audio(wav.read_bytes(), opts)
    events: list[DrumEvent] = []
    for n in res.notes:
        cls = _norm_label(n.drum if n.drum is not None else n.pitch)
        if cls in CANON and n.end > n.start:
            events.append(DrumEvent(float(n.start), cls, int(n.velocity)))
    events.sort(key=lambda e: (e.time, e.cls))
    return events


def match_events(
    ref: list[DrumEvent],
    pred: list[DrumEvent],
    tol: float,
    class_sensitive: bool,
) -> tuple[list[tuple[DrumEvent, DrumEvent]], list[DrumEvent], list[DrumEvent]]:
    used: set[int] = set()
    matches: list[tuple[DrumEvent, DrumEvent]] = []
    for r in ref:
        best_i = -1
        best_d = tol + 1e-9
        for i, p in enumerate(pred):
            if i in used:
                continue
            if class_sensitive and p.cls != r.cls:
                continue
            d = abs(p.time - r.time)
            if d <= tol and d < best_d:
                best_i = i
                best_d = d
        if best_i >= 0:
            used.add(best_i)
            matches.append((r, pred[best_i]))
    missed = [r for r in ref if all(m[0] is not r for m in matches)]
    extra = [p for i, p in enumerate(pred) if i not in used]
    return matches, missed, extra


def collapse_simultaneous(
    events: list[DrumEvent],
    window: float,
    priority: tuple[str, ...] = DEFAULT_COLLAPSE_PRIORITY,
) -> list[DrumEvent]:
    """Collapse near-simultaneous reference hits for monophonic beatbox eval.

    IDMT MIX annotations are polyphonic: kick+hat or snare+hat may occur at the
    same musical instant. HumTrack's current explicit drum path emits one note
    per vocal onset, so a separate monophonic score is useful while the product
    still records one intended drum sound at a time. The default priority keeps
    structural kick/snare hits over accompanying hats.
    """
    if window <= 0 or len(events) < 2:
        return events
    rank = {cls: i for i, cls in enumerate(priority)}
    out: list[DrumEvent] = []
    group: list[DrumEvent] = [events[0]]
    for event in events[1:]:
        if event.time - group[-1].time <= window:
            group.append(event)
            continue
        out.append(min(group, key=lambda e: (rank.get(e.cls, 999), e.time)))
        group = [event]
    out.append(min(group, key=lambda e: (rank.get(e.cls, 999), e.time)))
    out.sort(key=lambda e: (e.time, e.cls))
    return out


def _prf(matches: int, ref_count: int, pred_count: int) -> tuple[float, float, float]:
    precision = matches / pred_count if pred_count else 0.0
    recall = matches / ref_count if ref_count else 0.0
    f1 = 2.0 * precision * recall / (precision + recall) if precision + recall else 0.0
    return precision, recall, f1


def eval_pair(pair: DrumPair, args: argparse.Namespace) -> dict[str, object]:
    ref = read_events(pair.labels, sample_rate=args.annotation_sample_rate)
    ref_raw_count = len(ref)
    ref = collapse_simultaneous(ref, args.collapse_ref_window)
    pred = predicted_events(pair.wav)
    onset_matches, onset_missed, onset_extra = match_events(ref, pred, args.onset_tol, False)
    drum_matches, drum_missed, drum_extra = match_events(ref, pred, args.onset_tol, True)
    onset_p, onset_r, onset_f1 = _prf(len(onset_matches), len(ref), len(pred))
    drum_p, drum_r, drum_f1 = _prf(len(drum_matches), len(ref), len(pred))

    confusion = {f"{r}->{p}": 0 for r in CANON for p in CANON}
    for r, p in onset_matches:
        confusion[f"{r.cls}->{p.cls}"] += 1
    onset_mae = statistics.fmean(abs(p.time - r.time) for r, p in onset_matches) if onset_matches else 0.0

    row: dict[str, object] = {
        "key": pair.key,
        "ref_events": len(ref),
        "ref_events_raw": ref_raw_count,
        "pred_events": len(pred),
        "onset_matches": len(onset_matches),
        "drum_matches": len(drum_matches),
        "onset_precision": onset_p,
        "onset_recall": onset_r,
        "onset_f1": onset_f1,
        "drum_precision": drum_p,
        "drum_recall": drum_r,
        "drum_f1": drum_f1,
        "class_accuracy_on_matched_onsets": (
            len(drum_matches) / len(onset_matches) if onset_matches else 0.0
        ),
        "onset_mae_ms": onset_mae * 1000.0,
        "missed": len(drum_missed),
        "extra": len(drum_extra),
        "wav": str(pair.wav),
        "labels": str(pair.labels),
    }
    row.update(confusion)

    if args.details_dir is not None:
        args.details_dir.mkdir(parents=True, exist_ok=True)
        detail = {
            "key": pair.key,
            "ref": [e.__dict__ for e in ref],
            "pred": [e.__dict__ for e in pred],
            "onset_matches": [
                {"ref": r.__dict__, "pred": p.__dict__, "delta_ms": (p.time - r.time) * 1000.0}
                for r, p in onset_matches
            ],
            "drum_missed": [e.__dict__ for e in drum_missed],
            "drum_extra": [e.__dict__ for e in drum_extra],
        }
        (args.details_dir / f"{pair.key}.json").write_text(
            json.dumps(detail, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
    return row


def read_manifest(path: Path) -> list[DrumPair]:
    pairs: list[DrumPair] = []
    with path.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            key = str(row.get("key") or Path(str(row.get("wav") or "")).stem)
            wav = Path(str(row.get("wav") or ""))
            labels = Path(str(row.get("labels") or row.get("annotation") or row.get("midi") or ""))
            if wav.is_file() and labels.is_file():
                pairs.append(DrumPair(key, wav, labels))
    return pairs


def _is_ignored_dataset_path(path: Path) -> bool:
    """Skip archive sidecars and platform metadata that can shadow real files."""
    return (
        any(part == "__MACOSX" for part in path.parts)
        or path.name.startswith("._")
        or path.name == ".DS_Store"
    )


def _by_stem(paths: Iterable[Path]) -> dict[str, Path]:
    return {p.stem: p for p in sorted(paths) if not _is_ignored_dataset_path(p)}


def discover_pairs(root: Path) -> list[DrumPair]:
    wavs = _by_stem(root.rglob("*.wav"))
    labels = _by_stem(
        p
        for suffix in ("*.mid", "*.midi", "*.csv", "*.txt", "*.xml", "*.svl")
        for p in root.rglob(suffix)
    )
    keys = sorted(set(wavs) & set(labels))
    return [DrumPair(k, wavs[k], labels[k]) for k in keys]


def _mean(rows: list[dict[str, object]], key: str) -> float:
    vals = [float(r[key]) for r in rows]
    return statistics.fmean(vals) if vals else 0.0


def summarize(rows: list[dict[str, object]], target: float) -> dict[str, object]:
    total_ref = sum(int(r["ref_events"]) for r in rows)
    total_pred = sum(int(r["pred_events"]) for r in rows)
    total_drum_matches = sum(int(r["drum_matches"]) for r in rows)
    micro_p, micro_r, micro_f1 = _prf(total_drum_matches, total_ref, total_pred)
    return {
        "files": len(rows),
        "ref_events": total_ref,
        "pred_events": total_pred,
        "drum_precision": micro_p,
        "drum_recall": micro_r,
        "drum_f1": micro_f1,
        "macro_drum_f1": _mean(rows, "drum_f1"),
        "onset_f1": _mean(rows, "onset_f1"),
        "class_accuracy_on_matched_onsets": _mean(rows, "class_accuracy_on_matched_onsets"),
        "onset_mae_ms": _mean(rows, "onset_mae_ms"),
        "target": target,
        "target_pass": micro_f1 >= target,
    }


def filter_pairs(pairs: list[DrumPair], args: argparse.Namespace) -> list[DrumPair]:
    out = pairs
    if args.key_contains:
        out = [p for p in out if args.key_contains in p.key]
    if args.key_not_contains:
        out = [p for p in out if args.key_not_contains not in p.key]
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Evaluate drum onset/classification accuracy.")
    ap.add_argument("--root", type=Path)
    ap.add_argument("--manifest-csv", type=Path)
    ap.add_argument("--csv", type=Path, default=Path("drum_eval.csv"))
    ap.add_argument("--summary-json", type=Path)
    ap.add_argument("--details-dir", type=Path)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--onset-tol", type=float, default=0.05)
    ap.add_argument("--target", type=float, default=0.90)
    ap.add_argument("--annotation-sample-rate", type=int, default=44100)
    ap.add_argument("--key-contains", default="", help="Only evaluate pairs whose key contains this text.")
    ap.add_argument("--key-not-contains", default="", help="Skip pairs whose key contains this text.")
    ap.add_argument(
        "--collapse-ref-window",
        type=float,
        default=0.0,
        help="Collapse near-simultaneous reference events for monophonic beatbox scoring.",
    )
    args = ap.parse_args()

    if args.manifest_csv is not None:
        pairs = read_manifest(args.manifest_csv)
    elif args.root is not None:
        pairs = discover_pairs(args.root)
    else:
        raise SystemExit("Pass --manifest-csv or --root.")
    pairs = filter_pairs(pairs, args)
    if args.limit > 0:
        pairs = pairs[: args.limit]
    if not pairs:
        raise SystemExit("No drum WAV/label pairs found.")

    rows: list[dict[str, object]] = []
    for i, pair in enumerate(pairs, 1):
        try:
            row = eval_pair(pair, args)
            rows.append(row)
            print(
                f"[{i:04d}/{len(pairs):04d}] {pair.key} "
                f"drumF1={float(row['drum_f1']):.3f} "
                f"onsetF1={float(row['onset_f1']):.3f} "
                f"classAcc={float(row['class_accuracy_on_matched_onsets']):.3f} "
                f"events={row['pred_events']}/{row['ref_events']} "
                f"mae={float(row['onset_mae_ms']):.1f}ms"
            )
        except Exception as exc:
            print(f"[{i:04d}/{len(pairs):04d}] {pair.key} FAILED: {exc}", file=sys.stderr)

    if rows:
        args.csv.parent.mkdir(parents=True, exist_ok=True)
        with args.csv.open("w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)
    summary = summarize(rows, args.target)
    if args.summary_json is not None:
        args.summary_json.parent.mkdir(parents=True, exist_ok=True)
        args.summary_json.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")

    print("=" * 72)
    print(f"files             : {summary['files']}")
    print(f"events pred/ref   : {summary['pred_events']} / {summary['ref_events']}")
    print(f"drum precision    : {float(summary['drum_precision']):.3f}")
    print(f"drum recall       : {float(summary['drum_recall']):.3f}")
    print(f"drum f1           : {float(summary['drum_f1']):.3f}")
    print(f"macro drum f1     : {float(summary['macro_drum_f1']):.3f}")
    print(f"onset f1          : {float(summary['onset_f1']):.3f}")
    print(f"class acc matched : {float(summary['class_accuracy_on_matched_onsets']):.3f}")
    print(f"onset mae         : {float(summary['onset_mae_ms']):.1f} ms")
    print(f"target >=         : {float(summary['target']):.2f}")
    print(f"target pass       : {summary['target_pass']}")
    return 0 if summary["target_pass"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
