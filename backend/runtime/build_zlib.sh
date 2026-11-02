#!/bin/sh
set -eu
mkdir -p /src/zlib
cd /src/zlib
curl -fL --retry 3 -o zlib-1.3.1.tar.gz https://zlib.net/fossils/zlib-1.3.1.tar.gz
echo '9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23  zlib-1.3.1.tar.gz' | sha256sum -c -
echo '4c4a40b7329015fd89070667dd32e9307819e699d3ec4118af0a959f5fe1608c  /src/runtime/zlib-negative-length.patch' | sha256sum -c -
tar -xf zlib-1.3.1.tar.gz
cd zlib-1.3.1
patch --batch --fuzz=0 -p1 < /src/runtime/zlib-negative-length.patch
# Do not adopt the later nonblocking gzwrite implementation implicated by
# CVE-2026-85091 while backporting the independent CRC fix.
python -c "from pathlib import Path; assert 'gz_vacate' not in Path('gzwrite.c').read_text()"
./configure --shared --prefix=/opt/zlib
make -j2
make check
make install
timeout 5s python - <<'PY'
import ctypes
z=ctypes.CDLL('/opt/zlib/lib/libz.so.1')
z.crc32_combine64.argtypes=[ctypes.c_ulong,ctypes.c_ulong,ctypes.c_longlong]
z.crc32_combine64.restype=ctypes.c_ulong
z.crc32_combine_gen64.argtypes=[ctypes.c_longlong]
z.crc32_combine_gen64.restype=ctypes.c_ulong
assert z.crc32_combine64(1,2,-1)==0
assert z.crc32_combine_gen64(-1)==0
print('Real zlib negative-length regression passed')
PY
mkdir -p /opt/zlib/share/humtrack-runtime/zlib-source
cp ../zlib-1.3.1.tar.gz /src/runtime/zlib-negative-length.patch /src/runtime/build_zlib.sh zlib.h /opt/zlib/share/humtrack-runtime/zlib-source/
python - <<'PY'
import pathlib,hashlib,json
p=pathlib.Path('/opt/zlib')
(p/'share/humtrack-runtime/zlib.json').write_text(json.dumps(dict(version='1.3.1',
 upstream_patch='ba829a458576d1ff0f26fc7230c6de816d1f6a77',
 library_sha256=hashlib.sha256((p/'lib/libz.so.1').read_bytes()).hexdigest(),
 negative_length_regression_passed=True,gz_vacate_not_present=True),indent=2))
PY
