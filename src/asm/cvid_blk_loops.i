* cvid_blk_loops.i - loop frame of the block chunks 0x3000 and 0x3100.
*
* Included by two files that differ ONLY in the two macros PUTV4 and PUTV1:
*
*   src/asm/cvid_blk_020.s   16 bit per pixel, block row = 8 bytes
*   src/asm/cvid_blk8_020.s   8 bit per pixel, block row = 4 bytes
*
* Everything else - bit stream, row change, abort conditions - is identical.
* Keeping it here once was the alternative to 200 lines of duplicate of a loop
* measured by hand; that is exactly the kind of thing that rots when it is
* kept apart.
* sonst getrennt.
* Register use (all seven address registers are taken)
*   a0  state block or scratch       a1  from      a2  cend
*   a3  p0        a4  cb0            a5  cb1       a6  dirty row pointer
*   d0  flag word d1  remaining bits d2  bx
*   d3  binc      d5  stride         d4/d6/d7  scratch
*   d3  binc      d5  stride         d4/d6/d7  Scratch
* Two values deliberately do NOT live in registers but are fetched from the
* state block at the row change - once per block row instead of per block, so
* 45 times per frame at 320x180:
*
*   `wrap`    frees d4. The 8-bit version needs the third data register for
*             its OR operation.
*   `ylimit`  frees a6. That now holds the dirty row pointer: one byte per
*             block row, which the 8-bit version sets for every block written
*             (`st (a6)`). C2P afterwards then only has to convert the rows
*             that changed - measured, 36-58 % of the blocks per frame stay
*             unchanged.
*
* The 16-bit version marks nothing (its PUT macros contain no `st`) but moves
* a6 along all the same. For the change it pays no more than those two
* instructions per block row.
*

CVID_FROM   equ  0
CVID_CEND   equ  4
CVID_P0     equ  8
CVID_CB0    equ 12
CVID_CB1    equ 16
CVID_YLIMIT equ 20
CVID_STRIDE equ 24
CVID_BINC   equ 28
CVID_WRAP   equ 32
CVID_BX     equ 36
CVID_BCOLS  equ 40
CVID_DIRTY  equ 44

* --- Frame macros ------------------------------------------------------
*
* A version can replace them by setting CVX_OWN_FRAME and defining ENTER,
* LEAVE, ADVANCE and ENDROW itself BEFORE including this file. The 68000
* variant did exactly that: the 68000 knows neither scaling nor full extension
* words, so it needs a second address register pointing at row 2 instead of
* (a3,d5.l*2) - and that one has to move along at the block advance.
* Blockvorschub mitwandern.

        IFND    CVX_OWN_FRAME

* Fetch the state block into the registers. The argument sits at 48(sp):
* movem saves 11 registers (44 bytes), plus the return address.
ENTER   macro
        movem.l d2-d7/a2-a6,-(sp)
        movea.l 48(sp),a0
        movea.l CVID_FROM(a0),a1
        movea.l CVID_CEND(a0),a2
        movea.l CVID_P0(a0),a3
        movea.l CVID_CB0(a0),a4
        movea.l CVID_CB1(a0),a5
        movea.l CVID_DIRTY(a0),a6
        move.l  CVID_STRIDE(a0),d5
        move.l  CVID_BINC(a0),d3
        move.l  CVID_BX(a0),d2
        moveq   #0,d0
        moveq   #0,d1
        endm

LEAVE   macro
        movea.l 48(sp),a0
        move.l  a1,CVID_FROM(a0)
        move.l  a3,CVID_P0(a0)
        move.l  d2,CVID_BX(a0)
        move.l  a6,CVID_DIRTY(a0)
        movem.l (sp)+,d2-d7/a2-a6
        rts
        endm

* One block further.
ADVANCE macro
        adda.l  d3,a3
        endm

* Fetch the next 32-bit flag word from the bit stream.
*
* WHY THIS IS A MACRO OF ITS OWN: `a1` points at an ARBITRARY byte position -
* a V1 block advances the read pointer by exactly one byte. The 68020 reads a
* longword from an odd address as well; the 68000 answers with an address error
* (guru 8000 0003). The 68000 version therefore replaces this macro by four
* byte accesses.
GETFLAG macro
        move.l  (a1)+,d0
        endm

