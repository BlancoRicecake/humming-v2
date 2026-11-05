"""Build a minimal runtime rootfs from trusted installed files, preserving SBOM.

Only runs in the build stage. Does not alter the host or fabricate package
versions. Every retained distro library records its original package status,
source version and retained file hashes; absent package files stay documented.
"""
import hashlib,json,os,re,shutil,stat,subprocess
from pathlib import Path

out=Path('/runtime-root');out.mkdir()
selected=set()
def copy(path):
 p=Path(path)
 if p.is_symlink():
  target=Path(os.path.normpath(os.path.join(p.parent,os.readlink(p))));copy(target)
  dest=out/str(p).lstrip('/');dest.parent.mkdir(parents=True,exist_ok=True)
  if not dest.exists() and not dest.is_symlink():dest.symlink_to(os.readlink(p))
  selected.add(str(p));return
 if p.is_file():
  if p.resolve()!=p:copy(p.resolve())
  dest=out/str(p).lstrip('/');dest.parent.mkdir(parents=True,exist_ok=True)
  if not dest.exists():
   shutil.copyfile(p,dest);dest.chmod(stat.S_IMODE(p.stat().st_mode)&~(stat.S_ISUID|stat.S_ISGID))
  selected.add(str(p))

# Python, runtime wheels, patched audio libraries and their source/licenses.
# ensurepip is a build installer containing old vendored dependencies.
for p in Path('/usr/local').rglob('*'):
 if 'numba/np/ufunc/tbbpool.' in str(p):continue  # optional plugin was already unloadable without libtbb
 if p.name.startswith('_tkinter.') or 'tkinter' in p.parts or 'idlelib' in p.parts:continue
 # Interactive terminal extensions are not API dependencies. Removing them
 # also removes the ncurses/tinfo termcap parser and its tsearch/tdelete path.
 if p.name.startswith(('_curses.','_curses_panel.','readline.')) or 'curses' in p.parts:continue
 if 'ensurepip' not in p.parts and '__pycache__' not in p.parts and p.is_file():copy(p)
for p in [Path('/sbin/ldconfig'),Path('/usr/sbin/ldconfig')]:copy(p)
for name in ['bin/sh','bin/dash','usr/bin/sh','usr/bin/dash']:
 dest=out/name;dest.parent.mkdir(parents=True,exist_ok=True)
 dest.symlink_to('/usr/local/bin/dash')
# Keep glibc's resolver ABI for Python database/network integrations too; it is
# loaded dynamically by optional clients and thus absent from an ELF-only graph.
for p in Path('/usr/lib').glob('*-linux-gnu/libresolv.so.2'):copy(p)

# Resolve all trusted ELF inputs (including wheel-bundled libraries) using the
# build image's loader. Do not infer dependencies by package names alone.
roots=[p for p in selected if Path(p).is_file() and not Path(p).is_symlink()]
for name in roots:
 p=Path(name)
 with p.open('rb') as stream:magic=stream.read(4)
 if magic!=b'\x7fELF':continue
 # Wheel-private libraries can inherit the parent's $ORIGIN search path. A
 # standalone ldd of a child (e.g. scipy's libgfortran) lacks that parent; use
 # its trusted sibling directory for this dependency-discovery command only.
 loader_env=os.environ.copy();loader_env['LD_LIBRARY_PATH']=str(p.parent)+':'+loader_env.get('LD_LIBRARY_PATH','')
 r=subprocess.run(['ldd',name],capture_output=True,text=True,env=loader_env)
 assert 'not found' not in r.stdout,(name,r.stdout)
 for line in r.stdout.splitlines():
  match=re.search(r'(?:=>\s*)?(/\S+)\s+\(',line)
  if match:
   lib=Path(match.group(1));assert str(lib).startswith(('/lib/','/lib64/','/usr/lib/','/usr/local/')),lib
   copy(lib)

# NSS, CA trust, loader cache and timezone behavior are operational dependencies.
for name in ['/etc/nsswitch.conf','/etc/ld.so.cache','/etc/ssl/certs/ca-certificates.crt','/etc/ssl/openssl.cnf','/etc/localtime']:
 copy(name)
for folder in ['/usr/lib/ssl','/usr/share/zoneinfo']:
 for p in Path(folder).rglob('*'):
  if p.is_file():copy(p)
for name in ['tmp','dev','proc','app','home/humming']:(out/name).mkdir(parents=True,exist_ok=True)
(out/'tmp').chmod(0o1777);os.chown(out/'home/humming',1000,1000)
(out/'etc/passwd').write_text('root:x:0:0:root:/root:/bin/sh\nhumming:x:1000:1000:HumTrack:/home/humming:/bin/sh\n')
(out/'etc/group').write_text('root:x:0:\nhumming:x:1000:\n')
copy('/etc/os-release')
copy('/etc/debian_version')  # distro scanners require this marker as well as status

# dpkg status remains truthful for libraries retained from Debian, including
# original versions. Preserve partial-package coverage instead of dropping
# scanner metadata when binaries are copied into a scratch image.
status=Path('/var/lib/dpkg/status').read_text();blocks=status.strip().split('\n\n')
retained=[];inventory=[]
for block in blocks:
 m=re.search(r'^Package: (.+)$',block,re.M)
 if not m:continue
 package=m.group(1)
 r=subprocess.run(['dpkg-query','-L',package],capture_output=True,text=True)
 files=[p for p in r.stdout.splitlines() if p in selected]
 if not files:continue
 copy(Path('/usr/share/doc')/package/'copyright')
 retained.append(block)
 inventory.append(dict(package=package,version=re.search(r'^Version: (.+)$',block,re.M).group(1),
   partial_package=True,retained_files={p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in files if Path(p).is_file()}))
dest=out/'var/lib/dpkg';dest.mkdir(parents=True)
(dest/'status').write_text('\n\n'.join(retained)+'\n')
proof=out/'usr/local/share/humtrack-runtime';proof.mkdir(parents=True,exist_ok=True)
(proof/'debian-retained-files.json').write_text(json.dumps(inventory,indent=2))
(proof/'debian-build-status.txt').write_text(status)
(proof/'runtime-selection.json').write_text(json.dumps(dict(
 source='pinned official Python build image and verified native stages',
 retained_debian_packages=len(inventory),shell_retained_for_operator_ssh=True,
 excluded=['apt','curl','mount','nsenter','infocmp','perl','sqlite3 CLI','pip','wheel','setuptools','ensurepip','unavailable numba TBB plugin','unavailable Tk GUI module','interactive curses/readline and ncurses/tinfo','Debian dash recursive fallback (replaced with verified fnmatch-enabled build)'],
 selected_files=len(selected)),indent=2))
for p in Path('/usr/share/common-licenses').rglob('*'):
 if p.is_file():copy(p)
print('Assembled minimal rootfs with '+str(len(inventory))+' original Debian package records')
