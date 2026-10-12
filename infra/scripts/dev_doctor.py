#!/usr/bin/env python3
# 개발 기기(PC·Mac)의 도구 버전·git 상태·설정 파일 일치를 빌드 전에 점검하는 스크립트
"""HumTrack dev doctor.

Usage (repository root, Python 3.9+, standard library only):
  python infra/scripts/dev_doctor.py                    # all checks
  python infra/scripts/dev_doctor.py --fetch            # git fetch --prune first
  python infra/scripts/dev_doctor.py branches           # branch/worktree report (markdown)
  python infra/scripts/dev_doctor.py --write-fingerprints

Secret values are never printed. Only 12-char SHA-256 prefixes are written to
infra/dev-config-fingerprints.json so PC and Mac can prove they use the same
configuration without committing it.
Exit code 1 when any FAIL is reported.
"""
import hashlib
import json
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MOBILE = ROOT / "mobile"
SECRETS = ROOT / "backend" / ".env.secrets"
IOS_PLIST = MOBILE / "ios" / "Runner" / "GoogleService-Info.plist"
ANDROID_JSON = MOBILE / "android" / "app" / "google-services.json"
MANIFEST = ROOT / "infra" / "dev-config-fingerprints.json"
CI_MOBILE = ROOT / ".github" / "workflows" / "ci-mobile.yml"

APP_ID = "com.humtrack.app"
# Same lists as mobile/tool/release_support.rb (keep in sync).
REQUIRED_DEFINES = ["SUPABASE_URL", "SUPABASE_ANON_KEY", "GOOGLE_WEB_CLIENT_ID",
                    "ENGINE_URL", "CLARITY_PROJECT_ID", "SENTRY_DSN_MOBILE"]
PLIST_KEYS = ["GOOGLE_APP_ID", "API_KEY", "GCM_SENDER_ID", "PROJECT_ID",
              "BUNDLE_ID", "CLIENT_ID", "REVERSED_CLIENT_ID"]

results = []  # (level, area, message)


def report(level, area, message):
    results.append((level, area, message))


def fp(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]


def run(args, cwd=ROOT):
    """Run a command; return (code, stdout+stderr). Missing tools return code 127."""
    exe = shutil.which(args[0])
    if not exe:
        return 127, ""
    try:
        p = subprocess.run([exe] + args[1:], cwd=cwd, capture_output=True,
                           text=True, encoding="utf-8", errors="replace", timeout=300)
    except subprocess.TimeoutExpired:
        return 124, ""
    return p.returncode, (p.stdout or "") + (p.stderr or "")


# ── config parsing (pure functions, unit-tested) ──────────────────────────

def parse_env(text):
    values = {}
    for line in text.splitlines():
        key, sep, value = line.strip().partition("=")
        if not sep or key.startswith("#") or not value:
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key] = value
    return values


def parse_plist(text):
    return dict(re.findall(r"<key>([^<]+)</key>\s*<string>([^<]*)</string>", text))


def plist_problems(text):
    if "CI_COMPILE_ONLY" in text:
        return ["compile-only placeholder plist, not the real one"]
    values = parse_plist(text)
    problems = ["missing " + k for k in PLIST_KEYS if not values.get(k, "").strip()]
    if values.get("GOOGLE_APP_ID") and not re.fullmatch(r"1:\d+:ios:[0-9a-f]+", values["GOOGLE_APP_ID"]):
        problems.append("GOOGLE_APP_ID is not an iOS Firebase app ID")
    if values.get("BUNDLE_ID") and values["BUNDLE_ID"] != APP_ID:
        problems.append("BUNDLE_ID is not " + APP_ID)
    return problems


def android_json_values(text):
    data = json.loads(text)
    packages = [c.get("client_info", {}).get("android_client_info", {}).get("package_name")
                for c in data.get("client", [])]
    return {"project_id": data.get("project_info", {}).get("project_id", ""),
            "has_package": APP_ID in packages}


def sentry_project(dsn):
    m = re.fullmatch(r"https://[^@/]+@[^/]+/(\d+)", dsn.strip())
    return m.group(1) if m else None


def current_fingerprints():
    """Fingerprints of whatever config exists on this machine."""
    out = {}
    if SECRETS.is_file():
        env = parse_env(SECRETS.read_text(encoding="utf-8"))
        out["defines"] = {k: fp(env[k]) for k in REQUIRED_DEFINES if env.get(k)}
    if IOS_PLIST.is_file():
        v = parse_plist(IOS_PLIST.read_text(encoding="utf-8"))
        out["ios_plist"] = {k: fp(v[k]) for k in PLIST_KEYS if v.get(k)}
    if ANDROID_JSON.is_file():
        out["android_google_services"] = {"file": fp(ANDROID_JSON.read_text(encoding="utf-8"))}
    return out


