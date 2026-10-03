/* cvidbench - decode, check and measure Cinepak.
 *
 * Purpose 1 (correctness): prints the same FNV-1a hash as the x86 build.
 *   Since both builds use the same source, the tolerance is exactly 0 -
 *   every deviation is a bug (endianness, signed shift, padding).
 * Purpose 2 (performance): measures the pure decoding time through EClock,
 *   without display and without I/O.
 *
 * Call: cvidbench <file.avi|file.cpks> [gray|hi] [perframe] [noser] [N]
 *   gray = 8 bit grey levels, hi = 16 bit, otherwise 32 bit
 *   N    = only the first N frames (a purely numeric argument)
 *
 * WHY THE FRAME LIMIT EXISTS: fb_hash() runs over the whole framebuffer per
 * frame, with a 32-bit multiplication per byte - on the 68000 that is
 * MORE EXPENSIVE than the decoding itself. At 320x180 CLUT8 and 120 frames
 * it is about 90 s for the checking alone, and the run ran into the timeout
 * of the harness. That looked like a crash of the decoder and was none.
 * Twenty frames are enough for a hash comparison and a time measurement.
 *
 * CPKS is read frame by frame through src/cpks.c, the same reader as in the
 * player - with a 64 KB read buffer and one queue slot. What is measured
 * is nevertheless ONLY the decoding time: reading happens outside the clock.
 *
 * cvidbench used to load CPKS into ONE memory block in full as well. On a
 * real A600 (68000, 28 MHz) that ended with "AllocVec fehlgeschlagen - zu
 * wenig freier Speicher" while the player played the same file; in the
 * emulator with 4 MB of fast RAM and small test clips it had never shown up.
 * AVI is still loaded whole - avi_open() needs the index -, but AVI is
 * only the path of the golden hashes in the emulator now.
 */
#include <stdlib.h>
#include <string.h>

#include "cpu.h"
#include "plat.h"
#include "avi.h"
#include "bytes.h"
#include "yuv.h"
#include "timing.h"
#include "codec/cvid.h"
#include "cpks.h"

#ifdef __m68k__
#include <proto/dos.h>
#include <proto/exec.h>
#endif

static char obuf[256];

/* CPKS or AVI? Only the first four bytes - searching an AVI file through to
 * the sync word would be expensive on the 68000 in particular. */
static int is_cpks_file(const char *fn)
{
    uint8_t m[4];
#ifdef __m68k__
    BPTR fh = Open((CONST_STRPTR)fn, MODE_OLDFILE);
    LONG got;
    if (!fh) return 0;
    got = Read(fh, m, 4);
    Close(fh);
    if (got != 4) return 0;
#else
    FILE *f = fopen(fn, "rb");
    size_t got;
    if (!f) return 0;
    got = fread(m, 1, 4, f);
    fclose(f);
    if (got != 4) return 0;
#endif
    return m[0] == 'C' && m[1] == 'P' && m[2] == 'K' && m[3] == 'S';
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
static char *phex(char *p, unsigned long v)
{
    int i;
    for (i = 28; i >= 0; i -= 4) *p++ = "0123456789abcdef"[(v >> i) & 15];
    return p;
}
static void emit(char *end) { *end = 0; PLAT_PUTS(obuf); }

static uint32_t fb_hash(const uint8_t *fb, uint32_t w, uint32_t h,
                        uint32_t stride, uint32_t bpp)
{
    uint32_t hsh = 2166136261u, y, x;
    for (y = 0; y < h; y++) {
        const uint8_t *r = fb + (size_t)y * stride;
        for (x = 0; x < w * bpp; x++)
            hsh = (hsh ^ r[x]) * 16777619u;
    }
    return hsh;
}

/* Loads the file into memory in full.
 *
 * `why` gets a reason, so that a failure on real hardware is
 * diagnosable - "file not readable" alone helps nobody
 * along. */
/* On a failed AllocVec: what was asked for and what is free. */
static long g_fail_size, g_fail_largest;

static uint8_t *load(const char *fn, uint32_t *size, const char **why)
{
#ifdef __m68k__
    BPTR fh; uint8_t *buf; long n, got;

    *why = "?";
    fh = Open((CONST_STRPTR)fn, MODE_OLDFILE);
    if (!fh) { *why = "Open() fehlgeschlagen - Datei da? Pfad richtig?"; return NULL; }

    Seek(fh, 0, OFFSET_END);
    n = Seek(fh, 0, OFFSET_BEGINNING);
    if (n <= 0) { Close(fh); *why = "Datei ist leer"; return NULL; }

    buf = (uint8_t *)AllocVec((ULONG)n, MEMF_ANY);
    if (!buf) {
        Close(fh);
        g_fail_size    = n;
        g_fail_largest = (long)AvailMem(MEMF_ANY | MEMF_LARGEST);
        *why = "AllocVec fehlgeschlagen - zu wenig freier Speicher";
        return NULL;
    }

    got = Read(fh, buf, n);
    Close(fh);
    if (got != n) { FreeVec(buf); *why = "Read() unvollstaendig - Datei beschaedigt?"; return NULL; }

    *size = (uint32_t)n;
    return buf;
#else
    FILE *f = fopen(fn, "rb"); uint8_t *buf; long n;
    *why = "?";
    if (!f) { *why = "fopen fehlgeschlagen"; return NULL; }
    fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET);
    buf = (uint8_t *)malloc((size_t)n);
    if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n) {
        free(buf); fclose(f); *why = "Lesen fehlgeschlagen"; return NULL;
    }
    fclose(f); *size = (uint32_t)n; return buf;
