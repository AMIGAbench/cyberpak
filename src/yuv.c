/* yuv.c - portiert aus misc/YUVStuff.mod:167-189 (InitLimitTables)
 *                  and misc/YUVStuff.mod:217-243 (GenYUVTables).
 *
 * The quirks of the original are DELIBERATE and have to be kept, otherwise
 * every pixel deviates:
 *
 *  - x = 2*cnt-255, not 2*(cnt-128). The chroma is pre-centred, and for
 *    cnt=128 this yields x=1 instead of 0 - an asymmetry of the original.
 *  - The +32 rounding (half an LSB at 6 fixed-point bits) is there for
 *    ub/vr/vg but missing for ug. No oversight: ugTab and vgTab are always
 *    added (DecodeCVID.c:423), so the rounding is needed only once.
 *  - yTab[c] = (c<<6) + (c>>2) = c*64.25, a slight contrast stretch.
 *  - ENTIER() in Oberon is floor(), not truncation. For the negative halves
 *    of ugTab/vgTab that makes a difference of 1.
 */
#include "yuv.h"
#include "cpu.h"   /* PACK_ARGB for the shifted tables */

static yuv_table  g_tab;
static uint8_t    g_samp[YUV_RNGLIMIT_SIZE];
static int        g_tab_done  = 0;
static int        g_samp_done = 0;

/* Abrundende Ganzzahldivision. C schneidet Richtung null ab, Oberons ENTIER
 * is floor(). For the negative halves of ugTab/vgTab that makes a difference
 * of exactly 1 - hence spelled out. */
static int32_t fdiv(int32_t num, int32_t den)
{
    int32_t q = num / den;
    if ((num % den) != 0 && ((num < 0) != (den < 0)))
        q--;
    return q;
}

const yuv_table *yuv_tables(void)
{
    int cnt;

    if (g_tab_done)
        return &g_tab;

    /* The factors of the original, exactly as fractions instead of floating
     *   ub = (1.77200/2)*64 + 0.5 =  14301/250
     *   vr = (1.40200/2)*64 + 0.5 =  11341/250
     *   ug = (0.34414/2)*64 + 0.5 =  71953/6250
     *   vg = (0.71414/2)*64 + 0.5 = 145953/6250
     *
     * Recomputed for all 1024 table values as identical to the double
     * variant. Integers have three advantages: no libm, no
     * mathieeedoubbas.library at program start (it is missing from the
     * A1200 kickstart and made the first emulator run fail), and no way for
     * the host and the m68k soft float to diverge.
     *
     * Groesster Zwischenwert: 145953*255 + 200000 < 2^26, passt in int32. */
    for (cnt = 0; cnt < 256; cnt++) {
        int32_t x = 2 * cnt - 255;
        g_tab.ubTab[cnt] = fdiv(  14301 * x + 250 * 32,   250);
        g_tab.vrTab[cnt] = fdiv(  11341 * x + 250 * 32,   250);
        g_tab.ugTab[cnt] = fdiv( -71953 * x,             6250);
        g_tab.vgTab[cnt] = fdiv(-145953 * x + 6250 * 32, 6250);
        g_tab.yTab[cnt]  = (int32_t)((uint32_t)cnt << 6) + (cnt >> 2);
    }
    g_tab_done = 1;
    return &g_tab;
}

const uint8_t *yuv_rnglimit(void)
{
    int cnt;
    uint8_t *t;

    if (g_samp_done)
        return g_samp + YUV_RNGLIMIT_BIAS;

    /* Built after the IJG libjpeg scheme:
     *   rngLimit[-256 ..   -1] = 0        (Unterlauf-Clamp)
     *   rngLimit[   0 ..  255] = 0..255   (identisch)
     *   rngLimit[ 256 ..  639] = 255      (Ueberlauf-Clamp)
     *   rngLimit[ 640 .. 1023] = 0
     *   rngLimit[1024 .. 1151] = 0..127   (Wrap-Bereich)
     */
    t = g_samp;
    for (cnt = 0; cnt <= YUV_MAX_JSAMPLE; cnt++)
        t[cnt] = 0;

    t = g_samp + (YUV_MAX_JSAMPLE + 1);
    for (cnt = 0; cnt <= YUV_MAX_JSAMPLE; cnt++)
        t[cnt] = (uint8_t)cnt;

    t += YUV_CENTER_JSAMPLE;
    for (cnt = YUV_CENTER_JSAMPLE; cnt < 2 * (YUV_MAX_JSAMPLE + 1); cnt++)
        t[cnt] = (uint8_t)YUV_MAX_JSAMPLE;

    for (cnt = 2 * (YUV_MAX_JSAMPLE + 1);
         cnt < 4 * (YUV_MAX_JSAMPLE + 1) - YUV_CENTER_JSAMPLE; cnt++)
        t[cnt] = 0;

    {
        int off = 4 * (YUV_MAX_JSAMPLE + 1) - YUV_CENTER_JSAMPLE;
        for (cnt = off; cnt < 4 * (YUV_MAX_JSAMPLE + 1); cnt++)
            t[cnt] = g_samp[YUV_MAX_JSAMPLE + 1 + cnt - off];
    }

    g_samp_done = 1;
    return g_samp + YUV_RNGLIMIT_BIAS;
}

