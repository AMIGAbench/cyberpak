* cvxg8_mkcb.s - codebook entries for GRAY with 8 planes (AGA), 68020 and up
*
* Full form (0x2000/0x2200); the partial one is called by the parser per entry
* with a 6-byte range. Format as in cvidp_mkcb000.s with P = 8, 64 bytes:
*
*   V1   bytes 0-31 left position, row r plane k at r*8+k: upper nibble
*        a a b b (a = bit k of y0, b = bit k of y1; rows 2/3 y2 y3),
*        bytes 32-63 right position: the same as the lower nibble
*   V4   group g at g*8: group 0 (y0, y1) at bits 7-6, 1 at 5-4, 2 at 3-2,
*        3 at 1-0; groups 4-7 likewise with y2 y3
*
* Two bit vector tables of 256 x 8 bytes (tabellen.s): tab_c8 byte k = $C0 and
* tab_a8 = $80 when bit k of the grey value is set. An entry is therefore two
* longwords per row: load, shift, or them together. The shifts stay inside the
* byte (at most $C0 >> 6), so they are correct across longwords as well.
*
* Register use
*   a0 from   a1 tab_c8   a2 tab_a8   a6 entry
*   d0 grey value   d2/d3 row top/bottom   d4 scratch   d7 counter

MP_FROM   equ  0
MP_CEND   equ  4
MP_CM     equ  8
MP_CMEND  equ 12
MP_B8     equ 28      ; tab_a8
MP_PAT    equ 32      ; tab_c8

* Counter as in cvidh_mkcb.s: d7 = count - 1, branches to \1 at 0 entries.
NCOUNT  macro
        move.l  MP_CEND(a0),d7
        sub.l   MP_FROM(a0),d7
        bmi     \1
        cmp.l   #$5FFFF,d7
        bls     \2
        move.l  #$5FFFF,d7
\2:     divu    #6,d7
        swap    d7
        clr.w   d7
        swap    d7
        move.l  MP_CMEND(a0),d6
        sub.l   MP_CM(a0),d6
        bls     \1
        add.l   #63,d6
        lsr.l   #6,d6
        cmp.l   d6,d7
        bls     \3
        move.l  d6,d7
\3:     subq.l  #1,d7
        bmi     \1
        endm

* V1: two grey values (a0)+ -> nibble a a b b per plane in d2:d3, then the
* left position at \1 and \1+8, the right one at \1+32 and \1+40.
V1ROW   macro
        move.b  (a0)+,d0
        move.l  (a1,d0.w*8),d2
        move.l  4(a1,d0.w*8),d3
        move.b  (a0)+,d0
        move.l  (a1,d0.w*8),d4
        lsr.l   #2,d4
        or.l    d4,d2
        move.l  4(a1,d0.w*8),d4
        lsr.l   #2,d4
        or.l    d4,d3
        move.l  d2,\1(a6)
        move.l  d3,\1+4(a6)
        move.l  d2,\1+8(a6)
        move.l  d3,\1+12(a6)
        lsr.l   #4,d2
        lsr.l   #4,d3
        move.l  d2,\1+32(a6)
        move.l  d3,\1+36(a6)
        move.l  d2,\1+40(a6)
        move.l  d3,\1+44(a6)
        endm

* V4: two grey values (a0)+ -> groups at \1, \1+8, \1+16, \1+24.
V4ROW   macro
        move.b  (a0)+,d0
        move.l  (a2,d0.w*8),d2
        move.l  4(a2,d0.w*8),d3
        move.b  (a0)+,d0
        move.l  (a2,d0.w*8),d4
        lsr.l   #1,d4
        or.l    d4,d2
        move.l  4(a2,d0.w*8),d4
        lsr.l   #1,d4
        or.l    d4,d3
        move.l  d2,\1(a6)
        move.l  d3,\1+4(a6)
        lsr.l   #2,d2
        lsr.l   #2,d3
        move.l  d2,\1+8(a6)
        move.l  d3,\1+12(a6)
        lsr.l   #2,d2
        lsr.l   #2,d3
        move.l  d2,\1+16(a6)
        move.l  d3,\1+20(a6)
        lsr.l   #2,d2
        lsr.l   #2,d3
        move.l  d2,\1+24(a6)
        move.l  d3,\1+28(a6)
        endm

        section code

        xdef    _cvxg8_mkcbfull1
_cvxg8_mkcbfull1:
        movem.l d2-d7/a2-a6,-(sp)
        movea.l 48(sp),a0
        NCOUNT  g8_d1,g8_a1,g8_b1
        movea.l MP_CM(a0),a6
        movea.l MP_PAT(a0),a1
        movea.l MP_FROM(a0),a0
        moveq   #0,d0
g8_l1:  V1ROW   0
        V1ROW   16
        addq.l  #2,a0
        lea     64(a6),a6
        dbra    d7,g8_l1
g8_d1:  movem.l (sp)+,d2-d7/a2-a6
        rts

        xdef    _cvxg8_mkcbfull4
_cvxg8_mkcbfull4:
        movem.l d2-d7/a2-a6,-(sp)
        movea.l 48(sp),a0
        NCOUNT  g8_d4,g8_a4,g8_b4
        movea.l MP_CM(a0),a6
        movea.l MP_B8(a0),a2
        movea.l MP_FROM(a0),a0
        moveq   #0,d0
g8_l4:  V4ROW   0
        V4ROW   32
        addq.l  #2,a0
        lea     64(a6),a6
        dbra    d7,g8_l4
g8_d4:  movem.l (sp)+,d2-d7/a2-a6
        rts

        end
