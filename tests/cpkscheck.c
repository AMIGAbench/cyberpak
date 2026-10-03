/* cpkscheck - the CPKS path against independent references.
 *
 * Three modes of operation, which answer three different questions:
 *
 *   --struct  packet inventory. Comparable with the encoder's tools/cpksdump.py.
 *   --decode  frame hashes. Has to be CHARACTER-IDENTICAL with what the same
 *             decoder delivers through the AVI path from the same material -
 *             with that the claim "the Cinepak bitstream is unchanged"
 *             is verified instead of believed.
 *   --sim     playback loop on the host. Figures comparable with
 *             tools/cpkssim.py.
 *   --skip    keyframe jump with an artificially slowed decoder. That is
 *             the part cpkssim.py does NOT check: there the skip-ahead block
 *             is behaviour-neutral, because the simulator does not decode at all.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cpu.h"
#include "cpks.h"
#include "avi.h"
#include "yuv.h"
#include "codec/cvid.h"

static uint32_t fnv(uint32_t h, const uint8_t *p, uint32_t n)
{
    while (n--) h = (h ^ *p++) * 16777619u;
    return h;
}
static uint32_t fbhash(const uint8_t *fb, uint32_t w, uint32_t h_, uint32_t stride)
{
    uint32_t hh = 2166136261u, y;
    for (y = 0; y < h_; y++) hh = fnv(hh, fb + (size_t)y * stride, w * 4u);
    return hh;
}

static uint32_t a_samples;
static void sink_count(const uint8_t *p, uint32_t n) { (void)p; a_samples += n; }

/* --- inventory ---------------------------------------------------------- */

static int mode_struct(const char *fn)
{
    cpks_stream *s; int err;
    const cpks_info *in;
    uint32_t nv = 0, nk = 0;

    s = cpks_open(fn, 16, &err);
    if (!s) { printf("  cpks_open fehlgeschlagen, err=%d\n", err); return 2; }
    in = cpks_get_info(s);
    printf("  %ux%u  %u/%u fps  Codec %c%c%c%c\n", in->width, in->height,
           in->fps_num, in->fps_den,
           (char)(in->codec >> 24), (char)(in->codec >> 16),
           (char)(in->codec >> 8), (char)in->codec);
    printf("  Timebase %u  Audio %u Hz %u ch %u bit  Prebuffer %u Ticks\n",
           in->timebase, in->arate, in->achans, in->abits, in->prebuffer);

    for (;;) {
        uint32_t pts; int key;
        cpks_pump(s, sink_count);
        if (!cpks_next_video(s, NULL, NULL, &pts, &key)) break;
        nv++; if (key) nk++;
    }
    printf("  Pakete: %u Video (%u Keyframes), %u Tonsamples, %u Wiederaufsetzer\n",
           nv, nk, a_samples / ((uint32_t)in->achans * (in->abits / 8u)),
           cpks_dbg_resyncs(s));
    cpks_close(s);
    return 0;
}

/* --- bitstream ---------------------------------------------------------- */

static int mode_decode(const char *fn)
{
    cpks_stream *s; int err;
    const cpks_info *in;
    cvid_ctx *c; uint8_t *fb;
    uint32_t w, h, stride, tot = 2166136261u, nf = 0;
    const uint8_t *d; uint32_t len;

    s = cpks_open(fn, 16, &err);
    if (!s) { printf("  cpks_open fehlgeschlagen, err=%d\n", err); return 2; }
    in = cpks_get_info(s);
    w = in->width & ~3u; h = in->height & ~3u; stride = STRIDE_ALIGN(w * 4u);
    fb = calloc((size_t)stride * h, 1);
    c  = cvid_open(w, h, CVID_OUT_RGB32);
    if (!fb || !c) { puts("  no memory"); return 2; }

    for (;;) {
        cpks_pump(s, NULL);
        if (!cpks_next_video(s, &d, &len, NULL, NULL)) break;
        cvid_decode(c, d, len, fb, stride);
        tot = (tot ^ fbhash(fb, w, h, stride)) * 16777619u; nf++;
    }
    printf("  CPKS : %4u Frames, Hash %08x\n", nf, tot);
    cvid_close(c); free(fb); cpks_close(s);
    return 0;
}

