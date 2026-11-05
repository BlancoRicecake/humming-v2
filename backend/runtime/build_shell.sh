#!/bin/sh
set -eu
cd /src
curl --fail --location --retry 3 -o dash_0.5.12.orig.tar.gz https://deb.debian.org/debian/pool/main/d/dash/dash_0.5.12.orig.tar.gz
curl --fail --location --retry 3 -o dash_0.5.12-12.debian.tar.xz https://deb.debian.org/debian/pool/main/d/dash/dash_0.5.12-12.debian.tar.xz
printf '%s\n' \
  '6a474ac46e8b0b32916c4c60df694c82058d3297d8b385b74508030ca4a8f28a  dash_0.5.12.orig.tar.gz' \
  'a278acb5d9a1f5d9a086d36a547287cbf3105b8f33c0e62d86d264decf5ba1ad  dash_0.5.12-12.debian.tar.xz' | sha256sum --check
tar -xf dash_0.5.12.orig.tar.gz
tar -xf dash_0.5.12-12.debian.tar.xz -C dash-0.5.12
cd dash-0.5.12
while IFS= read -r entry; do
  case "$entry" in ''|'#'*) continue ;; esac
  patch --batch --fuzz=0 -p1 < "debian/patches/$entry"
done < debian/patches/series
autoreconf -fi
# CVE-2026-102473 affects the recursive fallback selected by Debian's
# --disable-fnmatch. Keep its other build options and source patches, but use
# glibc fnmatch instead. No glob(3) expansion path is added.
./configure --prefix=/opt/shell --enable-fnmatch --disable-glob --disable-lineno
make -j2
make install
mkdir -p /opt/shell/share/humtrack-runtime/source
cp /src/dash_*.tar.* /opt/shell/share/humtrack-runtime/source/
cp COPYING /opt/shell/share/humtrack-runtime/dash-LICENSE.txt
cp /src/runtime/build_shell.sh /opt/shell/share/humtrack-runtime/source/
python - <<'PY'
import hashlib,json,pathlib,re,subprocess
p=pathlib.Path('/opt/shell/bin/dash')
assert '#define HAVE_FNMATCH 1' in pathlib.Path('config.h').read_text()
# This exact source has no Unicode escape converter; the scanner's
# CVE-2026-102474 conversion precondition does not exist in this build.
source=pathlib.Path('src/bltin/printf.c').read_text()
assert "case 'u':" not in source[source.index('conv_escape(char *str, int *conv_ch)\n{'):]
r=subprocess.run([str(p),'-c',r"printf '%b' '\u1234\U12345678'"],capture_output=True,check=True)
assert r.stdout==b'\\u1234\\U12345678'
# A short multi-star pattern with a long non-matching tail must finish within
# two seconds. The old fallback can spend super-polynomial time here.
r=subprocess.run([str(p),'-c','case "$1" in *.*.*.*.*.*.*.*.tar.gz) exit 7;; esac',
                  'qa','.'*160+'x'],timeout=2,check=True)
data={'source':'Debian dash 0.5.12-12, same published patches',
      'build_options':['--enable-fnmatch','--disable-glob','--disable-lineno'],
      'recursive_pmatch_fallback_disabled':True,'unicode_escape_converter_absent':True,
      'adversarial_pattern_regression_passed':True,
      'library_sha256':hashlib.sha256(p.read_bytes()).hexdigest(),
      'sources':{n:hashlib.sha256(pathlib.Path('/src',n).read_bytes()).hexdigest()
                 for n in ('dash_0.5.12.orig.tar.gz','dash_0.5.12-12.debian.tar.xz')}}
pathlib.Path('/opt/shell/share/humtrack-runtime/dash.json').write_text(json.dumps(data,indent=2))
print(json.dumps(data))
PY
