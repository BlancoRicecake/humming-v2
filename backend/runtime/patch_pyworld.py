"""Backport upstream's metadata import; preserve the tested DSP extension."""
import csv
import base64
import hashlib
from importlib import metadata
import io
import json
from pathlib import Path

dist=metadata.distribution('pyworld')
assert dist.version=='0.3.5', 'Re-review metadata compatibility for a different pyworld'
path=Path(dist.locate_file('pyworld/__init__.py'))
original=path.read_bytes()
assert hashlib.sha256(original).hexdigest()=='9ba6891aa5e7c7465188858cc2749275d1d04e45eb19d62db1c6c89b6eacd9cb'
updated=original.replace(b'import pkg_resources',b'from importlib.metadata import version')
updated=updated.replace(b"pkg_resources.get_distribution('pyworld').version",b"version('pyworld')")
assert b'pkg_resources' not in updated and updated!=original
path.write_bytes(updated)
# Keep the installed distribution's file integrity record accurate and record
# both original and patched hashes; do not present this as an untouched wheel.
record=Path(dist.locate_file('pyworld-'+dist.version+'.dist-info/RECORD'))
rows=list(csv.reader(io.StringIO(record.read_text())))
matched=0
for row in rows:
 if row[0]=='pyworld/__init__.py':
  row[1]='sha256='+base64.urlsafe_b64encode(hashlib.sha256(updated).digest()).decode().rstrip('=')
  row[2]=str(len(updated));matched+=1
assert matched==1
with record.open('w',newline='') as stream:csv.writer(stream).writerows(rows)
out=Path('/usr/local/share/humtrack-runtime');out.mkdir(parents=True,exist_ok=True)
(out/'pyworld-metadata-patch.json').write_text(json.dumps(dict(version=dist.version,
 original_sha256=hashlib.sha256(original).hexdigest(),patched_sha256=hashlib.sha256(updated).hexdigest(),
 dsp_extension_changed=False,upstream_reference='https://github.com/JeremyCCHsu/Python-Wrapper-for-World-Vocoder/blob/master/pyworld/__init__.py'),indent=2))
