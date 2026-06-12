# Runtime SoundFont catalog

Instruments the mobile app downloads on demand. **Adding a sound needs no app
release** — drop a `.sf2` here, add a row to `catalog.json`, redeploy the
backend, and it appears in the in-app instrument picker.

## Add a sound

1. Get a **CC0 / royalty-free** `.sf2` (this is a commercial app — license matters).
   Good sources: musical-artifacts.com (filter by license), Polyphone gallery,
   VCSL (Versilian, CC0). Prefer a **single small instrument** SF2; trim a big
   bank to one preset with Polyphone if needed.
2. Copy it here, e.g. `warm_rhodes.sf2`.
3. Add an entry to `catalog.json`:

   ```json
   {
     "id": "warm_rhodes",
     "slot": 1001,
     "label": "Warm Rhodes",
     "role": "melody",
     "category": "Keys",
     "file": "warm_rhodes.sf2",
     "sf_bank": 0,
     "sf_program": 0,
     "midi_fallback": 4,
     "license": "CC0"
   }
   ```

   - `slot` must be **unique and >= 1000** (GM 0-127, 808=128, hip-hop=200 are
     reserved). Never reuse or renumber a shipped slot — songs store it.
   - `role`: `melody` | `bass` | `drums`.
   - `sf_bank`/`sf_program`: the preset WITHIN the file (usually 0/0).
   - `midi_fallback`: nearest GM program for `.mid` export (a Standard MIDI
     File can't carry a custom patch). For a drum kit, use a GM kit number.
4. Redeploy. The backend validates rows on read — a malformed row, a missing
   file, a duplicate id/slot, or a slot < 1000 is silently skipped, so a typo
   can't ship a broken entry.

## Endpoints

- `GET /soundfonts` → validated manifest (adds `bytes` + `sha256` per entry).
- `GET /soundfonts/{id}` → the `.sf2` file.

The app caches the manifest + downloaded files under
`Documents/looptap/soundfonts/`, verifies size/sha256, and falls back to the
default instrument when a stored slot is no longer in the catalog.
