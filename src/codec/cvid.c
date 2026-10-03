/* cvid.c - Cinepak decoder, instantiation of the output modes.
 *
 * The bitstream parser stands exactly once in cvid_body.h and is instantiated
 * here with different block and codebook macros for each output mode.
 */
#include <stdlib.h>
#include <string.h>

#include "cpu.h"
#include "bytes.h"
#include "yuv.h"
#include "codec/cvid.h"
#include "codec/cvid_asm.h"

/* One codebook entry, uniformly 16 bytes instead of the original's 80
 * (decoder/txt/DecodeCVID.c:20-26, where 16 ulong fields each hold one byte of
 * payload). What matters is not the memory but the cache: the block loop
 * indexes into a 256-entry book at random with a bitstream byte. Both active
 * books together were 40 KB and fitted into no 68k data cache (68030: 256 B,
 * 68040: 4 KB, 68060: 8 KB); now it is 8 KB.
 *
 * The meaning of the four longwords depends on the mode:
 *   RGB32  px[0..3] = the four pixels of the 2x2 pattern, each 0x00RRGGBB
 *   GRAY8  V1: row[0..3] = the four finished output rows
 *          V4: hi[0],hi[1],lo[0],lo[1] = pixel pairs for upper/lower half
 */
/* CVID_LEGACY_CB=1 inflates the entry to the original's 80 bytes without
 * changing anything else. That makes the pure cache effect of the layout
 * measurable, separated from everything else. */
#if defined(CVID_LEGACY_CB) && CVID_LEGACY_CB
typedef struct { uint32_t q[4]; uint32_t pad[16]; } cvid_cb;   /* 80 B */
#else
typedef struct { uint32_t q[4]; } cvid_cb;                     /* 16 B */
#endif

struct cvid_ctx {
    uint32_t          width, height;
    cvid_outmode      mode;
    const yuv_table  *yt;
    const uint8_t    *rng;
    const yuv_rngargb *rngargb;
    const yuv_rngargb *rng16;      /* CVID_OUT_RGB16 only */
    int                pix16;
    int                gsh;        /* CVID_OUT_GRAY8 only: Y >> gsh */

    cvid_cb  *maps0[CVID_MAX_STRIPS];   /* V4 */
    cvid_cb  *maps1[CVID_MAX_STRIPS];   /* V1 */
    uint8_t   vmap0[CVID_MAX_STRIPS];
    uint8_t   vmap1[CVID_MAX_STRIPS];
    cvid_cb  *pool;

    uint32_t  yTop;
    uint32_t  last_size;

    /* One byte per block row (4 picture rows). The block writers set it,
     * cvid_decode() clears it at the start of every frame. See
     * cvid_dirty_rows() in cvid.h. */
    uint8_t  *dirty;
    uint32_t  nrows;

    cvid_stats st;
};

#define CVID_CB cvid_cb

/* Does this build keep dirty rows at all? See the reasoning at the GRAY8
 * block further down. What matters is the consequence for the caller: if it
 * is 0, cvid_dirty_rows() returns NULL - because an array full of zeroes
 * would mean "nothing has changed", and the output path would convert
 * nothing at all any more. */
#if defined(__m68k__) && defined(CPU_LEVEL) && CPU_LEVEL < 20
#  define CVID_DIRTY_AVAILABLE 0
#else
#  define CVID_DIRTY_AVAILABLE 1
#endif

/* --- P3: statistics counters only where they are needed ----------------
 *
 * `ctx->st.advances++` ran on EVERY block, plus one of
 * blk_v1/blk_v4/blk_skip - that makes 7200 read-modify-write memory accesses
 * per frame at 320x180. The 68020 has no data cache, the 68030 a
 * write-through one: every one of them is a real bus cycle. Measured about
 * 80,000 cycles per frame.
 *
 * The side effect weighs heavier: for these counters alone `ctx` had to stay
 * in an address register permanently. With seven address registers in use
 * (four row pointers, bitstream, two codebook bases) that forced spills onto
 * the stack in the gray8 path.
 *
 * The counters are read solely by host/hostmain.c - that is, by stage A of the
 * verification against tools/refdec.py. There they stay on. */
