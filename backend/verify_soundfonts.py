"""Fail a server image build when its required instrument files are missing.

No downloads, provider calls or writes. Optional catalog rows may be absent;
the runtime filters those rows. The eight offline instrument IDs form the
minimum server pack; the desktop/mobile pack is tested by Flutter separately.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import struct

REQUIRED = frozenset({
    'freepats_nylon', 'freepats_bass_lately', 'freepats_bass_synth1',
    'freepats_bass_synth2', 'freepats_pad_choir', 'freepats_pad_sweep',
    'freepats_pad_newage', 'freepats_pad_bowed',
})


def verify(base: Path, required=REQUIRED) -> dict:
    rows = json.loads((base / 'catalog.json').read_text(encoding='utf-8'))
    if not isinstance(rows, list):
        raise ValueError('Instrument catalog must be a list')
    found, absent, invalid = set(), [], []
    seen = set()
    for row in rows:
        sid, filename = row['id'], row['file']
        if sid in seen:
            raise ValueError('Duplicate instrument ID')
        seen.add(sid)
        if not isinstance(filename, str) or Path(filename).name != filename or '/' in filename or '\\' in filename:
            raise ValueError('Instrument file must be a basename')
        path = base / filename
        if path.is_symlink() or not path.is_file():
            absent.append(sid)
            continue
        with path.open('rb') as stream:
            header = stream.read(12)
            valid = len(header) == 12 and header[:4] == b'RIFF' and header[8:] == b'sfbk'
            if valid:
                valid = struct.unpack('<I', header[4:8])[0] + 8 == path.stat().st_size
            if valid and row.get('sha256'):
                stream.seek(0)
                valid = hashlib.file_digest(stream, 'sha256').hexdigest() == row['sha256'].lower()
        if valid:
            found.add(sid)
        else:
            invalid.append(sid)
    missing = sorted(set(required) - found)
    return {'passed': not missing and not invalid, 'declared': len(rows),
            'available': len(found), 'missing_required': missing,
            'missing_optional': sorted(set(absent) - set(required)),
            'invalid': sorted(invalid), 'network_used': False}


def main():
    result = verify(Path(__file__).resolve().parent / 'soundfonts')
    print(json.dumps(result, sort_keys=True))
    if not result['passed']:
        raise SystemExit('Required instrument pack missing or corrupt; refusing server image')


if __name__ == '__main__':
    main()
