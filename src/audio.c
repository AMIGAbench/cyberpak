#include "audio.h"
#include "cpu.h"
#include "timing.h"

#ifdef __m68k__

#include <exec/types.h>
#include <exec/memory.h>
#include <devices/audio.h>
#include <graphics/gfxbase.h>
#include <proto/exec.h>
#include <proto/graphics.h>

extern struct GfxBase *GfxBase;

/* Sixteen short buffers instead of four long ones.
 *
 * The reason is the resolution: audio_played_samples() can only answer to
 * buffer precision, and 125 ms was coarser than a frame period (83 ms at
 * 12 fps). With rate/32 per buffer it is 31 ms - finer than the frame
 * spacing, and exactly that lets the CPKS path use the sound as its clock.
 *
 * The COUNT is independent of that and stays at 0.5 s of total reserve, so
 * exactly as much as with the previous four buffers - and the same chip RAM
 * demand (16 x 2 x 689 bytes at 22 kHz = 22 KB, as before
 * 4 x 2 x 2756). An intermediate state with eight buffers (0.25 s) ran dry
 * three times on real hardware; the reserve costs the synchronisation
 * nothing, because audio_played_samples() subtracts what is still due. */
#define NBUF 16          /* upper limit; a_nbuf of them are used */

/* Diagnostics - answers "why is there no sound" without guesswork. */
static uint32_t dbg_mask, dbg_bytes, dbg_sent, dbg_blocked, dbg_lost, dbg_under;
/* How close was it REALLY? `dbg_under` only says THAT no buffer was running
 * any more - not whether the reserve melted slowly or broke away at once.
 * minpend is the lowest fill level of the chip queue ever seen,
 * maxring the largest backlog in the fast RAM ring. Together they tell the
 * two cases apart: if the reserve melts, it is too small; if the ring backs
 * up, audio_service() is not keeping pace. */
static uint32_t dbg_minpend = 0xFFFFFFFFu, dbg_maxring;
/* Number of CheckIO calls actually performed. Without this counter there is
 * no evidence whether the bdone[] flag buys anything. */
static uint32_t dbg_checkio;

/* Buffer geometry adjustable at run time - only that way can the old layout
 * be compared against the new one in the same binary. */
static uint32_t cfg_div  = 32;   /* a_bufsz = rate / cfg_div */
static uint32_t cfg_nbuf = NBUF;
static uint32_t a_nbuf   = NBUF;

void audio_config(uint32_t bufdiv, uint32_t nbuf)
{
    if (bufdiv >= 4u && bufdiv <= 128u) cfg_div = bufdiv;
    if (nbuf   >= 2u && nbuf   <= NBUF) cfg_nbuf = nbuf;
}

/* Intermediate buffer in FAST RAM, two seconds per channel.
 *
 * Previously audio_write() wrote straight into the chip buffers and WAITED
 * when the next one was still playing. That tied the sound feed to Paula's
 * clock - and while prebuffering the sound was therefore already running
 * while the picture still stood. Measured up to 500 ms of offset, and with a
 * deeper video queue it grew instead of shrinking.
 *
 * With the ring in between, audio_write() never blocks. audio_service()
 * pushes from it into free chip buffers, likewise without waiting. Sound and
 * picture thus start together. */
#define RINGSEC 2
static uint8_t  *ring[2];
static uint32_t  ringsz, rhead, rtail, rcount;
static int32_t  dbg_err;      /* io_Error of the last finished request  */

static struct MsgPort *aport;
static struct IOAudio *alloc_req;
static struct IOAudio *req[NBUF][2];
static int8_t         *buf[NBUF][2];
static int             opened;
static int             stromende;     /* audio_ende(): nothing more coming */

static uint32_t a_rate, a_chans, a_bits, a_bufsz;
/* Playback position: samples handed to Paula and the length of each buffer.
 * Kept separately, so that audio_played_samples() need not assume all
 * buffers are the same length. */
