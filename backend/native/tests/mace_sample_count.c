/* Exercise the real upstream decoder's overflow guard under UBSan.
 * A one-byte sentinel is enough: these rejected packet sizes must never reach
 * allocation or input reads. This is a local build test, not an uploaded file.
 */
#include <limits.h>
#include <stdio.h>
#include "libavcodec/mace.c"

int main(void)
{
    const int sizes[] = { INT_MAX / 6 + 1, INT_MAX / 2, INT_MAX };
    unsigned char sentinel = 0;
    for (unsigned int i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
        AVCodecContext context = {0};
        AVFrame frame = {0};
        AVPacket packet = {0};
        int got_frame = 0;
        context.codec_id = AV_CODEC_ID_MACE6;
        context.ch_layout.nb_channels = 1;
        packet.data = &sentinel;
        packet.size = sizes[i];
        int result = mace_decode_frame(&context, &frame, &got_frame, &packet);
        if (result != AVERROR_INVALIDDATA || got_frame != 0 || frame.nb_samples != 0) {
            fprintf(stderr, "MACE rejected-sample-count regression failed: case %u\n", i);
            return 1;
        }
    }
    puts("MACE sample-count overflow: 3 real decoder boundary cases passed (UBSan)");
    return 0;
}
