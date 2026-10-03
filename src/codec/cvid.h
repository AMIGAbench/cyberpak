/* cvid.h - Cinepak-Decoder (CVID/cvid).
 *
 * Ported from decoder/txt/DecodeCVID.c, but in the target form:
 *
 *  - row pointers instead of (to,x,y,width) -> no multiplication per block
 *    (Muster aus decoder/txt/DecodeRPZA.c:15-29, :97-113)
 *  - no function pointer dispatch -> one specialised loop per output mode,
 *    chosen once when opening
 *  - pre-packed codebook entries -> 4 longword stores per 4x4 block instead
 *    of 16 byte stores
 *  - `strips` gegen CVID_MAX_STRIPS geklemmt (im Original ungeprueft,
 *    DecodeCVID.c:103 -> Pufferueberlauf)
 *  - state exclusively in the context, no globals
 *
 * The decoder depends only on <stdint.h> and headers of this project; it
 * builds unchanged for m68k and x86. That is the basis of the verification:
 * the x86 build is the bit-exact reference for the m68k builds.
 */
#ifndef CYBERPAK_CVID_H
#define CYBERPAK_CVID_H

#include <stdint.h>

#define CVID_MAX_STRIPS 16

typedef enum {
    CVID_OUT_RGB32 = 0,   /* 4 bytes/pixel, memory bytes A,R,G,B (A=0)  */
    CVID_OUT_GRAY8,       /* 1 byte/pixel, Y directly                   */
    CVID_OUT_YUV,          /* diagnostics: raw Y/U/V per 2x2, see cvid_yuv */
    CVID_OUT_RGB16        /* 2 bytes/pixel, format through cvid_set_pix16 */
} cvid_outmode;
/* The chipset modes (palette, HAM, adapted palette) went out of this decoder
 * with the 020+ rework: HAM6/DHAM6/DHAM8 and GRAY are shown by the assembler
 * modules (src/kern.h, src/a020). GRAY8 stays for the host tests and
 * cvidbench. */

typedef struct cvid_ctx cvid_ctx;

/* width/height in Pixeln (Cinepak arbeitet in 4x4-Bloecken; ungerade Masse
 * are simply truncated as in the original). */
cvid_ctx *cvid_open(uint32_t width, uint32_t height, cvid_outmode mode);
void      cvid_close(cvid_ctx *ctx);

/* For CVID_OUT_RGB16 only: which of the four 16-bit formats the card wants
 * (CVX_PIX16_* from cpu.h). Call it BEFORE the first cvid_decode - the choice
 * then sits in the codebook entries and costs nothing in the hot path.
 * The default is CVX_PIX16_R5G6B5. */
void      cvid_set_pix16(cvid_ctx *ctx, int fmt);

/* For CVID_OUT_GRAY8 only: quantise to `levels` grey levels instead of
 * passing Y through unchanged. `levels` has to be a power of two from 2 to
 * 256; 256 is the default and changes nothing.
 *
 * What for: on ECS only five bitplanes reach the screen, and an index above
 * 31 showed the wrong colour. The index is then Y >> 3.
 *
 * Call it BEFORE the first cvid_decode. */
void      cvid_set_gray(cvid_ctx *ctx, int levels);

/* Decodes one frame into dst. `stride` is the row distance in bytes and has to
 * be a multiple of 4 (see STRIDE_ALIGN in cpu.h): the block writers write
 * longword-wise, and on the 68000 a longword access at an odd address would be
 * an address error.
 *
 * Returns: 0 = ok, otherwise a CVID_ERR_* code. */
int cvid_decode(cvid_ctx *ctx, const uint8_t *data, uint32_t size,
                uint8_t *dst, uint32_t stride);

#define CVID_ERR_SIZE       -1   /* length field does not match the chunk size */
#define CVID_ERR_TRUNCATED  -2   /* Frame endet mitten im Bitstrom           */
#define CVID_ERR_CHUNKID    -3   /* unbekannte Chunk-ID                      */

/* Diagnostic counters of the last frame - the basis of stage A of the
 * verification (comparison against an independent Python parser). */
typedef struct {
    uint32_t strips;
    uint32_t cb_v1, cb_v4;     /* codebook entries built          */
    uint32_t blk_v1, blk_v4;   /* geschriebene Bloecke            */
    uint32_t blk_skip;         /* uebersprungene Bloecke          */
    uint32_t truncated;        /* Chunk endete vorzeitig          */
    uint32_t advances;         /* Blockvorschuebe (Deckungstest)  */
} cvid_stats;

const cvid_stats *cvid_last_stats(const cvid_ctx *ctx);

#endif
