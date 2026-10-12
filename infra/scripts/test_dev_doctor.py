# dev_doctor.py의 설정 파싱·검증·지문 비교 로직을 확인하는 단위 테스트
"""Run: python -m unittest infra/scripts/test_dev_doctor.py  (or python infra/scripts/test_dev_doctor.py)"""
import json
import sys
import unittest
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dev_doctor as d  # noqa: E402

GOOD_PLIST = """<plist><dict>
<key>GOOGLE_APP_ID</key><string>1:123:ios:abc123</string>
<key>API_KEY</key><string>k</string><key>GCM_SENDER_ID</key><string>123</string>
<key>PROJECT_ID</key><string>humtrack-hq</string><key>BUNDLE_ID</key><string>com.humtrack.app</string>
<key>CLIENT_ID</key><string>c</string><key>REVERSED_CLIENT_ID</key><string>r</string>
</dict></plist>"""

# The old Sign-In-only plist that crashed iOS 1.0.9 on launch.
SIGN_IN_ONLY_PLIST = """<plist><dict>
<key>BUNDLE_ID</key><string>com.humtrack.app</string><key>CLIENT_ID</key><string>c</string>
<key>PLIST_VERSION</key><string>1</string><key>REVERSED_CLIENT_ID</key><string>r</string>
</dict></plist>"""


class ParseEnv(unittest.TestCase):
    def test_quotes_comments_and_blanks(self):
        env = d.parse_env('# c\nA="x=1"\nB=\'y\'\nC=\n\nD=z\n')
        self.assertEqual(env, {"A": "x=1", "B": "y", "D": "z"})


class Plist(unittest.TestCase):
    def test_good_plist_passes(self):
        self.assertEqual(d.plist_problems(GOOD_PLIST), [])

    def test_sign_in_only_plist_is_rejected(self):
        problems = d.plist_problems(SIGN_IN_ONLY_PLIST)
        self.assertIn("missing GOOGLE_APP_ID", problems)
        self.assertIn("missing API_KEY", problems)

    def test_wrong_bundle_and_android_app_id(self):
        text = GOOD_PLIST.replace("com.humtrack.app", "com.other").replace(":ios:", ":android:")
        problems = d.plist_problems(text)
        self.assertIn("BUNDLE_ID is not com.humtrack.app", problems)
        self.assertIn("GOOGLE_APP_ID is not an iOS Firebase app ID", problems)

    def test_compile_only_placeholder(self):
        self.assertTrue(d.plist_problems(GOOD_PLIST.replace("</dict>", "<key>CI_COMPILE_ONLY</key><true/></dict>")))


class AndroidJson(unittest.TestCase):
    def test_package_detection(self):
        data = {"project_info": {"project_id": "humtrack-hq"},
                "client": [{"client_info": {"android_client_info": {"package_name": "com.humtrack.app"}}}]}
        self.assertTrue(d.android_json_values(json.dumps(data))["has_package"])
        data["client"][0]["client_info"]["android_client_info"]["package_name"] = "x"
        self.assertFalse(d.android_json_values(json.dumps(data))["has_package"])


class Sentry(unittest.TestCase):
    def test_project_id(self):
        self.assertEqual(d.sentry_project("https://abc@o1.ingest.sentry.io/4511601866833920"), "4511601866833920")
        self.assertIsNone(d.sentry_project("not a dsn"))


class Fingerprints(unittest.TestCase):
    def test_hash_is_short_and_stable(self):
        self.assertEqual(d.fp("a"), d.fp("a"))
        self.assertEqual(len(d.fp("a")), 12)
        self.assertNotEqual(d.fp("a"), d.fp("b"))

    def test_compare_reports_only_differing_shared_keys(self):
        expected = {"defines": {"A": "1", "B": "2"}, "ios_plist": {"X": "9"}, "sentry_mobile_project_id": "1"}
        actual = {"defines": {"A": "1", "B": "3"}}
        self.assertEqual(d.compare_fingerprints(expected, actual), ["defines.B"])


class GitChecks(unittest.TestCase):
    def check_branch(self, refs, ancestor_code):
        def fake_run(args, cwd=d.ROOT):
            if args[1:3] == ["rev-parse", "--abbrev-ref"]:
                return 0, "chore/devinfra\n"
            if args[1] == "for-each-ref":
                return 0, refs
            if args[1] == "merge-base":
                return ancestor_code, ""
            return 0, ""
        with patch.object(d, "results", []), patch.object(d, "run", side_effect=fake_run):
            d.check_git(False)
            return list(d.results)

    def test_merged_unpublished_branch_is_not_a_failure(self):
        for refs in ("merged||", "merged|origin/merged|[ahead 24]"):
            with self.subTest(refs=refs):
                rows = self.check_branch(refs, 0)
                self.assertFalse(any(level == "FAIL" for level, _, _ in rows))
                self.assertTrue(any("no unpublished commits" in msg for _, _, msg in rows))

    def test_unmerged_unpublished_branch_still_fails(self):
        for refs in ("feature||", "feature|origin/feature|[ahead 1]"):
            with self.subTest(refs=refs):
                rows = self.check_branch(refs, 1)
                self.assertTrue(any(level == "FAIL" for level, _, _ in rows))

    def test_missing_main_does_not_hide_unpublished_commits(self):
        rows = self.check_branch("feature|origin/feature|[ahead 1]", 128)
        self.assertTrue(any(level == "FAIL" for level, _, _ in rows))


if __name__ == "__main__":
    unittest.main()
