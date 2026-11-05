"""Packaging boundary tests; fixtures stay in workspace artifacts."""
import base64
import gzip
import json
import pathlib
import struct
import tempfile
import unittest

from build_windows_candidate import read_config
from package_windows import ROOT, REQUIRED, digest, package
from check_android_native_alignment import segments


class WindowsReleaseTests(unittest.TestCase):
    def setUp(self):
        qa = ROOT / 'artifacts/release-preflight-2026-10-31'
        qa.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=qa, prefix='package-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.build = self.root / 'build'
        self.crt = self.root / 'crt'
        self.crt.mkdir()
        for n in ['msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll']:
            (self.crt / n).write_bytes(b'fixture CRT')
        for n in REQUIRED:
            f = self.build / n
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_bytes(b'fixture ' + n.encode())
        (self.build / 'data/flutter_assets/NOTICES.Z').write_bytes(gzip.compress(b'Flutter fixture license'))
        self.receipt = {
            'entrypoint': 'lib/main.dart', 'mode': 'release', 'version': '1.0.13+43',
            'configuration_keys': ['SUPABASE_URL', 'SUPABASE_ANON_KEY', 'ENGINE_URL', 'SENTRY_DSN_MOBILE'],
            'binary_sha256': {n: digest(self.build / n) for n in ['HumTrack.exe', 'data/app.so']},
        }
        self.save_receipt()

    def save_receipt(self):
        (self.build / 'humtrack-build-receipt.json').write_text(json.dumps(self.receipt))

    def pack(self):
        return package(self.build, self.root / 'candidate', self.crt)

    def test_stale_build_files_are_excluded_and_crt_is_included(self):
        for n in ['old-notes.txt', 'HumTrack.lib', 'old.exe', 'private.env', 'old.dll']:
            (self.build / n).write_text('must not ship')
        result = self.pack()
        names = result['files']
        self.assertIn('msvcp140.dll', names)
        self.assertIn('data/app.so', names)
        self.assertIn('THIRD-PARTY-NOTICES.txt', names)
        notices = (self.root / 'candidate/payload/THIRD-PARTY-NOTICES.txt').read_text(encoding='utf-8')
        self.assertIn('Flutter fixture license', notices)
        self.assertIn('GeneralUser-GS-LICENSE.txt', notices)
        self.assertNotIn('old-notes.txt', names)
        self.assertNotIn('old.dll', names)
        self.assertFalse(result['public_release_ready'])

    def test_test_entrypoint_is_refused(self):
        self.receipt['entrypoint'] = 'test/qa_exit_save_app.dart'
        self.save_receipt()
        with self.assertRaises(ValueError): self.pack()

    def test_changed_dart_code_is_refused(self):
        (self.build / 'data/app.so').write_bytes(b'new unverified build')
        with self.assertRaises(ValueError): self.pack()

    def test_unconfigured_build_is_refused(self):
        self.receipt['configuration_keys'] = []
        self.save_receipt()
        with self.assertRaises(ValueError): self.pack()

    def test_missing_runtime_is_refused_before_output(self):
        (self.crt / 'vcruntime140.dll').unlink()
        with self.assertRaises(ValueError): self.pack()
        self.assertFalse((self.root / 'candidate').exists())

    def test_invalid_license_bundle_is_refused_before_output(self):
        (self.build / 'data/flutter_assets/NOTICES.Z').write_bytes(b'corrupt bundle')
        with self.assertRaises(ValueError): self.pack()
        self.assertFalse((self.root / 'candidate').exists())

    def test_existing_candidate_is_never_overwritten(self):
        self.pack()
        with self.assertRaises(ValueError): self.pack()

    def test_configuration_rejects_admin_key_and_unknown_json_fields(self):
        payload = base64.urlsafe_b64encode(json.dumps({'role': 'anon'}).encode()).decode().rstrip('=')
        values = {'SUPABASE_URL': 'https://fixture.supabase.co', 'SUPABASE_ANON_KEY': 'h.' + payload + '.s',
                  'ENGINE_URL': 'https://api.hum-track.com',
                  'SENTRY_DSN_MOBILE': 'https://fixture@o0.ingest.sentry.io/4511601866833920'}
        f = self.root / 'public.json'
        f.write_text(json.dumps(values))
        self.assertEqual(set(read_config(f)), set(values))
        values['SUPABASE_SERVICE_ROLE_KEY'] = 'fixture admin key'
        f.write_text(json.dumps(values))
        with self.assertRaises(ValueError): read_config(f)
        del values['SUPABASE_SERVICE_ROLE_KEY']
        values['SUPABASE_ANON_KEY'] = 'sb_secret_' + 'x' * 30
        f.write_text(json.dumps(values))
        with self.assertRaises(ValueError): read_config(f)

    def test_elf_checker_refuses_4kb_segments_and_accepts_16kb(self):
        elf = bytearray(120)
        elf[:6] = b'\x7fELF\x02\x01'
        struct.pack_into('<Q', elf, 32, 64)
        struct.pack_into('<HH', elf, 54, 56, 1)
        struct.pack_into('<IIQQQQQQ', elf, 64, 1, 5, 0, 0, 0, 100, 100, 4096)
        self.assertFalse(segments(elf)[0]['ok'])
        struct.pack_into('<Q', elf, 112, 16384)
        self.assertTrue(segments(elf)[0]['ok'])
        struct.pack_into('<Q', elf, 80, 4096)
        self.assertFalse(segments(elf)[0]['ok'])


if __name__ == '__main__': unittest.main()