#ifndef CVID_STATS
#  ifdef __m68k__
#    define CVID_STATS 0
#  else
#    define CVID_STATS 1
#  endif
#endif
#if CVID_STATS
#  define CVID_ST(stmt) do { stmt; } while (0)
#else
#  define CVID_ST(stmt) do { } while (0)
#endif

/* Block advance.
 *
 * Normal case: pure pointer addition, the row break adds `wrap`, which is
 * computed once per frame.
 *
 * CVID_LEGACY_ADDR=1 restores the original's arithmetic
 * (DecodeCVID.c:11-14 plus :441 etc.): keep x/y and from them form, per block,
 * to+(y*stride)+x*bpp. On the 68000 that becomes a __mulsi3 call
 * per block. Serves only to measure the gain. */
#if defined(CVID_LEGACY_ADDR) && CVID_LEGACY_ADDR
#define CVID_BLOCKINC()                                   \
    do {                                                  \
        CVID_ST(ctx->st.advances++);                      \
        x += 4;                                           \
        if (x >= width) { x = 0; yy += 4; CVID_NEXTROW(); } \
        p0 = dst + (uint32_t)yy * stride + x * CVID_BPP;   \
        p1 = p0 + stride; p2 = p1 + stride; p3 = p2 + stride; \
    } while (0)
#else
/* P4: a block counter counting down instead of `x >= width`.
 *
 * Previously `width` was fetched from memory per block - under the register
 * pressure gcc had put it on the stack, and the assembler held `cmp.l 68(sp),d1`
 * at every one of the 3600 blocks. A `subq.l #1,dN` + `bne` needs no
 * memory operand. */
#define CVID_BLOCKINC()                                   \
    do {                                                  \
        CVID_ST(ctx->st.advances++);                      \
        if (--bx) {                                       \
            p0 += binc; p1 += binc; p2 += binc; p3 += binc; \
        } else {                                          \
            bx = bcols;                                   \
            p0 += wrap; p1 += wrap; p2 += wrap; p3 += wrap; \
            CVID_NEXTROW();                               \
        }                                                 \
    } while (0)
#endif

/* --- common YUV arithmetic --------------------------------------------- *
 * Exactly like YUVtoRGB in decoder/txt/YUV.h:43-49: the chroma addends
 * once per entry, Y from yTab, >>6 as a fixed-point shift, rngLimit clamps
 * without a sign check. */

/* P5: instead of reading three times from the byte clamp table and shifting
 * the bytes into position by hand, the values are read from three longword
 * tables that already contain the shift. Out of
 *   move.b / andi.l #255 / swap / clr.w / lsl.l #8 / or.l  (per pixel)
 * comes
 *   move.l / or.l / or.l
 * The values are the same by construction - see yuv.h. */
#define CVID_RGB_OF(yy_, out_)                     \
    do {                                           \
        int32_t _y = yt->yTab[yy_];                \
        out_ = rngR[(_y + cr)  >> 6]               \
             | rngG[(_y + cg)  >> 6]               \
             | rngB[(_y + cbb) >> 6];              \
    } while (0)

/* ====================================================================== */
/* RGB32                                                                   */
/* ====================================================================== */

#define CVID_MKCB_RGB(e, y0, y1, y2, y3, u, v)                 \
    do {                                                       \
        int32_t cr  = yt->vrTab[v];                            \
        int32_t cg  = yt->ugTab[u] + yt->vgTab[v];             \
        int32_t cbb = yt->ubTab[u];                            \
        CVID_RGB_OF(y0, (e)->q[0]);                            \
        CVID_RGB_OF(y1, (e)->q[1]);                            \
        CVID_RGB_OF(y2, (e)->q[2]);                            \
        CVID_RGB_OF(y3, (e)->q[3]);                            \
    } while (0)

