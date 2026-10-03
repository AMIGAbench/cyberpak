#include <stdlib.h>
#include <string.h>
#include "bytes.h"
#include "cpks.h"
#include "timing.h"

#ifdef __m68k__
#include <exec/types.h>
#include <exec/memory.h>
#include <proto/exec.h>
#include <proto/dos.h>
#else
#include <stdio.h>
#endif

/* Tailoring of the read path.
 *
 * The read path costs TWO different things, and the assumption about which of
 * them dominates was wrong. Measured with tests/readbench.c on an
 * emulated 68000 @ 7 MHz, 120 frames from cpkstest.cpks:
 *
 *   fill    direct   Read()   copied     time
 *   16 KB      off       44   494,928   651 ms   <- starting point
 *   16 KB   3072 B       47   458,139  1106 ms
 *    8 KB   3072 B       96   434,348  1307 ms
 *    2 KB   2048 B      242    22,699  1005 ms
 *    1 KB   1024 B      362   242,175  1875 ms
 *   64 KB      off       12   471,042   540 ms   <- chosen
 *
 * THREE ADDITIONAL Read() calls cost 455 ms and save 37 KB of memcpy in
 * doing so, that is about 40 ms. A Read() is thus one to two orders of
 * magnitude more expensive than the copy it saves - and the reason is
 * ALIGNMENT: with a fixed buffer every read offset lies on a
 * multiple of the buffer size and thus on a block boundary, while with
 * direct reading it lies in the middle of a block. The file system then has
 * to assemble block fragments.
 *
 * From that follows the opposite of what seemed obvious: do not avoid the
 * copy, but lower the number of read operations. The buffer is therefore
 * made BIGGER instead of smaller, and the direct path stays off.
 *
 * But it stays IN THE CODE and adjustable - for one thing because the table
 * above would otherwise not be reproducible, for another because a network
 * stream (CPKS over TCP) has no block boundaries and may come out quite
 * differently there. Then it gets measured again, not guessed. */
#define RBUF   (64u * 1024u)   /* capacity of the read buffer */
#define PKTHDR 16u

static uint32_t cfg_fill   = RBUF;   /* this much rb_fill fetches           */
static uint32_t cfg_direct = 0u;     /* direct path off - see table above   */

void cpks_tune(uint32_t fill, uint32_t direct)
{
    if (fill >= PKTHDR && fill <= RBUF) cfg_fill = fill;
    /* 0 = never direct; that is the comparison case against the old path. */
    if (direct == 0u || direct >= 64u)  cfg_direct = direct;
}

struct cpks_stream {
    cpks_info info;
    int       have_info;

    /* Queue of compressed video frames, each with a timestamp. */
    uint8_t  *qmem;
    uint32_t *qlen, *qpts;
    uint8_t  *qkey;
    uint32_t  qslots, qframe;
    uint32_t  qhead, qtail, qcount;

    /* Read buffer. It reads forward only, never seeks. */
    uint8_t  *rb;
    uint32_t  rpos, rlen, rbcap;
    int       feof;

    uint32_t  asamples;      /* audio samples handed to the callback */
    uint32_t  apts_base;     /* time base of the sound, see one_packet() */
    uint32_t  bytes_read;
    uint32_t  resyncs;
    /* Diagnostics of the read path: how many Read() calls, and how many bytes
     * were COPIED through the intermediate buffer instead of going straight
     * into the target memory. Both are the levers of this path - without the
     * counters it is guesswork. */
    uint32_t  dbg_reads, dbg_copied;
    uint64_t  sink_ticks;    /* time INSIDE the audio callback, see cpks_pump() */
    uint64_t  read_ticks;
    int       eof;

#ifdef __m68k__
    BPTR      fh;
#else
    FILE     *fh;
#endif
};

/* --- thin file layer, deliberately without seek ------------------------- */

/* NO seek, not even to find out the file size.
 *
 * The reader needs it nowhere, and on a non-seekable handle -
 * NETSTREAM: on the Amiga, later a socket - even this one
 * move would fail or throw the stream away. That is exactly what CPKS is
 * made for: read from front to back, nothing else. */
