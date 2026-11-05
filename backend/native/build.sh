#!/bin/sh
set -eu

cd /src
curl --fail --location --retry 3 --output ffmpeg-9.0.2.tar.xz https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
curl --fail --location --retry 3 --output ffmpeg-9.0.2.tar.xz.asc https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz.asc
curl --fail --location --retry 3 --output ffmpeg-devel.asc https://ffmpeg.org/ffmpeg-devel.asc
curl --fail --location --retry 3 --output libsndfile-1.2.2.tar.xz https://github.com/libsndfile/libsndfile/releases/download/1.2.2/libsndfile-1.2.2.tar.xz
sha256sum --check native/SHA256SUMS

# The expected release key fingerprint is published on ffmpeg.org/download.html.
mkdir -m 700 /src/keyring
gpg --homedir /src/keyring --batch --import ffmpeg-devel.asc
gpg --homedir /src/keyring --batch --status-fd 1 --verify ffmpeg-9.0.2.tar.xz.asc ffmpeg-9.0.2.tar.xz > /src/signature-status.txt
grep -F '[GNUPG:] VALIDSIG FCF986EA15E6E293A5644F10B4322F04D67658D8 ' /src/signature-status.txt

tar -xf ffmpeg-9.0.2.tar.xz
tar -xf libsndfile-1.2.2.tar.xz
cd /src/libsndfile-1.2.2
patch --batch --fuzz=0 -p1 < /src/native/patches/libsndfile-aiff-overflow.patch
patch --batch --fuzz=0 -p1 < /src/native/patches/libsndfile-ima-overflow.patch
# Local companion fix: upstream's frame-count patches leave the seek bounds,
# offsets and return values doing the same int*int arithmetic. The virtual WAV
# regression reads and seeks above INT_MAX as well as inspecting metadata.
patch --batch --fuzz=0 -p1 < /src/native/patches/libsndfile-seek-count.patch
patch --batch --fuzz=0 -p1 < /src/native/patches/libsndfile-vorbis.patch
patch --batch --fuzz=0 -p1 < /src/native/patches/libsndfile-alignment-backport.patch
patch --batch --fuzz=0 -p1 < /src/native/patches/libsndfile-cue-label-backport.patch
patch --batch --fuzz=0 -p1 < /src/native/patches/libsndfile-mat4-backport.patch
# Guard against a changed/misidentified patch, not just its advertised CVE ID.
python /src/native/verify_sources.py
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/native \
  -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF \
  -DBUILD_PROGRAMS=OFF -DBUILD_EXAMPLES=OFF -DENABLE_EXTERNAL_LIBS=ON -DENABLE_MPEG=OFF
cmake --build build --parallel 2
cmake --install build
# Upstream disables its tests for shared builds. Build a separate static test
# target from the exact same patched sources, and reject an empty test suite.
cmake -S . -B build-tests -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_TESTING=ON -DBUILD_PROGRAMS=OFF -DBUILD_EXAMPLES=OFF \
  -DENABLE_EXTERNAL_LIBS=ON -DENABLE_MPEG=OFF
cmake --build build-tests --parallel 2
ctest --test-dir build-tests --output-on-failure --no-tests=error --parallel 2

cd /src/ffmpeg-9.0.2
# Audio-only API: retain supported upload containers/codecs and local fixture
# encoders. No network protocols, device access, video/image/subtitle decoders,
# GPL or nonfree components. Internal FFmpeg libraries are statically linked.
./configure --prefix=/opt/native --disable-everything --disable-autodetect \
  --disable-network --disable-ffplay --disable-doc --disable-debug \
  --disable-avdevice --disable-swscale --disable-gpl --disable-nonfree \
  --enable-small --enable-ffmpeg --enable-ffprobe --enable-avfilter \
  --enable-libopus --enable-protocol=file,pipe \
  --enable-demuxer=wav,ogg,mov,mp3,aac,flac,caf,aiff,au,amr,matroska \
  --enable-muxer=wav,ogg,mp4,ipod,adts,flac,caf,aiff,au,mp3,matroska,webm,pcm_s16le,pcm_f32le \
  --enable-parser=aac,aac_latm,flac,mpegaudio,opus,vorbis \
  --enable-decoder=aac,aac_fixed,aac_latm,alac,flac,mp3,mp3float,opus,vorbis,mace3,mace6,amrnb,amrwb,adpcm_ima_wav,adpcm_ima_qt,adpcm_ms \
  --enable-decoder=pcm_alaw,pcm_mulaw,pcm_s8,pcm_u8,pcm_s16le,pcm_s16be,pcm_u16le,pcm_u16be,pcm_s24le,pcm_s24be,pcm_u24le,pcm_u24be,pcm_s32le,pcm_s32be,pcm_u32le,pcm_u32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be \
  --enable-encoder=pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_f32le,pcm_mulaw,pcm_alaw,aac,alac,flac,libopus,vorbis \
  --enable-filter=aresample,anull,atrim,aformat,abuffer,abuffersink,asetnsamples
make -j2
make install
cc -I. -fsanitize=undefined -fno-sanitize-recover=all \
  /src/native/tests/mace_sample_count.c \
  $(PKG_CONFIG_PATH=/opt/native/lib/pkgconfig pkg-config --libs --static libavcodec) \
  -o /src/mace-sample-count
/src/mace-sample-count

install -d /opt/native/share/humtrack-native/source
cp /src/*tar.xz /src/ffmpeg-9.0.2.tar.xz.asc /src/ffmpeg-devel.asc /opt/native/share/humtrack-native/source/
cp /src/native/patches/*.patch /opt/native/share/humtrack-native/source/
cp /src/native/SHA256SUMS /opt/native/share/humtrack-native/source/
cp /src/signature-status.txt /opt/native/share/humtrack-native/
cp /src/ffmpeg-9.0.2/ffbuild/config.log /opt/native/share/humtrack-native/ffmpeg-config.log
cp /src/ffmpeg-9.0.2/COPYING.LGPLv2.1 /opt/native/share/humtrack-native/FFmpeg-LICENSE.txt
cp /src/libsndfile-1.2.2/COPYING /opt/native/share/humtrack-native/libsndfile-LICENSE.txt
cp /src/native/verify_runtime.py /opt/native/share/humtrack-native/
python /src/native/write_manifest.py
