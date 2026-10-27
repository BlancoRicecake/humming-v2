# Clean-room process for DAW features

HumTrack Studio aims to cover as much of what commercial DAWs (FL Studio, Ableton Live, …) offer as possible. Every such feature is built **from a written behavioral spec, never from the original program's code, binaries or bundled content.**

## Rules

| | Allowed | Not allowed |
|---|---|---|
| **Sources for a spec** | Official public manuals and help pages; hands-on use of the original program (watching what it does); public or community-documented file formats (MIDI, WAV, Ableton `.als` XML) | Disassembly or decompilation, function and vtable tables, resource extraction, unpacked installers, anything under `C:/src/re-lab` |
| **What a spec contains** | User-visible behavior (input → result), edge cases, acceptance tests, a source for each statement (URL, or "observed hands-on on <date>") | Function names, addresses, internal constants, numbers read out of a binary, copied UI art, icons, samples, presets |
| **What implementation reads** | `docs/specs/**` and HumTrack's own code | `C:/src/re-lab/**`, the old `studio/` prototype, and original-program screenshots in `artifacts/` |

**Assets:** sounds, presets, icons and skins come only from our own work or from properly licensed sources (see `CREDITS-soundfonts.md`).

## Roles

- **Spec author:** reads manuals and hands-on observations, and writes `docs/specs/<area>/<feature>.md` using `_TEMPLATE.md`.
- **Implementer:** a separate session or agent (`.claude/agents/cleanroom-impl.md`). It works from the spec and HumTrack's code only.
- **Review:** the owner approves each spec before implementation starts.

## Quarantine log

| Date | What | Where | Note |
|---|---|---|---|
| 2026-10-22 | FL Studio installer extraction, binary analysis scripts and notes (`analysis/`, `artifacts/original-core`, `tools/`, `evidence/`) | moved from `studio/` to `C:/src/re-lab/flstudio-20261022` (outside git) | Produced 2026-10-14 to 10-21 while building the Studio 0.1.x prototype |
| 2026-10-22 | Studio 0.1.x prototype (`studio/app`) | stays local, git-ignored | Its code cites the analysis above, so it is **not** clean-room. Do not port code from it. Only behavior that is re-specified from allowed sources may be rebuilt. |
| 2026-10-22 | Ableton Live 12 trial observations (`artifacts/ableton-analysis-20261021`) | stays local, git-ignored | Black-box use plus reading the bundled demo `.als` XML; the scope explicitly excluded executable analysis. Usable as a spec source when cited; the screenshots themselves are not shipped. |

Never commit anything that comes from `C:/src/re-lab`. `.gitignore` excludes `/studio/` and `/artifacts/`.
