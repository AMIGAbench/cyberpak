/* readbench - measures ONLY the read path, without decoder and without display.
 *
 * Why a program of its own: the costs of the read path are two quite
 * different things on the Amiga, and in the player they sit together under a
 * single number ("disk") along with sound and display:
 *
 *   1. Read() calls. Each one is a DOS packet to the file system task,
 *      so a task switch there and back. Their NUMBER counts, not the
 *      amount.
 *   2. memcpy from the read buffer into the target memory. Pure CPU work,
 *      and on a 68000 with a 16-bit bus the more expensive half.
 *
 * Both are counted separately here, so that a change to the read path is
 * provable instead of plausible. Nothing is decoded on purpose - the decoder
 * would cover the measurement by an order of magnitude.
 *
 * Call: readbench <file.cpks> [noser]
 */
#include <stdlib.h>
#include <string.h>

#include "cpu.h"
#include "plat.h"
#include "timing.h"
#include "cpks.h"

static char obuf[200];
static uint32_t sink_bytes, sink_hash = 2166136261u;

/* The sound IS HASHED ALONG - otherwise it would go unnoticed if the callback
 * pointed at different bytes on the new path. That is exactly the risky spot. */
static void sink(const uint8_t *p, uint32_t n)
{
    uint32_t i;
    sink_bytes += n;
    for (i = 0; i < n; i++) sink_hash = (sink_hash ^ p[i]) * 16777619u;
}

static char *pstr(char *p, const char *s) { while (*s) *p++ = *s++; return p; }
static char *pnum(char *p, long v)
{
    char t[12]; int n = 0;
    if (v < 0) { *p++ = '-'; v = -v; }
    do { t[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (n) *p++ = t[--n];
    return p;
}
static void emit(char *end) { *end = 0; PLAT_PUTS(obuf); }

/* Milliseconds from ticks, without a 64-bit division in the body. */
static long ticks_ms(uint64_t t, uint32_t freq)
{
    if (!freq) return 0;
    return (long)((t * 1000u) / freq);
}

static char *phex(char *p, unsigned long v)
{
    int i;
    for (i = 28; i >= 0; i -= 4) *p++ = "0123456789abcdef"[(v >> i) & 15];
    return p;
}

/* One run with a particular layout.
 *
 * The hash runs over the DELIVERED frame bytes and over everything that
 * went to the audio callback. It is thus the proof that the change of the
 * read path does not change the stream: every row of the table has to show the
 * same hash, only time and counters may differ. */
static int run_cpks(const char *fn, uint32_t fill, uint32_t direct)
{
    cpks_stream *s;
    int err;
    uint32_t frames = 0, freq;
    char *p;

    sink_bytes = 0;
    sink_hash  = 2166136261u;
    cpks_tune(fill, direct);

    s = cpks_open(fn, 0, &err);
    if (!s) {
        p = pstr(obuf, "[FAIL] cpks_open rc="); p = pnum(p, err);
        *p++ = '\n'; emit(p); return 1;
    }
    freq = timing_freq();

    for (;;) {
        const uint8_t *d; uint32_t l; uint32_t i;
        cpks_pump(s, sink);
        if (!cpks_next_video(s, &d, &l, NULL, NULL)) break;
        for (i = 0; i < l; i++) sink_hash = (sink_hash ^ d[i]) * 16777619u;
        frames++;
    }

    p = obuf;
    p = pstr(p, "  fill=");        p = pnum(p, (long)fill);
    p = pstr(p, " direct=");       p = pnum(p, (long)direct);
    p = pstr(p, " frames=");       p = pnum(p, (long)frames);
    p = pstr(p, " reads=");        p = pnum(p, (long)cpks_dbg_reads(s));
    p = pstr(p, " copied=");       p = pnum(p, (long)cpks_dbg_copied(s));
    p = pstr(p, " read_ms=");      p = pnum(p, ticks_ms(cpks_read_ticks(s), freq));
    p = pstr(p, " ton=");          p = pnum(p, (long)sink_bytes);
    p = pstr(p, " hash=");         p = phex(p, sink_hash);
    *p++ = '\n'; emit(p);
    cpks_close(s);
    return 0;
}

/* The layout is a question of measurement, so it is measured instead of
 * guessed. The first row is the OLD way (direct=0, 16 KB) and thus the
 * reference; all the others have to return the same hash. */
static const uint32_t sweep[][2] = {
    { 16384u,    0u },
    { 16384u, 3072u },
    {  8192u, 3072u },
    {  4096u, 3072u },
    {  2048u, 2048u },
    {  1024u, 1024u },
    {   512u,  512u },
    { 65536u,    0u },
    { 32768u, 3072u },
};

int main(int argc, char **argv)
{
    const char *fn;
    int rc;

    if (argc < 2) { PLAT_PUTS("[FAIL] usage: readbench <datei.cpks>\n"); return 1; }
    fn = argv[1];

    {
        int ai;
        for (ai = 2; ai < argc; ai++)
            if (argv[ai][0] == 'n' && argv[ai][1] == 'o' && argv[ai][2] == 's')
                plat_serial(0);
    }

    PLAT_PUTS("[BOOT] readbench\n");
    timing_open();

    {
        size_t i;
        rc = 0;
        for (i = 0; i < sizeof(sweep) / sizeof(sweep[0]) && !rc; i++)
            rc = run_cpks(fn, sweep[i][0], sweep[i][1]);
    }

    timing_close();
    if (!rc) PLAT_PUTS("[OK] done\n");
    return rc;
}
