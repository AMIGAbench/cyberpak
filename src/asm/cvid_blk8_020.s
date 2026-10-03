* cvid_blk8_020.s - block loops 0x3000/0x3100, 8 bit per pixel, 68020+
*
* One byte per pixel: CVID_OUT_GRAY8 (PUT macros like CVID_PUT1_GRAY /
* CVID_PUT4_GRAY in src/codec/cvid.c) and the chunky buffer for GRAY in the
* 020/030 player (src/a020/cvid.s). The codebooks for the fixed palette (CLUT8)
* went away with the 020+ rework.
*
* The loop frame comes from src/asm/cvid_blk_loops.i, the same file the 16-bit
* version uses. Only the two PUT macros live here.
*
* THE DIFFERENCE TO THE 16-BIT VERSION: a block row is four pixels wide, so at
* one byte per pixel exactly ONE longword instead of two. That halves the
* number of memory accesses per block:
*
*                       16 bit          8 bit
*   V1  load               4              4
*       store              8              4
*   V4  load               8              8
*       store              8              4
*
* With V4 the gain is not free: a row there is the OR of two codebook entries
* (c0->q0 | c1->q2), so a third data register is needed as scratch. d4 is free,
* because the frame no longer keeps `wrap` in a register but reloads it at the
* row change - once per block row instead of register pressure per block.
*
*
* DIRTY ROWS: both macros end with `st (a6)` - one byte per block row saying
* "something was written here". One instruction per block written, about 1,800
* per frame. In return C2P afterwards only has to convert the rows that
* changed, and that costs 79 ms for a full frame. The 16-bit version does not
* mark anything - there is no C2P there.
*
* No AMMX: at 16 bit the eight bytes of a block row lie together, one 64-bit
* access covers them. At 8 bit it is four bytes, and the next row is `stride`
* further on - a 64-bit load would bring two rows' values at once, which would
* then have to go to different addresses one by one anyway.

        section code

* V4: four codebook indices, four 2x2 quarters. \1 = branch target on abort.
*
* The model is CVID_PUT4_GRAY:
*   p0 = c0->q[0] | c1->q[2]      p1 = c0->q[1] | c1->q[3]
*   p2 = c2->q[0] | c3->q[2]      p3 = c2->q[1] | c3->q[3]
*
* The index is kept HALVED (add.l dN,dN), then the addressing mode
* (a4,dN.l*8) does the multiplication by 16 for free - a codebook entry is
* 16 bytes.
PUTV4   macro
        lea     4(a1),a0
        cmpa.l  a2,a0
        bhi     \1
        moveq   #0,d7
        move.b  (a1)+,d7
        add.l   d7,d7                        ; c0
        moveq   #0,d6
        move.b  (a1)+,d6
        add.l   d6,d6                        ; c1
        move.l  (a4,d7.l*8),d4               ; c0->q0
        or.l    (8,a4,d6.l*8),d4             ; | c1->q2
        move.l  d4,(a3)                      ; row 0
        move.l  (4,a4,d7.l*8),d4             ; c0->q1
        or.l    (12,a4,d6.l*8),d4            ; | c1->q3
        move.l  d4,(a3,d5.l)                 ; row 1
        moveq   #0,d7
        move.b  (a1)+,d7
        add.l   d7,d7                        ; c2
        moveq   #0,d6
        move.b  (a1)+,d6
        add.l   d6,d6                        ; c3
        lea     (a3,d5.l*2),a0               ; a0 = row 2
        move.l  (a4,d7.l*8),d4               ; c2->q0
        or.l    (8,a4,d6.l*8),d4             ; | c3->q2
        move.l  d4,(a0)                      ; row 2
        move.l  (4,a4,d7.l*8),d4             ; c2->q1
        or.l    (12,a4,d6.l*8),d4            ; | c3->q3
        move.l  d4,(a0,d5.l)                 ; row 3
        st      (a6)                         ; block row has changed
        endm

* V1: one index, four finished rows. The model is CVID_PUT1_GRAY:
*   p0 = q[0]   p1 = q[1]   p2 = q[2]   p3 = q[3]
*
* The codebook pointer is formed ONCE with lea and then read with (a0)+. Four
* indexed accesses (a5,d7.l*8) computed the effective address every time;
* post-increment is the cheapest mode on the 68020. The same lesson as with
* the 16-bit version, where the indexed form was 22 % slower than the C code.
*
PUTV1   macro
        cmpa.l  a2,a1
        bcc     \1                           ; from >= cend
        moveq   #0,d7
        move.b  (a1)+,d7
        add.l   d7,d7
        lea     (a5,d7.l*8),a0               ; a0 = &cb1[idx]
        move.l  (a0)+,d6                     ; q0
        move.l  d6,(a3)                      ; row 0
        move.l  (a0)+,d6                     ; q1
        move.l  d6,(a3,d5.l)                 ; row 1
        move.l  (a0)+,d4                     ; q2
        move.l  (a0),d6                      ; q3
        lea     (a3,d5.l*2),a0
        move.l  d4,(a0)                      ; row 2
        move.l  d6,(a0,d5.l)                 ; row 3
        st      (a6)                         ; block row has changed
        endm

        include "src/asm/cvid_blk_loops.i"
        BLKLOOPS pix8
