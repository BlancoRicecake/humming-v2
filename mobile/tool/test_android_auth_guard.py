"""Exercise the real Gradle release guard without Android, credentials or network.

Run: python3 tool/test_android_auth_guard.py
Optional GRADLE points to a local Gradle executable; otherwise use the wrapper.
"""
import base64
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

MOBILE = Path(__file__).resolve().parents[1]
GUARD = MOBILE / "android/auth-config.gradle"
GRADLE = os.environ.get("GRADLE", str(MOBILE / "android" / ("gradlew.bat" if os.name == "nt" else "gradlew")))
VALID = {
    "SUPABASE_URL": "https://login.example.test",
    "SUPABASE_ANON_KEY": "test-only-public-key-do-not-log",
    "GOOGLE_WEB_CLIENT_ID": "123-test.apps.googleusercontent.com",
}

class AndroidAuthGuardTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="humtrack-auth-guard-")
        cls.project = Path(cls.temp.name)
        (cls.project / "settings.gradle").write_text("rootProject.name = 'auth-guard-test'\n")
        path = GUARD.as_posix().replace("'", "\\'")
        (cls.project / "build.gradle").write_text(
            f"apply from: '{path}'\n"
            "['compileFlutterBuildRelease', 'compileFlutterBuildProductionRelease', 'compileFlutterBuildDebug'].each { taskName ->\n"
            "    tasks.register(taskName) { doLast { println 'COMPILER_REACHED' } }\n"
            "}\n"
        )

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def run_guard(self, values=None, task="compileFlutterBuildRelease", encoded=None):
        if encoded is None:
            encoded = ",".join(base64.b64encode(f"{k}={v}".encode()).decode() for k, v in (values or {}).items())
        result = subprocess.run(
            [GRADLE, "--offline", "--console=plain", "-p", str(self.project), task, f"-Pdart-defines={encoded}"],
            text=True, encoding="utf-8", errors="replace", stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=120,
        )
        self.assertNotIn(VALID["SUPABASE_ANON_KEY"], result.stdout)
        self.assertNotIn(VALID["SUPABASE_URL"], result.stdout)
        return result

    def test_no_defines_blocks_compiler(self):
        result = self.run_guard()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SUPABASE_URL, SUPABASE_ANON_KEY, GOOGLE_WEB_CLIENT_ID", result.stdout)
        self.assertNotIn("COMPILER_REACHED", result.stdout)

    def test_firebase_only_blocks_compiler(self):
        result = self.run_guard({"FIREBASE_ANALYTICS_ENABLED": "true", "FIREBASE_PROJECT_ID": "analytics-only"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing release authentication configuration", result.stdout)
        self.assertNotIn("COMPILER_REACHED", result.stdout)

    def test_complete_configuration_reaches_compiler(self):
        result = self.run_guard(VALID)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("COMPILER_REACHED", result.stdout)

    def test_missing_google_id_rejected_for_flavor(self):
        result = self.run_guard({k: v for k, v in VALID.items() if k != "GOOGLE_WEB_CLIENT_ID"}, task="compileFlutterBuildProductionRelease")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("GOOGLE_WEB_CLIENT_ID", result.stdout)
        self.assertNotIn("COMPILER_REACHED", result.stdout)

    def test_whitespace_key_rejected(self):
        result = self.run_guard(dict(VALID, SUPABASE_ANON_KEY="   "))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SUPABASE_ANON_KEY", result.stdout)

    def test_malformed_base64_rejected_without_echo(self):
        result = self.run_guard(encoded="not-valid-base64:private")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Invalid encoded Dart configuration", result.stdout)
        self.assertNotIn("not-valid-base64:private", result.stdout)

    def test_invalid_url_rejected(self):
        result = self.run_guard(dict(VALID, SUPABASE_URL="http://login.example.test"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SUPABASE_URL must be an HTTPS origin", result.stdout)

    def test_invalid_google_client_rejected(self):
        result = self.run_guard(dict(VALID, GOOGLE_WEB_CLIENT_ID="not-a-client"))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("GOOGLE_WEB_CLIENT_ID must be", result.stdout)

    def test_debug_build_still_works_without_secrets(self):
        result = self.run_guard(task="compileFlutterBuildDebug")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("COMPILER_REACHED", result.stdout)
        self.assertNotIn("Release authentication configuration verified", result.stdout)

    def test_success_cannot_cache_away_later_missing_defines(self):
        self.assertEqual(self.run_guard(VALID).returncode, 0)
        result = self.run_guard()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("COMPILER_REACHED", result.stdout)

if __name__ == "__main__":
    unittest.main(verbosity=2)
