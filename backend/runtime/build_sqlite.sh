#!/bin/sh
set -eu
mkdir -p /src/sqlite
cd /src/sqlite
curl -fL --retry 3 -o sqlite-autoconf-3540100.tar.gz https://sqlite.org/2026/sqlite-autoconf-3540100.tar.gz
python - <<'PY'
import hashlib,pathlib
p=pathlib.Path('sqlite-autoconf-3540100.tar.gz')
assert hashlib.sha3_256(p.read_bytes()).hexdigest()=='b6ced585c750916b1052667239a12c25a7ff34e7f06e1e6e01ecb0427657d9c4'
PY
tar -xf sqlite-autoconf-3540100.tar.gz
cd sqlite-autoconf-3540100
# Build the shared library only. The affected .recover shell is not installed.
./configure --prefix=/opt/sqlite --disable-static --enable-fts5
make -j2 libsqlite3.so
install -d /opt/sqlite/lib /opt/sqlite/share/humtrack-runtime/sqlite-source
install -m 755 libsqlite3.so /opt/sqlite/lib/libsqlite3.so.0
ln -s libsqlite3.so.0 /opt/sqlite/lib/libsqlite3.so
cp ../sqlite-autoconf-3540100.tar.gz /opt/sqlite/share/humtrack-runtime/sqlite-source/
cp /src/runtime/build_sqlite.sh /opt/sqlite/share/humtrack-runtime/sqlite-source/
python - <<'PY'
import hashlib,json,pathlib
p=pathlib.Path('/opt/sqlite')
(p/'share/humtrack-runtime/sqlite.json').write_text(json.dumps(dict(version='3.54.1',
 library_sha256=hashlib.sha256((p/'lib/libsqlite3.so.0').read_bytes()).hexdigest(),
 source_sha3_256='b6ced585c750916b1052667239a12c25a7ff34e7f06e1e6e01ecb0427657d9c4',
 cli_installed=False),indent=2))
PY
