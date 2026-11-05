# GitHub-hosted Ubuntu 러너의 디스크 측정·확보 (Android CI / Android release).
"""Measure and, on GitHub-hosted Ubuntu runners only, reclaim disk space.

2026-11-04: develop's Mobile CI died in the Android build with
``System.IO.IOException: No space left on device`` (runner _diag log) after
analyze + all tests had passed. The image ships large toolchains this
repository never uses; the Android build (Gradle, NDK 28.2 C++ for jni/
MeltySynth, arm64 APK/AAB) needs the room.

  report   print free space and the size of every candidate / kept path
  reclaim  delete ONLY the named, unused preinstalled tools below, then
           check that every kept tool is still there and report again;
           with --min-free-gb, fail early and clearly if space stays short

Never touched: the workspace, HOME, RUNNER_TEMP, the Android SDK (all NDKs
included), Java, Flutter, Ruby, Python, Node, Gradle caches, Docker images.
Self-hosted or non-Linux runners: nothing is deleted.

Run: python3 infra/scripts/ci_disk_space.py report|reclaim [--min-free-gb N]
Tests: python3 infra/scripts/test_ci_disk_space.py
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Callable, Iterable, Optional

# Preinstalled on ubuntu-latest, unused by this repository's Android jobs
# (no .NET, Haskell, Swift, Julia, PowerShell, Azure CLI, CodeQL or Boost).
RECLAIM = (
    "/usr/share/dotnet",
    "/opt/ghc",
    "/usr/local/.ghcup",
    "/usr/share/swift",
    "/usr/local/share/boost",
    "/usr/local/share/powershell",
    "/opt/microsoft/powershell",
    "/opt/az",
    "/usr/local/julia",
    "/opt/hostedtoolcache/CodeQL",
)

# Must survive (checked after reclaiming; the Android SDK and Java are what
# the build needs before setup-java / flutter-action add their own).
KEEP_ENV = ("GITHUB_WORKSPACE", "HOME", "RUNNER_TEMP", "ANDROID_HOME", "ANDROID_SDK_ROOT",
            "JAVA_HOME", "JAVA_HOME_17_X64", "RUNNER_TOOL_CACHE")
KEEP_FIXED = ("/usr/local/lib/android/sdk", "/opt/hostedtoolcache")
REQUIRED_AFTER = ("/usr/local/lib/android/sdk",)
NDK = "28.2.13676358"  # mobile/android/app/build.gradle.kts ndkVersion


def kept_paths(env: dict) -> list[Path]:
    out = [Path(p) for p in KEEP_FIXED]
    out += [Path(env[k]) for k in KEEP_ENV if env.get(k)]
    return list(dict.fromkeys(p.resolve() for p in out))


def _inside(child: Path, parent: Path) -> bool:
    return child == parent or parent in child.parents


# Nothing below these may be deleted (the tool cache is not here: CodeQL
# lives in it next to the kept Java / Ruby / Flutter / Python).
PROTECTED_ENV = ("GITHUB_WORKSPACE", "HOME", "RUNNER_TEMP", "ANDROID_HOME", "ANDROID_SDK_ROOT", "JAVA_HOME")
PROTECTED_FIXED = ("/usr/local/lib/android/sdk", "/usr/lib/jvm")


def protected_roots(env: dict) -> list[Path]:
    out = [Path(p) for p in PROTECTED_FIXED] + [Path(env[k]) for k in PROTECTED_ENV if env.get(k)]
    return [p.resolve() for p in out]


def check_target(target: Path, keep: Iterable[Path], protected: Iterable[Path] = ()) -> Optional[str]:
    """Why [target] must not be deleted, or None when it may be."""
    if target.is_symlink():
        return "is a symlink"
    real = target.resolve()
    if not real.is_absolute() or len(real.parts) < 3:
        return "too close to /"
    for k in keep:
        if _inside(k, real):
            return f"holds kept path {k}"
    for p in protected:
        if _inside(real, p):
            return f"inside protected path {p}"
    return None


def size_bytes(path: Path) -> int:
    """du -sb (0 when missing or unreadable)."""
    if not path.exists():
        return 0
    try:
        out = subprocess.run(["du", "-sb", str(path)], capture_output=True, text=True, timeout=120)
        return int(out.stdout.split()[0]) if out.stdout else 0
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return 0


def free_gb(path: str = "/") -> float:
    return shutil.disk_usage(path).free / 1024**3


def _gb(n: int) -> str:
    return f"{n / 1024**3:.1f} GiB"


def report(env: dict, size: Callable[[Path], int] = size_bytes, out=print) -> None:
    for mount in sorted({"/", env.get("GITHUB_WORKSPACE") or "/", env.get("RUNNER_TEMP") or "/"}):
        if os.path.exists(mount):
            u = shutil.disk_usage(mount)
            out(f"[disk] {mount}: free {_gb(u.free)} of {_gb(u.total)}")
    for p in RECLAIM:
        if Path(p).exists():
            out(f"[disk] reclaimable {p}: {_gb(size(Path(p)))}")
    for p in kept_paths(env):
        if p.exists():
            out(f"[disk] kept {p}: {_gb(size(p))}")
    ndk = Path("/usr/local/lib/android/sdk/ndk") / NDK
    out(f"[disk] NDK {NDK}: {'present' if ndk.exists() else 'absent (Gradle installs it)'}")


def _sudo_rm(path: Path) -> None:
    cmd = ["rm", "-rf", "--one-file-system", "--", str(path)]
    if os.geteuid() != 0:
        cmd = ["sudo", "-n", *cmd]
    subprocess.run(cmd, check=True, timeout=600)


def reclaim(
    env: dict,
    *,
    targets: Iterable[str] = RECLAIM,
    remove: Callable[[Path], None] = _sudo_rm,
    size: Callable[[Path], int] = size_bytes,
    required_after: Iterable[str] = REQUIRED_AFTER,
    platform: str = sys.platform,
    out=print,
) -> int:
    """Delete the named targets; returns bytes reclaimed. Raises if a kept
    tool went missing."""
    if not platform.startswith("linux") or env.get("RUNNER_ENVIRONMENT") != "github-hosted":
        out("[disk] not a GitHub-hosted Linux runner: nothing deleted")
        return 0
    keep = kept_paths(env)
    protected = protected_roots(env)
    present_before = [p for p in required_after if Path(p).exists()]
    total = 0
    for t in targets:
        path = Path(t)
        if not path.exists():
            continue
        why = check_target(path, keep, protected)
        if why:
            out(f"[disk] skip {path}: {why}")
            continue
        n = size(path)
        remove(path)
        total += n
        out(f"[disk] removed {path} ({_gb(n)})")
    missing = [p for p in present_before if not Path(p).exists()]
    if missing:
        raise SystemExit(f"[disk] kept tool missing after reclaim: {', '.join(missing)}")
    out(f"[disk] reclaimed {_gb(total)}")
    return total


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("mode", choices=("report", "reclaim"))
    ap.add_argument("--min-free-gb", type=float, default=0.0,
                    help="fail when / has less free space than this afterwards")
    a = ap.parse_args(argv)
    env = dict(os.environ)
    if a.mode == "reclaim":
        reclaim(env)
    report(env)
    if a.min_free_gb and free_gb("/") < a.min_free_gb:
        print(f"[disk] only {free_gb('/'):.1f} GiB free on /, need {a.min_free_gb:.0f} GiB", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