static uint32_t sent_samples;
static uint32_t buflen[NBUF];
/* Anchor points for the interpolation in audio_played_samples(). */
static uint64_t pos_t0;
static uint32_t pos_last;
static uint32_t a_clock, a_effrate;   /* colour clock and actual rate    */
static uint32_t fill;          /* fill level of the current buffer  */
static int      cur;           /* current buffer                   */
static int      queued[NBUF];  /* is the request still running?    */
/* Once done, always done - until the buffer is sent off again.
 *
 * CheckIO is non-destructive, but not free: it is a library call with
 * Forbid/Permit around a list check. audio_service() and
 * audio_played_samples() asked EVERY one of the up to 16 buffers, and did so
 * in four passes per loop turn of the player - up to 64 calls, most of which
 * repeated the same yes. The flag answers them without a call; only what
 * really is still playing gets asked.
 */
static int      bdone[NBUF];
static UWORD    period;

uint32_t audio_rate(void)     { return a_rate; }
uint32_t audio_eff_rate(void) { return a_effrate; }
uint32_t audio_period(void)   { return period; }
uint32_t audio_clock(void)    { return a_clock; }
uint32_t audio_dbg_mask(void)  { return dbg_mask; }
uint32_t audio_dbg_samples(void){ return dbg_bytes; }
uint32_t audio_dbg_sent(void)  { return dbg_sent; }
uint32_t audio_dbg_blocked(void){ return dbg_blocked; }
uint32_t audio_dbg_lost(void)   { return dbg_lost; }
uint32_t audio_dbg_under(void)  { return dbg_under; }
uint32_t audio_dbg_minpend(void){ return dbg_minpend == 0xFFFFFFFFu ? 0 : dbg_minpend; }
uint32_t audio_dbg_maxring(void){ return dbg_maxring; }
uint32_t audio_dbg_checkio(void){ return dbg_checkio; }
uint32_t audio_dbg_bufsz(void)  { return a_bufsz; }
uint32_t audio_dbg_nbuf(void)   { return a_nbuf; }
int32_t  audio_dbg_error(void) { return dbg_err; }

/* Channel assignment on Paula: 0 and 3 are on the LEFT, 1 and 2 on the RIGHT.
 * For stereo we need one from each side - that is exactly these
 * four combinations:
 *   0x03 = channels 0+1,  0x05 = 0+2,  0x0A = 1+3,  0x0C = 2+3
 * (0x09 = 0+3 used to be first here - both on the left. Then the right
 *  channel selection found nothing and no sound came.) */
static UBYTE combos[] = { 0x03, 0x05, 0x0A, 0x0C };



/* Has the buffer finished playing? Without blocking. */
static int buf_done(int b)
{
    int c;
    if (!queued[b]) return 1;
    if (bdone[b])   return 1;
    for (c = 0; c < 2; c++)
        if (req[b][c]) {
            dbg_checkio++;
            if (!CheckIO((struct IORequest *)req[b][c])) return 0;
        }
    bdone[b] = 1;
    return 1;
}

static void wait_buf(int b)
{
    int c;
    if (!queued[b]) return;
    if (!buf_done(b)) dbg_blocked++;
    for (c = 0; c < 2; c++)
        if (req[b][c]) {
            WaitIO((struct IORequest *)req[b][c]);
            /* Without this check it stays invisible that the device did not
             * carry out the write request at all - it then simply returns
             * right away. */
            if (req[b][c]->ioa_Request.io_Error)
                dbg_err = req[b][c]->ioa_Request.io_Error;
        }
    queued[b] = 0;
}

static void send_buf(int b, uint32_t len)
{
    int c;
    if (!len) return;
    for (c = 0; c < 2; c++) {
        if (!req[b][c]) continue;
        req[b][c]->ioa_Request.io_Command = CMD_WRITE;
        req[b][c]->ioa_Request.io_Flags   = ADIOF_PERVOL;
        req[b][c]->ioa_Data    = (UBYTE *)buf[b][c];
        req[b][c]->ioa_Length  = len;
        req[b][c]->ioa_Period  = period;
        req[b][c]->ioa_Volume  = 64;
        req[b][c]->ioa_Cycles  = 1;
        SendIO((struct IORequest *)req[b][c]);
    }
    dbg_sent++;
    bdone[b] = 0;                 /* running again - the flag no longer holds */
    buflen[b] = len;
    sent_samples += len;
    queued[b] = 1;
}

