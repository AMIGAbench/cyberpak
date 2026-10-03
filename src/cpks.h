/* cpks.h - reading a CPKS stream: Cinepak with timestamps.
 *
 * CPKS wraps a 16-byte shell around the very same Cinepak bitstream an AVI
 * file carries - byte for byte the same, checked against a hash in
 * tests/run_tests.sh - and gives every packet a timestamp. With sound present
 * the timebase is the SAMPLE RATE, so `pts` is a sample index.
 *
 * That is the whole point, and the reason why the player has read nothing but
 * this format since the commit "AVI out of the player": an AVI player clocks
 * the picture from timer.device and the sound from Paula, and because Paula
 * can only do integer periods, the two clocks drift apart (measured
 * -907 ppm). If instead both sides count in samples, Paula's rate deviation
 * drops out: the film runs 0.9 per mille too slow, but picture and sound stay
 * exactly together.
 *
 * The reader does buffered read-ahead, keeps a queue of compressed video
 * frames and hands the sound on through a callback. Every queue slot also
 * carries `pts` and the keyframe flag; the whole playback control rests on
 * that.
 *
 * It reads forward only and never seeks, so that the same reader can later
 * hang on a socket unchanged.
 */
#ifndef CYBERPAK_CPKS_H
#define CYBERPAK_CPKS_H

#include <stdint.h>

#define CPKS_ERR_OPEN    -1
#define CPKS_ERR_FORMAT  -2
#define CPKS_ERR_MEMORY  -3

#define CPKS_MAGIC  0x43504B53ul   /* 'CPKS' */

/* Packet types. 4 (tick) is not produced by the encoder at present; a server
 * may sprinkle it in as a sign of life. */
#define CPKS_T_HEADER 1
#define CPKS_T_VIDEO  2
#define CPKS_T_AUDIO  3
#define CPKS_T_TICK   4

#define CPKS_F_KEY    0x01

typedef struct {
    uint16_t version, flags;
    uint16_t width, height;
    uint32_t fps_num, fps_den;
    uint32_t timebase;      /* ticks per second                        */
    uint32_t arate;         /* 0 = NO sound. Do not ask `achans` -     */
    uint8_t  achans;        /*   that is set even without sound.       */
    uint8_t  abits;
    uint32_t codec;         /* 'cvid'                                  */
    uint32_t prebuffer;     /* recommended lead-in in ticks            */
} cpks_info;

typedef struct cpks_stream cpks_stream;

/* Recognises the container by the first four bytes. */
int cpks_probe(const uint8_t *p, uint32_t n);

/* `queue` = number of video frames kept ready. On opening it waits for the
 * first header packet; video and audio packets before it are discarded,
 * because without geometry and timebase there is nothing to do with them. */
/* Tailoring of the read path, to be set BEFORE cpks_open().
 *   fill   size of the read buffer (and thus the amount per Read())
 *   direct payload from this size on goes straight into the target memory,
 *          without the detour through the buffer; 0 switches that off.
 * It exists because both values are a question of measurement - see cpks.c. */
void cpks_tune(uint32_t fill, uint32_t direct);

cpks_stream *cpks_open(const char *fn, uint32_t queue, int *err);
void         cpks_close(cpks_stream *s);

const cpks_info *cpks_get_info(const cpks_stream *s);

/* Reads on until the queue is full or the stream ends.
 * Audio packets go out through the callback right away. */
void cpks_pump(cpks_stream *s, void (*audio_sink)(const uint8_t *, uint32_t));

/* Look at the queue without taking anything out. Index 0 is the OLDEST.
 * Needed for the keyframe search when skipping ahead. */
uint32_t cpks_queued(const cpks_stream *s);
int      cpks_peek(const cpks_stream *s, uint32_t i, uint32_t *pts, int *key);

/* Take out the oldest frame. 0 = queue empty. */
int  cpks_next_video(cpks_stream *s, const uint8_t **data, uint32_t *len,
                     uint32_t *pts, int *key);
/* Discard the oldest frame WITHOUT decoding it. Allowed only after a keyframe
 * jump - Cinepak inter frames build on one another. */
void cpks_drop_video(cpks_stream *s);

/* Audio samples handed to the callback so far. Basis of the prebuffering. */
uint32_t cpks_audio_samples(const cpks_stream *s);

/* Time base of the sound: position = cpks_audio_base() + audio_played_samples().
 * In a file that is 0; after a gap in the stream it pulls itself straight again
 * from the absolute sample index of the next audio packet. */
uint32_t cpks_audio_base(const cpks_stream *s);

/* Core of the playback control (specification 5.3/5.4). Returns how many
 * frames of the queue are due: decode ALL of them, show only the last one.
 * With more than one second of backlog it first skips ahead to the newest
 * keyframe with pts <= pos; *dropped counts those frames, and only they may
 * be left undecoded. */
uint32_t cpks_advance(cpks_stream *s, uint32_t pos, uint32_t *dropped);

uint32_t cpks_bytes_read(const cpks_stream *s);
uint64_t cpks_read_ticks(const cpks_stream *s);
/* Time inside the audio callback, already taken out of cpks_read_ticks(). */
uint64_t cpks_sink_ticks(const cpks_stream *s);
int      cpks_eof(const cpks_stream *s);
uint32_t cpks_dbg_resyncs(const cpks_stream *s);
/* Read path diagnostics: number of Read() calls and the bytes copied through
 * the intermediate buffer. */
uint32_t cpks_dbg_reads(const cpks_stream *s);
uint32_t cpks_dbg_copied(const cpks_stream *s);

#endif
