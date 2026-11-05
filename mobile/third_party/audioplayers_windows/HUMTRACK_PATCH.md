# HumTrack patch of audioplayers_windows 4.3.0

Copied from pub.dev `audioplayers_windows-4.3.0` (BSD/MIT, see LICENSE) and used
through `dependency_overrides` in `mobile/pubspec.yaml`. Only these changes:

- `analysis_options.yaml`: removed (it includes the upstream-only `flame_lint`).
- `pubspec.yaml`: removed `resolution: workspace` (upstream monorepo setting; a
  path dependency cannot be a workspace member).
- `windows/audioplayers_windows_plugin.cpp`: `globalEvents` was a **static
  `std::unique_ptr<EventStreamHandler<>>`** whose raw pointer was ALSO handed to
  the global event channel as its owning `unique_ptr` (`SetStreamHandler`).
  Closing the window (title-bar X) shuts the Flutter engine down, which deletes
  the handler through the channel; at process exit the static `unique_ptr`
  deleted it again — a double free (`c0000005` in
  `std::default_delete<EventStreamHandler<flutter::EncodableValue>>`, module
  offset `0x3fbf9` of the debug DLL; HumTrack QA 2026-10-30 P1-02,
  `artifacts/qa-fix-2026-10-30/`). Now the channel is the only owner:
  `globalEvents` is a non-owning pointer, cleared in the plugin destructor and
  checked before use.

The per-player event handlers already had a single owner (the channel) and are
unchanged. Drop this copy when an upstream release fixes the ownership.