#endif
}

int main(int argc, char **argv)
{
    uint8_t *data, *fb; uint32_t size, stride, w, h, bpp;
    avi_file av; cvid_ctx *ctx;
    cpks_stream *cs = 0;  int is_cpks;
    uint32_t total = 2166136261u;
    uint64_t t0, t1, elapsed = 0; uint32_t freq;
    int n = 0, gray = 0, perframe = 0, hi = 0, limit = 0;
    char *p;

    if (argc < 2) { PLAT_PUTS("[FAIL] usage: cvidbench <datei.avi|datei.cpks> [gray|hi]\n"); return 1; }
    gray = (argc > 2 && argv[2][0] == 'g');
    /* "hi" selects the 16-bit output mode - the path with the
     * assembler block loop. For the comparison against the C branch
     * (-DCVID_NO_ASM) the hash has to be identical. */
    {
        int ai;
        for (ai = 1; ai < argc; ai++)
            if (argv[ai][0] == 'h' && argv[ai][1] == 'i') hi = 1;
    }

    /* "noser" as any argument switches the serial output off.
     * On real hardware that saves wall clock time; the FS-UAE harness
     * needs it, by contrast, which is why it is on by default. */
    {
        int ai;
        for (ai = 1; ai < argc; ai++)
            if (argv[ai][0] == 'n' && argv[ai][1] == 'o' && argv[ai][2] == 's')
                plat_serial(0);
            else if (argv[ai][0] == 'p')       /* "perframe" */
                perframe = 1;
            else if (ai > 1 && argv[ai][0] >= '0' && argv[ai][0] <= '9')
                limit = atoi(argv[ai]);        /* frame limit */
    }

    if (yuv_selftest()) { PLAT_PUTS("[FAIL] yuv_selftest\n"); return 1; }

    /* The clock BEFORE opening: the CPKS reader measures its read time itself
     * with timing_now(), and without timer.device there would be a null pointer. */
    timing_open();
    freq = timing_freq();

    is_cpks = is_cpks_file(argv[1]);
    if (is_cpks) {
        int err;
        const cpks_info *ci;
        cs = cpks_open(argv[1], 1, &err);
        if (!cs) {
            p = pstr(obuf, "[FAIL] "); p = pstr(p, argv[1]); p = pstr(p, ": ");
            p = pstr(p, err == CPKS_ERR_OPEN   ? "Open() fehlgeschlagen - Datei da? Pfad richtig?"
                      : err == CPKS_ERR_MEMORY ? "zu wenig Speicher fuer Lesepuffer und Warteschlange"
                      :                          "kein brauchbares CPKS-Kopfpaket");
            *p++ = '\n'; emit(p);
            timing_close();
            return 1;
        }
        ci = cpks_get_info(cs);
        w = ci->width & ~3u; h = ci->height & ~3u;
        PLAT_PUTS("  CPKS wird bildweise gelesen\n");
    } else {
        const char *why;
        int arc;
        data = load(argv[1], &size, &why);
        if (!data) {
            p = pstr(obuf, "[FAIL] "); p = pstr(p, argv[1]);
            p = pstr(p, ": "); p = pstr(p, why);
            if (g_fail_size) {
                p = pstr(p, " (Datei "); p = pnum(p, g_fail_size);
                p = pstr(p, " Bytes, groesster freier Block "); p = pnum(p, g_fail_largest);
                p = pstr(p, " Bytes - auf echter Hardware CPKS verwenden)");
            }
            *p++ = '\n'; emit(p);
            timing_close();
            return 1;
        }
        p = pstr(obuf, "  Datei gelesen, "); p = pnum(p, (long)size);
        p = pstr(p, " Bytes\n"); emit(p);
        arc = avi_open(&av, data, size);
        if (arc != 0) {
            p = pstr(obuf, "[FAIL] weder CPKS noch brauchbares AVI (rc=");
            p = pnum(p, arc);
            p = pstr(p, arc == -1 ? ", kein RIFF/AVI-Kopf"
                                  : ", movi/Videospur nicht gefunden");
            p = pstr(p, ")\n"); emit(p);
            timing_close();
            return 1;
        }
        w = av.width & ~3u; h = av.height & ~3u;
    }

    bpp = gray ? 1u : (hi ? 2u : 4u);
    stride = STRIDE_ALIGN(w * bpp);

    ctx = cvid_open(w, h, gray ? CVID_OUT_GRAY8 : (hi ? CVID_OUT_RGB16 : CVID_OUT_RGB32));
    fb = (uint8_t *)calloc((size_t)stride * h, 1);
    if (!ctx || !fb) { PLAT_PUTS("[FAIL] kein Speicher fuer Decoder und Bildpuffer\n"); timing_close(); return 1; }

    p = pstr(obuf, "[BOOT] cvidbench "); p = pnum(p, (long)w); p = pstr(p, "x");
    p = pnum(p, (long)h);
    p = pstr(p, gray ? " gray  CPU_LEVEL=" : (hi ? " rgb16 CPU_LEVEL=" : " rgb32 CPU_LEVEL="));
    p = pnum(p, (long)CPU_LEVEL); *p++ = '\n'; emit(p);

    /* Measure the decoding time only. The hash runs over the complete
     * framebuffer (at 320x180 rgb32 that is 230 KB per frame) and would
     * otherwise dominate the measurement - the baseline would be useless. */
    for (;;) {
        const uint8_t *fd; uint32_t fs;
        if (limit && n >= limit) break;
        if (is_cpks) {
            /* Reading outside the clock. The pointer is valid until the next
             * cpks_pump(). */
            cpks_pump(cs, NULL);
            if (!cpks_next_video(cs, &fd, &fs, 0, 0)) break;
        }
        else         { if (!avi_next_video(&av, &fd, &fs)) break; }
        t0 = timing_now();
        cvid_decode(ctx, fd, fs, fb, stride);
        t1 = timing_now();
        elapsed += t1 - t0;
        {
            uint32_t fh = fb_hash(fb, w, h, stride, bpp);
            total = (total ^ fh) * 16777619u;
            /* Print per frame, so that on a deviation from the x86 build the
             * first differing frame can be narrowed down. The format is
             * identical to host/hostmain.c --hash. */
            if (perframe) {
                char *q = obuf;
                int k; long v = n;
                char t[8]; int tn = 0;
                do { t[tn++] = (char)('0' + v % 10); v /= 10; } while (v);
                for (k = tn; k < 5; k++) *q++ = ' ';
                while (tn) *q++ = t[--tn];
                *q++ = ' ';
                q = phex(q, fh);
                *q++ = '\n'; *q = 0;
                PLAT_PUTS(obuf);
            }
        }
        n++;
    }
    if (cs) cpks_close(cs);
    timing_close();

    p = pstr(obuf, "  frames="); p = pnum(p, n);
    p = pstr(p, " hash="); p = phex(p, total);
    if (freq && elapsed) {
        uint32_t ms = (uint32_t)((elapsed * 1000u) / freq);
        p = pstr(p, " decode_ms="); p = pnum(p, (long)ms);
        if (ms) {
            p = pstr(p, " fps="); p = pnum(p, (long)((n * 1000L) / (long)ms));
            p = pstr(p, " us/frame="); p = pnum(p, (long)((ms * 1000L) / n));
        }
    }
    *p++ = '\n'; emit(p);

    /* The hash is checked against tests/golden; the mark is set by
     * the test script, not by the program - it does not know the expected value. */
    PLAT_PUTS("[OK] done\n");
    return 0;
}
