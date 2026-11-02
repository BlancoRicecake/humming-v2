"""Build a reviewed Windows installer payload from the CURRENT mobile build.

No upload, signing-key access, registry writes, or customer-data access. A build
receipt is mandatory: a successful exe compile alone does not prove that auth,
Sentry and public announcement configuration were included. Source/QA copies
and old files left in the reused build directory must never enter the package.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import pathlib
import re
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
NATIVE = {
    'HumTrack.exe', 'flutter_windows.dll', 'app_links_plugin.dll',
    'audioplayers_windows_plugin.dll', 'file_selector_windows_plugin.dll',
    'record_windows_plugin.dll', 'sentry.dll', 'share_plus_plugin.dll',
    'url_launcher_windows_plugin.dll', 'crashpad_wer.dll', 'crashpad_handler.exe',
    'dartjni.dll', 'native_assets.json',
}
REQUIRED = {'HumTrack.exe', 'flutter_windows.dll', 'data/app.so',
            'data/icudtl.dat', 'data/flutter_assets/NOTICES.Z',
            'data/flutter_assets/assets/legal/GeneralUser-GS-LICENSE.txt'}
CONFIG = {'SUPABASE_URL', 'SUPABASE_ANON_KEY', 'ENGINE_URL', 'SENTRY_DSN_MOBILE'}


def digest(path: pathlib.Path) -> str:
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def inside_root(path: pathlib.Path) -> pathlib.Path:
    result = path.resolve()
    if not result.is_relative_to(ROOT) or result == ROOT:
        raise ValueError('Build and output paths must stay inside the workspace')
    return result


def package(build: pathlib.Path, output: pathlib.Path, crt: pathlib.Path) -> dict:
    build, output = inside_root(build), inside_root(output)
    if output.exists():
        raise ValueError('Output already exists; choose a new candidate directory')
    receipt = json.loads((build / 'humtrack-build-receipt.json').read_text(encoding='utf-8'))
    if not re.fullmatch(r'\d+\.\d+\.\d+\+[1-9]\d*', receipt.get('version', '')):
        raise ValueError('Invalid package version')
    if receipt.get('entrypoint') != 'lib/main.dart' or receipt.get('mode') != 'release':
        raise ValueError('Only the production main entrypoint in release mode can be packaged')
    if not CONFIG.issubset(receipt.get('configuration_keys', [])):
        raise ValueError('Release configuration was not verified at build time')
    if not all((build / p).is_file() for p in REQUIRED):
        raise ValueError('Incomplete Flutter distribution')
    for name in ['HumTrack.exe', 'data/app.so']:
        if receipt.get('binary_sha256', {}).get(name) != digest(build / name):
            raise ValueError('Build receipt no longer matches the executable/Dart code')
    try:
        package_notices = gzip.decompress((build / 'data/flutter_assets/NOTICES.Z').read_bytes()).decode('utf-8')
    except (OSError, ValueError, UnicodeError) as error:
        raise ValueError('Flutter third-party license bundle is invalid') from error
    if not all((crt / name).is_file() for name in ['msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll']):
        raise ValueError('Supply the official Visual Studio x64 VC143.CRT redist directory')
    files = []
    for p in build.rglob('*'):
        if p.is_symlink():
            raise ValueError('Symlinks are not permitted in a release payload')
        if not p.is_file():
            continue
        relative = p.relative_to(build)
        if len(relative.parts) == 1 and relative.name in NATIVE:
            files.append((p, relative))
        elif relative.parts[0] == 'data':
            files.append((p, relative))
    output.mkdir(parents=True)
    payload = output / 'payload'
    payload.mkdir()
    for source, relative in files:
        target = payload / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    for source in crt.glob('*.dll'):
        shutil.copy2(source, payload / source.name)
    legal = build / 'data/flutter_assets/assets/legal'
    notices = ['HumTrack third-party notices\n\nFlutter and package licenses\n\n', package_notices]
    for source in sorted(legal.glob('*.txt')):
        notices.extend(['\n\n' + source.name + '\n\n', source.read_text(encoding='utf-8-sig')])
    (payload / 'THIRD-PARTY-NOTICES.txt').write_text(''.join(notices), encoding='utf-8')
    (payload / 'README.txt').write_text(
        'HumTrack for Windows\nhttps://hum-track.com\nSupport: humtrack@gmail.com\n\n'
        'Basic instruments are included. Additional sounds download from inside the app.\n'
        'Save and close HumTrack before installing an update.\n'
        'Uninstalling removes the application, not your saved music.\n'
        'Subscriptions: use the phone app, then sign in with the same account.\n'
        'Open Settings > Licenses for third-party notices.\n', encoding='utf-8')
    manifest = dict(receipt, public_release_ready=False,
                    reason='Signing, clean-machine install and release checklist still required',
                    files={p.relative_to(payload).as_posix(): digest(p)
                           for p in sorted(payload.rglob('*')) if p.is_file()})
    (output / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=pathlib.Path, default=ROOT / 'mobile/build/windows/x64/runner/Release')
    parser.add_argument('--output', required=True, type=pathlib.Path)
    parser.add_argument('--crt-dir', required=True, type=pathlib.Path)
    parser.add_argument('--iscc', required=True, type=pathlib.Path)
    args = parser.parse_args()
    manifest = package(args.build_dir, args.output, args.crt_dir)
    version, build = manifest['version'].split('+')
    subprocess.run([str(args.iscc), '/Qp', f'/DPayloadDir={args.output.resolve() / "payload"}',
                    f'/DOutputDir={args.output.resolve()}', f'/DAppVersion={version}',
                    f'/DAppBuild={build}', f'/DAppIcon={ROOT / "mobile/windows/runner/resources/app_icon.ico"}',
                    str(ROOT / 'infra/windows/humtrack.iss')], check=True)
    installer = next(args.output.glob('*-setup.exe'))
    (args.output / 'SHA256SUMS.txt').write_text(f'{digest(installer)}  {installer.name}\n', encoding='utf-8')
    print(json.dumps({'installer': str(installer), 'sha256': digest(installer), 'public_release_ready': False}))


if __name__ == '__main__':
    main()
