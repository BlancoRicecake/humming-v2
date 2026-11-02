"""Mandatory Linux image check: provenance, actual loader, and overflow regression.

Run after Python dependencies are installed. No credentials, network, or user
media; the 1.25 GB WAV below is virtual and never allocated or written to disk.
"""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import subprocess


class VirtualImaWav:
    samples_per_block = 50001
    blocks = 50000
    block_align = (samples_per_block - 1) // 2 + 4

    def __init__(self):
        data_size = self.block_align * self.blocks
        fmt = struct.pack('<HHIIHHHH', 17, 1, 22050, 11026,
                          self.block_align, 4, 2, self.samples_per_block)
        chunks = b'fmt ' + struct.pack('<I', len(fmt)) + fmt
        chunks += b'fact' + struct.pack('<II', 4, 0)
        chunks += b'data' + struct.pack('<I', data_size)
        self.header = b'RIFF' + struct.pack('<I', 4 + len(chunks) + data_size) + b'WAVE' + chunks
        self.size = len(self.header) + data_size
        self.position = 0

    def seek(self, offset, whence=io.SEEK_SET):
        start = (0, self.position, self.size)[whence]
        if start + offset < 0:
            raise ValueError('negative seek')
        self.position = start + offset
        return self.position

    def tell(self):
        return self.position

    def read(self, count=-1):
        remaining = max(0, self.size - self.position)
        count = remaining if count < 0 else min(count, remaining)
        if count > 1 << 20:
            raise ValueError('regression fixture must not read the full virtual WAV')
        start = self.position
        self.position += count
        prefix = self.header[start:start + count]
        return prefix + bytes(count - len(prefix))


def check_ima_frame_count():
    import soundfile as sf
    fixture = VirtualImaWav()
    with sf.SoundFile(fixture) as audio:
        expected = fixture.samples_per_block * fixture.blocks
        assert audio.frames == expected, (audio.frames, expected)
        assert audio.frames > 2**31 - 1
        assert audio.read(8, dtype='float32').shape == (8,)
        assert audio.seek(2**31 + 10) == 2**31 + 10
        assert audio.read(8, dtype='float32').shape == (8,)
    return expected


def verify():
    import soundfile as sf
    prefix = Path('/usr/local')
    evidence = prefix / 'share/humtrack-native'
    manifest = json.loads((evidence / 'manifest.json').read_text())
    for name, digest in manifest['installed_sha256'].items():
        assert hashlib.sha256((prefix / name).read_bytes()).hexdigest() == digest, name
    assert importlib.util.find_spec('_soundfile_data') is None, 'unpatched wheel must not override libsndfile'
    maps = {line.split()[-1] for line in Path('/proc/self/maps').read_text().splitlines() if 'libsndfile' in line}
    assert len(maps) == 1, maps
    loaded = Path(next(iter(maps))).resolve()
    assert loaded.is_relative_to(prefix / 'lib'), loaded
    assert str(loaded.relative_to(prefix)) in manifest['installed_sha256'], loaded
    versions = {}
    for command in ('ffmpeg', 'ffprobe'):
        text = subprocess.check_output([command, '-version'], text=True)
        assert text.startswith(command + ' version 9.0.2 '), text[:100]
        assert '--disable-network' in text
        versions[command] = text.splitlines()[0]
    protocols = subprocess.check_output(['ffmpeg', '-hide_banner', '-protocols'], text=True)
    assert {line.strip() for line in protocols.splitlines() if line.startswith('  ')} == {'file', 'pipe'}
    frames = check_ima_frame_count()
    result = dict(passed=True, versions=versions, libsndfile_version=sf.__libsndfile_version__,
                  loaded_libsndfile=str(loaded), ima_virtual_frames=frames,
                  image_binary_hashes_verified=True, wheel_override_absent=True,
                  network_protocols_absent=True)
    print(json.dumps(result))
    return result


if __name__ == '__main__':
    verify()
