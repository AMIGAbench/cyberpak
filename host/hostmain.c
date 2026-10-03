/* hostmain.c - x86-Harness.
 *
 * Builds the same decoder as the Amiga build and writes the decoded frames as
 * PPM or PGM. That is how the golden reference comes about, before
 * ueberhaupt AmigaOS-Code existiert:
 *
 *   stage A  --stats     counters per frame against an independent parser
 *   stage B  --pgm       Y plane against ffmpeg (tolerance 0 in the structure)
 *   stage C  --ppm       RGB, later bit-exact against the m68k build
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cpu.h"
#include "bytes.h"
#include "avi.h"
#include "yuv.h"
#include "codec/cvid.h"

/* FNV-1a over the visible image area (without stride padding), so that the
 * host and the m68k build have to deliver the same value. */
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

static uint8_t *slurp(const char *fn, uint32_t *size)
{
    FILE *f = fopen(fn, "rb");
    uint8_t *buf;
    long n;
    if (!f) return NULL;
    fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET);
    buf = (uint8_t *)malloc((size_t)n);
    if (!buf || fread(buf, 1, (size_t)n, f) != (size_t)n) { free(buf); fclose(f); return NULL; }
    fclose(f);
    *size = (uint32_t)n;
    return buf;
}

static void write_ppm(const char *dir, int idx, const uint8_t *fb,
                      uint32_t w, uint32_t h, uint32_t stride)
{
    char path[512];
    FILE *f;
    uint32_t y, x;
    snprintf(path, sizeof(path), "%s/f%05d.ppm", dir, idx);
    f = fopen(path, "wb");
    if (!f) return;
    fprintf(f, "P6\n%u %u\n255\n", w, h);
    for (y = 0; y < h; y++) {
        const uint8_t *row = fb + (size_t)y * stride;
        for (x = 0; x < w; x++)
            fwrite(row + x * 4 + 1, 1, 3, f);   /* A,R,G,B -> R,G,B */
    }
    fclose(f);
}

static void write_pgm(const char *dir, int idx, const uint8_t *fb,
                      uint32_t w, uint32_t h, uint32_t stride)
{
    char path[512];
    FILE *f;
    uint32_t y;
    snprintf(path, sizeof(path), "%s/f%05d.pgm", dir, idx);
    f = fopen(path, "wb");
    if (!f) return;
    fprintf(f, "P5\n%u %u\n255\n", w, h);
    for (y = 0; y < h; y++)
        fwrite(fb + (size_t)y * stride, 1, w, f);
    fclose(f);
}

int main(int argc, char **argv)
{
    const char *fn = NULL, *outdir = NULL;
    int want_stats = 0, want_ppm = 0, want_pgm = 0, want_hash = 0, maxframes = 1 << 30;
    uint8_t *data; uint32_t size;
    avi_file av;
    cvid_ctx *ctx;
    uint8_t *fb;
    uint32_t stride, w, h;
    int i, n = 0, rc;
    uint32_t total_hash = 2166136261u;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--stats"))      want_stats = 1;
        else if (!strcmp(argv[i], "--hash"))  want_hash = 1;
        else if (!strcmp(argv[i], "--gray"))  want_pgm = 2;
        else if (!strcmp(argv[i], "--ppm"))   { want_ppm = 1; outdir = argv[++i]; }
        else if (!strcmp(argv[i], "--pgm"))   { want_pgm = 1; outdir = argv[++i]; }
        else if (!strcmp(argv[i], "--frames")) maxframes = atoi(argv[++i]);
        else fn = argv[i];
    }
    if (!fn) { fprintf(stderr, "usage: %s [--stats] [--ppm DIR|--pgm DIR] [--frames N] file.avi\n", argv[0]); return 2; }

    if (yuv_selftest()) { fprintf(stderr, "yuv_selftest fehlgeschlagen\n"); return 3; }

    data = slurp(fn, &size);
    if (!data) { fprintf(stderr, "cannot read %s\n", fn); return 3; }

    if (avi_open(&av, data, size) != 0) { fprintf(stderr, "no usable AVI\n"); return 3; }

    fprintf(stderr, "AVI %ux%u  fourcc=%c%c%c%c  %u bit  %u Frames  %u us/Frame\n",
            av.width, av.height,
            (char)(av.compression >> 24), (char)(av.compression >> 16),
            (char)(av.compression >> 8),  (char)av.compression,
            av.bit_count, av.total_frames, av.micros_per_frame);

    if (av.compression != FOURCC('c','v','i','d') &&
        av.compression != FOURCC('C','V','I','D')) {
        fprintf(stderr, "not Cinepak\n"); return 3;
    }

    w = av.width & ~3u;
    h = av.height & ~3u;
    stride = STRIDE_ALIGN(w * (want_pgm ? 1u : 4u));

    ctx = cvid_open(w, h, want_pgm ? CVID_OUT_GRAY8 : CVID_OUT_RGB32);
    fb  = (uint8_t *)calloc((size_t)stride * h, 1);
    if (!ctx || !fb) return 3;

    if (want_stats)
        printf("frame strips cb_v4 cb_v1 blk_v4 blk_v1 skip adv trunc rc\n");

    for (;;) {
        const uint8_t *fdata; uint32_t fsize;
        const cvid_stats *st;
        if (n >= maxframes) break;
        if (!avi_next_video(&av, &fdata, &fsize)) break;
        rc = cvid_decode(ctx, fdata, fsize, fb, stride);
        st = cvid_last_stats(ctx);
        if (want_stats)
            printf("%5d %6u %5u %5u %6u %6u %4u %5u %5u %2d\n", n,
                   st->strips, st->cb_v4, st->cb_v1,
                   st->blk_v4, st->blk_v1, st->blk_skip, st->advances, st->truncated, rc);
        if (want_ppm) write_ppm(outdir, n, fb, w, h, stride);
        if (want_pgm == 1) write_pgm(outdir, n, fb, w, h, stride);
        if (want_hash) {
            uint32_t bpp = (want_pgm ? 1u : 4u);
            uint32_t fh = fb_hash(fb, w, h, stride, bpp);
            total_hash = (total_hash ^ fh) * 16777619u;
            printf("%5d %08lx\n", n, (unsigned long)fh);
        }
        n++;
    }

    if (want_hash) printf("TOTAL %08lx  (%d Frames)\n", (unsigned long)total_hash, n);
    fprintf(stderr, "%d Frames dekodiert\n", n);
    cvid_close(ctx);
    free(fb); free(data);
    return 0;
}
