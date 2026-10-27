# Workspace location

- Keep all HumTrack and HumTrack Studio project work inside `C:/src/humming-v2`: source copies, worktrees, builds, runnable packages, temporary files, and analysis output.
- The current, possibly uncommitted files under this root are authoritative. Never copy an older staged `app/lib` or archived source tree over them.
- Build the current Flutter app directly from `mobile/`; reuse `mobile/build/` instead of creating a new staging project for every version.
- Keep runnable releases in `artifacts/releases/`, historical build snapshots in `artifacts/build-history/`, and any additional Git worktrees in `.worktrees/` under this root.
