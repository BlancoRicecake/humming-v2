"""Opt-in provider contract check using ONLY two explicitly isolated accounts.

Default is a plan, with no network. --apply requires CLOUD_QA_TOKEN_A/B and
CLOUD_QA_ALLOWED_USERS (two UUIDs). It creates one uniquely named QA project,
uses synthetic bytes only, and cleans that project in finally. No admin key,
customer project, Auth deletion or entitlement modification is accepted.

This checks the storage/API contract. Actual app backup import/audio and phone
roundtrips are separate checks; synthetic bytes are deliberately not music.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import logging
import os
import uuid
from urllib.parse import urlparse

import httpx


def account_id(token):
    try:
        payload = token.split('.')[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + '=' * (-len(payload) % 4)))
        if claims.get('role') != 'authenticated':
            raise ValueError()
        return str(uuid.UUID(claims['sub']))
    except Exception:
        raise ValueError('A dedicated test-user access token is required') from None


class ProviderCheck:
    def __init__(self, url, tokens, allowed_users, *, allow_local=False):
        uri = urlparse(url)
        local = allow_local and uri.scheme == 'http' and uri.hostname == '127.0.0.1'
        if uri.query or uri.fragment or (not local and (uri.scheme != 'https' or not uri.hostname or uri.username or uri.password)):
            raise ValueError('Use an explicit HTTPS API, or the local fixture option')
        self.users = [account_id(t) for t in tokens]
        allowed = {str(uuid.UUID(u.strip())) for u in allowed_users.split(',')}
        if len(allowed) != 2 or len(set(self.users)) != 2 or set(self.users) != allowed:
            raise ValueError('Tokens must match exactly two explicitly allowed QA accounts')
        self.tokens, self.local = tokens, local
        self.project = 'ltqa_' + uuid.uuid4().hex
        self.api = httpx.Client(base_url=url.rstrip('/'), timeout=20, follow_redirects=False, trust_env=True)
        self.storage = httpx.Client(timeout=20, follow_redirects=False, trust_env=True)
        self.steps = []
        self.created = False

    def api_request(self, who, method, path, body=None):
        try:
            return self.api.request(method, path, json=body, headers={
                'Authorization': 'Bearer ' + self.tokens[who], 'X-Expected-User': self.users[who]})
        except Exception:
            raise RuntimeError('API transport failed; credentials and URLs suppressed') from None

    def expect(self, response, statuses, step):
        if response.status_code not in statuses:
            raise RuntimeError(f'{step} failed (HTTP {response.status_code}); response body suppressed')
        self.steps.append(step)
        if not response.content:
            return None
        try:
            return response.json()
        except Exception:
            raise RuntimeError(f'{step} returned an invalid JSON response') from None

    def object_request(self, method, url, *, data=None, headers=None):
        uri = urlparse(url)
        local = self.local and uri.scheme == 'http' and uri.hostname == '127.0.0.1'
        if not local and (uri.scheme != 'https' or not uri.hostname or
                          not uri.hostname.endswith('.r2.cloudflarestorage.com') or uri.username or uri.password):
            raise RuntimeError('Unapproved object storage host (signed URL suppressed)')
        try:
            return self.storage.request(method, url, content=data, headers=headers)
        except Exception:
            raise RuntimeError('Object transport failed (signed URL suppressed)') from None

    def presign(self, data):
        grant = self.expect(self.api_request(0, 'POST', '/storage/presign', {
            'project_id': self.project, 'size_bytes': len(data)}), {200}, 'presign')
        self.created = True  # even a failed PUT can leave a fixture to clean
        prefix = f'vocals/{self.users[0]}/{self.project}/up-'
        if not grant['key'].startswith(prefix):
            raise RuntimeError('Upload grant is outside the owned fixture project')
        if grant.get('headers', {}).get('If-None-Match') != '*':
            raise RuntimeError('Upload is not create-only')
        return grant

    def upload(self, data, *, check_conditional=False):
        grant = self.presign(data)
        first = self.object_request('PUT', grant['url'], data=data, headers=grant['headers'])
        if first.status_code not in {200, 201, 204}:
            raise RuntimeError(f'PUT failed (HTTP {first.status_code}); signed URL suppressed')
        if check_conditional:
            replay = self.object_request('PUT', grant['url'], data=b'X' * len(data), headers=grant['headers'])
            if replay.status_code != 412:
                raise RuntimeError(f'Conditional PUT failed (HTTP {replay.status_code})')
            self.steps.append('conditional_put_412')
        return grant

    def commit(self, grant, data, *, expected=None):
        body = {'project_id': self.project, 'title': 'HumTrack isolated provider QA',
                'meta': {'format': 'humtrack', 'formatVersion': 1, 'key': grant['key'],
                         'size': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                         'audioIncluded': False, 'takes': 0, 'missingTakes': 0, 'songSchema': 3}}
        body.update({'expect_absent': True} if expected is None else {'expected_updated_at': expected})
        return self.api_request(0, 'POST', '/projects', body)

    def verify_copy(self, data):
        row = self.expect(self.api_request(0, 'GET', '/projects/' + self.project), {200}, 'read_copy')
        key = row['meta']['key']
        if not key.startswith(f'vocals/{self.users[0]}/{self.project}/bk-'):
            raise RuntimeError('Published key is not a private committed copy')
        signed = self.expect(self.api_request(0, 'POST', '/storage/presign_get', {'key': key}), {200}, 'download_grant')
        downloaded = self.object_request('GET', signed['url'])
        if downloaded.status_code != 200 or hashlib.sha256(downloaded.content).digest() != hashlib.sha256(data).digest():
            raise RuntimeError('Downloaded fixture bytes differ')
        self.steps.append('download_sha256_matches')
        return row

    def run(self):
        # Disable URL-bearing library logs for this check, restoring afterwards.
        levels = {n: logging.getLogger(n).level for n in ['httpx', 'httpcore']}
        for name in levels: logging.getLogger(name).setLevel(logging.CRITICAL)
        report = {'project_id': self.project, 'passed': False, 'cleanup_confirmed': False,
                  'synthetic_provider_fixture': True, 'app_import_tested': False, 'steps': self.steps}
        try:
            usage = self.expect(self.api_request(0, 'GET', '/storage/usage'), {200}, 'contract')
            if usage.get('contract') != 1: raise RuntimeError('Backup contract 1 is required')
            first = b'HumTrack isolated provider QA original\n'
            a = self.upload(first, check_conditional=True)
            version = self.expect(self.commit(a, first), {200}, 'first_commit')['updated_at']
            row = self.verify_copy(first)
            replay = self.object_request('PUT', a['url'], data=b'X' * len(first), headers=a['headers'])
            if replay.status_code not in {200, 201, 204, 412}:
                raise RuntimeError('Committed-upload URL replay returned an unexpected status')
            self.verify_copy(first)
            self.steps.append('old_upload_url_cannot_mutate_published_copy')
            self.expect(self.api_request(1, 'GET', '/projects/' + self.project), {404}, 'other_account_cannot_read')
            self.expect(self.api_request(1, 'POST', '/storage/presign_get', {'key': row['meta']['key']}), {403}, 'other_account_cannot_download')
            self.expect(self.api_request(1, 'DELETE', '/projects/' + self.project), {204}, 'other_account_delete_is_scoped')
            self.verify_copy(first)
            second = b'HumTrack isolated provider QA replacement\n'
            b = self.upload(second)
            self.expect(self.commit(b, second, expected=version), {200}, 'replacement_commit')
            self.verify_copy(second)
            third = b'HumTrack isolated provider QA stale device\n'
            c = self.upload(third)
            self.expect(self.commit(c, third, expected=version), {409}, 'stale_commit_409')
            self.verify_copy(second)
            bad = self.presign(first)
            headers = dict(bad['headers'], **{'Content-Length': str(len(first) + 1)})
            response = self.object_request('PUT', bad['url'], data=first + b'X', headers=headers)
            if response.status_code not in {400, 403}:
                raise RuntimeError(f'Signed length was not refused (HTTP {response.status_code})')
            self.steps.append('signed_length_refused')
            report['passed'] = True
        except Exception as error:
            report['error'] = str(error) if isinstance(error, RuntimeError) else 'Unexpected provider check failure (details suppressed)'
        finally:
            if self.created:
                try:
                    r = self.api_request(0, 'DELETE', '/projects/' + self.project)
                    gone = self.api_request(0, 'GET', '/projects/' + self.project)
                    report['cleanup_confirmed'] = r.status_code == 204 and gone.status_code == 404
                except Exception:
                    report['cleanup_confirmed'] = False
            else:
                report['cleanup_confirmed'] = True
            for name, level in levels.items(): logging.getLogger(name).setLevel(level)
            self.api.close()
            self.storage.close()
        report['passed'] &= report['cleanup_confirmed']
        return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--api-url', required=True)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if not args.apply:
        print(json.dumps({'network_used': False, 'writes': False, 'plan': [
            'contract1', 'conditional PUT', 'signed length', 'copy SHA256',
            'account isolation', 'replacement/CAS conflict', 'owned fixture cleanup']}))
        return
    tokens = [os.environ.get('CLOUD_QA_TOKEN_A', ''), os.environ.get('CLOUD_QA_TOKEN_B', '')]
    check = ProviderCheck(args.api_url, tokens, os.environ.get('CLOUD_QA_ALLOWED_USERS', ''))
    report = check.run()
    print(json.dumps(report, ensure_ascii=False))
    if not report['passed']: raise SystemExit(1)


if __name__ == '__main__': main()
