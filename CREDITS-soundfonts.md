# Soundfont Credits & Licenses

Downloadable catalog soundfonts (served from `backend/soundfonts/`, listed in
`backend/soundfonts/catalog.json`). All are royalty-free for commercial use.
Public-domain / CC0 items need no attribution; **CC-BY items below must be
credited** (surface this list in the app's credits/licenses screen).

## Guitars — FreePats (CC0, public domain)
Source: https://freepats.zenvoid.org/
- Nylon Acoustic (Spanish Classical Guitar) — CC0
- Clean Electric Guitar DI / Clean Electric Guitar — CC0
- Distortion Electric Guitar — CC0

## Synth bass + pads — FreePats (CC0, public domain)
Source: https://freepats.zenvoid.org/Synthesizer/
- Lately Bass, Synth Bass 1, Synth Bass 2 — CC0
- Synth Pad Choir, Sweep Pad, New Age, Synth Pad Bowed — CC0

These seven sounds, plus the Nylon Acoustic guitar above (slot 1001, so the
first guitar works without a download), are bundled for offline use in
`mobile/assets/sounds/reference/` (eight fonts in total). The catalog records the
exact upstream release URL, archive and SF2 SHA256, and actual bank/program.
Upstream README and license text are retained alongside each font. Reproduce the
pack with `python tools/prepare_reference_soundfonts.py` (bass/pads) and
`python tools/prepare_guitar_soundfont.py` (nylon guitar). Either tool merges
into `catalog.json`, so running one never drops the other's rows.

## EDM synths — Musical Artifacts
- **Supersaw Lead / Supersaw Pluck** — "Supersaw Collection" by Strix SoundFont Team — Public Domain
  https://musical-artifacts.com/artifacts/701
- **Saw 8-Detune** by Strix Soundfont Team — Public Domain
  https://musical-artifacts.com/artifacts/1092
- **Daft Punk Style Synth** by MySingingMashups — Public Domain
  https://musical-artifacts.com/artifacts/5574
- **Synth Lead (DaveN)** by MySingingMashups — Public Domain
  https://musical-artifacts.com/artifacts/6353
- **Plucks & Bells** by Vini — Public Domain
  https://musical-artifacts.com/artifacts/7483

### Attribution required (CC-BY)
- **Avicii Pluck** — "Avicii Pluck (Waiting For Love)" by Simone Piervergili —
  **CC-BY 3.0** — https://musical-artifacts.com/artifacts/5632
  Required credit: "Avicii Pluck by Simone Piervergili, CC BY 3.0".