/* Samples played: sent minus what is still inside Paula.
 *
 * The ring in fast RAM deliberately does NOT count - what lies there Paula
 * has never seen. Exactly that governs the behaviour on an underrun: if
 * Paula runs dry, all requests are done, `sent_samples` stops growing for
 * want of data, and the position stands still instead of running away.
 * The picture thereby waits along by itself (CPKS-FORMAT.md 5.5).
 *
 * CheckIO is non-destructive and may be asked as often as one likes; a
 * finished but not yet collected request counts correctly as played.
 *
 * Between two buffer boundaries the value is INTERPOLATED linearly. Without
 * that the resolution is one buffer (31 ms), and the player gets its frames
 * in bursts: at 40 ms frame spacing, 31 ms steps advance now by one, now by
 * two frames. On real hardware 84 of 600 frames thus went through the
 * decoder but never onto the screen (shown 516, decoded 600).
 *
 * The interpolation introduces NO drift: it is anchored anew at every buffer
 * boundary and capped at one buffer. And if Paula runs dry (pending == 0)
 * nothing is interpolated at all - the position then stands exactly still,
 * as 5.5 demands. */
uint32_t audio_played_samples(void)
{
    uint32_t b, pending = 0, played, d, f, minlen = a_bufsz;
    uint64_t now;

    if (!opened) return 0;
    for (b = 0; b < a_nbuf; b++)
        if (queued[b] && !buf_done((int)b)) {
            pending += buflen[b];
            if (buflen[b] < minlen) minlen = buflen[b];
        }
    played = sent_samples - pending;

    now = timing_now();
    if (played != pos_last) {          /* buffer boundary - anchor anew */
        pos_last = played;
        pos_t0   = now;
        return played;
    }
    if (!pending) return played;       /* Paula plays nothing -> standstill */

    f = timing_freq();
    if (!f || now < pos_t0) return played;
    /* 32 bits are enough and save the call to __udivdi3 (on the 68020
     * 500-1500 cycles). `now - pos_t0` is by construction capped at one
     * buffer length - at 31 ms that is about 22,000 EClock ticks,
     * times 22,050 Hz stays far below 2^32. */
    {
        uint32_t dt = (uint32_t)(now - pos_t0);
        /* Clamp to 1/16 second. That is markedly more than one buffer
         * (31 ms) and therefore of no consequence for the result - d is
         * capped at a_bufsz in a moment anyway. But it prevents the overflow
         * of the multiplication: f/16 is about 44,700, times at most
         * 28,000 Hz gives 1.25e9 and stays safely below 2^32. */
        if (dt > (f >> 4)) dt = f >> 4;
        d = (dt * a_effrate) / f;
    }
    /* Never past the next boundary. Since audio_service() also sends short
     * remainders, not all buffers are a_bufsz long any more. In mid-stream a
     * short remainder only goes to an empty Paula, so it is then the oldest;
     * at the end of the stream also behind running buffers. The shortest
     * running buffer is thus the right boundary or a more cautious one. */
    if (d >= minlen) d = minlen - 1u;
    return played + d;
}

