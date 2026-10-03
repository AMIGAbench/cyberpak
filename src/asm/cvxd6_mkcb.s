* cvxd6_mkcb.s - codebook entries for DHAM6 (AGA, double width), 68020 and up
*
* Full form (0x2000/0x2200); the partial one is called by the parser per entry.
* The format (groups of 4 bytes, byte k = data plane k) is described in the
* generator at byte_loops(): V1 group 0/1 = B G R G from y0 and y1 or y2 and
* y3, V4 group 0 = top << 4, 1 = top, 2 = bottom << 4, 3 = bottom.
*
* Like cvidh_mkcb.s (HAM6 single width): per pixel two pair indices from the
* large clamp tables, p = level << 4 | green (n4hi + n4lo, rounded), then
* tab_h6: at 0(a1,p*8) the four plane bytes with the two bits at 7-6, at
* 4(a1,p*8) at 3-2; a5 (tab_h6 + 2048) likewise for 5-4 and 1-0.
*
* Register use
*   a0 from   a1 table 7-6/3-2   a2 word block   a3 n4hi large   a4 n4lo large
*   a5 table 5-4/1-0             a6 entry
*   d0 cr   d1 cg   d2 cb   d3 _y   d4 pair blue/green   d6 pair red/green
*   d5 scratch   d7 counter

MP_FROM   equ  0
MP_CEND   equ  4
MP_CM     equ  8
MP_CMEND  equ 12
MP_YTAB   equ 16      ; word block: yTab at 0, UB -2048, UG -1536, VR -1024, VG -512
MP_R8     equ 20      ; n4hi large
MP_G8     equ 24      ; n4lo large
MP_B8     equ 28      ; tab_h6 + 2048
MP_PAT    equ 32      ; tab_h6

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

NLOAD   macro
        movea.l MP_CM(a0),a6
        movea.l MP_YTAB(a0),a2
        movea.l MP_R8(a0),a3
        movea.l MP_G8(a0),a4
        movea.l MP_B8(a0),a5
        movea.l MP_PAT(a0),a1
        movea.l MP_FROM(a0),a0
        endm

CHROMAN macro
        moveq   #0,d5
        move.b  4(a0),d5
        move.w  -2048(a2,d5.w*2),d2
        move.w  -1536(a2,d5.w*2),d1
        move.b  5(a0),d5
        move.w  -1024(a2,d5.w*2),d0
        add.w   -512(a2,d5.w*2),d1
        endm

* One pixel (a0)+ -> d4 = blue << 4 | green, d6 = red << 4 | green
PIX     macro
        moveq   #0,d5
        move.b  (a0)+,d5
        move.w  (a2,d5.w*2),d3
        move.w  d3,d5
        add.w   d1,d5
        moveq   #0,d6
        move.b  (a4,d5.w),d6
        move.w  d6,d4
        move.w  d3,d5
        add.w   d2,d5
        add.b   (a3,d5.w),d4
        add.w   d0,d3
        add.b   (a3,d3.w),d6
        endm

        section code

        xdef    _cvxd6_mkcbfull1
_cvxd6_mkcbfull1:
        movem.l d2-d7/a2-a6,-(sp)
        movea.l 48(sp),a0
        NCOUNT  d6_d1,d6_a1,d6_b1
        NLOAD
d6_l1:  CHROMAN
        PIX                             ; y0: B G R G an 7-4
        move.l  (a1,d4.w*8),d5
        or.l    (a5,d6.w*8),d5
        move.l  d5,(a6)
        PIX                             ; y1: an 3-0
        move.l  4(a1,d4.w*8),d5
        or.l    4(a5,d6.w*8),d5
        or.l    d5,(a6)
        PIX                             ; y2
        move.l  (a1,d4.w*8),d5
        or.l    (a5,d6.w*8),d5
        move.l  d5,4(a6)
        PIX                             ; y3
        move.l  4(a1,d4.w*8),d5
        or.l    4(a5,d6.w*8),d5
        or.l    d5,4(a6)
        addq.l  #2,a0
        lea     64(a6),a6
        dbra    d7,d6_l1
d6_d1:  movem.l (sp)+,d2-d7/a2-a6
        rts

        xdef    _cvxd6_mkcbfull4
_cvxd6_mkcbfull4:
        movem.l d2-d7/a2-a6,-(sp)
        movea.l 48(sp),a0
        NCOUNT  d6_d4,d6_a4,d6_b4
        NLOAD
d6_l4:  CHROMAN
        PIX                             ; y0: B G an 7-6
        move.l  (a1,d4.w*8),(a6)
        PIX                             ; y1: R G an 5-4
        move.l  (a5,d6.w*8),d5
        or.l    (a6),d5
        move.l  d5,(a6)
        lsr.l   #4,d5
        move.l  d5,4(a6)
        PIX                             ; y2
        move.l  (a1,d4.w*8),8(a6)
        PIX                             ; y3
        move.l  (a5,d6.w*8),d5
        or.l    8(a6),d5
        move.l  d5,8(a6)
        lsr.l   #4,d5
        move.l  d5,12(a6)
        addq.l  #2,a0
        lea     64(a6),a6
        dbra    d7,d6_l4
d6_d4:  movem.l (sp)+,d2-d7/a2-a6
        rts

        end
