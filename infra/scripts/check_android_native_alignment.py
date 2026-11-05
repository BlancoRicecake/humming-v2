"""Inspect ELF PT_LOAD alignment in an APK/AAB without executing binaries.

For APKs also check ZIP offsets for uncompressed .so files. AAB ZIP offsets
are not install-time APK offsets, so only ELF is checked in that container.
This does not replace a release AAB/Play Console and 16KB device test.
"""
import argparse
import json
import pathlib
import struct
import sys
import zipfile


def segments(data):
    if data[:4] != b'\x7fELF' or data[5] != 1:
        raise ValueError('Expected a little-endian ELF binary')
    if data[4] == 2:
        offset = struct.unpack_from('<Q', data, 32)[0]
        size, count = struct.unpack_from('<HH', data, 54)
        fmt = '<IIQQQQQQ'
        fields = (2, 3, 7)
    elif data[4] == 1:
        offset = struct.unpack_from('<I', data, 28)[0]
        size, count = struct.unpack_from('<HH', data, 42)
        fmt = '<IIIIIIII'
        fields = (1, 2, 7)
    else:
        raise ValueError('Unsupported ELF class')
    result = []
    for i in range(count):
        row = struct.unpack_from(fmt, data, offset + i * size)
        if row[0] == 1:
            file_offset, address, alignment = (row[n] for n in fields)
            result.append({'alignment': alignment, 'ok': alignment >= 16384 and (address - file_offset) % 16384 == 0})
    return result


def inspect(path):
    rows = []
    with zipfile.ZipFile(path) as archive, path.open('rb') as raw:
        for entry in archive.infolist():
            if not entry.filename.endswith('.so'):
                continue
            loads = segments(archive.read(entry))
            zipped_ok = None
            if path.suffix == '.apk' and entry.compress_type == zipfile.ZIP_STORED:
                raw.seek(entry.header_offset)
                header = raw.read(30)
                name_len, extra_len = struct.unpack_from('<HH', header, 26)
                zipped_ok = (entry.header_offset + 30 + name_len + extra_len) % 16384 == 0
            # The Play requirement concerns 64-bit native code. Report other
            # ABIs too but do not confuse a legacy 32-bit binary with arm64.
            relevant = '/arm64-v8a/' in '/' + entry.filename or '/x86_64/' in '/' + entry.filename
            rows.append({'file': entry.filename, 'relevant_64bit': relevant,
                         'load_segments': loads, 'zip_alignment_ok': zipped_ok,
                         'ok': bool(loads) and all(x['ok'] for x in loads) and zipped_ok is not False})
    return {'artifact': str(path), 'libraries': rows,
            'passed': bool(rows) and all(r['ok'] for r in rows if r['relevant_64bit']),
            'device_tested': False}


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('artifact', type=pathlib.Path)
    p.add_argument('--output', type=pathlib.Path, required=True)
    a = p.parse_args()
    report = inspect(a.artifact)
    a.output.write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps({'libraries': len(report['libraries']), 'passed': report['passed'],
                      'failed': [x['file'] for x in report['libraries'] if x['relevant_64bit'] and not x['ok']]}))
    sys.exit(0 if report['passed'] else 1)
