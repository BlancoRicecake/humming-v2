"""Verify actual hardened-runtime dependencies, not just scanner row counts."""
import ctypes,gzip,hashlib,importlib.util,json,os,sqlite3,ssl,subprocess,zlib
from importlib import metadata
from pathlib import Path


def verify():
    root=Path('/usr/local/share/humtrack-runtime')
    for name in ('setuptools','pkg_resources','pip','wheel','ensurepip'):
        assert importlib.util.find_spec(name) is None,name
    for name in ('_curses','_curses_panel','readline'):
        assert importlib.util.find_spec(name) is None,name
    assert os.environ.get('LOCALDOMAIN')==''
    assert os.environ.get('LC_ALL')=='C.UTF-8' and os.environ.get('LANGUAGE')==''
    shell=json.loads((root/'dash.json').read_text())
    assert shell['recursive_pmatch_fallback_disabled'] and shell['unicode_escape_converter_absent']
    assert hashlib.sha256(Path('/bin/sh').read_bytes()).hexdigest()==shell['library_sha256']
    subprocess.run(['/bin/sh','-c','case "$1" in *.*.*.*.*.*.*.*.tar.gz) exit 7;; esac',
                    'qa','.'*160+'x'],check=True,timeout=2)
    for prefix in ('libncurses','libtinfo','libreadline'):
        assert not list(Path('/usr/lib').rglob(prefix+'*.so*')),prefix
    patch=json.loads((root/'pyworld-metadata-patch.json').read_text())
    dist=metadata.distribution('pyworld')
    assert hashlib.sha256(Path(dist.locate_file('pyworld/__init__.py')).read_bytes()).hexdigest()==patch['patched_sha256']
    assert sqlite3.sqlite_version=='3.54.1'
    zp=json.loads((root/'zlib.json').read_text())
    assert zlib.ZLIB_RUNTIME_VERSION=='1.3.1'
    assert hashlib.sha256(Path('/usr/local/lib/libz.so.1').read_bytes()).hexdigest()==zp['library_sha256']
    library=ctypes.CDLL('/usr/local/lib/libz.so.1')
    library.crc32_combine64.argtypes=[ctypes.c_ulong,ctypes.c_ulong,ctypes.c_longlong]
    library.crc32_combine64.restype=ctypes.c_ulong
    library.crc32_combine_gen64.argtypes=[ctypes.c_longlong]
    library.crc32_combine_gen64.restype=ctypes.c_ulong
    assert library.crc32_combine64(1,2,-1)==0 and library.crc32_combine_gen64(-1)==0
    assert gzip.decompress(gzip.compress(b'humming'*1024))==b'humming'*1024
    sql=json.loads((root/'sqlite.json').read_text())
    assert hashlib.sha256(Path('/usr/local/lib/libsqlite3.so.0').read_bytes()).hexdigest()==sql['library_sha256']
    # Exercise the formerly affected FTS5 detail=none/prefix merge family on a
    # synthetic in-memory database. No customer database is opened.
    with sqlite3.connect(':memory:') as db:
        db.execute("create virtual table notes using fts5(body, detail=none, prefix='2 3')")
        db.executemany('insert into notes(rowid,body) values (?,?)',[(-2,'humming music'),(-1,'humtrack melody'),(1,'humming harmony')])
        db.execute("insert into notes(notes) values ('optimize')")
        assert db.execute("select count(*) from notes where notes match 'hum*'").fetchone()[0]==3
    for name in ('/usr/bin/curl','/bin/mount','/usr/bin/mount','/usr/bin/nsenter','/usr/bin/infocmp','/usr/bin/perl','/usr/bin/sqlite3','/usr/bin/apt'):
        assert not Path(name).exists(),name
    probe=subprocess.check_output(['/bin/sh','-c','exec python -c "print(123)"'],text=True)
    assert probe.strip()=='123'
    assert ssl.create_default_context().cert_store_stats()['x509_ca']>0
    inventory=json.loads((root/'debian-retained-files.json').read_text())
    for package in inventory:
        for name,digest in package['retained_files'].items():
            assert Path(name).exists(),name
            assert hashlib.sha256(Path(name).read_bytes()).hexdigest()==digest,name
    import numpy as np,pyworld
    assert pyworld.__version__==dist.version=='0.3.5'
    sr=22050;t=np.arange(sr)/sr;x=(.15*np.sin(2*np.pi*220*t)).astype(np.float64)
    f0,tm=pyworld.dio(x,sr);f0=pyworld.stonemask(x,f0,tm,sr)
    spectral=pyworld.cheaptrick(x,f0,tm,sr);ap=pyworld.d4c(x,f0,tm,sr)
    y=pyworld.synthesize(f0,spectral,ap,sr)
    assert len(y)>0 and np.isfinite(y).all() and np.max(np.abs(y))>0
    result=dict(passed=True,build_installers_absent=True,pyworld_metadata_backport_verified=True,
                pyworld_full_synthesis_passed=True,sqlite_version=sqlite3.sqlite_version,
                sqlite_binary_hash_verified=True,fts5_negative_rowid_prefix_regression_passed=True,
                zlib_crc_negative_length_fixed=True,gzip_roundtrip_passed=True,
                operator_shell_works=True,ca_trust_present=True,retained_debian_packages=len(inventory),
                interactive_terminal_libraries_absent=True,dash_fnmatch_regression_passed=True,
                dns_search_disabled=True,gettext_locale_fixed=True)
    print(json.dumps(result));return result


if __name__=='__main__':verify()
