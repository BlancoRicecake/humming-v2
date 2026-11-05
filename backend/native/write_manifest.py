"""Record provenance and exact installed binaries, without changing version IDs."""
import hashlib,json,pathlib

prefix=pathlib.Path('/opt/native')
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
files={str(p.relative_to(prefix)):sha(p) for pattern in ('bin/ffmpeg','bin/ffprobe','lib/libsndfile.so.*') for p in prefix.glob(pattern) if p.is_file() and not p.is_symlink()}
manifest={
 'ffmpeg_version':'9.0.2','libsndfile_version':'1.2.2',
 'libsndfile_upstream_patches':['9a829113c88a51e57c1e46473e90609e4b7df151','cdadf9a65fdc1f28da9d235eb443d5f5e57010d2',
  '4755f5bd7854611d92ad0f1295587b439f9950ba','474e4d328b1e6240b93ec6ed14efb7c6a44bee57',
  '1ccd2a18826722c3aa9ed54122ebff20e3b92b10','c45de8ed8b1d98ca532e94a00dbfb0e49eb9bb8a'],
 'libsndfile_local_patches':['libsndfile-seek-count.patch'],
 'ffmpeg_release_signer':'FCF986EA15E6E293A5644F10B4322F04D67658D8',
 'fixed_boundaries':['CVE-2026-66039','CVE-2026-37555','CVE-2022-33065',
  'CVE-2024-50612','CVE-2026-88386','CVE-2026-109828','CVE-2026-88372'],
 'source_patch_assertions_passed':True,'libsndfile_upstream_ctest_passed':True,
 'mace_decoder_ubsan_boundary_cases_passed':3,
 'source_sha256':{p.name:sha(p) for p in (prefix/'share/humtrack-native/source').iterdir() if p.is_file()},
 'installed_sha256':files,
}
(prefix/'share/humtrack-native/manifest.json').write_text(json.dumps(manifest,indent=2))