/* Color2x2Blk1RGB, DecodeCVID.c:433-462 */
#define CVID_PUT1_RGB(p0_, p1_, p2_, p3_, c)                   \
    do {                                                       \
        uint32_t a_ = (c)->q[0], b_ = (c)->q[1];               \
        uint32_t d_ = (c)->q[2], e_ = (c)->q[3];               \
        cvx_u32a *w;                                           \
        w = (cvx_u32a *)(p0_); w[0]=a_; w[1]=a_; w[2]=b_; w[3]=b_; \
        w = (cvx_u32a *)(p1_); w[0]=a_; w[1]=a_; w[2]=b_; w[3]=b_; \
        w = (cvx_u32a *)(p2_); w[0]=d_; w[1]=d_; w[2]=e_; w[3]=e_; \
        w = (cvx_u32a *)(p3_); w[0]=d_; w[1]=d_; w[2]=e_; w[3]=e_; \
    } while (0)

/* Color2x2Blk4RGB, DecodeCVID.c:466-497 */
#define CVID_PUT4_RGB(p0_, p1_, p2_, p3_, c0, c1, c2, c3)      \
    do {                                                       \
        cvx_u32a *w;                                           \
        w = (cvx_u32a *)(p0_);                                 \
        w[0]=(c0)->q[0]; w[1]=(c0)->q[1]; w[2]=(c1)->q[0]; w[3]=(c1)->q[1]; \
        w = (cvx_u32a *)(p1_);                                 \
        w[0]=(c0)->q[2]; w[1]=(c0)->q[3]; w[2]=(c1)->q[2]; w[3]=(c1)->q[3]; \
        w = (cvx_u32a *)(p2_);                                 \
        w[0]=(c2)->q[0]; w[1]=(c2)->q[1]; w[2]=(c3)->q[0]; w[3]=(c3)->q[1]; \
        w = (cvx_u32a *)(p3_);                                 \
        w[0]=(c2)->q[2]; w[1]=(c2)->q[3]; w[2]=(c3)->q[2]; w[3]=(c3)->q[3]; \
    } while (0)

/* RGB32 gets block loops AND a codebook, both from the 68020 on. The mode
 * is the fallback for graphics cards that report neither 15 nor 16 bit -
 * on this project's target machines it does not run, but this way no
 * output mode is left without assembler. */
#if defined(__m68k__) && CPU_LEVEL >= 20 && !defined(CVID_NO_ASM)
#  define CVID_ASM_3100    1
#  define CVID_ASM_BLK3100 cvid_blk3100_rgb32
#  define CVID_ASM_BLK3000 cvid_blk3000_rgb32
/* The codebook assembler stays OFF for RGB32 - measured 44,775 against
 * 43,041 us, so 4.0 % slower than the C code. As with GRAY8: the entry is
 * four plain longword stores, there gcc is already at the goal, and the
 * per-chunk call overhead remains.
 *
 * The BLOCK LOOPS, by contrast, gain 19.8 % and are on.
 * CVX_RGB32_MKCB switches the codebook part on for re-measuring. */
#  if !defined(CVID_NO_MKCB) && defined(CVX_RGB32_MKCB)
#    define CVID_ASM_MKCBFULL   1
#    define CVID_ASM_MKCBFULL1  cvid_mkcbfull1_rgb32
#    define CVID_ASM_MKCBFULL4  cvid_mkcbfull4_rgb32
#  endif
#endif
#define CVID_NEED_RNGARGB 1
#define CVID_FN     cvid_decode_rgb32
#define CVID_BPP    4
#define CVID_MKCB1  CVID_MKCB_RGB
#define CVID_MKCB4  CVID_MKCB_RGB
#define CVID_PUT1   CVID_PUT1_RGB
#define CVID_PUT4   CVID_PUT4_RGB
#include "codec/cvid_body.h"
#undef CVID_FN
#undef CVID_BPP
#undef CVID_MKCB1
#undef CVID_MKCB4
#undef CVID_PUT1
#undef CVID_PUT4
#undef CVID_NEED_RNGARGB
#undef CVID_ASM_3100
#undef CVID_ASM_BLK3100
#undef CVID_ASM_BLK3000
#undef CVID_ASM_MKCBFULL
#undef CVID_ASM_MKCBFULL1
#undef CVID_ASM_MKCBFULL4

/* ====================================================================== */
/* RGB16 - 2 bytes per pixel                                               */
/* ====================================================================== */
/*
 * Half the bus traffic against RGB32, and a block row is two
 * longwords instead of four - so 8 stores per block instead of 16.
 *
 * The codebook entries stay 4 longwords in size; V4 uses only two of them.
 * Shrinking them would gain nothing: the active set is at 8 KB far outside
 * any 68k data cache anyway (the 68020 has none at all, the
 * 68030 256 bytes), and indexing with a bitstream byte is practically
 * random.
 */