def compare_fingerprints(expected, actual):
    """Return list of 'section.key' entries whose fingerprints differ."""
    diffs = []
    for section, keys in expected.items():
        if not isinstance(keys, dict) or section not in actual:
            continue
        for key, value in keys.items():
            if key in actual[section] and actual[section][key] != value:
                diffs.append(section + "." + key)
    return diffs


# ── checks ────────────────────────────────────────────────────────────────

def check_git(fetch):
    if fetch:
        code, _ = run(["git", "fetch", "--prune", "origin"])
        report("PASS" if code == 0 else "WARN", "git", "fetched origin" if code == 0 else "git fetch failed (offline?)")
    code, branch = run(["git", "rev-parse", "--abbrev-ref", "HEAD"])
    if code != 0:
        report("FAIL", "git", "not a git checkout or git missing")
        return
    report("INFO", "git", "current branch: " + branch.strip())
    _, status = run(["git", "status", "--porcelain"])
    dirty = [l for l in status.splitlines() if l.strip()]
    if dirty:
        report("WARN", "git", f"{len(dirty)} uncommitted change(s)")
    for name in ("mobile/pubspec.lock", "mobile/analysis_options.yaml"):
        if any(l.endswith(name) for l in dirty):
            report("WARN", "git", name + " changed — usually tool noise; do not commit unless intended")
    _, refs = run(["git", "for-each-ref", "refs/heads",
                   "--format=%(refname:short)|%(upstream:short)|%(upstream:track)"])
    for line in refs.splitlines():
        name, upstream, track = (line.split("|") + ["", ""])[:3]
        if (not upstream or "ahead" in track) and run(["git", "merge-base", "--is-ancestor", name, "origin/main"])[0] == 0:
            report("INFO", "git", f"branch '{name}' committed history is already contained in origin/main (no unpublished commits)")
            continue
        if not upstream:
            report("FAIL", "git", f"branch '{name}' is not on GitHub (no upstream) — push it or delete it")
        elif "gone" in track:
            report("WARN", "git", f"branch '{name}': upstream deleted")
        elif "ahead" in track:
            report("FAIL", "git", f"branch '{name}' has unpushed commits {track}")
    _, wt = run(["git", "worktree", "list", "--porcelain"])
    allowed = (ROOT / ".worktrees").resolve()
    for line in wt.splitlines():
        if line.startswith("worktree "):
            path = Path(line[9:].strip()).resolve()
            if path != ROOT.resolve() and allowed not in path.parents:
                report("WARN", "git", f"worktree outside .worktrees/: {path}")


def expected_flutter_version():
    if CI_MOBILE.is_file():
        m = re.search(r"flutter-version:\s*'?([\d.]+)'?", CI_MOBILE.read_text(encoding="utf-8"))
        if m:
            return m.group(1)
    return None


def check_tools():
    want = expected_flutter_version()
    code, out = run(["flutter", "--version", "--machine"])
    if code == 127:
        report("FAIL", "tools", "flutter not on PATH")
    else:
        try:
            have = json.loads(out[out.index("{"):])["frameworkVersion"]
        except (ValueError, KeyError):
            have = None
        if have is None:
            report("WARN", "tools", "could not read flutter version")
        elif want and have != want:
            report("FAIL", "tools", f"flutter {have}, CI pins {want}")
        else:
            report("PASS", "tools", f"flutter {have}")
    _, cfg = run(["flutter", "config", "--list"])
    m = re.search(r"jdk-dir:\s*(\S.*)", cfg)
    java = ["java"]
    if m and "Not set" not in m.group(1):
        java = [str(Path(m.group(1).strip()) / "bin" / "java")]
    code, out = run(java + ["-version"])
    major = re.search(r'version "(\d+)', out)
    if code == 127 or not major:
        report("WARN", "tools", "java not found (needed for Android builds)")
    elif major.group(1) != "17":
        report("FAIL", "tools", f"Android builds use JDK {major.group(1)}; set JDK 17 with flutter config --jdk-dir")
    else:
        report("PASS", "tools", "JDK 17")
    if platform.system() == "Darwin":
        code, out = run(["xcodebuild", "-version"])
        xm = re.search(r"Xcode (\d+)", out)
        if not xm:
            report("FAIL", "tools", "xcodebuild not available (install Xcode, run xcode-select)")
        else:
            report("PASS" if int(xm.group(1)) >= 26 else "FAIL", "tools", f"Xcode {xm.group(1)} (release CI uses 26+)")
        for tool in ("pod", "bundle"):
            report("PASS" if shutil.which(tool) else "WARN", "tools", tool + (" found" if shutil.which(tool) else " missing"))