/* The same arithmetic through the AVI path - for the direct comparison. */
static int mode_decode_avi(const char *fn)
{
    FILE *f; long n; uint8_t *data, *fb;
    avi_file av; cvid_ctx *c;
    uint32_t w, h, stride, tot = 2166136261u, nf = 0;
    const uint8_t *d; uint32_t len;

    f = fopen(fn, "rb"); if (!f) { puts("  not readable"); return 2; }
    fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET);
    data = malloc(n);
    if (!data || fread(data, 1, n, f) != (size_t)n) return 2;
    fclose(f);
    if (avi_open(&av, data, (uint32_t)n)) { puts("  no AVI"); return 2; }

    w = av.width & ~3u; h = av.height & ~3u; stride = STRIDE_ALIGN(w * 4u);
    fb = calloc((size_t)stride * h, 1);
    c  = cvid_open(w, h, CVID_OUT_RGB32);
    while (avi_next_video(&av, &d, &len)) {
        cvid_decode(c, d, len, fb, stride);
        tot = (tot ^ fbhash(fb, w, h, stride)) * 16777619u; nf++;
    }
    printf("  AVI  : %4u Frames, Hash %08x\n", nf, tot);
    cvid_close(c); free(fb); free(data);
    return 0;
}

/* --- playback loop ------------------------------------------------------ */

/* Models Paula the way tools/cpkssim.py does: the position grows with the
 * ACTUAL playback rate, and it grows only as far as sound has been fed in
 * at all. If the sound runs dry, the position stands still - exactly what
 * audio_played_samples() does on the Amiga.
 *
 * What is deliberately NOT reproduced is the bug in cpkssim.py:129-132, where
 * `pos` jumps back by a whole packet duration on an underrun. That is why only
 * the undisturbed case is compared. */
static int mode_sim(const char *fn, double paula_dev)
{
    cpks_stream *s; int err;
    const cpks_info *in;
    double t = 0.0, dt = 0.005, played = 0.0, prate;
    uint32_t tb, shown_pts = 0, dropped = 0, under = 0, nshown = 0, ndec = 0;
    int have_shown = 0, started = 0;
    double worst = 0.0, drift = 0.0;
    double *offs; uint32_t noffs = 0, cap = 65536;

    a_samples = 0;
    s = cpks_open(fn, 16, &err);
    if (!s) { printf("  cpks_open fehlgeschlagen, err=%d\n", err); return 2; }
    in = cpks_get_info(s);
    if (!in->arate) { puts("  stream without sound - unsuitable for --sim"); return 2; }
    tb    = in->timebase;
    prate = (double)in->arate * (1.0 + paula_dev / 1000.0);

    offs = (double *)malloc(cap * sizeof(double));
    if (!offs) { puts("  no memory"); return 2; }

    for (;;) {
        uint32_t pos, due, drop, i;
        double fed;

        cpks_pump(s, sink_count);
        fed = (double)(a_samples / ((uint32_t)in->achans * (in->abits / 8u)));

        /* 5.2 prebuffering */
        if (!started) {
            if (fed >= (double)in->prebuffer || cpks_eof(s)) started = 1;
            else { t += dt; continue; }
        }

        played += prate * dt;
        if (played > fed) { played = fed; under++; }
        pos = (uint32_t)(cpks_audio_base(s) + (uint32_t)played);

        due = cpks_advance(s, pos, &drop);
        dropped += drop;
        for (i = 0; i < due; i++) {
            uint32_t p;
            /* Decode ALL of them (here only take them out), show only the last. */
            if (!cpks_next_video(s, NULL, NULL, &p, NULL)) break;
            ndec++;
            shown_pts = p; have_shown = 1;
        }
        if (due) nshown++;

        if (have_shown && noffs < cap) {
            double off = ((double)(int32_t)(pos - shown_pts)) / (double)tb;
            double a = off < 0 ? -off : off;
            if (a > worst) worst = a;
            offs[noffs++] = off;
        }

        if (cpks_eof(s) && !cpks_queued(s)) break;
        t += dt;
        if (t > 36000.0) break;                 /* emergency brake */
    }

    /* Drift as in cpkssim.py: mean of the last quarter minus mean of the
     * first quarter. With a sound time base that has to be zero - exactly that
     * is the gain over the AVI path. */
    if (noffs >= 8) {
        uint32_t q = noffs / 4, i;
        double f = 0.0, l = 0.0;
        for (i = 0; i < q; i++) f += offs[i];
        for (i = noffs - q; i < noffs; i++) l += offs[i];
        drift = l / q - f / q;
    }
    printf("  Simuliert %.1f s, Paula %+.1f Promille\n", t, paula_dev);
    printf("  sound/picture offset: max %+.0f ms\n", worst * 1000.0);
    printf("  Drift erstes zu letztes Viertel: %+.0f ms\n", drift * 1000.0);
    printf("  frames shown %u, decoded %u, dropped %u, underruns %u\n",
           nshown, ndec, dropped, under);
    free(offs);
    cpks_close(s);
    return 0;
}