static int f_open(cpks_stream *s, const char *fn)
{
#ifdef __m68k__
    s->fh = Open((CONST_STRPTR)fn, MODE_OLDFILE);
    return s->fh ? 1 : 0;
#else
    s->fh = fopen(fn, "rb");
    return s->fh ? 1 : 0;
#endif
}
static long f_read(cpks_stream *s, void *buf, long n)
{
    s->dbg_reads++;
#ifdef __m68k__
    return Read(s->fh, buf, n);
#else
    return (long)fread(buf, 1, (size_t)n, s->fh);
#endif
}
static void f_close(cpks_stream *s)
{
    if (!s->fh) return;
#ifdef __m68k__
    Close(s->fh);
#else
    fclose(s->fh);
#endif
    s->fh = 0;
}
static void *mem_alloc(uint32_t n)
{
#ifdef __m68k__
    return AllocVec(n, MEMF_ANY | MEMF_CLEAR);
#else
    return calloc(n, 1);
#endif
}
static void mem_free(void *p)
{
    if (!p) return;
#ifdef __m68k__
    FreeVec(p);
#else
    free(p);
#endif
}

/* --- buffer layer ------------------------------------------------------- */

/* Compacts the buffer and loads more. Returns the number of bytes available. */
static uint32_t rb_fill(cpks_stream *s)
{
    if (s->rpos) {
        if (s->rlen > s->rpos)
            memmove(s->rb, s->rb + s->rpos, s->rlen - s->rpos);
        s->rlen -= s->rpos;
        s->rpos  = 0;
    }
    if (s->rlen < s->rbcap && !s->feof) {
        long got = f_read(s, s->rb + s->rlen, (long)(s->rbcap - s->rlen));
        if (got <= 0) s->feof = 1;
        else { s->rlen += (uint32_t)got; s->bytes_read += (uint32_t)got; }
    }
    return s->rlen - s->rpos;
}

/* Makes sure that at least n bytes are in the buffer.
 *
 * Read repeatedly until it is enough. A single read attempt is NOT enough:
 * with a file Read() always delivers the full requested amount, with
 * a network stream (NETSTREAM:, BoingTube) only what has just
 * arrived. A short read is the normal case there and
 * does not mean end of file - the previous version took it as such
 * and declared the stream finished.
 *
 * It gives up only when a read attempt brings NO progress;
 * then the stream really is at its end (rb_fill sets feof while doing so). */
static int rb_need(cpks_stream *s, uint32_t n)
{
    while (s->rlen - s->rpos < n) {
        uint32_t before = s->rlen - s->rpos;
        if (rb_fill(s) <= before) return 0;
    }
    return 1;
}

/* Take what is already in the buffer over into dst. Returns how much. */
static uint32_t rb_drain(cpks_stream *s, uint8_t *dst, uint32_t n)
{
    uint32_t avail = s->rlen - s->rpos;
    if (!avail) return 0;
    if (avail > n) avail = n;
    memcpy(dst, s->rb + s->rpos, avail);
    s->dbg_copied += avail;
    s->rpos += avail;
    return avail;
}

/* Fetch n bytes into dst.
 *
 * First what is already in the buffer is drained - those bytes have already
 * been read, there is nothing left to save on them. The REST goes straight
 * into the target memory as soon as it is worth a DOS packet. Afterwards the
 * buffer is empty, so the loop is always in the same state. */
static int rb_take(cpks_stream *s, uint8_t *dst, uint32_t n)
{
    uint32_t got0 = rb_drain(s, dst, n);
    dst += got0; n -= got0;

    while (n) {
        if (cfg_direct && n >= cfg_direct && !s->feof) {
            long got = f_read(s, dst, (long)n);
            if (got <= 0) { s->feof = 1; return 0; }
            s->bytes_read += (uint32_t)got;
            dst += got; n -= (uint32_t)got;
            continue;
        }
        if (!rb_fill(s)) return 0;
        got0 = rb_drain(s, dst, n);
        if (!got0) return 0;
        dst += got0; n -= got0;
    }
    return 1;
}

/* Skip n bytes. Deliberately without seek - see the header comment. */
static int rb_skip(cpks_stream *s, uint32_t n)
{
    while (n) {
        uint32_t avail = s->rlen - s->rpos;
        if (!avail) { if (!rb_fill(s)) return 0; avail = s->rlen - s->rpos; }
        if (avail > n) avail = n;
        s->rpos += avail; n -= avail;
    }
    return 1;
}

static int is_magic(const uint8_t *p)
{
    return p[0] == 'C' && p[1] == 'P' && p[2] == 'K' && p[3] == 'S';
}

/* Find the next sync word and position in front of it.
 *
 * This is the format's re-entry path: at an arbitrary place in the stream
 * look for the next 'CPKS' and parse from there. A random byte pattern
 * in the payload shows up at the next packet at the latest, because its
 * header then does not begin with the sync word and the search runs again. */
