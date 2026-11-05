"""Fetch the CC0 FreePats bass/pad pack from upstream, without running downloads.

Reproducible inputs and SHA256/preset metadata are saved next to the assets.
Extraction uses Windows' libarchive tar, restricted to listed SF2/text members.
"""
import hashlib
import json
import shutil
import struct
import subprocess
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / 'mobile/assets/sounds/reference'
CACHE = ROOT / 'artifacts/reference-prep/soundfonts'
SOURCES = [
    ('freepats_bass_lately', 'lately-bass', '2024-04-09', 'LatelyBass-SF2-20240409.7z'),
    ('freepats_bass_synth1', 'synth-bass-1', '2019-07-23', 'SynthBass1-SF2-20190723.7z'),
    ('freepats_bass_synth2', 'synth-bass-2', '2021-04-05', 'SynthBass2-SF2-20210405.7z'),
    ('freepats_pad_choir', 'synth-pad-choir', '2020-05-16', 'SynthPadChoir-SF2-20200516.7z'),
    ('freepats_pad_sweep', 'sweep-pad', '2019-08-13', 'SweepPad-SF2-20190813.7z'),
    ('freepats_pad_newage', 'new-age', '2019-07-30', 'NewAge-SF2-20190730.7z'),
    ('freepats_pad_bowed', 'synth-pad-bowed', '2019-07-19', 'SynthPadBowed-SF2-20190719.7z'),
]


def presets(data):
    assert data[:4] == b'RIFF' and data[8:12] == b'sfbk', 'Not a SoundFont'
    assert struct.unpack_from('<I', data, 4)[0] + 8 == len(data)
    pos = 12
    while pos + 8 <= len(data):
        tag, length = struct.unpack_from('<4sI', data, pos)
        start, end = pos + 8, pos + 8 + length
        assert end <= len(data)
        if tag == b'LIST' and data[start:start+4] == b'pdta':
            sub = start + 4
            while sub + 8 <= end:
                name, size = struct.unpack_from('<4sI', data, sub)
                if name == b'phdr':
                    assert size % 38 == 0 and size >= 76
                    return [dict(name=data[p:p+20].split(b'\0')[0].decode('latin1'),
                                 program=struct.unpack_from('<H', data, p+20)[0],
                                 bank=struct.unpack_from('<H', data, p+22)[0])
                            for p in range(sub+8, sub+8+size-38, 38)]
                sub += 8 + size + (size & 1)
        pos = end + (length & 1)
    raise ValueError('Missing preset headers')


def main():
    PACK.mkdir(parents=True, exist_ok=True)
    CACHE.mkdir(parents=True, exist_ok=True)
    catalog = {e['id']: e for e in json.loads((ROOT / 'backend/soundfonts/catalog.json').read_text())}
    result = []
    for sid, repo, version, archive in SOURCES:
        url = f'https://github.com/freepats/{repo}/releases/download/{version}/{archive}'
        archive_path = CACHE / archive
        if not archive_path.exists():
            req = urllib.request.Request(url, headers={'User-Agent': 'HumTrack-reference-preparation'})
            with urllib.request.urlopen(req, timeout=60) as response, archive_path.open('wb') as out:
                shutil.copyfileobj(response, out)
        members = subprocess.check_output(['tar', '-tf', str(archive_path)], text=True).splitlines()
        safe = [m for m in members if not Path(m).is_absolute() and '..' not in Path(m).parts
                and Path(m).suffix.lower() in {'.sf2', '.txt', '.md'}]
        assert len([m for m in safe if m.lower().endswith('.sf2')]) == 1
        extract_dir = CACHE / sid
        extract_dir.mkdir(exist_ok=True)
        subprocess.run(['tar', '-xf', str(archive_path), '-C', str(extract_dir), *safe], check=True)
        source = next(extract_dir.rglob('*.sf2'))
        data = source.read_bytes()
        entries = presets(data)
        assert entries
        target = PACK / f'{sid}.sf2'
        target.write_bytes(data)
        for text in extract_dir.rglob('*.txt'):
            shutil.copy2(text, PACK / f'{sid}.{text.name}')
        e = dict(catalog[sid])
        # Upstream SF2s keep GM bank/program numbers; never assume preset 0/0.
        e.update(sf_bank=entries[0]['bank'], sf_program=entries[0]['program'],
                 bytes=len(data), sha256=hashlib.sha256(data).hexdigest(),
                 asset=f'assets/sounds/reference/{sid}.sf2', source=url,
                 presets=entries, archive_sha256=hashlib.sha256(archive_path.read_bytes()).hexdigest())
        if sid == 'freepats_pad_newage':
            e['midi_fallback'] = 88
        if sid == 'freepats_pad_choir':
            e['midi_fallback'] = 91
        if sid == 'freepats_pad_bowed':
            e['midi_fallback'] = 92
        result.append(e)
        (ROOT / 'backend/soundfonts' / f'{sid}.sf2').write_bytes(data)
        catalog[sid]['midi_fallback'] = e['midi_fallback']
        print(f'{sid}: {len(data)} bytes; {entries}', flush=True)
    # Merge instead of overwrite: rows prepared by other tools (e.g. the nylon
    # guitar from prepare_guitar_soundfont.py) must survive a re-run here.
    manifest = PACK / 'catalog.json'
    rows = json.loads(manifest.read_text(encoding='utf-8')) if manifest.exists() else []
    prepared = {e['id']: e for e in result}
    merged = [prepared.pop(r['id'], r) for r in rows]
    merged += list(prepared.values())
    manifest.write_text(json.dumps(merged, indent=2) + '\n', encoding='utf-8')
    (ROOT / 'backend/soundfonts/catalog.json').write_text(json.dumps(list(catalog.values()), indent=2) + '\n', encoding='utf-8')
    print(f'Prepared {len(result)} verified SF2 files, {sum(e["bytes"] for e in result)} bytes')


if __name__ == '__main__':
    main()