* Row change: the last block of a row advanced by `binc` but would have needed
* `wrap`. Add the difference, set the block counter anew.
ENDROW  macro
        movea.l 48(sp),a0
        move.l  CVID_WRAP(a0),d7
        sub.l   d3,d7
        adda.l  d7,a3
        move.l  CVID_BCOLS(a0),d2
        addq.l  #1,a6                        ; next block row
        endm

        ENDC

* ================================================================
* BLKLOOPS \1 - generates _cvid_blk3100_\1 and _cvid_blk3000_\1
* ================================================================
BLKLOOPS macro

* 0x3100 - continuous bit stream: 0 = skip, 10 = V1, 11 = V4
*
* TWO nested loops: the check `p0 < ylimit` sits in the outer one, so once per
* block row instead of per block. p0 can only cross the limit at a row break,
* within a row it runs horizontally. That is what gcc does as well - the first
* version checked per block and was slower for it, despite fewer instructions.
*
*
* Flag bits through the carry: `add.l d0,d0` shifts bit 31 out, `bcc` tests
* it. Four instructions per bit instead of seven, and one register free.
        xdef _cvid_blk3100_\1
_cvid_blk3100_\1:
        ENTER
.row:
        movea.l 48(sp),a0
        cmpa.l  CVID_YLIMIT(a0),a3           ; p0 >= ylimit ? (per row)
        bcc     .done
.blk:
        subq.l  #1,d1                        ; any bits left in the flag word?
        bge.s   .have
        lea     4(a1),a0
        cmpa.l  a2,a0
        bhi     .done
        GETFLAG
        moveq   #31,d1
.have:
        add.l   d0,d0
        bcc     .next                        ; block unchanged
        subq.l  #1,d1                        ; Typbit
        bge.s   .have2
        lea     4(a1),a0
        cmpa.l  a2,a0
        bhi     .done
        GETFLAG
        moveq   #31,d1
.have2:
        add.l   d0,d0
* No forced .s: with RGB32 PUTV4 is too long for a short branch (16 stores
* per block). vasm picks the shortest form that works by itself - for the
* leaner versions it stays a short branch.
        bcc     .isv1
        PUTV4   .done
        bra     .next
.isv1:
        PUTV1   .done
.next:
        ADVANCE                              ; one block on (binc)
        subq.l  #1,d2
        bne     .blk
        ENDROW
        bra     .row
.done:
        LEAVE

* 0x3000 - one flag bit per block: 1 = V4, 0 = V1, no skip
        xdef _cvid_blk3000_\1
_cvid_blk3000_\1:
        ENTER
.row:
        movea.l 48(sp),a0
        cmpa.l  CVID_YLIMIT(a0),a3
        bcc     .done
.blk:
        subq.l  #1,d1
        bge.s   .have
        lea     4(a1),a0
        cmpa.l  a2,a0
        bhi     .done
        GETFLAG
        moveq   #31,d1
.have:
        add.l   d0,d0
* No forced .s: with RGB32 PUTV4 is too long for a short branch (16 stores
* per block). vasm picks the shortest form that works by itself - for the
* leaner versions it stays a short branch.
        bcc     .isv1
        PUTV4   .done
        bra     .next
.isv1:
        PUTV1   .done
.next:
        ADVANCE
        subq.l  #1,d2
        bne     .blk
        ENDROW
        bra     .row
.done:
        LEAVE

* 0x3200 - V1 only, no flag word. In the C builds this chunk stays with the C
* code (cvid_body.h); the 020/030 assembler player (src/a020) calls this
* version for its RTG modes.
        xdef _cvid_blk3200_\1
_cvid_blk3200_\1:
        ENTER
.row:
        movea.l 48(sp),a0
        cmpa.l  CVID_YLIMIT(a0),a3
        bcc     .done
.blk:
        PUTV1   .done
        ADVANCE
        subq.l  #1,d2
        bne     .blk
        ENDROW
        bra     .row
.done:
        LEAVE

        endm
