# ci_disk_space.py: 이름이 정해진 미사용 도구만 지우고, 필요한 도구·작업공간은 지키는지
"""Run: python3 infra/scripts/test_ci_disk_space.py"""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci_disk_space as d  # noqa: E402


class Reclaim(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        r = Path(self.tmp.name).resolve()
        self.r = r
        for p in ("usr/share/dotnet/x", "opt/ghc/x", "tool/CodeQL/x", "tool/Ruby/3.3", "work/repo/mobile",
                  "home/runner/.gradle", "android/sdk/ndk/28.2.13676358", "jvm/temurin-17"):
            (r / p).mkdir(parents=True)
        self.env = {
            "RUNNER_ENVIRONMENT": "github-hosted",
            "GITHUB_WORKSPACE": str(r / "work/repo"),
            "HOME": str(r / "home/runner"),
            "ANDROID_HOME": str(r / "android/sdk"),
            "JAVA_HOME": str(r / "jvm/temurin-17"),
            "RUNNER_TOOL_CACHE": str(r / "tool"),
        }
        self.removed = []

    def tearDown(self):
        self.tmp.cleanup()

    def run_reclaim(self, targets, **kw):
        def remove(p):
            self.removed.append(p)
            import shutil
            shutil.rmtree(p)
        return d.reclaim(self.env, targets=[str(self.r / t) for t in targets], remove=remove,
                         size=lambda p: 1024**3, platform="linux", out=lambda *_: None, **kw)

    def test_only_named_unused_tools_go(self):
        n = self.run_reclaim(["usr/share/dotnet", "opt/ghc", "tool/CodeQL", "missing/tool"],
                             required_after=[str(self.r / "android/sdk")])
        self.assertEqual(n, 3 * 1024**3)
        self.assertEqual([p.name for p in self.removed], ["dotnet", "ghc", "CodeQL"])
        for kept in ("tool/Ruby/3.3", "work/repo/mobile", "home/runner/.gradle",
                     "android/sdk/ndk/28.2.13676358", "jvm/temurin-17"):
            self.assertTrue((self.r / kept).exists(), kept)

    def test_never_a_kept_or_protected_path(self):
        targets = ["work/repo", "work", "home/runner/.gradle", "android/sdk/ndk", "android", "tool", "jvm/temurin-17"]
        self.run_reclaim(targets)
        self.assertEqual(self.removed, [])

    def test_a_symlink_is_not_followed(self):
        link = self.r / "opt/link"
        try:
            link.symlink_to(self.r / "work/repo", target_is_directory=True)
        except OSError:
            self.skipTest("symlinks not permitted here")
        self.run_reclaim(["opt/link"])
        self.assertEqual(self.removed, [])
        self.assertTrue((self.r / "work/repo/mobile").exists())

    def test_too_close_to_root_is_refused(self):
        self.assertEqual(d.check_target(Path("/opt"), []), "too close to /")

    def test_self_hosted_or_not_linux_deletes_nothing(self):
        for env, platform in ((dict(self.env, RUNNER_ENVIRONMENT="self-hosted"), "linux"),
                              (dict(self.env), "darwin"), ({}, "linux")):
            self.env = env
            n = d.reclaim(env, targets=[str(self.r / "usr/share/dotnet")], remove=self.removed.append,
                          size=lambda p: 1, platform=platform, out=lambda *_: None)
            self.assertEqual(n, 0)
        self.assertEqual(self.removed, [])

    def test_a_kept_tool_that_disappears_fails_the_job(self):
        sdk = self.r / "android/sdk"

        def remove_and_break(p):
            import shutil
            shutil.rmtree(p)
            shutil.rmtree(sdk)
        with self.assertRaises(SystemExit):
            d.reclaim(self.env, targets=[str(self.r / "opt/ghc")], remove=remove_and_break,
                      size=lambda p: 1, required_after=[str(sdk)], platform="linux", out=lambda *_: None)

    def test_the_real_list_spares_every_android_build_tool(self):
        keep = [Path(p) for p in ("/usr/local/lib/android/sdk", "/usr/lib/jvm", "/opt/hostedtoolcache/Ruby",
                                  "/opt/hostedtoolcache/flutter", "/opt/hostedtoolcache/Java_Temurin-Hotspot_jdk",
                                  "/opt/hostedtoolcache/Python", "/home/runner")]
        for t in d.RECLAIM:
            for k in keep:
                self.assertFalse(d._inside(k, Path(t)), f"{t} would remove {k}")
                self.assertFalse(d._inside(Path(t), k) and k != Path("/opt/hostedtoolcache"), f"{t} inside {k}")


class Report(unittest.TestCase):
    def test_report_prints_free_space_and_ndk(self):
        lines = []
        d.report({"GITHUB_WORKSPACE": str(Path.cwd())}, size=lambda p: 0, out=lines.append)
        self.assertTrue(any("free" in l for l in lines))
        self.assertTrue(any(d.NDK in l for l in lines))


if __name__ == "__main__":
    unittest.main()
