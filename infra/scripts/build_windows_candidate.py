"""Build main.dart with validated PUBLIC client configuration, never server keys.

The receipt contains key NAMES and binary/source hashes only. The supplied
configuration file remains ignored and must not be distributed. The result is
an internal candidate, not permission to publish or enable cloud backup.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import pathlib
import re
import subprocess
import tempfile
from urllib.parse import urlparse

from package_windows import ROOT, digest

PUBLIC = {
    'SUPABASE_URL', 'SUPABASE_ANON_KEY', 'GOOGLE_WEB_CLIENT_ID', 'ENGINE_URL',
    'CLARITY_PROJECT_ID', 'SENTRY_DSN_MOBILE', 'APP_ENVIRONMENT', 'SENTRY_ENVIRONMENT',
    'HUMTRACK_CLOUD_BACKUP',
}
REQUIRED = {'SUPABASE_URL', 'SUPABASE_ANON_KEY', 'ENGINE_URL', 'SENTRY_DSN_MOBILE'}


def read_config(path: pathlib.Path) -> dict[str, str]:
    if path.suffix == '.json':
        values = json.loads(path.read_text(encoding='utf-8-sig'))
        if not isinstance(values, dict) or set(values) - PUBLIC:
            raise ValueError('JSON must contain only approved public Windows client keys')
    else:
        values = {}
        for line in path.read_text(encoding='utf-8-sig').splitlines():
            key, sep, value = line.partition('=')
            if sep and key.strip() in PUBLIC:
                values[key.strip()] = value.strip().strip('"\'')
    if not REQUIRED.issubset(values) or any(not isinstance(v, str) or not v.strip() for v in values.values()):
        raise ValueError('Required public client configuration is missing or empty')
    for key in ['SUPABASE_URL', 'ENGINE_URL', 'SENTRY_DSN_MOBILE']:
        uri = urlparse(values[key])
        if uri.scheme != 'https' or not uri.hostname or uri.hostname in {'localhost', '127.0.0.1'}:
            raise ValueError(f'{key} must use a production HTTPS endpoint')
    dsn = urlparse(values['SENTRY_DSN_MOBILE'])
    if dsn.path.rstrip('/').split('/')[-1] != '4511601866833920':
        raise ValueError('Sentry must use the verified HumTrack mobile project')
    anon = values['SUPABASE_ANON_KEY']
    if anon.startswith('sb_secret_'):
        raise ValueError('An admin key must never be compiled into the app')
    if anon.count('.') == 2:
        payload = anon.split('.')[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + '=' * (-len(payload) % 4)))
        if claims.get('role') != 'anon':
            raise ValueError('Only a public Supabase anon key is allowed')
    elif not anon.startswith('sb_publishable_'):
        raise ValueError('Supabase key must be a public anon or publishable key')
    for key in ['HUMTRACK_CLOUD_BACKUP']:
        if key in values and values[key] not in {'true', 'false'}:
            raise ValueError(f'{key} must be true or false')
    return values


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=pathlib.Path, required=True)
    parser.add_argument('--flutter', default='flutter')
    parser.add_argument('--evidence-dir', required=True, type=pathlib.Path)
    args = parser.parse_args()
    values = read_config(args.config)
    qa = args.evidence_dir.resolve()
    if not qa.is_relative_to(ROOT / 'artifacts'):
        raise ValueError('Evidence must stay under workspace artifacts')
    qa.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.update(TMP=str(qa), TEMP=str(qa))
    version = re.search(r'^version:\s*(\d+\.\d+\.\d+\+[1-9]\d*)\s*$',
                        (ROOT / 'mobile/pubspec.yaml').read_text(encoding='utf-8'), re.M).group(1)
    build = ROOT / 'mobile/build/windows/x64/runner/Release'
    receipt = build / 'humtrack-build-receipt.json'
    # Never leave a prior success receipt when this build fails.
    if receipt.exists():
        receipt.unlink()
    with tempfile.TemporaryDirectory(prefix='public-defines-', dir=qa) as temp:
        config = pathlib.Path(temp) / 'defines.json'
        config.write_text(json.dumps(values), encoding='utf-8')
        with (qa / 'windows-configured-build.log').open('w', encoding='utf-8') as log:
            result = subprocess.run([args.flutter, 'build', 'windows', '--release', '--no-pub',
                                     '--target', 'lib/main.dart', '--dart-define-from-file=' + str(config)],
                                    cwd=ROOT / 'mobile', env=env, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            raise SystemExit(result.returncode)
    source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    metadata = {'entrypoint': 'lib/main.dart', 'mode': 'release', 'version': version,
                'source_commit': source, 'source_has_local_changes': bool(subprocess.check_output(
                    ['git', 'status', '--porcelain', '--', 'mobile', 'infra/windows', 'infra/scripts'], cwd=ROOT)),
                'configuration_keys': sorted(values),
                'cloud_backup_enabled': values.get('HUMTRACK_CLOUD_BACKUP', 'false') == 'true',
                'binary_sha256': {name: digest(build / name) for name in ['HumTrack.exe', 'data/app.so']}}
    receipt.write_text(json.dumps(metadata, indent=2), encoding='utf-8')
    (qa / receipt.name).write_text(json.dumps(metadata, indent=2), encoding='utf-8')
    print(json.dumps({'built': True, 'version': version, 'cloud_backup_enabled': metadata['cloud_backup_enabled'],
                      'configuration_keys': metadata['configuration_keys'], 'public_release_ready': False}))


if __name__ == '__main__':
    main()