int audio_open(uint32_t rate, uint32_t channels, uint32_t bits)
{
    uint32_t clock;
    int b, c;
    UBYTE unit;

    if (!rate || channels < 1 || channels > 2) return AUDIO_ERR_FORMAT;
    if (bits != 8 && bits != 16) return AUDIO_ERR_FORMAT;

    /* Derive the colour clock from the ECLOCK FREQUENCY, not through GfxBase.
     *
     * Paula's period counts in colour clocks: 3546895 Hz (PAL) respectively
     * 3579545 Hz (NTSC). That is exactly five times the EClock frequency,
     * which we read reliably from timer.device anyway.
     *
     * Previously `GfxBase->DisplayFlags & PAL` decided it. But the player
     * calls not a single graphics.library function, so GfxBase is never
     * opened and is NULL - it therefore always fell back to NTSC.
     * On PAL hardware that gives period 162 instead of 161: the sound ran
     * 0.7 % too slow and the picture was thus visibly ahead. */
    clock = timing_freq() * 5u;
    if (clock < 3000000u || clock > 4000000u) clock = 3546895u;   /* PAL stopgap */
    a_clock = clock;

    /* Paula's upper limit. The original additionally limits to 27 kHz when
     * the screen is not scandoubled - there the bitplane DMA otherwise eats
     * the bandwidth away (CyberAVIAudio.mod:577-586). */
    if (rate > 28000u) rate = 28000u;

    /* ROUND, do not truncate. At 22050 Hz and PAL that is 160.86:
     * truncated 160 (+0.54 %), rounded 161 (-0.09 %) - a factor of six
     * less drift, for free. */
    period = (UWORD)((clock + rate / 2u) / rate);
    if (period < 124) period = 124;
    a_effrate = clock / period;

    a_rate  = rate;
    a_chans = channels;
    a_bits  = bits;
    /* About 31 ms per buffer, sixteen of them: 0.5 s of hardware reserve at a
     * position resolution finer than one frame spacing (see NBUF). */
    a_nbuf  = cfg_nbuf;
    a_bufsz = rate / cfg_div;
    a_bufsz &= ~3u;                       /* multiple of 4 for longword stores */
    if (a_bufsz < 512) a_bufsz = 512;

    aport = CreateMsgPort();
    if (!aport) return AUDIO_ERR_DEVICE;

    alloc_req = (struct IOAudio *)CreateIORequest(aport, sizeof(struct IOAudio));
    if (!alloc_req) { audio_close(); return AUDIO_ERR_DEVICE; }

    alloc_req->ioa_Request.io_Message.mn_Node.ln_Pri = 10;
    alloc_req->ioa_Data   = combos;
    alloc_req->ioa_Length = sizeof(combos);
    if (OpenDevice((CONST_STRPTR)"audio.device", 0,
                   (struct IORequest *)alloc_req, 0) != 0) {
        audio_close(); return AUDIO_ERR_DEVICE;
    }
    opened = 1;
    stromende = 0;
    unit = (UBYTE)(ULONG)alloc_req->ioa_Request.io_Unit;
    dbg_mask = unit;

    for (b = 0; b < (int)a_nbuf; b++) {
        for (c = 0; c < 2; c++) {
            /* Left channel from {0,3}, right one from {1,2}. */
            UBYTE avail = c ? (UBYTE)(unit & 0x06) : (UBYTE)(unit & 0x09);
            UBYTE mask;
            if (!avail) continue;
            /* Keep exactly one channel - the lowest set bit. */
            mask = (UBYTE)(avail & 0x01) ? 0x01 :
                   (UBYTE)(avail & 0x02) ? 0x02 :
                   (UBYTE)(avail & 0x04) ? 0x04 : 0x08;

            req[b][c] = (struct IOAudio *)AllocVec(sizeof(struct IOAudio),
                                                   MEMF_ANY | MEMF_CLEAR);
            if (!req[b][c]) { audio_close(); return AUDIO_ERR_MEMORY; }
            *req[b][c] = *alloc_req;
            req[b][c]->ioa_Request.io_Message.mn_ReplyPort = aport;
            req[b][c]->ioa_Request.io_Unit = (struct Unit *)(ULONG)mask;

            buf[b][c] = (int8_t *)AllocVec(a_bufsz, MEMF_CHIP | MEMF_CLEAR);
            if (!buf[b][c]) { audio_close(); return AUDIO_ERR_MEMORY; }
        }
    }
    /* Set period and volume EXPLICITLY.
     *
     * ADIOF_PERVOL on CMD_WRITE is supposed to do exactly that, and the
     * specification says so too. Measured on real hardware, however, the
     * flag is not evaluated: the playback rate stayed constant no matter
     * which period was set (31 kHz instead of the requested 11-28 kHz),
     * and the volume stayed at its default of 0 - so the device played
     * dutifully, only inaudibly quiet, and reported io_Error = 0 while doing it.
     *
     * An ADCMD_PERVOL sent beforehand sets both reliably. The values stick
     * to the channel afterwards, so once per channel is enough. */
    for (c = 0; c < 2; c++) {
        if (!req[0][c]) continue;
        req[0][c]->ioa_Request.io_Command = ADCMD_PERVOL;
        req[0][c]->ioa_Request.io_Flags   = 0;
        req[0][c]->ioa_Period = period;
        req[0][c]->ioa_Volume = 64;
        DoIO((struct IORequest *)req[0][c]);
        if (req[0][c]->ioa_Request.io_Error)
            dbg_err = req[0][c]->ioa_Request.io_Error;
    }

    ringsz = rate * RINGSEC;
    for (c = 0; c < 2; c++) {
        ring[c] = (uint8_t *)AllocVec(ringsz, MEMF_ANY | MEMF_CLEAR);
        if (!ring[c]) { audio_close(); return AUDIO_ERR_MEMORY; }
    }
    rhead = rtail = rcount = 0;

    fill = 0; cur = 0;
    sent_samples = 0;
    pos_last = 0; pos_t0 = timing_now();
    dbg_minpend = 0xFFFFFFFFu; dbg_maxring = 0;
    for (b = 0; b < NBUF; b++) buflen[b] = 0;
    return 0;
}