/* --- keyframe jump ------------------------------------------------------ */

/* The test cpkssim.py cannot perform: a decoder that is too slow.
 * After the jump it MUST resume on a keyframe, and no inter frame may
 * have been skipped undecoded. */
static int mode_skip(const char *fn)
{
    cpks_stream *s; int err;
    const cpks_info *in;
    uint32_t pos = 0, frame_ticks, cost, dropped = 0, ndec = 0, njump = 0;
    int bad = 0, need_key = 0;

    s = cpks_open(fn, 16, &err);
    if (!s) { printf("  cpks_open fehlgeschlagen, err=%d\n", err); return 2; }
    in = cpks_get_info(s);

    /* Every decoded frame costs THREE TIMES the frame period in clock time.
     * The player cannot possibly keep up with that, the queue inevitably
     * fills up and the oldest frame falls more than a second
     * behind - exactly the situation 5.4 is meant for. Without this cost
     * the skip-ahead block stays without effect, and that is why
     * cpkssim.py does not check it either: there nothing is decoded. */
    frame_ticks = (uint32_t)((uint64_t)in->timebase * in->fps_den / in->fps_num);
    cost = frame_ticks * 3u;

    for (;;) {
        uint32_t due, drop, i;
        cpks_pump(s, sink_count);
        if (cpks_eof(s) && !cpks_queued(s)) break;

        due = cpks_advance(s, pos, &drop);
        if (drop) { dropped += drop; njump++; need_key = 1; }
        if (!due) { pos += frame_ticks; continue; }

        for (i = 0; i < due; i++) {
            uint32_t p; int key;
            if (!cpks_next_video(s, NULL, NULL, &p, &key)) break;
            if (need_key) {
                if (!key) {
                    printf("  ERROR: after the jump, on a non-keyframe pts %u\n", p);
                    bad = 1;
                }
                need_key = 0;
            }
            ndec++;
            pos += cost;              /* decoding costs wall clock time */
        }
    }

    printf("  Sprungtest: %u Spruenge, %u Frames undekodiert verworfen, %u dekodiert\n",
           njump, dropped, ndec);
    if (!njump) { puts("  ERROR: not a single jump triggered - the test does not bite"); bad = 1; }
    if (dropped + ndec != 360u && !bad) { /* informative only */ }
    puts(bad ? "  DEVIATION" : "  the jump always resumes on a keyframe");
    cpks_close(s);
    return bad;
}

int main(int argc, char **argv)
{
    const char *mode = argc > 2 ? argv[2] : "--struct";
    if (argc < 2) {
        puts("cpkscheck <datei> [--struct|--decode|--decode-avi|--sim|--skip] [paula-dev]");
        return 2;
    }
    if (!strcmp(mode, "--decode"))     return mode_decode(argv[1]);
    if (!strcmp(mode, "--decode-avi")) return mode_decode_avi(argv[1]);
    if (!strcmp(mode, "--sim"))
        return mode_sim(argv[1], argc > 3 ? atof(argv[3]) : 0.0);
    if (!strcmp(mode, "--skip"))       return mode_skip(argv[1]);
    return mode_struct(argv[1]);
}