def check_config():
    if not SECRETS.is_file():
        report("FAIL", "config", "backend/.env.secrets missing — dev builds will have login disabled")
        env = {}
    else:
        env = parse_env(SECRETS.read_text(encoding="utf-8"))
        missing = [k for k in REQUIRED_DEFINES if not env.get(k)]
        if missing:
            report("FAIL", "config", ".env.secrets missing: " + ", ".join(missing))
        else:
            report("PASS", "config", ".env.secrets has all required keys")
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8")) if MANIFEST.is_file() else None
    dsn = env.get("SENTRY_DSN_MOBILE")
    want_project = (manifest or {}).get("sentry_mobile_project_id")
    if dsn and want_project:
        got = sentry_project(dsn)
        if got != want_project:
            report("FAIL", "config", f"SENTRY_DSN_MOBILE points to project {got}, expected {want_project}")
        else:
            report("PASS", "config", "Sentry DSN targets humtrack-mobile")
    if IOS_PLIST.is_file():
        problems = plist_problems(IOS_PLIST.read_text(encoding="utf-8"))
        report("FAIL" if problems else "PASS", "config",
               "iOS GoogleService-Info.plist: " + ("; ".join(problems) if problems else "ok"))
    elif platform.system() == "Darwin":
        report("FAIL", "config", "iOS GoogleService-Info.plist missing (Firebase aborts launch without it)")
    if ANDROID_JSON.is_file():
        v = android_json_values(ANDROID_JSON.read_text(encoding="utf-8"))
        report("PASS" if v["has_package"] else "FAIL", "config",
               "google-services.json " + ("has " if v["has_package"] else "lacks ") + APP_ID)
    if manifest is None:
        report("WARN", "config", "no fingerprint manifest; run --write-fingerprints on the trusted machine")
        return
    diffs = compare_fingerprints(manifest, current_fingerprints())
    if diffs:
        report("FAIL", "config", "differs from committed fingerprints: " + ", ".join(diffs))
    else:
        report("PASS", "config", "matches committed fingerprints")


def check_devices():
    code, out = run(["flutter", "devices", "--machine"])
    if code != 0:
        return
    try:
        devices = json.loads(out[out.index("["):])
    except ValueError:
        return
    for d in devices:
        report("INFO", "devices", f"{d.get('name')} ({d.get('targetPlatform')})")


def branches_report():
    _, main_ref = run(["git", "rev-parse", "--verify", "-q", "origin/main"])
    rows = ["| branch | upstream | vs upstream | in origin/main | last commit |", "|---|---|---|---|---|"]
    _, refs = run(["git", "for-each-ref", "refs/heads", "--sort=-committerdate",
                   "--format=%(refname:short)|%(upstream:short)|%(upstream:track)|%(committerdate:short)"])
    for line in refs.splitlines():
        name, upstream, track, date = (line.split("|") + ["", "", ""])[:4]
        merged = "?"
        if main_ref.strip():
            code, _ = run(["git", "merge-base", "--is-ancestor", name, "origin/main"])
            merged = "yes" if code == 0 else "no"
        rows.append(f"| {name} | {upstream or '**none**'} | {track or '-'} | {merged} | {date} |")
    _, wt = run(["git", "worktree", "list"])
    return "\n".join(rows) + "\n\nWorktrees:\n\n```\n" + wt.strip() + "\n```\n"


def main(argv):
    if sys.version_info < (3, 9):
        print("Python 3.9+ required")
        return 1
    if "branches" in argv:
        print(branches_report())
        return 0
    if "--write-fingerprints" in argv:
        data = json.loads(MANIFEST.read_text(encoding="utf-8")) if MANIFEST.is_file() else {}
        data.update(current_fingerprints())
        MANIFEST.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print("wrote", MANIFEST.relative_to(ROOT), "sections:", ", ".join(sorted(data)))
        return 0
    check_git("--fetch" in argv)
    check_tools()
    check_config()
    check_devices()
    for level, area, message in results:
        print(f"[{level}] {area}: {message}")
    fails = sum(1 for r in results if r[0] == "FAIL")
    print(f"\n{fails} FAIL, {sum(1 for r in results if r[0] == 'WARN')} WARN")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