#define CVID_16_OF(yy_, out_)                      \
    do {                                           \
        int32_t _y = yt->yTab[yy_];                \
        out_ = t16R[(_y + cr)  >> 6]               \
             | t16G[(_y + cg)  >> 6]               \
             | t16B[(_y + cbb) >> 6];              \
    } while (0)

/* V1 (read by PUT1 only): the four output rows as two longwords each.
 * Rows 0 and 1 are equal, rows 2 and 3 as well - hence four suffice. */
#define CVID_MKCB1_16(e, y0, y1, y2, y3, u, v)                 \
    do {                                                       \
        int32_t cr  = yt->vrTab[v];                            \
        int32_t cg  = yt->ugTab[u] + yt->vgTab[v];             \
        int32_t cbb = yt->ubTab[u];                            \
        uint32_t a_, b_, d_, e_;                               \
        CVID_16_OF(y0, a_); CVID_16_OF(y1, b_);                \
        CVID_16_OF(y2, d_); CVID_16_OF(y3, e_);                \
        (e)->q[0] = PACK2PX(a_, a_);   /* rows 0/1, left     */ \
        (e)->q[1] = PACK2PX(b_, b_);   /* rows 0/1, right    */ \
        (e)->q[2] = PACK2PX(d_, d_);   /* rows 2/3, left     */ \
        (e)->q[3] = PACK2PX(e_, e_);   /* rows 2/3, right    */ \
    } while (0)

/* V4 (read by PUT4 only): every entry covers one 2x2 quarter, so exactly
 * one longword per block row. q[2]/q[3] stay unused. */
#define CVID_MKCB4_16(e, y0, y1, y2, y3, u, v)                 \
    do {                                                       \
        int32_t cr  = yt->vrTab[v];                            \
        int32_t cg  = yt->ugTab[u] + yt->vgTab[v];             \
        int32_t cbb = yt->ubTab[u];                            \
        uint32_t a_, b_, d_, e_;                               \
        CVID_16_OF(y0, a_); CVID_16_OF(y1, b_);                \
        CVID_16_OF(y2, d_); CVID_16_OF(y3, e_);                \
        (e)->q[0] = PACK2PX(a_, b_);   /* upper row    */      \
        (e)->q[1] = PACK2PX(d_, e_);   /* lower row    */      \
        (e)->q[2] = 0; (e)->q[3] = 0;                          \
    } while (0)

#define CVID_PUT1_16(p0_, p1_, p2_, p3_, c)                    \
    do {                                                       \
        uint32_t l_ = (c)->q[0], r_ = (c)->q[1];               \
        uint32_t L_ = (c)->q[2], R_ = (c)->q[3];               \
        cvx_u32a *w;                                           \
        w = (cvx_u32a *)(p0_); w[0]=l_; w[1]=r_;               \
        w = (cvx_u32a *)(p1_); w[0]=l_; w[1]=r_;               \
        w = (cvx_u32a *)(p2_); w[0]=L_; w[1]=R_;               \
        w = (cvx_u32a *)(p3_); w[0]=L_; w[1]=R_;               \
    } while (0)

#define CVID_PUT4_16(p0_, p1_, p2_, p3_, c0, c1, c2, c3)       \
    do {                                                       \
        cvx_u32a *w;                                           \
        w = (cvx_u32a *)(p0_); w[0]=(c0)->q[0]; w[1]=(c1)->q[0]; \
        w = (cvx_u32a *)(p1_); w[0]=(c0)->q[1]; w[1]=(c1)->q[1]; \
        w = (cvx_u32a *)(p2_); w[0]=(c2)->q[0]; w[1]=(c3)->q[0]; \
        w = (cvx_u32a *)(p3_); w[0]=(c2)->q[1]; w[1]=(c3)->q[1]; \
    } while (0)

/* The assembler block loops exist only for 68020+ - they use addressing
 * modes the 68000 does not know. With -DCVID_NO_ASM=1 the C branch can be
 * built for comparison; both have to return the same
 * hash. */
