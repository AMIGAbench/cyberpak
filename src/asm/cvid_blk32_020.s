* cvid_blk32_020.s - block loops 0x3000/0x3100, 32 bit per pixel, 68020+.
*
* RGB32 is the store-heaviest mode: four bytes per pixel, so a block row is
* 16 bytes = FOUR longwords, 16 stores per block. For comparison: eight at
* 16 bit and four at 8 bit.
*
* WHAT FOR: the fallback when a graphics card reports neither 15 nor 16 bit.
* On the target machines of this project it never runs - an AGA/ECS machine has
* no card, and on the Vampire the 16-bit path takes over. It is here all the
* same, so that no output mode is left without assembler.
* bleibt.
* 68020 and up, like the 16-bit path: RGB32 presupposes a graphics card, and a
* 68000 with RTG is not a case this project serves.
*
* THE TRICK THAT APPEARS NOWHERE ELSE: `move.l <ea>,<ea>` from memory to
* memory. With V4 every codebook value is needed exactly ONCE - routing it
* through a data register would be a detour. The 68020 also allows the indexed
* form (d8,An,Xn) as a destination, so the whole block row goes in four
* instructions instead of eight.
*
* With V1 it is the other way round: there every value stands twice side by
* side AND the row twice one below the other. Four values become sixteen
* stores - there the register pays off.
*
* Register use as in the shared frame (cvid_blk_loops.i):
*   a0 scratch  a1 from  a2 cend  a3 p0  a4 cb0  a5 cb1  a6 dirty (unused)
*   d0 flag word d1 remaining bits d2 bx d3 binc d5 stride  d4/d6/d7 scratch
*   d0 flag word d1 rest bits d2 bx d3 binc d5 stride  d4/d6/d7 scratch

        section code

* V4: four codebook indices. Model CVID_PUT4_RGB:
*   row 0 = c0->q0, c0->q1, c1->q0, c1->q1
*   row 1 = c0->q2, c0->q3, c1->q2, c1->q3
*   row 2 = c2->q0, c2->q1, c3->q0, c3->q1
*   row 3 = c2->q2, c2->q3, c3->q2, c3->q3
*
* The index is kept HALVED (add.l dN,dN), then (a4,dN.l*8) does the
* multiplication by 16 for free - an entry is 16 bytes.
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
        move.l  (a4,d7.l*8),(a3)             ; row 0
        move.l  (4,a4,d7.l*8),4(a3)
        move.l  (a4,d6.l*8),8(a3)
        move.l  (4,a4,d6.l*8),12(a3)
        move.l  (8,a4,d7.l*8),(a3,d5.l)      ; row 1
        move.l  (12,a4,d7.l*8),(4,a3,d5.l)
        move.l  (8,a4,d6.l*8),(8,a3,d5.l)
        move.l  (12,a4,d6.l*8),(12,a3,d5.l)
        moveq   #0,d7
        move.b  (a1)+,d7
        add.l   d7,d7                        ; c2
        moveq   #0,d6
        move.b  (a1)+,d6
        add.l   d6,d6                        ; c3
        lea     (a3,d5.l*2),a0               ; a0 = row 2
        move.l  (a4,d7.l*8),(a0)             ; row 2
        move.l  (4,a4,d7.l*8),4(a0)
        move.l  (a4,d6.l*8),8(a0)
        move.l  (4,a4,d6.l*8),12(a0)
        move.l  (8,a4,d7.l*8),(a0,d5.l)      ; row 3
        move.l  (12,a4,d7.l*8),(4,a0,d5.l)
        move.l  (8,a4,d6.l*8),(8,a0,d5.l)
        move.l  (12,a4,d6.l*8),(12,a0,d5.l)
        endm

* V1: one index, 2x2 stretched to 4x4. Model CVID_PUT1_RGB:
*   row 0 = row 1 = a,a,b,b     row 2 = row 3 = d,d,e,e
*
* Four values, sixteen stores - every value is needed four times, so load it
* into a register once and write from there. The codebook pointer is formed
* ONCE with lea and read with (a0)+; post-increment is the cheapest mode on
* the 68020.
PUTV1   macro
        cmpa.l  a2,a1
        bcc     \1                           ; from >= cend
        moveq   #0,d7
        move.b  (a1)+,d7
        add.l   d7,d7
        lea     (a5,d7.l*8),a0               ; a0 = &cb1[idx]
        move.l  (a0)+,d4                     ; a
        move.l  (a0)+,d6                     ; b
        move.l  d4,(a3)                      ; row 0: a a b b
        move.l  d4,4(a3)
        move.l  d6,8(a3)
        move.l  d6,12(a3)
        move.l  d4,(a3,d5.l)                 ; row 1: the same
        move.l  d4,(4,a3,d5.l)
        move.l  d6,(8,a3,d5.l)
        move.l  d6,(12,a3,d5.l)
        move.l  (a0)+,d4                     ; d
        move.l  (a0),d6                      ; e
        lea     (a3,d5.l*2),a0               ; a0 = row 2
        move.l  d4,(a0)                      ; row 2: d d e e
        move.l  d4,4(a0)
        move.l  d6,8(a0)
        move.l  d6,12(a0)
        move.l  d4,(a0,d5.l)                 ; row 3: the same
        move.l  d4,(4,a0,d5.l)
        move.l  d6,(8,a0,d5.l)
        move.l  d6,(12,a0,d5.l)
        endm

        include "src/asm/cvid_blk_loops.i"
        BLKLOOPS rgb32

* -------- codebook, full form (0x2000 / 0x2200) ------------------------
* V1 and V4 are the same computation here - two entry points all the same, so
* that the hook-up in cvid_body.h looks the same for every mode.
        include "src/asm/cvid_mkcb_common.i"

        xdef _cvid_mkcbfull4_rgb32
_cvid_mkcbfull4_rgb32:
        MKFULL  ENT_32

        xdef _cvid_mkcbfull1_rgb32
_cvid_mkcbfull1_rgb32:
        MKFULL  ENT_32

        end
