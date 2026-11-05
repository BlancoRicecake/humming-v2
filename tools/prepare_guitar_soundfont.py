"""Bundle the upstream CC0 nylon guitar so the first guitar works offline.

All inputs, extraction output and metadata stay inside the HumTrack workspace.
Only SF2 and license/readme text are extracted; nothing downloaded is executed.
"""
import hashlib
import json
import shutil
import subprocess
import urllib.request
from pathlib import Path, PurePosixPath

from prepare_reference_soundfonts import presets

ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / "mobile/assets/sounds/reference"
CACHE = ROOT / "artifacts/reference-prep/guitar"
URL = ("https://freepats.zenvoid.org/Guitar/SpanishClassicalGuitar/"
       "SpanishClassicalGuitar-SF2-20190618.7z")
SID = "freepats_nylon"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    CACHE.mkdir(parents=True, exist_ok=True)
    PACK.mkdir(parents=True, exist_ok=True)
    archive = CACHE / URL.rsplit("/", 1)[1]
    if not archive.exists():
        part = archive.with_suffix(".part")
        request = urllib.request.Request(URL, headers={"User-Agent": "HumTrack-guitar-preparation"})
        with urllib.request.urlopen(request, timeout=60) as response, part.open("wb") as out:
            shutil.copyfileobj(response, out)
        part.replace(archive)
    names = subprocess.check_output(["tar", "-tf", str(archive)], text=True).splitlines()
    members = []
    for name in names:
        path = PurePosixPath(name.replace("\\", "/"))
        if path.is_absolute() or ".." in path.parts or ":" in name:
            raise ValueError("Unsafe archive member")
        if path.suffix.lower() in {".sf2", ".txt", ".md"}:
            members.append(name)
    if len([name for name in members if name.lower().endswith(".sf2")]) != 1:
        raise ValueError("Expected exactly one SF2")
    unpack = CACHE / "upstream"
    unpack.mkdir(exist_ok=True)
    subprocess.run(["tar", "-xf", str(archive), "-C", str(unpack), *members], check=True)
    files = list(unpack.rglob("*.sf2"))
    if len(files) != 1:
        raise ValueError("Expected one extracted font")
    data = files[0].read_bytes()
    entries = presets(data)
    text_files = [f for f in unpack.rglob("*") if f.is_file() and f.suffix.lower() in {".txt", ".md"}]
    if not any("CC0" in f.read_text(encoding="utf-8", errors="replace") for f in text_files):
        raise ValueError("Upstream archive is missing the expected CC0 text")
    backend_rows = json.loads((ROOT / "backend/soundfonts/catalog.json").read_text(encoding="utf-8"))
    row = dict(next(e for e in backend_rows if e["id"] == SID))
    row.update(sf_bank=entries[0]["bank"], sf_program=entries[0]["program"],
               bytes=len(data), sha256=digest(data), source=URL,
               asset=f"assets/sounds/reference/{SID}.sf2", presets=entries,
               archive_sha256=digest(archive.read_bytes()))
    target = PACK / f"{SID}.sf2"
    target.write_bytes(data)
    for source in text_files:
        shutil.copy2(source, PACK / f"{SID}.{source.name}")
    manifest = PACK / "catalog.json"
    rows = json.loads(manifest.read_text(encoding="utf-8"))
    existing = next((i for i, e in enumerate(rows) if e["id"] == SID), None)
    if existing is None:
        rows.append(row)
    else:
        rows[existing] = row
    manifest.write_text(json.dumps(rows, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"id": SID, "bytes": len(data), "presets": entries,
                      "sha256": row["sha256"], "licenseFiles": [f.name for f in text_files]}))


if __name__ == "__main__":
    main()