void audio_close(void)
{
    int b, c;
    for (b = 0; b < NBUF; b++) wait_buf(b);
    for (b = 0; b < NBUF; b++)
        for (c = 0; c < 2; c++) {
            if (buf[b][c]) { FreeVec(buf[b][c]); buf[b][c] = NULL; }
            if (req[b][c]) { FreeVec(req[b][c]); req[b][c] = NULL; }
        }
    for (b = 0; b < 2; b++)
        if (ring[b]) { FreeVec(ring[b]); ring[b] = NULL; }
    if (opened) { CloseDevice((struct IORequest *)alloc_req); opened = 0; }
    if (alloc_req) { DeleteIORequest((struct IORequest *)alloc_req); alloc_req = NULL; }
    if (aport) { DeleteMsgPort(aport); aport = NULL; }
}

void audio_testtone(void)
{
    /* 1 second of square wave, 440 Hz, through exactly the same chain as real
     * sound data. If the sound is audible, the fault is in the data; if it
     * stays silent, the device setup is wrong. */
    uint32_t i, n = a_rate;
    uint32_t half = a_rate / 880;      /* half period in samples */
    uint8_t  s[2];
    if (!opened || !half) return;
    for (i = 0; i < n; i++) {
        uint8_t v = ((i / half) & 1) ? 0xC0 : 0x40;   /* unsigned, as in the AVI */
        s[0] = v; s[1] = v;
        audio_write(s, 2);
    }
}

/* Pushes from the ring into free chip buffers. NEVER waits - if no buffer is
 * free, the data stays put and gets its turn on the next call.
 * Exactly that decouples the feed from Paula's clock. */
void audio_ende(void) { stromende = 1; }

void audio_service(void)
{
    int b, c;
    uint32_t pend = 0, n;

    if (!opened) return;

    /* A real underrun: NO buffer is playing any more although there is still
     * data - so Paula had nothing to put out. "0x blocked" could no longer
     * detect that after the rework, because nothing ever waits. */
    for (b = 0; b < (int)a_nbuf; b++) if (queued[b] && !buf_done(b)) pend++;
    if (dbg_sent) {
        if (pend < dbg_minpend) dbg_minpend = pend;
        if (rcount > dbg_maxring) dbg_maxring = rcount;
        if (!pend && rcount > 0) dbg_under++;
    }

    for (;;) {
        n = a_bufsz;
        if (rcount < a_bufsz) {
            /* A remainder only to an EMPTY Paula. Previously everything below
             * one buffer size stayed in the ring until more data came - at
             * the end of the stream none does. With ABUF=8 (1376 samples)
             * 1020 samples stayed behind on goku12b, the position ended at
             * 660480, the last frame has pts 660581: it never became
             * due, the player hung until it was aborted and counted every
             * tick as "ran dry". If a buffer is still running, the
             * remainder stays put as before - except at the end of the
             * stream (audio_ende): then nothing follows, and if it waited
             * for an empty Paula a gap would open before it. Even length,
             * because Paula counts in words. */
            if ((pend && !stromende) || rcount < 2u) return;
            n = rcount & ~1u;
        }
        /* look for a free buffer without blocking */
        for (b = 0; b < (int)a_nbuf; b++)
            if (buf_done(b)) break;
        if (b >= (int)a_nbuf) return;       /* all busy, later on           */
        if (queued[b]) { wait_buf(b); }     /* done, only needs collecting   */

        for (c = 0; c < 2; c++) {
            uint32_t first, rest;
            if (!buf[b][c] || !ring[c]) continue;
            /* Mind the end of the ring: up to two pieces. CopyMem instead of
             * a byte loop - the target buffer lies in chip RAM, and there
             * the number of bus accesses counts. */
            first = ringsz - rtail;
            if (first > n) first = n;
            rest  = n - first;
            CopyMem(ring[c] + rtail, buf[b][c], first);
            if (rest) CopyMem(ring[c], (uint8_t *)buf[b][c] + first, rest);
        }
        rtail += n;
        if (rtail >= ringsz) rtail -= ringsz;   /* instead of modulo */
        rcount -= n;
        send_buf(b, n);
        pend++;                   /* no short remainder behind it any more */
    }
}

