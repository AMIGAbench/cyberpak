/* avi.h - minimaler RIFF/AVI-Demuxer.
 *
 * Portiert aus CyberAVI.mod:214-980 (ReadAVIH/ReadSTRH/ReadVIDS/ReadAUDS/
 * ReadHDRL/ParseRIFF), cut down to what video and audio need.
 * Works on a memory buffer.
 */
#ifndef CYBERPAK_AVI_H
#define CYBERPAK_AVI_H

#include <stdint.h>

#define AVI_CHUNK_NONE   0
#define AVI_CHUNK_VIDEO  1
#define AVI_CHUNK_AUDIO  2

typedef struct {
    const uint8_t *base;
    uint32_t       size;

    /* Video */
    uint32_t       width, height;
    uint32_t       compression;      /* FourCC, big-endian gepackt */
    uint32_t       bit_count;
    uint32_t       micros_per_frame;
    uint32_t       total_frames;

    /* Audio (0 when there is no audio track) */
    uint32_t       aud_format;       /* WAVE_FORMAT_PCM == 1        */
    uint32_t       aud_channels;
    uint32_t       aud_rate;
    uint32_t       aud_bits;
    uint32_t       aud_block_align;
    uint32_t       aud_stream;       /* stream number of the audio track */

    uint32_t       movi_off, movi_end;
    uint32_t       cursor;      /* video runs here                 */
    uint32_t       acursor;     /* sound runs AHEAD, see below     */
} avi_file;

int  avi_open(avi_file *av, const uint8_t *data, uint32_t size);

/* Read the header data from a PIECE at the start of the file.
 *
 * The headers of an AVI (RIFF, hdrl, strl, strf) all sit before the actual
 * data, usually in the first few kilobytes. That way the file can be streamed
 * instead of being loaded into memory completely - at 70 MB and 128 MB of fast
 * RAM that is not a luxury but a precondition.
 *
 * `size` is the size of the piece at hand, `filesize` that of the whole file
 * (for movi_end).
 * Returns 0 = ok, -1 = not an AVI, -2 = header incomplete or unusable. */
int  avi_parse_header(avi_file *av, const uint8_t *data, uint32_t size,
                      uint32_t filesize);

/* Returns the next chunk in file order - video and audio come interleaved, and
 * that is exactly how they have to be processed.
 * Returns: AVI_CHUNK_VIDEO, AVI_CHUNK_AUDIO or AVI_CHUNK_NONE (end). */
int  avi_next_chunk(avi_file *av, const uint8_t **out, uint32_t *out_size);

/* Video frames only, audio is skipped. */
int  avi_next_video(avi_file *av, const uint8_t **out, uint32_t *out_size);

/* Audio chunks only, with a read pointer OF THEIR OWN.
 *
 * The audio needs a head start: otherwise it only begins once the first buffer
 * is full - with us about 125 ms after the picture. With a second pointer the
 * audio can be preloaded before the clock starts and then kept a little ahead
 * of the picture. As the file lies in memory completely, a
 * zweiter Zeiger nichts. */
int  avi_next_audio(avi_file *av, const uint8_t **out, uint32_t *out_size);

#endif
