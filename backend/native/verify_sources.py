"""Fail the image build unless the actual source contains the upstream fixes."""
from pathlib import Path

root=Path('/src')
mace=(root/'ffmpeg-9.0.2/libavcodec/mace.c').read_text()
assert 'int64_t nb_samples' in mace and '(int64_t)buf_size' in mace
assert 'if (nb_samples > INT_MAX)' in mace
ima=(root/'libsndfile-1.2.2/src/ima_adpcm.c').read_text()
assert 'psf->sf.frames = pima->samplesperblock *' not in ima
for expression in (
 '(sf_count_t) pima->samplesperblock * pima->blocks ;',
 '(sf_count_t) pima->samplesperblock * pima->blocks / pima->channels ;',
 '(sf_count_t) pima->samplesperblock * pima->blockcount / psf->sf.channels ;',
):assert expression in ima,expression
assert 'offset > pima->blocks * pima->samplesperblock' not in ima
assert 'return newblock * pima->samplesperblock' not in ima
common=(root/'libsndfile-1.2.2/src/common.c').read_text()
assert 'store_uint (void *ptr, unsigned int value)' in common
reader=common.split('psf_binheader_readf (',1)[1].split('return byte_count',1)[0]
assert '*intptr =' not in reader and '*shortptr =' not in reader
mat4=(root/'libsndfile-1.2.2/src/mat4.c').read_text()
assert 'rows < 0' in mat4 and 'datasize = (sf_count_t) rows * (sf_count_t) cols' in mat4
cue=(root/'libsndfile-1.2.2/src/wavlike.c').read_text()
assert 'psf_strlcpy (psf->cues->cue_points [i].name' in cue
print('Verified FFmpeg MACE sample-count guard and libsndfile WAV/AIFF/close widening')
