* cvxc_mkcb.s - codebook entries for HAM through a chunky buffer (C2P),
* 020/030 player. Used where a build sends HAM through C2P (the 68080 build,
* and the measurement direct against C2P): the same rounded levels as the
* direct routines (tab_n4lo for HAM6/DHAM6, tab_l6 for DHAM8, made large in
* cvid_open), so that both paths yield byte-identical planes and only the time
* differs.
*
* The block loops are the existing chunky ones:
*
*   HAM6   pix8 (one byte per screen pixel, 16 bytes per entry). The pattern
*          B,G,R,G repeats every four columns, so a V4 quarter depends on where
*          it sits. That fits the pix8 entry exactly: the loop takes q0/q1 for
*          the left quarter and q2/q3 for the right one.
*   DHAM6  rgb16 (one word per SOURCE pixel = two screen bytes). The pattern
*   DHAM8  repeats every two source columns: even (B,G), odd (R,G) - no
*          quarter depends on where it sits.
*
* Pixel bytes: HAM6/DHAM6 control bits 5-4 (B $10, R $20, G $30) above the
* 4-bit level; DHAM8 control bits 7-6 (B $40, R $80, G $C0) above 6 bits.
*
*   HAM6  V1  q0 = q1 = B(y0) G(y0) R(y1) G(y1)    q2 = q3 from y2, y3
*         V4  q0 = B(a) G(b) 0 0   q1 = B(d) G(e) 0 0
*             q2 = 0 0 R(a) G(b)   q3 = 0 0 R(d) G(e)
*   DHAM  V1  qk = BG(yk) << 16 | RG(yk)
*         V4  q0 = BG(a) << 16 | RG(b)   q1 = BG(d) << 16 | RG(e)
*             (the 16-bit V4 loop does not read q2/q3)
*
* Chroma and luma as in cvidh_mkcb.s: word block tab_wort, raw u/v byte as the
* index, level = large[_y + c] (word index, no asr).
*
* Register use
*   a0 from   a2 word block   a3 level table (large)   a6 entry
*   d0 cr   d1 cg   d2 cb   d3 _y   d4/d5/d6 scratch   d7 counter
MK_FROM   equ  0
MK_CEND   equ  4
MK_CM     equ  8
MK_CMEND  equ 12
MK_YTAB   equ 16      ; word block: yTab at 0, UB -2048, UG -1536, VR -1024, VG -512
MK_R8     equ 20      ; level table large, at sum 0

* Counter: d7 = count - 1, branches to \1 at 0 entries. a0 = state.
* Count = min((cend - from) / 6, (cmend - cm + 15) / 16).
CCOUNT  macro
        move.l  MK_CEND(a0),d7
        sub.l   MK_FROM(a0),d7
        bmi     \1
        cmp.l   #$5FFFF,d7
        bls     \2
        move.l  #$5FFFF,d7
\2:     divu    #6,d7
        swap    d7
        clr.w   d7
        swap    d7
        move.l  MK_CMEND(a0),d6
        sub.l   MK_CM(a0),d6
        bls     \1
        add.l   #15,d6
        lsr.l   #4,d6
        cmp.l   d6,d7
        bls     \3
        move.l  d6,d7
\3:     subq.l  #1,d7
        bmi     \1
        endm

CLOAD   macro
        movea.l MK_CM(a0),a6
        movea.l MK_YTAB(a0),a2
        movea.l MK_R8(a0),a3
        movea.l MK_FROM(a0),a0
        endm

* Write from back (as in cvid_mkcbgray.s), restore the registers.
CLEAVE  macro
        movea.l 48(sp),a1
        move.l  a0,MK_FROM(a1)
        movem.l (sp)+,d2-d7/a2-a6
        rts
        endm

CHROMAC macro
        moveq   #0,d5
        move.b  4(a0),d5
        add.w   d5,d5
        adda.w  d5,a2
        move.w  -2048(a2),d2
        move.w  -1536(a2),d1
        suba.w  d5,a2
        moveq   #0,d5
        move.b  5(a0),d5
        add.w   d5,d5
        adda.w  d5,a2
        move.w  -1024(a2),d0
        add.w   -512(a2),d1
        suba.w  d5,a2
        endm

* d3 = yTab[next Y byte]
LUMA    macro
        moveq   #0,d5
        move.b  (a0)+,d5
        add.w   d5,d5
        move.w  (a2,d5.w),d3
        endm

* HAM6 V1: two Y values (left, right) -> one longword B G R G, to \1(a6) and
* \1+4(a6).
H6V1    macro
        LUMA
        moveq   #0,d6
        move.w  d3,d5
        add.w   d2,d5
        move.b  (a3,d5.w),d6            ; B(links)
        lsl.l   #8,d6
        add.w   d1,d3
        move.b  (a3,d3.w),d6            ; G(links)
        LUMA
        lsl.l   #8,d6
        move.w  d3,d5
        add.w   d0,d5
        move.b  (a3,d5.w),d6            ; R(rechts)
        lsl.l   #8,d6
        add.w   d1,d3
        move.b  (a3,d3.w),d6            ; G(rechts)
        or.l    #$10302030,d6
        move.l  d6,\1(a6)
        move.l  d6,\1+4(a6)
        endm