void audio_write(const uint8_t *pcm, uint32_t bytes)
{
    uint32_t step;

    if (!opened || !bytes) return;
    step = (a_bits / 8) * a_chans;
    if (!step) return;

    /* Block-wise instead of sample by sample.
     *
     * Previously the loop body held, per sample: one `% ringsz` (ringsz is
     * rate*2, so not a power of two - the 68020 turns that into a real
     * divul.l with 44 cycles), the tests on a_bits and a_chans, two
     * NULL checks of the ring pointers and two indexed byte stores.
     * Together about 125 cycles per sample; at 22050 Hz that is ~19 % of a
     * 14 MHz 68020 - more than disk and display together. On the 68080 that
     * was invisible, because its divider takes 2-4 cycles instead of 44.
     *
     * Now the number of samples possible in one go is determined up front
     * (up to the end of the ring and up to the free space), and the body
     * contains nothing but post-increment stores. No modulo, no format
     * tests, no NULL checks. */
    {
        uint32_t nsmp = bytes / step;
        const uint8_t *sp = pcm;
        uint8_t *d0 = ring[0], *d1 = ring[1];

        if (!d0 || !d1) return;          /* both rings always exist */

        while (nsmp) {
            uint32_t room = ringsz - rcount;
            uint32_t run  = ringsz - rhead;    /* up to the end of the ring */
            uint8_t *q0, *q1;

            if (!room) { dbg_lost++; break; }
            if (run  > room) run  = room;
            if (run  > nsmp) run  = nsmp;

            q0 = d0 + rhead;
            q1 = d1 + rhead;
            rhead  += run;
            if (rhead == ringsz) rhead = 0;    /* instead of modulo */
            rcount += run;
            dbg_bytes += run;
            nsmp   -= run;

            /* One minimal loop of its own per format. */
            if (a_bits == 8) {
                if (a_chans == 2) {
                    uint32_t k = run;
                    while (k--) { *q0++ = (uint8_t)(sp[0] ^ 0x80);
                                  *q1++ = (uint8_t)(sp[1] ^ 0x80); sp += 2; }
                } else {
                    uint32_t k = run;
                    while (k--) { uint8_t v = (uint8_t)(*sp++ ^ 0x80);
                                  *q0++ = v; *q1++ = v; }
                }
            } else {
                if (a_chans == 2) {
                    uint32_t k = run;
                    while (k--) { *q0++ = sp[1]; *q1++ = sp[3]; sp += 4; }
                } else {
                    uint32_t k = run;
                    while (k--) { uint8_t v = sp[1]; sp += 2;
                                  *q0++ = v; *q1++ = v; }
                }
            }
        }
    }
}

#else   /* host stubs */

int      audio_open(uint32_t r, uint32_t c, uint32_t b) { (void)r;(void)c;(void)b; return 0; }
void     audio_close(void) { }
void     audio_write(const uint8_t *p, uint32_t n) { (void)p; (void)n; }
uint32_t audio_rate(void) { return 0; }
uint32_t audio_dbg_mask(void)   { return 0; }
uint32_t audio_dbg_samples(void){ return 0; }
uint32_t audio_dbg_sent(void)   { return 0; }
uint32_t audio_dbg_blocked(void){ return 0; }
uint32_t audio_dbg_lost(void)   { return 0; }
uint32_t audio_dbg_under(void)  { return 0; }
void     audio_ende(void)       { }
uint32_t audio_eff_rate(void)   { return 0; }
uint32_t audio_period(void)     { return 0; }
uint32_t audio_clock(void)      { return 0; }
void     audio_service(void)    { }
uint32_t audio_played_samples(void) { return 0; }
uint32_t audio_dbg_checkio(void) { return 0; }
void     audio_config(uint32_t d, uint32_t n) { (void)d; (void)n; }
uint32_t audio_dbg_minpend(void) { return 0; }
uint32_t audio_dbg_maxring(void) { return 0; }
uint32_t audio_dbg_bufsz(void)   { return 0; }
uint32_t audio_dbg_nbuf(void)    { return 0; }

#endif
