/* bigcbcheck - does a codebook that is too large write past its block?
 *
 * The FULL codebook form (0x2000/0x2200) computed `n = cSize / 6` and
 * wrote n entries without limiting them to 256. `cSize` comes from the
 * bitstream and can become up to 65531 - so up to 10921 entries into an
 * array of 256. The partial form has always checked it, the full one has not.
 *
 * It does not occur in real material. That is exactly why this test is
 * needed: tests/mkbigcb.py produces a stream with 2048 entries per chunk,
 * eight times too many, right in the first strip.
 *
 * It is built with AddressSanitizer - without the clamp it aborts there
 * with "heap-buffer-overflow", with it it runs through.
 *
 * Call: bigcbcheck <file.cpks>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cpu.h"
#include "codec/cvid.h"

int main(int argc, char **argv)
{
    FILE *f; long n; uint8_t *data, *fb;
    cvid_ctx *ctx;
    const uint32_t w = 320, h = 192, stride = 320;
    int rc;

    if (argc < 2) { puts("usage: bigcbcheck <frame.cvid>"); return 2; }
    f = fopen(argv[1], "rb");
    if (!f) { puts("not readable"); return 2; }
    fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET);
    data = (uint8_t *)malloc((size_t)n);
    if (!data || fread(data, 1, (size_t)n, f) != (size_t)n) return 2;
    fclose(f);

    fb  = (uint8_t *)calloc((size_t)stride * h, 1);
    ctx = cvid_open(w, h, CVID_OUT_GRAY8);
    if (!fb || !ctx) { puts("no memory"); return 2; }

    rc = cvid_decode(ctx, data, (uint32_t)n, fb, stride);

    printf("  bigcb  %ld bytes, rc=%d, no overflow\n", n, rc);
    cvid_close(ctx); free(fb); free(data);
    return 0;
}