#if defined(__m68k__) && CPU_LEVEL >= 20 && !defined(CVID_NO_ASM)
#  define CVID_ASM_3100    1
#  define CVID_ASM_BLK3100 cvid_blk3100_rgb16
#  define CVID_ASM_BLK3000 cvid_blk3000_rgb16
#  define CVID_ASM_MKCB    1        /* codebook build by hand as well */
#  define CVID_ASM_MKCB1P  cvid_mkcb1p_rgb16
#  define CVID_ASM_MKCB4P  cvid_mkcb4p_rgb16
#  if !defined(CVID_NO_MKCB)
#    define CVID_ASM_MKCBFULL   1
#  endif
#  define CVID_ASM_MKCBFULL1  cvid_mkcbfull1_rgb16
#  define CVID_ASM_MKCBFULL4  cvid_mkcbfull4_rgb16
#endif
#define CVID_NEED_RNG16 1
#define CVID_FN     cvid_decode_rgb16
#define CVID_BPP    2
#define CVID_MKCB1  CVID_MKCB1_16
#define CVID_MKCB4  CVID_MKCB4_16
#define CVID_PUT1   CVID_PUT1_16
#define CVID_PUT4   CVID_PUT4_16
#include "codec/cvid_body.h"
#undef CVID_FN
#undef CVID_BPP
#undef CVID_MKCB1
#undef CVID_MKCB4
#undef CVID_PUT1
#undef CVID_PUT4
#undef CVID_NEED_RNG16
#undef CVID_ASM_3100
#undef CVID_ASM_BLK3100
#undef CVID_ASM_BLK3000
#undef CVID_ASM_MKCB
#undef CVID_ASM_MKCB1P
#undef CVID_ASM_MKCB4P
#undef CVID_ASM_MKCBFULL
#undef CVID_ASM_MKCBFULL1
#undef CVID_ASM_MKCBFULL4
#undef CVID_DIRTY

/* ====================================================================== */
/* GRAY8 - 1 byte per pixel, Y directly                                    */
/* ====================================================================== */

/* `gsh` quantises to a power of two of grey levels - on ECS only five
 * planes reach the screen. At the default of 0, Y stays
 * unchanged; the shift is a register, not a memory access. */
#define CVID_GRAY_OF(y_)  ((uint32_t)(y_) >> gsh)

/* V1 (read by PUT1 only): the four output rows packed ready.
 * That turns 16 byte stores into four longword stores. */
#define CVID_MKCB1_GRAY(e, y0, y1, y2, y3, u, v)               \
    do {                                                       \
        uint32_t a_ = CVID_GRAY_OF(y0), b_ = CVID_GRAY_OF(y1); \
        uint32_t d_ = CVID_GRAY_OF(y2), e_ = CVID_GRAY_OF(y3); \
        uint32_t r01 = PACK4B(a_, a_, b_, b_);                 \
        uint32_t r23 = PACK4B(d_, d_, e_, e_);                 \
        (e)->q[0] = r01; (e)->q[1] = r01;                      \
        (e)->q[2] = r23; (e)->q[3] = r23;                      \
        (void)(u); (void)(v);                                  \
    } while (0)

/* V4 (read by PUT4 only): every entry delivers one pixel pair per row,
 * prepared once for the upper and once for the lower longword half.
 * A block row is then an OR of two entries. */
#define CVID_MKCB4_GRAY(e, y0, y1, y2, y3, u, v)               \
    do {                                                       \
        uint32_t a_ = CVID_GRAY_OF(y0), b_ = CVID_GRAY_OF(y1); \
        uint32_t d_ = CVID_GRAY_OF(y2), e_ = CVID_GRAY_OF(y3); \
        (e)->q[0] = PACK4B(a_, b_, 0, 0);   /* row 0, upper   */ \
        (e)->q[1] = PACK4B(d_, e_, 0, 0);   /* row 1, upper   */ \
        (e)->q[2] = PACK4B(0, 0, a_, b_);   /* row 0, lower   */ \
        (e)->q[3] = PACK4B(0, 0, d_, e_);   /* row 1, lower   */ \
        (void)(u); (void)(v);                                  \
    } while (0)