* HAM6 V4: two Y values (a left, b right) -> \1(a6) = B(a) G(b) 0 0,
* \1+8(a6) = 0 0 R(a) G(b).
H6V4    macro
        LUMA
        moveq   #0,d6
        move.w  d3,d5
        add.w   d2,d5
        move.b  (a3,d5.w),d6            ; B(a)
        moveq   #0,d4
        add.w   d0,d3
        move.b  (a3,d3.w),d4            ; R(a)
        LUMA
        add.w   d1,d3
        move.b  (a3,d3.w),d5            ; G(b)
        lsl.w   #8,d6
        move.b  d5,d6
        lsl.w   #8,d4
        move.b  d5,d4
        or.w    #$1030,d6
        or.w    #$2030,d4
        move.l  d4,\1+8(a6)
        swap    d6
        move.l  d6,\1(a6)
        endm

* DHAM V1: one Y -> BG << 16 | RG to (a6)+. \1 = control bits B<<8|G,
* \2 = R<<8|G.
DV1     macro
        LUMA
        moveq   #0,d6
        move.w  d3,d5
        add.w   d2,d5
        move.b  (a3,d5.w),d6            ; B
        moveq   #0,d4
        move.w  d3,d5
        add.w   d0,d5
        move.b  (a3,d5.w),d4            ; R
        add.w   d1,d3
        move.b  (a3,d3.w),d5            ; G
        lsl.w   #8,d6
        move.b  d5,d6
        lsl.w   #8,d4
        move.b  d5,d4
        or.w    #\1,d6
        or.w    #\2,d4
        swap    d6
        move.w  d4,d6
        move.l  d6,(a6)+
        endm

* DHAM V4: two Y values (a even, b odd) -> BG(a) << 16 | RG(b) to (a6)+.
DV4     macro
        LUMA
        moveq   #0,d6
        move.w  d3,d5
        add.w   d2,d5
        move.b  (a3,d5.w),d6            ; B(a)
        lsl.w   #8,d6
        add.w   d1,d3
        move.b  (a3,d3.w),d6            ; G(a)
        LUMA
        moveq   #0,d4
        move.w  d3,d5
        add.w   d0,d5
        move.b  (a3,d5.w),d4            ; R(b)
        lsl.w   #8,d4
        add.w   d1,d3
        move.b  (a3,d3.w),d4            ; G(b)
        or.w    #\1,d6
        or.w    #\2,d4
        swap    d6
        move.w  d4,d6
        move.l  d6,(a6)+
        endm

        section code

        xdef    _cvxc_mkcbfull1_ham6
_cvxc_mkcbfull1_ham6:
        movem.l d2-d7/a2-a6,-(sp)
        movea.l 48(sp),a0
        CCOUNT  c61_d,c61_a,c61_b
        CLOAD
c61_l:  CHROMAC
        H6V1    0
        H6V1    8
        addq.l  #2,a0
        lea     16(a6),a6
        dbra    d7,c61_l
c61_d:  CLEAVE

        xdef    _cvxc_mkcbfull4_ham6
_cvxc_mkcbfull4_ham6:
        movem.l d2-d7/a2-a6,-(sp)
        movea.l 48(sp),a0
        CCOUNT  c64_d,c64_a,c64_b
        CLOAD
c64_l:  CHROMAC
        H6V4    0
        H6V4    4
        addq.l  #2,a0
        lea     16(a6),a6
        dbra    d7,c64_l
c64_d:  CLEAVE

        xdef    _cvxc_mkcbfull1_dham6
_cvxc_mkcbfull1_dham6:
        movem.l d2-d7/a2-a6,-(sp)
        movea.l 48(sp),a0
        CCOUNT  cd61_d,cd61_a,cd61_b
        CLOAD
cd61_l: CHROMAC
        DV1     $1030,$2030
        DV1     $1030,$2030
        DV1     $1030,$2030
        DV1     $1030,$2030
        addq.l  #2,a0
        dbra    d7,cd61_l
cd61_d: CLEAVE

        xdef    _cvxc_mkcbfull4_dham6
_cvxc_mkcbfull4_dham6:
        movem.l d2-d7/a2-a6,-(sp)
        movea.l 48(sp),a0
        CCOUNT  cd64_d,cd64_a,cd64_b
        CLOAD
cd64_l: CHROMAC
        DV4     $1030,$2030
        DV4     $1030,$2030
        addq.l  #2,a0
        lea     8(a6),a6
        dbra    d7,cd64_l
cd64_d: CLEAVE

        xdef    _cvxc_mkcbfull1_dham8
_cvxc_mkcbfull1_dham8:
        movem.l d2-d7/a2-a6,-(sp)
        movea.l 48(sp),a0
        CCOUNT  cd81_d,cd81_a,cd81_b
        CLOAD
cd81_l: CHROMAC
        DV1     $40C0,$80C0
        DV1     $40C0,$80C0
        DV1     $40C0,$80C0
        DV1     $40C0,$80C0
        addq.l  #2,a0
        dbra    d7,cd81_l
cd81_d: CLEAVE

        xdef    _cvxc_mkcbfull4_dham8
_cvxc_mkcbfull4_dham8:
        movem.l d2-d7/a2-a6,-(sp)
        movea.l 48(sp),a0
        CCOUNT  cd84_d,cd84_a,cd84_b
        CLOAD
cd84_l: CHROMAC
        DV4     $40C0,$80C0
        DV4     $40C0,$80C0
        addq.l  #2,a0
        lea     8(a6),a6
        dbra    d7,cd84_l
cd84_d: CLEAVE

        end
