* cvid_blk_020.s - block loops 0x3000/0x3100, 16-bit output, 68020+
*
* Implements the block chunks from src/codec/cvid_body.h together with
* CVID_PUT4_16/CVID_PUT1_16 and CVID_BLOCKINC from cvid.c. The C branch stays
* buildable with -DCVID_NO_ASM=1; both have to yield the same hash.
*
* Only the two PUT macros live here - the loop frame is in
* src/asm/cvid_blk_loops.i and is shared with the 8-bit version.
*
* Why assembler at all: gcc runs out of address registers here. Of the four
* row pointers three sat in data registers, and before every store there was a
* `movea.l dN,aX` - 28 instructions per block for only 8 real stores. The
* attempt to solve that from C (two pointers plus (An,Dn.l) for the rows in
* between) failed: gcc does not generate that addressing mode there.
*
* Two tricks carry the gain in the PUT macros:
*  - p0 stays put; the four rows go through (a3), (a3,d5.l), (a3,d5.l*2) and
*    one lea. A block that is skipped therefore costs no more than the
*    advance - and 36-58 % are skipped.
*  - codebook access through (a4,d7.l*8) with a HALVED index: the addressing
*    mode does the multiplication by 16 for free, and the four `lsl.l #4` per
*    V4 block are gone.
*
* The remaining tricks (carry bits, two nested loops) are in the shared frame.
*
* stehen im gemeinsamen Geruest.

        section code

MARKROW macro
        endm

        include "src/asm/cvid_blk16_puts.i"


        include "src/asm/cvid_blk_loops.i"
        BLKLOOPS rgb16

* ================================================================
* Building codebooks, partial form (0x2100 / 0x2300)
* ================================================================
*
* Register use
*   a0 from   a1 cend   a2 &yTab[0]   a3 t16r  a4 t16g  a5 t16b  a6 dst
*   d0 cr     d1 cg     d2 cbb        d3 _y    d4 pixel d5 index
*   d6 flag word        d7 remaining bits
*   (sp) holds cmend - the only value for which no register was left; it is
*   read once per entry, not per bit.
*
* The chroma tables lie contiguously before yTab, so ONE address register is
* enough for all five:
*   ubTab -4096   vrTab -3072   ugTab -2048   vgTab -1024   yTab 0

        include "src/asm/cvid_mkcb_common.i"

* -------- 0x2100: V4, q0 = (a<<16)|b, q1 = (d<<16)|e, q2 = q3 = 0 -------
        xdef _cvid_mkcb4p_rgb16
_cvid_mkcb4p_rgb16:
        MKENTER
.word:
        MKBIT   .done,.next,.flush
        ENT4_16
        bra.s   .next
.flush:
        moveq   #0,d7                        ; discard the rest of the flag word
        bra     .word
.next:
        lea     16(a6),a6                    ; ci++
        bra     .word
.done:
        MKLEAVE

* -------- 0x2300: V1, q0=(a<<16)|a, q1=(b<<16)|b, q2/q3 from d,e --------
        xdef _cvid_mkcb1p_rgb16
_cvid_mkcb1p_rgb16:
        MKENTER
.word:
        MKBIT   .done,.next,.flush
        ENT1_16
        bra.s   .next
.flush:
        moveq   #0,d7
        bra     .word
.next:
        lea     16(a6),a6
        bra     .word
.done:
        MKLEAVE

* -------- 0x2000 / 0x2200: full form, 16 bit --------------------------
        xdef _cvid_mkcbfull4_rgb16
_cvid_mkcbfull4_rgb16:
        MKFULL  ENT4_16

        xdef _cvid_mkcbfull1_rgb16
_cvid_mkcbfull1_rgb16:
        MKFULL  ENT1_16

        end