static int find_sync(cpks_stream *s)
{
    for (;;) {
        uint32_t avail = rb_fill(s), i;
        if (avail < 4) return 0;
        for (i = 0; i + 4 <= avail; i++)
            if (is_magic(s->rb + s->rpos + i)) { s->rpos += i; return 1; }
        /* The last three bytes may still be the start of the sync word. */
        s->rpos += avail - 3;
    }
}

/* --- packet loop -------------------------------------------------------- */

static void parse_header(cpks_info *in, const uint8_t *p)
{
    in->version   = (uint16_t)rd_be16(p +  0);
    in->flags     = (uint16_t)rd_be16(p +  2);
    in->width     = (uint16_t)rd_be16(p +  4);
    in->height    = (uint16_t)rd_be16(p +  6);
    in->fps_num   = rd_be32(p +  8);
    in->fps_den   = rd_be32(p + 12);
    in->timebase  = rd_be32(p + 16);
    in->arate     = rd_be32(p + 20);
    in->achans    = p[24];
    in->abits     = p[25];
    /* 26..27 reserved */
    in->codec     = rd_be32(p + 28);
    in->prebuffer = rd_be32(p + 32);
}

/* Process exactly one packet. Return 0 = stream at its end. */
static int one_packet(cpks_stream *s, void (*audio_sink)(const uint8_t *, uint32_t))
{
    const uint8_t *h;
    uint32_t type, flags, pts, len, pad;

    if (!rb_need(s, PKTHDR)) return 0;
    if (!is_magic(s->rb + s->rpos)) {
        s->resyncs++;
        if (!find_sync(s)) return 0;
        if (!rb_need(s, PKTHDR)) return 0;
    }
    /* Look at the type BEFORE the header is consumed: with a full queue
     * the video packet has to be allowed to stay put. cpks_pump() only calls
     * when there is free space anyway - but without this lock another caller
     * would silently lose a frame here, and with Cinepak that tears open
     * the whole following difference chain. */
    if (s->rb[s->rpos + 4] == CPKS_T_VIDEO && s->have_info &&
        s->qcount >= s->qslots)
        return 1;

    /* Read straight from the buffer. All fields are fetched BEFORE rpos
     * moves on and before any rb_* call compacts the buffer -
     * afterwards the pointer would be invalid. */
    h = s->rb + s->rpos;
    type  = h[4];
    flags = h[5];
    /* h[6..7] is `seq` - pure diagnostics, wraps around, is not evaluated. */
    pts   = rd_be32(h +  8);
    len   = rd_be32(h + 12);
    pad   = (4u - (len & 3u)) & 3u;      /* len == 0 correctly gives 0 */
    s->rpos += PKTHDR;                   /* from here on h is invalid */

    if (type == CPKS_T_VIDEO && s->have_info) {
        uint8_t *slot = s->qmem + (size_t)s->qhead * s->qframe;
        uint32_t want = (len > s->qframe) ? s->qframe : len;
        if (!rb_take(s, slot, want)) return 0;
        if (want < len && !rb_skip(s, len - want)) return 0;
        s->qlen[s->qhead] = want;
        s->qpts[s->qhead] = pts;
        s->qkey[s->qhead] = (uint8_t)((flags & CPKS_F_KEY) ? 1 : 0);
        s->qhead = (s->qhead + 1) % s->qslots;
        s->qcount++;
    } else if (type == CPKS_T_AUDIO && s->have_info && s->info.arate) {
        /* Sound goes on right away. The next free queue slot serves as the
         * intermediate buffer - it is overwritten again in a moment. */
        uint8_t *tmp = s->qmem + (size_t)s->qhead * s->qframe;
        uint32_t want = (len > s->qframe) ? s->qframe : len;
        uint32_t block = (uint32_t)s->info.achans * (s->info.abits / 8u);
        const uint8_t *ap;
        /* If the packet is in the read buffer in full, the callback gets
         * a pointer TO IT. The detour through the intermediate slot would be
         * a second copy of the same bytes - audio_write() copies into its
         * ring anyway. The buffer stays unchanged until the next rb_* call,
         * and that comes only after the callback. */
        if (s->rlen - s->rpos >= want) {
            ap = s->rb + s->rpos;
            s->rpos += want;
        } else {
            if (!rb_take(s, tmp, want)) return 0;
            ap = tmp;
        }
        if (want < len && !rb_skip(s, len - want)) return 0;
        /* Pull the time base along. In a gapless stream from a file
         * apts_base + asamples == pts always holds, and the assignment is
         * then without effect. If the stream tears (entering in the middle,
         * network loss), every audio packet carries its ABSOLUTE sample
         * index - the position thereby joins up again by itself, without
         * error handling. */
        if (s->apts_base + s->asamples != pts)
            s->apts_base = pts - s->asamples;
        /* Keep the time inside the callback separately and take it out of the
         * read time. Previously audio_write() lay inside the bracket around
         * cpks_pump() - what was printed as "disk" was in truth
         * disk plus audio deinterleave. On the 68020 that was the biggest
         * unmeasured item of all. */
        if (audio_sink && want) {
            uint64_t ts = timing_now();
            audio_sink(ap, want);
            s->sink_ticks += timing_now() - ts;
        }
        if (block) s->asamples += want / block;
    } else if (type == CPKS_T_HEADER) {
        /* The header is repeated every two seconds. Only the first one
         * counts; the later ones are there for entering in the middle, which
         * we do not need here - they are discarded. */
        if (len >= 36u && !s->have_info) {
            uint8_t hb[36];
            if (!rb_take(s, hb, 36u)) return 0;
            if (!rb_skip(s, len - 36u)) return 0;
            parse_header(&s->info, hb);
            s->have_info = 1;
        } else if (!rb_skip(s, len)) return 0;
    } else {
        /* Unknown type, tick packet, or payload before the first header:
         * skip it using `len`. That is exactly the format's extension path -
         * a player must not bail out here. */
        if (!rb_skip(s, len)) return 0;
    }

    if (pad && !rb_skip(s, pad)) return 0;
    return 1;
}

