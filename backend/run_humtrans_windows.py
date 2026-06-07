"""Run rolling HumTrans evaluation windows.

Use this to avoid repeatedly optimizing on the same tiny sample set. Example:
train-ish smoke on 1-10, then compare 11-20/21-30/etc. without changing test
holdout policy for final reports.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser(description="Run repeated HumTrans eval windows.")
    ap.add_argument("--root", type=Path, required=True)
    ap.add_argument("--split", choices=["train", "dev", "test"], default="dev")
    ap.add_argument("--window-size", type=int, default=10)
    ap.add_argument("--windows", type=int, default=3)
    ap.add_argument("--start-offset", type=int, default=0)
    ap.add_argument("--out-dir", type=Path, required=True)
    ap.add_argument("--cache-dir", type=Path)
    ap.add_argument("--align-time", action="store_true", default=True)
    ap.add_argument("--no-align-time", dest="align_time", action="store_false")
    args = ap.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    rows: list[dict[str, object]] = []
    for i in range(args.windows):
        offset = args.start_offset + i * args.window_size
        stem = f"{args.split}_w{i + 1:02d}_{offset:05d}_{offset + args.window_size - 1:05d}"
        summary = args.out_dir / f"{stem}.json"
        csv_path = args.out_dir / f"{stem}.csv"
        cmd = [
            sys.executable,
            str(Path(__file__).resolve().parent / "eval_humtrans.py"),
            "--root",
            str(args.root),
            "--split",
            args.split,
            "--offset",
            str(offset),
            "--limit",
            str(args.window_size),
            "--csv",
            str(csv_path),
            "--summary-json",
            str(summary),
        ]
        if args.align_time:
            cmd.append("--align-time")
        if args.cache_dir is not None:
            cmd.extend(["--cache-dir", str(args.cache_dir)])
        print(" ".join(cmd))
        subprocess.run(cmd, check=True)
        data = json.loads(summary.read_text(encoding="utf-8"))
        rows.append(
            {
                "window": stem,
                "offset": offset,
                "limit": args.window_size,
                "note_f1": data.get("note_f1", 0.0),
                "note_precision": data.get("note_precision", 0.0),
                "note_recall": data.get("note_recall", 0.0),
                "onset_f1": data.get("onset_f1", 0.0),
                "onset_pitch_accuracy": data.get("onset_pitch_accuracy", 0.0),
                "errors": data.get("errors", {}),
            }
        )
    rollup = {
        "split": args.split,
        "window_size": args.window_size,
        "windows": rows,
    }
    out = args.out_dir / f"{args.split}_windows_rollup.json"
    out.write_text(json.dumps(rollup, indent=2, ensure_ascii=False), encoding="utf-8")
    print(json.dumps(rollup, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