/* Color2x2Blk1Gray, DecodeCVID.c:517-552 - 4 bytes/pixel there still */
#define CVID_PUT1_GRAY(p0_, p1_, p2_, p3_, c)                  \
    do {                                                       \
        *(cvx_u32a *)(p0_) = (c)->q[0];                        \
        *(cvx_u32a *)(p1_) = (c)->q[1];                        \
        *(cvx_u32a *)(p2_) = (c)->q[2];                        \
        *(cvx_u32a *)(p3_) = (c)->q[3];                        \
    } while (0)

/* Color2x2Blk4Gray, DecodeCVID.c:556-605 */
#define CVID_PUT4_GRAY(p0_, p1_, p2_, p3_, c0, c1, c2, c3)     \
    do {                                                       \
        *(cvx_u32a *)(p0_) = (c0)->q[0] | (c1)->q[2];          \
        *(cvx_u32a *)(p1_) = (c0)->q[1] | (c1)->q[3];          \
        *(cvx_u32a *)(p2_) = (c2)->q[0] | (c3)->q[2];          \
        *(cvx_u32a *)(p3_) = (c2)->q[1] | (c3)->q[3];          \
    } while (0)

/* One byte per pixel: a block row is exactly one longword. The same
 * assembler version serves GRAY8 and CLUT8 - the PUT macros are identical,
 * only the codebook is filled differently, and of that the block writer sees
 * nothing. The codebook build (CVID_ASM_MKCB) stays with the C code here. */
/* The 8-bit block loops exist for EVERY CPU - for 68020+ and, with a
 * register frame of its own, for the 68000. There it counts the most:
 * it is the slowest target machine, and the decoder is the biggest item
 * there. */
#if defined(__m68k__) && !defined(CVID_NO_ASM)
#  define CVID_ASM_3100    1
#  define CVID_ASM_BLK3100 cvid_blk3100_pix8
#  define CVID_ASM_BLK3000 cvid_blk3000_pix8
#endif
/* Only the 8-bit modes keep the dirty rows: only the chipset path needs
 * them (C2P), and one byte store per written block should not burden the
 * RTG path, which gains nothing from it.
 *
 * NOT AT ALL ON THE 68000. Its block loops use the register that otherwise
 * holds the dirty pointer for the second row pointer. That is no sacrifice -
 * measured on real material, 100 % of the block rows are changed, so the
 * bookkeeping saves nothing and costs 2 %. */
/* GRAY8's codebook stays with the C code - MEASURED, not assumed.
 *
 * The assembler version exists (src/asm/cvid_mkcbgray.s, runnable on every
 * CPU) and returns bit-identical results - checked frame by frame against
 * the host. It is simply not faster: 25,008 against 24,575 us per frame on
 * the 68020, so 1.8 % SLOWER.
 *
 * The reason is plain once it has been measured: the grey level entry is
 * pure repacking of four bytes without a single table access. For that gcc
 * produces good code already, and the per-chunk overhead - saving registers,
 * filling the state block - eats the rest.
 *
 * CVX_GRAY_MKCB switches it on for re-measuring. */
#if defined(__m68k__) && !defined(CVID_NO_ASM) && defined(CVX_GRAY_MKCB)
#  define CVID_ASM_MKCBFULL   1
#  define CVID_ASM_MKCBFULL1  cvid_mkcbfull1_gray
#  define CVID_ASM_MKCBFULL4  cvid_mkcbfull4_gray
#endif
#define CVID_NEED_GRAY 1
#define CVID_FN     cvid_decode_gray8
#define CVID_BPP    1
#define CVID_MKCB1  CVID_MKCB1_GRAY
#define CVID_MKCB4  CVID_MKCB4_GRAY
#define CVID_PUT1   CVID_PUT1_GRAY
#define CVID_PUT4   CVID_PUT4_GRAY
#include "codec/cvid_body.h"
#undef CVID_FN
#undef CVID_BPP
#undef CVID_MKCB1
#undef CVID_MKCB4
#undef CVID_PUT1
#undef CVID_PUT4
#undef CVID_NEED_GRAY
#undef CVID_ASM_MKCBFULL
#undef CVID_ASM_MKCBFULL1
#undef CVID_ASM_MKCBFULL4

