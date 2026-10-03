#include <string.h>
#include "bytes.h"
#include "avi.h"

/* AVI is an Intel format: lengths and header fields are little endian.
 * Only the FourCCs are treated as a byte sequence. */

static uint32_t fcc(const uint8_t *p)
{
    return FOURCC(p[0], p[1], p[2], p[3]);
}

int avi_parse_header(avi_file *av, const uint8_t *data, uint32_t size,
                     uint32_t filesize)
{
    uint32_t p;
    uint32_t stream = 0;         /* laufende Stream-Nummer   */
    uint32_t cur_type = 0;       /* fccType of the open strh */

    memset(av, 0, sizeof(*av));
    if (size < 12 || fcc(data) != FOURCC('R','I','F','F')
                  || fcc(data + 8) != FOURCC('A','V','I',' '))
        return -1;

    av->base = data;
    av->size = size;

    p = 12;
    while (p + 8 <= size) {
        uint32_t id  = fcc(data + p);
        uint32_t len = rd_le32(data + p + 4);

        if (id == FOURCC('L','I','S','T')) {
            uint32_t lt = (p + 12 <= size) ? fcc(data + p + 8) : 0;
            if (lt == FOURCC('m','o','v','i')) {
                /* Compute in 64 bit. In streaming mode the encoder writes
                 * the size fields as 0xFFFFFFFF, because it cannot seek
                 * back - `p + 8 + len` would then overflow and yield a
                 * movi_end BEFORE the start. The file looked empty that
                 * way (0 frames, without an error message). */
                uint64_t end = (uint64_t)p + 8u + (uint64_t)len;
                av->movi_off = p + 12;
                /* Limit against the FILE size, not against the piece at
                 * hand - otherwise streaming stops after the first
                 * buffer. */
                if (end > (uint64_t)filesize) end = (uint64_t)filesize;
                av->movi_end = (uint32_t)end;
                /* Everything else is behind the data; for us this is
                 * Schluss. */
                break;
            }
            if (lt == FOURCC('s','t','r','l')) stream++;   /* a new track */
            p += 12;                                        /* hineinlaufen */
            continue;
        }

        if (id == FOURCC('a','v','i','h') && p + 8 + 56 <= size) {
            av->micros_per_frame = rd_le32(data + p + 8);
            av->total_frames     = rd_le32(data + p + 8 + 16);

        } else if (id == FOURCC('s','t','r','h') && p + 8 + 8 <= size) {
            /* Remembers whether the strf that follows belongs to video or audio. */
            cur_type = fcc(data + p + 8);

        } else if (id == FOURCC('s','t','r','f') && p + 8 <= size) {
            if (cur_type == FOURCC('v','i','d','s') && av->width == 0
                && p + 8 + 20 <= size) {
                /* BITMAPINFOHEADER */
                av->width       = rd_le32(data + p + 8 + 4);
                av->height      = rd_le32(data + p + 8 + 8);
                av->bit_count   = rd_le16(data + p + 8 + 14);
                av->compression = fcc(data + p + 8 + 16);
            } else if (cur_type == FOURCC('a','u','d','s') && av->aud_rate == 0
                       && p + 8 + 16 <= size) {
                /* WAVEFORMATEX */
                av->aud_format      = rd_le16(data + p + 8 + 0);
                av->aud_channels    = rd_le16(data + p + 8 + 2);
                av->aud_rate        = rd_le32(data + p + 8 + 4);
                av->aud_block_align = rd_le16(data + p + 8 + 12);
                av->aud_bits        = rd_le16(data + p + 8 + 14);
                av->aud_stream      = (stream > 0) ? (stream - 1) : 1;
            }
        }

        p += 8 + len + (len & 1);
    }

    if (!av->movi_off || !av->width || !av->height)
        return -2;

    av->cursor  = av->movi_off;
    av->acursor = av->movi_off;
    return 0;
}

int avi_open(avi_file *av, const uint8_t *data, uint32_t size)
{
    return avi_parse_header(av, data, size, size);
}

int avi_next_chunk(avi_file *av, const uint8_t **out, uint32_t *out_size)
{
    while (av->cursor + 8 <= av->movi_end) {
        const uint8_t *p = av->base + av->cursor;
        uint32_t len = rd_le32(p + 4);
        uint32_t adv = 8 + len + (len & 1);
        int kind = AVI_CHUNK_NONE;

        if (av->cursor + 8 + len > av->movi_end)
            return AVI_CHUNK_NONE;

        /* "##dc"/"##db" = video, "##wb" = sound. */
        if (p[2] == 'd' && (p[3] == 'c' || p[3] == 'b'))      kind = AVI_CHUNK_VIDEO;
        else if (p[2] == 'w' && p[3] == 'b')                  kind = AVI_CHUNK_AUDIO;

        if (kind != AVI_CHUNK_NONE) {
            *out      = p + 8;
            *out_size = len;
            av->cursor += adv;
            return kind;
        }
        av->cursor += adv;
    }
    return AVI_CHUNK_NONE;
}

int avi_next_video(avi_file *av, const uint8_t **out, uint32_t *out_size)
{
    int k;
    while ((k = avi_next_chunk(av, out, out_size)) != AVI_CHUNK_NONE)
        if (k == AVI_CHUNK_VIDEO) return 1;
    return 0;
}

int avi_next_audio(avi_file *av, const uint8_t **out, uint32_t *out_size)
{
    while (av->acursor + 8 <= av->movi_end) {
        const uint8_t *p = av->base + av->acursor;
        uint32_t len = rd_le32(p + 4);
        uint32_t adv = 8 + len + (len & 1);

        if (av->acursor + 8 + len > av->movi_end) return 0;

        if (p[2] == 'w' && p[3] == 'b') {
            *out = p + 8; *out_size = len;
            av->acursor += adv;
            return 1;
        }
        av->acursor += adv;
    }
    return 0;
}
