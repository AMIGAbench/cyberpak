/* yuv.h - colour tables of the original (misc/YUVStuff.mod).
 *
 * These tables DEFINE the golden reference: every deviation here changes every
 * decoded pixel. They are therefore taken over 1:1 from the original,
 * inklusive seiner Eigenheiten (siehe yuv.c).
 */
#ifndef CYBERPAK_YUV_H
#define CYBERPAK_YUV_H

#include <stdint.h>

#define YUV_MAX_JSAMPLE     255
#define YUV_CENTER_JSAMPLE  128
#define YUV_RNGLIMIT_SIZE   (5 * (YUV_MAX_JSAMPLE + 1) + YUV_CENTER_JSAMPLE)  /* 1408 */
#define YUV_RNGLIMIT_BIAS   (YUV_MAX_JSAMPLE + 1)                             /* 256  */

typedef struct {
    int32_t ubTab[256];   /* U -> Blue   */
    int32_t vrTab[256];   /* V -> Red    */
    int32_t ugTab[256];   /* U -> Green  */
    int32_t vgTab[256];   /* V -> Green  */
    int32_t yTab[256];    /* Y skaliert  */
} yuv_table;

/* Checksums of the generated tables (sum = sum*31 + value).
 * Produced from the same formula; every deviation between the host and the
 * m68k build (soft float, floor vs trunc, rounding) shows up at once. */
#define YUV_SUM_UB 0xea82e896u
#define YUV_SUM_VR 0xbd6fb31cu
#define YUV_SUM_UG 0x3a259480u
#define YUV_SUM_VG 0xcddbcf06u
#define YUV_SUM_Y  0x899b1800u

/* Both getters are idempotent and return module-global singletons, exactly like
 * GenYUVTables()/InitLimitTables() in the original. */
const yuv_table *yuv_tables(void);

/* Clamp table, offset by -256: rngLimit[-256 .. +1151] is valid. That way
 * rngLimit[x] clamps without a sign check - which is exactly what the dither
 * macros need, as they add an error term. */
const uint8_t *yuv_rnglimit(void);

/* The same clamp table, but shifted per colour channel to the right byte
 * position of an ARGB longword - offset by -256 as well.
 *
 * That turns
 *     PACK_ARGB(rng[a], rng[b], rng[c])
 * into a mere
 *     r[a] | g[b] | c[b]
 * On 68020/030 that saves three `andi.l #255` per pixel (the `move.b` leaves
 * the upper 24 bits standing), one `swap`, one `clr.w` and one `lsl.l #8` -
 * measured about 112 cycles per codebook entry at 332 entries per frame.
 *
 * The values are identical to PACK_ARGB by construction, because PACK4B only
 * ors disjoint byte fields; the byte order sits in PACK_ARGB itself and is
 * therefore right on both platforms. Cost: 3 x 1408 x 4 = 16.5 KB. */
typedef struct {
    const uint32_t *r, *g, *b;
} yuv_rngargb;

const yuv_rngargb *yuv_rngargb_tables(void);

/* The same for 16 bit per pixel. `fmt` is one of the CVX_PIX16_* from cpu.h.
 * The values are zero-extended in a uint32, so that two of them can be
 * combined into one longword with PACK2PX.
 *
 * The trick with the PC formats: R, G and B occupy disjoint bit fields, and
 * swapping bytes maps disjoint fields to disjoint ones again. Swapping per
 * table therefore yields the same as swapping the finished pixel - and costs
 * nothing in the hot path. */
const yuv_rngargb *yuv_rng16_tables(int fmt);

/* Self test: checks the tables against hard-wired checksums.
 * Catches every deviation between the host and the m68k build at once
 * (Soft-Float, Rundung, floor-vs-trunc). 0 = ok. */
int yuv_selftest(void);

#endif