#undef CVID_ASM_3100
#undef CVID_ASM_BLK3100
#undef CVID_ASM_BLK3000

/* ====================================================================== */
/* Context                                                                 */
/* ====================================================================== */

cvid_ctx *cvid_open(uint32_t width, uint32_t height, cvid_outmode mode)
{
    cvid_ctx *ctx;
    int i;

    ctx = (cvid_ctx *)calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;

    ctx->width  = width & ~3u;     /* Cinepak works in 4x4 blocks */
    ctx->height = height & ~3u;
    ctx->mode   = mode;
    ctx->yt     = yuv_tables();
    ctx->rng    = yuv_rnglimit();
    ctx->rngargb = yuv_rngargb_tables();
    ctx->pix16   = CVX_PIX16_R5G6B5;
    ctx->rng16   = yuv_rng16_tables(ctx->pix16);
    ctx->gsh  = 0;                 /* 256 grey levels, Y unchanged */

    /* One contiguous block for all 32 codebooks: 32 * 256 * 16 B
     * = 128 KB (instead of 640 KB in the original). */
    ctx->pool = (cvid_cb *)calloc((size_t)CVID_MAX_STRIPS * 2 * 256,
                                  sizeof(cvid_cb));
    if (!ctx->pool) { free(ctx); return NULL; }

    /* One block row is four picture rows.
     *
     * ONE byte more than needed: the block advance moves the pointer on once
     * more after the last block row, before the loop breaks off. Nothing is
     * ever written there - but the pointer briefly points there, and against
     * a later change of the break order one byte is the cheapest insurance
     * there is. */
    ctx->nrows = ctx->height >> 2;
    ctx->dirty = (uint8_t *)calloc((size_t)ctx->nrows + 1, 1);
    if (!ctx->dirty) { free(ctx->pool); free(ctx); return NULL; }

    for (i = 0; i < CVID_MAX_STRIPS; i++) {
        ctx->maps0[i] = ctx->pool + (size_t)(i * 2 + 0) * 256;
        ctx->maps1[i] = ctx->pool + (size_t)(i * 2 + 1) * 256;
    }
    return ctx;
}

void cvid_close(cvid_ctx *ctx)
{
    if (!ctx) return;
    free(ctx->dirty);
    free(ctx->pool);
    free(ctx);
}

int cvid_decode(cvid_ctx *ctx, const uint8_t *data, uint32_t size,
                uint8_t *dst, uint32_t stride)
{
    if (!ctx || !data || !dst) return CVID_ERR_SIZE;

    memset(&ctx->st, 0, sizeof(ctx->st));

    /* An empty or tiny ##dc chunk is a regular drop frame:
     * "repeat the picture unchanged". It occurs in the test material
     * (frame 1 of the 320x180 file has 0 bytes). Not an error. */
    if (size < 10)
        return 0;

    ctx->last_size = size;

    switch (ctx->mode) {
    case CVID_OUT_GRAY8:
        return cvid_decode_gray8(ctx, data, data + size, dst, stride);
    case CVID_OUT_RGB16:
        return cvid_decode_rgb16(ctx, data, data + size, dst, stride);
    case CVID_OUT_RGB32:
    default:
        return cvid_decode_rgb32(ctx, data, data + size, dst, stride);
    }
}

void cvid_set_gray(cvid_ctx *ctx, int levels)
{
    int sh = 0;
    if (!ctx) return;
    /* 256 -> 0, 128 -> 1, ... 2 -> 7. Non-powers of two are rounded down to
     * the next smaller one; a division per pixel would be the point at
     * which the mode would lose its advantage. */
    if (levels < 2)   levels = 2;
    if (levels > 256) levels = 256;
    while ((256 >> sh) > levels) sh++;
    ctx->gsh = sh;
}

void cvid_set_pix16(cvid_ctx *ctx, int fmt)
{
    if (!ctx) return;
    if (fmt < CVX_PIX16_R5G6B5 || fmt > CVX_PIX16_R5G5B5PC) return;
    ctx->pix16 = fmt;
    ctx->rng16 = yuv_rng16_tables(fmt);
}

const cvid_stats *cvid_last_stats(const cvid_ctx *ctx)
{
    return &ctx->st;
}