/* --- public ------------------------------------------------------------- */

int cpks_probe(const uint8_t *p, uint32_t n)
{
    return n >= 4 && is_magic(p);
}

cpks_stream *cpks_open(const char *fn, uint32_t queue, int *err)
{
    cpks_stream *s;
    uint32_t maxframe, guard;

    *err = CPKS_ERR_MEMORY;
    s = (cpks_stream *)mem_alloc(sizeof(*s));
    if (!s) return NULL;

    if (!f_open(s, fn)) { *err = CPKS_ERR_OPEN; mem_free(s); return NULL; }

    /* Only as large as configured - the buffer never fills up more. */
    s->rbcap = cfg_fill;
    s->rb = (uint8_t *)mem_alloc(s->rbcap);
    if (!s->rb) { cpks_close(s); return NULL; }

    /* The queue only after the header, but one_packet() needs it already
     * as an intermediate buffer. So create it with a provisional size
     * first: up to the header only packets are skipped anyway. */
    if (!queue) queue = 16;
    s->qslots = queue;
    s->qframe = 65536u;
    s->qmem = (uint8_t *)mem_alloc(queue * s->qframe);
    s->qlen = (uint32_t *)mem_alloc(queue * sizeof(uint32_t));
    s->qpts = (uint32_t *)mem_alloc(queue * sizeof(uint32_t));
    s->qkey = (uint8_t  *)mem_alloc(queue);
    if (!s->qmem || !s->qlen || !s->qpts || !s->qkey) { cpks_close(s); return NULL; }

    if (!rb_need(s, 4) || !is_magic(s->rb + s->rpos)) {
        /* No sync word right at the front - search anyway, then the player
         * also reads a stream cut off in the middle. */
        if (!find_sync(s)) { *err = CPKS_ERR_FORMAT; cpks_close(s); return NULL; }
    }

    /* Wait for the first header packet. Without geometry and timebase there
     * is nothing to do with video and audio packets; they are discarded. The
     * encoder puts the header first, when entering in the middle it takes up
     * to two seconds. */
    guard = 4096u;
    while (!s->have_info && guard--) {
        if (!one_packet(s, NULL)) break;
    }
    if (!s->have_info || !s->info.width || !s->info.height || !s->info.timebase) {
        *err = CPKS_ERR_FORMAT; cpks_close(s); return NULL;
    }

    /* Now bring the queue to the actual frame size.
     *
     * One slot has to hold the LARGEST frame, that is a keyframe. If it does
     * not fit, one_packet() truncates it and the decoder gets fragments
     * - silently. Half the pixel count is ample (Cinepak
     * stays well below that even for keyframes) and also covers 1280x720,
     * where the earlier 256 KB would no longer have been enough. */
    maxframe = (uint32_t)s->info.width * (uint32_t)s->info.height / 2u;
    if (maxframe < 32768u)   maxframe = 32768u;
    if (maxframe > 1048576u) maxframe = 1048576u;
    if (maxframe != s->qframe) {
        mem_free(s->qmem);
        s->qframe = maxframe;
        s->qmem = (uint8_t *)mem_alloc(queue * maxframe);
        if (!s->qmem) { cpks_close(s); return NULL; }
    }

    *err = 0;
    return s;
}

