# Server audio libraries — reproducible build and validation

The final server runtime now also removes setuptools, uses patched SQLite/zlib,
and selects runtime files with original Debian package provenance. See
[runtime security results](RUNTIME-SECURITY-2026-11-02.md). The audio build below
remains part of that image; the final stage is not a full Python slim filesystem.

The latest [OS impact review](OS-IMPACT-REVIEW-2026-11-02.md) adds a verified
fnmatch-enabled Debian-source dash build, removes unused interactive terminal
extensions/libraries, and fixes the runtime DNS search/locale configuration.
These changes do not claim that the underlying glibc/libstdc++ are fully patched.

The production Dockerfile builds a small audio-only FFmpeg **9.0.2** and a
patched **libsndfile 1.2.2**, then installs SoundFile from its source distribution.
This prevents a Python wheel's bundled, unpatched `libsndfile` from taking
precedence over the library we built. It changes the server image, not mobile
or Windows application packages.

The base image is pinned by digest. `SHA256SUMS` pins all source archives,
release signature/key, original upstream patches and backports. FFmpeg's
signature must match the fingerprint published on its official download page.
`patch --fuzz=0`, source assertions and mandatory tests stop the build on drift.
Do not bypass a failed check or merely change the claimed version to silence a
scanner.

The image retains the exact source archives, applied/original patches, source
hashes, build configuration, licenses and binary hashes in
`/usr/local/share/humtrack-native/`. libsndfile continues to report its honest
upstream version, 1.2.2; the manifest identifies its additional patches.

## Patches

| File | Origin / purpose |
|---|---|
| libsndfile-aiff-overflow.patch | upstream 9a829113c88a51e57c1e46473e90609e4b7df151; AIFF IMA frame widening |
| libsndfile-ima-overflow.patch | upstream cdadf9a65fdc1f28da9d235eb443d5f5e57010d2 / PR1123; WAV/close frame widening |
| libsndfile-seek-count.patch | local companion patch; keep IMA seek bounds, byte offsets and return arithmetic in sf_count_t too |
| libsndfile-vorbis.patch | upstream 4755f5bd7854611d92ad0f1295587b439f9950ba; retain the Ogg fix carried by Debian |
| libsndfile-alignment-backport.patch | upstream 474e4d328b1e6240b93ec6ed14efb7c6a44bee57; adapted to 1.2.2's byte_count accumulation API |
| libsndfile-cue-label-backport.patch | upstream 1ccd2a18826722c3aa9ed54122ebff20e3b92b10; use 1.2.2's psf->cues pointer instead of a newer local alias |
| libsndfile-mat4-backport.patch | upstream c45de8ed8b1d98ca532e94a00dbfb0e49eb9bb8a / PR1167; match 1.2.2's original expression while preserving checked payload sizing |

Original patches are preserved alongside adaptations. MPEG encoding in
libsndfile is disabled; MP3 input is decoded by FFmpeg. FFmpeg omits network
protocols, devices, video/image/subtitle decoders and GPL/nonfree components.
Ordinary supported audio input remains available; this build does not promise
support for arbitrary video files or every historical audio codec.

## Mandatory validation

1. The shared runtime and a separate static test library use the same patched
   source. Upstream CTest must contain tests and pass; shared builds otherwise
   silently disable that upstream suite.
2. The real FFmpeg MACE decoder is compiled into a local boundary test with
   UndefinedBehaviorSanitizer. Three oversized packet counts must return before
   allocation or data access.
3. `verify_runtime.py` checks actual binary hashes, the mapped shared-library
   path, absence of the wheel override, FFmpeg versions and file/pipe-only
   protocols. A virtual 1.25 GB IMA WAV verifies 2,500,050,000 frames and seek/read
   across INT_MAX without allocating or writing the virtual file.

After an image build, also run API media-format/auto-tune regressions and the
backend suite with local PostgreSQL against that image. A Windows virtualenv's
tests do not establish that the Linux image loaded the patched library. Native
source libraries may not appear as ordinary distribution packages in a scan;
use the source/patch manifest with scan results, not scanner counts alone.

References: [FFmpeg release/signing key](https://ffmpeg.org/download.html),
[CAF/MACE](https://security-tracker.debian.org/tracker/CVE-2026-66039),
[libsndfile WAV fix](https://github.com/libsndfile/libsndfile/pull/1123),
[MAT4 fix](https://github.com/libsndfile/libsndfile/pull/1167).