/* --- Selbsttest -------------------------------------------------------- */

static uint32_t sum32(const int32_t *p, int n)
{
    uint32_t s = 0;
    int i;
    for (i = 0; i < n; i++)
        s = s * 31u + (uint32_t)p[i];
    return s;
}

int yuv_selftest(void)
{
    const yuv_table *t = yuv_tables();
    const uint8_t   *r = yuv_rnglimit();
    uint32_t s;
    int i;

    /* Spot checks with values recomputed by hand. */
    if (t->yTab[0]   != 0)      return 1;
    if (t->yTab[255] != 16383)  return 2;   /* 255*64 + 63 */
    if (t->yTab[4]   != 257)    return 3;   /* 4*64 + 1     */

    /* Clamp table: the five ranges. */
    if (r[-256] != 0)   return 10;
    if (r[-1]   != 0)   return 11;
    if (r[0]    != 0)   return 12;
    if (r[255]  != 255) return 13;
    if (r[256]  != 255) return 14;
    if (r[639]  != 255) return 15;
    if (r[640]  != 0)   return 16;
    if (r[1023] != 0)   return 17;
    if (r[1024] != 0)   return 18;
    if (r[1151] != 127) return 19;
    for (i = 0; i < 256; i++)
        if (r[i] != (uint8_t)i) return 20;

    /* Checksums of the four chroma tables - catches every rounding or soft
     * float deviation between the host and the m68k build. */
    s = sum32(t->ubTab, 256); if (s != YUV_SUM_UB) return 30;
    s = sum32(t->vrTab, 256); if (s != YUV_SUM_VR) return 31;
    s = sum32(t->ugTab, 256); if (s != YUV_SUM_UG) return 32;
    s = sum32(t->vgTab, 256); if (s != YUV_SUM_VG) return 33;
    s = sum32(t->yTab,  256); if (s != YUV_SUM_Y)  return 34;
    return 0;
}

/* --- shifted clamp tables per colour channel (see yuv.h) --------------- */
static uint32_t   g_rr[YUV_RNGLIMIT_SIZE];
static uint32_t   g_rg[YUV_RNGLIMIT_SIZE];
static uint32_t   g_rb[YUV_RNGLIMIT_SIZE];
static yuv_rngargb g_rngargb;
static int        g_rngargb_done;

const yuv_rngargb *yuv_rngargb_tables(void)
{
    const uint8_t *rng;
    int i;

    if (g_rngargb_done)
        return &g_rngargb;

    /* Build them unshifted, shift only when handing them out - exactly as
     * yuv_rnglimit() es haelt. */
    rng = yuv_rnglimit() - YUV_RNGLIMIT_BIAS;
    for (i = 0; i < YUV_RNGLIMIT_SIZE; i++) {
        g_rr[i] = PACK_ARGB(rng[i], 0, 0);
        g_rg[i] = PACK_ARGB(0, rng[i], 0);
        g_rb[i] = PACK_ARGB(0, 0, rng[i]);
    }
    g_rngargb.r = g_rr + YUV_RNGLIMIT_BIAS;
    g_rngargb.g = g_rg + YUV_RNGLIMIT_BIAS;
    g_rngargb.b = g_rb + YUV_RNGLIMIT_BIAS;
    g_rngargb_done = 1;
    return &g_rngargb;
}

/* --- shifted clamp tables for 16 bit (see yuv.h) ----------------------- */
static uint32_t   g_16r[YUV_RNGLIMIT_SIZE];
static uint32_t   g_16g[YUV_RNGLIMIT_SIZE];
static uint32_t   g_16b[YUV_RNGLIMIT_SIZE];
static yuv_rngargb g_rng16;
static int        g_rng16_fmt = -1;

static uint32_t swap16(uint32_t v)
{
    return ((v >> 8) & 0x00ffu) | ((v << 8) & 0xff00u);
}

const yuv_rngargb *yuv_rng16_tables(int fmt)
{
    const uint8_t *rng;
    int i, pc, g6;

    if (g_rng16_fmt == fmt)
        return &g_rng16;

    pc = (fmt == CVX_PIX16_R5G6B5PC || fmt == CVX_PIX16_R5G5B5PC);
    g6 = (fmt == CVX_PIX16_R5G6B5   || fmt == CVX_PIX16_R5G6B5PC);

    rng = yuv_rnglimit() - YUV_RNGLIMIT_BIAS;
    for (i = 0; i < YUV_RNGLIMIT_SIZE; i++) {
        uint32_t v = rng[i];
        uint32_t r = (v >> 3) << (g6 ? 11 : 10);
        uint32_t g = g6 ? ((v >> 2) << 5) : ((v >> 3) << 5);
        uint32_t b = (v >> 3);
        g_16r[i] = pc ? swap16(r) : r;
        g_16g[i] = pc ? swap16(g) : g;
        g_16b[i] = pc ? swap16(b) : b;
    }
    g_rng16.r = g_16r + YUV_RNGLIMIT_BIAS;
    g_rng16.g = g_16g + YUV_RNGLIMIT_BIAS;
    g_rng16.b = g_16b + YUV_RNGLIMIT_BIAS;
    g_rng16_fmt = fmt;
    return &g_rng16;
}
