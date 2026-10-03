* cvxd8_mkcb.s - codebook entries for DHAM8 (AGA, double width), 68020 and up
*
* Full form (0x2000/0x2200); the partial one is called by the parser per entry.
* Format as in cvxd6_mkcb.s, but six data planes and groups of 8 bytes (two
* longwords): V1 group 0/1 at 0/8, V4 groups at 0, 8, 16, 24.
*
* Level per share min(63, (v+2)>>2) from ONE large clamp table (l6), pair index
* p = level << 6 | green (12 bit). Two pair tables of 4096 x 8 bytes are built
* at runtime by cvid_open (_cvxd8_paare): h76 with the two bits at 7-6, h54 at
* 5-4; 3-2 and 1-0 are the same longwords >> 4 (the bits stay inside the byte).
*
* Register use
*   a0 from   a1 h76   a2 word block   a3 l6 large   a5 h54   a6 entry
*   d0 cr   d1 cg   d2 cb   d3 _y   d4 pair blue/green   d6 pair red/green
*   d5 scratch   d7 counter

MP_FROM   equ  0
MP_CEND   equ  4
MP_CM     equ  8
MP_CMEND  equ 12
MP_YTAB   equ 16
MP_R8     equ 20      ; l6 large
MP_B8     equ 28      ; h54
MP_PAT    equ 32      ; h76

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

* One pixel (a0)+ -> d4 = blue << 6 | green, d6 = red << 6 | green
PIX8    macro
        moveq   #0,d5
        move.b  (a0)+,d5
        move.w  (a2,d5.w*2),d3
        move.w  d3,d5
        add.w   d1,d5
        moveq   #0,d6
        move.b  (a3,d5.w),d6
        move.w  d3,d5
        add.w   d2,d5
        moveq   #0,d4
        move.b  (a3,d5.w),d4
        lsl.w   #6,d4
        or.w    d6,d4
        add.w   d0,d3
        moveq   #0,d5
        move.b  (a3,d3.w),d5
        lsl.w   #6,d5
        or.w    d5,d6
        endm

* V1 group at \1: y (a0)+ at 7-4 and y (a0)+ at 3-0.
V1GRP   macro
        PIX8
        move.l  (a1,d4.w*8),d5
        or.l    (a5,d6.w*8),d5
        move.l  d5,\1(a6)
        move.l  4(a1,d4.w*8),d5
        or.l    4(a5,d6.w*8),d5
        move.l  d5,\1+4(a6)
        PIX8
        move.l  (a1,d4.w*8),d5
        or.l    (a5,d6.w*8),d5
        lsr.l   #4,d5
        or.l    d5,\1(a6)
        move.l  4(a1,d4.w*8),d5
        or.l    4(a5,d6.w*8),d5
        lsr.l   #4,d5
        or.l    d5,\1+4(a6)
        endm

* V4 groups at \1 and \1+8: B G from y (a0)+ at 7-6, R G from y (a0)+ at 5-4.
V4GRP   macro
        PIX8
        move.l  (a1,d4.w*8),\1(a6)
        move.l  4(a1,d4.w*8),\1+4(a6)
        PIX8
        move.l  (a5,d6.w*8),d5
        or.l    \1(a6),d5
        move.l  d5,\1(a6)
        lsr.l   #4,d5
        move.l  d5,\1+8(a6)
        move.l  4(a5,d6.w*8),d5
        or.l    \1+4(a6),d5
        move.l  d5,\1+4(a6)
        lsr.l   #4,d5
        move.l  d5,\1+12(a6)
        endm

        section code

        xdef    _cvxd8_mkcbfull1
_cvxd8_mkcbfull1:
        movem.l d2-d7/a2-a6,-(sp)
        movea.l 48(sp),a0
        NCOUNT  d8_d1,d8_a1,d8_b1
        NLOAD
d8_l1:  CHROMAN
        V1GRP   0
        V1GRP   8
        addq.l  #2,a0
        lea     64(a6),a6
        dbra    d7,d8_l1
d8_d1:  movem.l (sp)+,d2-d7/a2-a6
        rts

        xdef    _cvxd8_mkcbfull4
_cvxd8_mkcbfull4:
        movem.l d2-d7/a2-a6,-(sp)
        movea.l 48(sp),a0
        NCOUNT  d8_d4,d8_a4,d8_b4
        NLOAD
d8_l4:  CHROMAN
        V4GRP   0
        V4GRP   16
        addq.l  #2,a0
        lea     64(a6),a6
        dbra    d7,d8_l4
d8_d4:  movem.l (sp)+,d2-d7/a2-a6
        rts

* void cvxd8_paare(uint8_t *target) - the two pair tables (4096 x 8 bytes each,
* 65536 bytes in one piece): target = h76, target + 32768 = h54. p = hi << 6 |
* lo; byte k (k < 6) = bit k of hi << 7 | bit k of lo << 6, or << 5 / << 4.
        xdef    _cvxd8_paare
_cvxd8_paare:
        movem.l d2-d5/a2,-(sp)
        movea.l 24(sp),a0
        movea.l a0,a1
        adda.l  #32768,a1
        moveq   #0,d2                   ; p
.p:     move.l  d2,d3
        lsr.l   #6,d3                   ; hi
        moveq   #63,d4
        and.l   d2,d4                   ; lo
        moveq   #0,d5                   ; k
.k:     moveq   #0,d0
        moveq   #0,d1
        btst    d5,d3
        beq     .lo
        moveq   #-128,d0                ; byte $80
        moveq   #$20,d1
.lo:    btst    d5,d4
        beq     .setzen
        or.b    #$40,d0
        or.b    #$10,d1
.setzen:
        move.b  d0,(a0)+
        move.b  d1,(a1)+
        addq.w  #1,d5
        cmp.w   #8,d5
        blo     .k
        addq.w  #1,d2
        cmp.w   #4096,d2
        blo     .p
        movem.l (sp)+,d2-d5/a2
        rts

        end
