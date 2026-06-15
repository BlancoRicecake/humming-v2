"""Inspect which sample sits under each drum slot for every kit the app exposes.

The LoopTap app fires FIXED notes per drum kind (loop_audio.dart kDrumNote):
    kick=36  snare=38  hihat=42   (main kit)
    clap=39  tambourine=54  shaker=82  (beat-fill decoration kit)
on whatever bank-128 preset the selected kit maps to. This script parses the
SF2 preset->instrument->sample zones (no synthesis) and prints, for each kit,
the sample name(s) that actually cover those keys -- so we can confirm e.g.
"kit_room note 36 really is a kick", and catch any slot that's empty or wrong.
"""
from __future__ import annotations

import struct
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOUNDS = REPO / "mobile" / "assets" / "sounds"

# (asset, bank, [(program, kit-label)]) for the 9 kits in instruments.dart
TIMGM = SOUNDS / "TimGM6mb.sf2"
HIPHOP = SOUNDS / "hiphop_kit.sf2"
GM_KITS = [
    (0, "Standard"), (8, "Room"), (16, "Power"), (24, "Electronic"),
    (25, "TR-808"), (32, "Jazz"), (40, "Brush"), (48, "Orchestra"),
]
SLOTS = [("kick", 36), ("snare", 38), ("hihat", 42)]


def read_chunks(data, start, end):
    """Yield (tag, payload_start, payload_end) for RIFF subchunks in [start,end)."""
    p = start
    while p + 8 <= end:
        tag = data[p:p + 4]
        size = struct.unpack_from("<I", data, p + 4)[0]
        body = p + 8
        yield tag, body, body + size
        p = body + size + (size & 1)  # word-align


def find_pdta(data):
    assert data[0:4] == b"RIFF" and data[8:12] == b"sfbk"
    for tag, s, e in read_chunks(data, 12, struct.unpack_from("<I", data, 4)[0] + 8):
        if tag == b"LIST" and data[s:s + 4] == b"pdta":
            return s + 4, e
    raise SystemExit("no pdta")


def parse(path):
    data = path.read_bytes()
    ps, pe = find_pdta(data)
    sub = {}
    for tag, s, e in read_chunks(data, ps, pe):
        sub[tag.decode("latin1")] = (s, e)

    def recs(tag, size):
        s, e = sub[tag]
        return [(data[s + i:s + i + size]) for i in range(0, e - s, size)]

    # phdr: 38 bytes; name(20) preset(2) bank(2) bagNdx(2) ...
    phdr = []
    for r in recs("phdr", 38):
        name = r[0:20].split(b"\0")[0].decode("latin1")
        preset, bank, bag = struct.unpack_from("<HHH", r, 20)
        phdr.append((name, preset, bank, bag))
    pbag = [struct.unpack_from("<HH", r, 0) for r in recs("pbag", 4)]  # genNdx, modNdx
    pgen = [struct.unpack_from("<Hh", r, 0) for r in recs("pgen", 4)]  # oper, amount
    inst = []
    for r in recs("inst", 22):
        name = r[0:20].split(b"\0")[0].decode("latin1")
        bag = struct.unpack_from("<H", r, 20)[0]
        inst.append((name, bag))
    ibag = [struct.unpack_from("<HH", r, 0) for r in recs("ibag", 4)]
    igen = [struct.unpack_from("<Hh", r, 0) for r in recs("igen", 4)]
    shdr = []
    for r in recs("shdr", 46):
        name = r[0:20].split(b"\0")[0].decode("latin1")
        shdr.append(name)
    return dict(phdr=phdr, pbag=pbag, pgen=pgen, inst=inst, ibag=ibag, igen=igen, shdr=shdr)


GEN_KEYRANGE = 43
GEN_INSTRUMENT = 41
GEN_SAMPLEID = 53
GEN_OVERRIDE_KEY = 46  # keynum override (fixes the note for percussion zones)


def zone_gens(gens, bags, zi):
    g0 = bags[zi][0]
    g1 = bags[zi + 1][0] if zi + 1 < len(bags) else len(gens)
    out = {}
    krange = None
    for gi in range(g0, g1):
        oper, amt = gens[gi]
        if oper == GEN_KEYRANGE:
            krange = (amt & 0xFF, (amt >> 8) & 0xFF)
        out[oper] = amt
    return out, krange


def samples_for_note(sf, preset_idx, note):
    """Return list of sample names whose zone covers `note` for the given preset."""
    phdr, pbag, pgen = sf["phdr"], sf["pbag"], sf["pgen"]
    inst, ibag, igen, shdr = sf["inst"], sf["ibag"], sf["igen"], sf["shdr"]
    name, preset, bank, bag0 = phdr[preset_idx]
    bag1 = phdr[preset_idx + 1][3] if preset_idx + 1 < len(phdr) else len(pbag)
    hits = []
    for zi in range(bag0, bag1):
        gens, krange = zone_gens(pgen, pbag, zi)
        if krange and not (krange[0] <= note <= krange[1]):
            continue
        inst_id = gens.get(GEN_INSTRUMENT)
        if inst_id is None:
            continue
        # descend into the instrument's zones
        ib0 = inst[inst_id][1]
        ib1 = inst[inst_id + 1][1] if inst_id + 1 < len(inst) else len(ibag)
        for izi in range(ib0, ib1):
            igens, ikrange = zone_gens(igen, ibag, izi)
            if ikrange and not (ikrange[0] <= note <= ikrange[1]):
                continue
            sid = igens.get(GEN_SAMPLEID)
            if sid is None:
                continue
            # capture the generators that change how the SAME sample sounds
            def sg(op):
                v = igens.get(op)
                return v if v is not None else gens.get(op)
            coarse = sg(51) or 0      # coarseTune (semitones)
            fine = sg(52) or 0        # fineTune (cents)
            atten = sg(48) or 0       # initialAttenuation (0.1 dB)
            reverb = sg(16) or 0      # reverbEffectsSend (0.1%)
            pan = sg(17) or 0         # pan
            tag = (f"#{sid}:{shdr[sid]}"
                   f" tune={coarse}st{fine:+d}c att={atten/10:.1f}dB"
                   f" rev={reverb/10:.0f}% pan={pan}")
            hits.append(tag)
    return hits


def report(path, kits, bank):
    sf = parse(path)
    # index presets by (bank, program)
    by_bp = {}
    for i, (name, preset, b, bag) in enumerate(sf["phdr"][:-1]):  # last is EOP terminal
        by_bp[(b, preset)] = (i, name)
    print(f"\n=== {path.name}  (bank {bank}) ===")
    for prog, label in kits:
        key = (bank, prog)
        if key not in by_bp:
            print(f"  [{prog:>3}] {label:<10} -- PRESET MISSING")
            continue
        idx, pname = by_bp[key]
        cells = []
        for kind, note in SLOTS:
            names = samples_for_note(sf, idx, note)
            shown = ",".join(names) if names else "(none)"
            cells.append(f"{kind}{note}={shown}")
        print(f"  [{prog:>3}] {label:<10} <{pname}>")
        for c in cells:
            print(f"        {c}")


if __name__ == "__main__":
    report(TIMGM, GM_KITS, 128)
    report(HIPHOP, [(0, "Hip-Hop")], 128)
