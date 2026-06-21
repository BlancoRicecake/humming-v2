"""Shrink an SF2 by downsampling its sample data — safe, zone-preserving.

The FreePats electric guitars are huge (200–425MB) because the sample data
(`smpl`) is 44.1kHz with many velocity layers. Downloading that to a phone is
slow + memory-heavy. This rewrites ONLY the sample stream + the `shdr` offsets
(start/end/loop/sampleRate); it does NOT touch the preset/instrument zone
tables, so every velocity layer / stereo pair / generator stays intact — only
each sample becomes smaller. A 24-bit `sm24` chunk, if present, is dropped
(downgraded to 16-bit) for an extra size win.

Usage:
    python tools/shrink_sf2.py IN.sf2 OUT.sf2 --rate 22050

Mirrors the RIFF parsing style of app/render.py (dependency-free struct reads;
resampling via scipy). Verify the output by loading it through FluidSynth.
"""
from __future__ import annotations

import argparse
import struct
from math import gcd
from pathlib import Path

import numpy as np
from scipy.signal import resample_poly

SHDR_LEN = 46  # bytes per sample header record


def _find_chunk(buf: bytes, tag: bytes, start: int = 0, end: int | None = None) -> tuple[int, int]:
    """Return (data_offset, size) of the first `tag` chunk in [start,end)."""
    end = len(buf) if end is None else end
    i = buf.find(tag, start, end)
    if i < 0:
        raise ValueError(f"chunk {tag!r} not found")
    (size,) = struct.unpack_from("<I", buf, i + 4)
    return i + 8, size


def _pad(b: bytearray) -> None:
    if len(b) % 2:  # RIFF chunks are word-aligned
        b.append(0)


def shrink(in_path: Path, out_path: Path, target_rate: int) -> None:
    raw = in_path.read_bytes()
    assert raw[:4] == b"RIFF" and raw[8:12] == b"sfbk", "not an SF2"

    # --- locate the three top LISTs (INFO / sdta / pdta) ---
    # sdta holds smpl (+ optional sm24); pdta holds shdr (among others).
    smpl_off, smpl_sz = _find_chunk(raw, b"smpl")
    pcm = np.frombuffer(raw, dtype="<i2", count=smpl_sz // 2, offset=smpl_off)

    shdr_off, shdr_sz = _find_chunk(raw, b"shdr")
    n = shdr_sz // SHDR_LEN

    up, down = (target_rate, 0)  # set per-sample (rates can differ); reduce later
    guard = 46  # SF2-recommended zero guard samples after each sample
    out_pcm: list[np.ndarray] = []
    new_shdr = bytearray()
    cursor = 0  # running sample-word offset into the rebuilt smpl

    for k in range(n):
        rec = raw[shdr_off + k * SHDR_LEN : shdr_off + (k + 1) * SHDR_LEN]
        name = rec[:20]
        start, end, sl, el, rate = struct.unpack_from("<IIIII", rec, 20)
        orig_key, corr, link, styp = struct.unpack_from("<BbHH", rec, 40)

        is_rom = bool(styp & 0x8000)
        terminal = name[:3] == b"EOS" or (start == 0 and end == 0 and rate == 0)
        if terminal or is_rom or end <= start or rate <= 0:
            # keep record as-is but re-point offsets to current cursor (harmless)
            new_shdr += struct.pack(
                "<20sIIIIIBbHH", name.ljust(20, b"\x00")[:20],
                cursor, cursor, cursor, cursor, target_rate, orig_key, corr, link, styp,
            )
            continue

        seg = pcm[start:end].astype(np.float32)
        g = gcd(target_rate, rate)
        up, down = target_rate // g, rate // g
        if up != down:
            res = resample_poly(seg, up, down)
        else:
            res = seg
        res = np.clip(np.round(res), -32768, 32767).astype("<i2")

        ratio = up / down
        new_start = cursor
        new_end = new_start + len(res)
        new_sl = new_start + int(round((sl - start) * ratio))
        new_el = new_start + int(round((el - start) * ratio))
        new_sl = min(max(new_sl, new_start), new_end)
        new_el = min(max(new_el, new_start), new_end)

        out_pcm.append(res)
        out_pcm.append(np.zeros(guard, dtype="<i2"))
        cursor = new_end + guard

        new_shdr += struct.pack(
            "<20sIIIIIBbHH", name.ljust(20, b"\x00")[:20],
            new_start, new_end, new_sl, new_el, target_rate, orig_key, corr, link, styp,
        )

    new_smpl = np.concatenate(out_pcm) if out_pcm else np.zeros(0, dtype="<i2")
    new_smpl_bytes = new_smpl.tobytes()

    # --- rebuild the file: INFO verbatim, new sdta(smpl only), pdta with new shdr ---
    info_off, info_sz = _find_chunk(raw, b"LIST")  # first LIST is INFO
    info_list = raw[info_off - 8 : info_off + info_sz + (info_sz & 1)]

    # pdta: copy the whole LIST but swap the shdr subchunk body.
    # find the pdta LIST (the LIST whose form is 'pdta')
    pos = 12
    pdta_start = pdta_end = -1
    while pos + 8 <= len(raw):
        ck = raw[pos : pos + 4]
        (csz,) = struct.unpack_from("<I", raw, pos + 4)
        body = pos + 8
        if ck == b"LIST" and raw[body : body + 4] == b"pdta":
            pdta_start, pdta_end = pos, body + csz
            break
        pos = body + csz + (csz & 1)
    assert pdta_start >= 0, "pdta not found"
    pdta = bytearray(raw[pdta_start:pdta_end])
    # shdr subchunk header sits 8 bytes before its data; replace body in-place
    shdr_hdr = shdr_off - 8 - pdta_start
    assert pdta[shdr_hdr : shdr_hdr + 4] == b"shdr"
    pdta[shdr_hdr + 8 : shdr_hdr + 8 + shdr_sz] = new_shdr  # same length (n unchanged)

    # sdta LIST: 'sdta' + smpl chunk
    sdta_body = bytearray(b"sdta")
    sdta_body += b"smpl" + struct.pack("<I", len(new_smpl_bytes)) + new_smpl_bytes
    _pad(sdta_body)
    sdta = bytearray(b"LIST" + struct.pack("<I", len(sdta_body)) + sdta_body)

    out = bytearray(b"RIFF\x00\x00\x00\x00sfbk")
    out += info_list
    out += sdta
    out += pdta
    struct.pack_into("<I", out, 4, len(out) - 8)
    out_path.write_bytes(out)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("inp")
    ap.add_argument("out")
    ap.add_argument("--rate", type=int, default=22050)
    a = ap.parse_args()
    src, dst = Path(a.inp), Path(a.out)
    shrink(src, dst, a.rate)
    print(f"{src.name} {src.stat().st_size/1048576:.1f}MB -> "
          f"{dst.name} {dst.stat().st_size/1048576:.1f}MB @ {a.rate}Hz")


if __name__ == "__main__":
    main()
