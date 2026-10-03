/* cpu.h - CPU capabilities and pixel packing at compile time.
 *
 * CAUTION: do NOT use the gcc macros __mc680x0__ to ask about features.
 * Verifiziert an apollocrossdev / m68k-amigaos-gcc 6.5.0b:
 *
 *   -m68000: __mc68000__
 *   -m68020: __mc68000__ __mc68020__
 *   -m68030: __mc68000__ __mc68030__   <- KEIN __mc68020__
 *   -m68040: __mc68000__ __mc68040__   <- KEIN __mc68020__
 *   -m68060: __mc68000__ __mc68060__   <- KEIN __mc68020__
 *   -m68080: __mc68000__ __mc68080__   <- KEIN __mc68020__
 *
 * So an "#ifdef __mc68020__" silently picks the 68000 path on 030/040/060/080,
 * and __mc68000__ is set everywhere. The CPU level therefore comes solely from
 * -DCPU_LEVEL=n in the Makefile.
 */
#ifndef CYBERPAK_CPU_H
#define CYBERPAK_CPU_H

#include <stdint.h>

#ifndef CPU_LEVEL
#  ifdef __x86_64__
#    define CPU_LEVEL 9999          /* host build */
#  else
#    error "CPU_LEVEL not defined - set -DCPU_LEVEL=... in the Makefile"
#  endif
#endif

#if CPU_LEVEL >= 20
#  define CPU_UNALIGNED_OK  1   /* unaligned word/longword access allowed    */
#  define CPU_HAS_MUL32     1   /* mulu.l/muls.l present                     */
#else
#  define CPU_UNALIGNED_OK  0   /* 68000: unaligned access = address error   */
#  define CPU_HAS_MUL32     0   /* 68000: only mulu.w, 32x32 costs __mulsi3  */
#endif

#if CPU_LEVEL >= 40
#  define CPU_HAS_CACHE     1
#else
#  define CPU_HAS_CACHE     0
#endif

/* --- Apollo 68080: no unaligned longword accesses ------------------------
 *
 * On real 68080 hardware the decoder returned wrong results
 * non-deterministically: same binary, same input, changing hashes
 * (97113064, 09ca833f, c7fa05d8). Emulated 68000/68020/68060 were always
 * correct, ASAN on x86 found nothing, and a harmless change to the test
 * program tipped the behaviour over - typical of instruction pairing.
 *
 * The user narrowed it down: with the SECOND PIPELINE SWITCHED OFF
 * (apollocontrol) the result is right. The decoder has exactly one
 * unaligned access - rd_be32() reads the flag longwords of the bitstream,
 * and the read pointer walks through the data byte by byte. A variant
 * without that access returned correct results again with both pipelines
 * enabled.
 *
 * We therefore avoid the access on the 68080 as a matter of principle. The
 * cost is small: flag longwords are read only about every 16-32 blocks, so
 * roughly 150-225 times per frame against ~2300 block writes.
 *
 * Architecturally unaligned access is allowed from the 68020 on; this is
 * thus a concession to the behaviour of the Apollo core, not a bug in the
 * C code. */
#if defined(__m68k__) && CPU_LEVEL >= 20 && CPU_LEVEL < 80 && !defined(CVX_FORCE_ALIGNED)
#  define CVX_FAST_UNALIGNED 1
#else
#  define CVX_FAST_UNALIGNED 0
#endif

/* Always round the row stride up to a multiple of 4: the block writers write
 * longword-wise, and row n starts at n*stride. With an odd stride the odd
 * rows would be oddly addressed - on the 68000 an address error, on 020+
 * merely expensive. The original rounds only to 2
 * (CyberAVIVideo.mod:1985). */
#define STRIDE_ALIGN(x) (((x) + 3u) & ~3u)

/* --- Aliasing ------------------------------------------------------------
 *
 * The block writers put 32-bit words into a buffer that is otherwise read as
 * a uint8_t array (display, hash, C2P). A bare `*(uint32_t *)p = ...`
 * therefore violates C's aliasing rules - the compiler may assume that the
 * two kinds of access do not overlap, and may reorder loads and stores.
 *
 * This only became relevant in practice with `-m68080`: there gcc 6.5 acts on
 * that assumption, while with `-m68060` `-fno-strict-aliasing` produces a
 * byte-identical binary. So the bug was present all along and merely
 * invisible.
 *
 * `may_alias` tells the compiler the truth: this type may alias with
 * anything. That is the correct solution; a global -fno-strict-aliasing would
 * only hide the symptom and switch off the optimisation across the whole
 * program.
 */
typedef uint32_t cvx_u32a __attribute__((__may_alias__));
typedef uint16_t cvx_u16a __attribute__((__may_alias__));

/* --- Pixel-Packing ------------------------------------------------------
 *
 * The target buffer is byte-addressed: a 32-bit pixel lies as A,R,G,B in
 * memory (RGBTriple from decoder/txt/Decode.h:23-28), an 8-bit block row as
 * four consecutive index bytes.
 *
 * So that a *native* uint32 store produces the same byte sequence on both
 * platforms - and host and m68k output are thus comparable bit for bit - the
 * host build reverses the packing order. On m68k it stays the direct, optimal
 * case.
 */
#if defined(__m68k__)
#  define CPU_BIG_ENDIAN 1
#else
#  define CPU_BIG_ENDIAN 0
#endif

#if CPU_BIG_ENDIAN
#  define PACK4B(b0,b1,b2,b3)  ( ((uint32_t)(b0)<<24) | ((uint32_t)(b1)<<16) \
                               | ((uint32_t)(b2)<< 8) |  (uint32_t)(b3) )
#else
#  define PACK4B(b0,b1,b2,b3)  ( ((uint32_t)(b3)<<24) | ((uint32_t)(b2)<<16) \
                               | ((uint32_t)(b1)<< 8) |  (uint32_t)(b0) )
#endif

/* 32-bit pixel: memory bytes A,R,G,B. Alpha is always 0 (as in the original). */
#define PACK_ARGB(r,g,b)  PACK4B(0,(r),(g),(b))

/* --- 16 bits per pixel -------------------------------------------------
 *
 * Halves the bus traffic against 32 bit - on 020/030 with a graphics card the
 * biggest lever, because there the path to the card and not the CPU is the
 * bottleneck (at 320x180 and 25 fps 14.8 against 7.4 MB/s).
 *
 * Which of the four formats applies is decided by the card. That costs
 * nothing in the hot path: the choice sits in the pre-built tables from
 * yuv.c, which are made once when opening. */
#define CVX_PIX16_R5G6B5    0   /* 0rrrrrggggggbbbbb            */
#define CVX_PIX16_R5G5B5    1   /* 0rrrrrgggggbbbbb             */
#define CVX_PIX16_R5G6B5PC  2   /* the same, bytes swapped      */
#define CVX_PIX16_R5G5B5PC  3

/* Two 16-bit pixels in one longword. `a` lies at the LOWER address - so the
 * order within the longword depends on the byte order, exactly as with
 * PACK4B. A block row thus writes two longwords instead of four. */
#if CPU_BIG_ENDIAN
#  define PACK2PX(a,b)  ( ((uint32_t)(a) << 16) | (uint32_t)(b) )
#else
#  define PACK2PX(a,b)  ( ((uint32_t)(b) << 16) | (uint32_t)(a) )
#endif

#endif