void cpks_close(cpks_stream *s)
{
    if (!s) return;
    mem_free(s->qmem);
    mem_free(s->qlen);
    mem_free(s->qpts);
    mem_free(s->qkey);
    mem_free(s->rb);
    f_close(s);
    mem_free(s);
}

const cpks_info *cpks_get_info(const cpks_stream *s) { return &s->info; }
uint32_t cpks_queued(const cpks_stream *s)        { return s->qcount; }
uint32_t cpks_audio_samples(const cpks_stream *s) { return s->asamples; }
uint32_t cpks_audio_base(const cpks_stream *s)    { return s->apts_base; }
uint32_t cpks_bytes_read(const cpks_stream *s)    { return s->bytes_read; }
uint64_t cpks_read_ticks(const cpks_stream *s)    { return s->read_ticks; }
uint64_t cpks_sink_ticks(const cpks_stream *s)    { return s->sink_ticks; }
int      cpks_eof(const cpks_stream *s)           { return s->eof; }
uint32_t cpks_dbg_resyncs(const cpks_stream *s)   { return s->resyncs; }
uint32_t cpks_dbg_reads(const cpks_stream *s)     { return s->dbg_reads; }
uint32_t cpks_dbg_copied(const cpks_stream *s)    { return s->dbg_copied; }

void cpks_pump(cpks_stream *s, void (*audio_sink)(const uint8_t *, uint32_t))
{
    uint64_t t0 = timing_now();
    uint64_t s0 = s->sink_ticks;
    while (!s->eof && s->qcount < s->qslots)
        if (!one_packet(s, audio_sink)) s->eof = 1;
    /* Only the read time, without the audio callback. */
    s->read_ticks += (timing_now() - t0) - (s->sink_ticks - s0);
}

int cpks_peek(const cpks_stream *s, uint32_t i, uint32_t *pts, int *key)
{
    uint32_t k;
    if (i >= s->qcount) return 0;
    k = (s->qtail + i) % s->qslots;
    if (pts) *pts = s->qpts[k];
    if (key) *key = s->qkey[k];
    return 1;
}

int cpks_next_video(cpks_stream *s, const uint8_t **data, uint32_t *len,
                    uint32_t *pts, int *key)
{
    if (!s->qcount) return 0;
    if (data) *data = s->qmem + (size_t)s->qtail * s->qframe;
    if (len)  *len  = s->qlen[s->qtail];
    if (pts)  *pts  = s->qpts[s->qtail];
    if (key)  *key  = s->qkey[s->qtail];
    s->qtail = (s->qtail + 1) % s->qslots;
    s->qcount--;
    return 1;
}

void cpks_drop_video(cpks_stream *s)
{
    if (!s->qcount) return;
    s->qtail = (s->qtail + 1) % s->qslots;
    s->qcount--;
}

/* Bring the queue up to `pos` - sections 5.3 and 5.4 of the specification.
 *
 * All comparisons run over the SIGNED difference. `pts` is
 * a uint32 and wraps after 27 hours at 44.1 kHz; a direct
 * `<=` comparison would tip the playback over at that point.
 *
 * Return: number of frames with pts <= pos. ALL of them have to be
 * DECODED - Cinepak inter frames build on one another - only the last one
 * is shown. Only the keyframe jump may really skip; it counts
 * through *dropped. */
uint32_t cpks_advance(cpks_stream *s, uint32_t pos, uint32_t *dropped)
{
    uint32_t i, n = 0, drop = 0;

    if (dropped) *dropped = 0;
    if (!s->qcount) return 0;

    /* 5.4: more than one second behind? Then skip ahead to the NEWEST
     * keyframe with pts <= pos. Not to the next one - the search loop
     * deliberately does not break off (tools/cpkssim.py does it the same way).
     * If there is no such keyframe, nothing happens: the encoder guarantees
     * no fixed spacing. */
    if ((int32_t)(pos - s->qpts[s->qtail]) > (int32_t)s->info.timebase) {
        uint32_t best = 0;
        for (i = 0; i < s->qcount; i++) {
            uint32_t k = (s->qtail + i) % s->qslots;
            if (s->qkey[k] && (int32_t)(pos - s->qpts[k]) >= 0) best = i;
        }
        for (i = 0; i < best; i++) cpks_drop_video(s);
        drop = best;
    }

    /* 5.3: everything that is due. */
    for (i = 0; i < s->qcount; i++) {
        uint32_t k = (s->qtail + i) % s->qslots;
        if ((int32_t)(pos - s->qpts[k]) < 0) break;
        n++;
    }

    if (dropped) *dropped = drop;
    return n;
}
