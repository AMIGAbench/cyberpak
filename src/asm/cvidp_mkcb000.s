* cvidp_mkcb000.s - codebook entries of the planar path, 68000 player
*
* Like cvidp_mkcb.s (entry format, pattern block, grey levels), but CLUT in the
* FAST FORM as in cvidh_mkcb.s: the count once per call with dbra, chroma and
* yTab as words with a raw u/v index, large clamp tables without asr #6, the
* three shares summed up directly. Checked byte for byte against cvidp_mkcb.s.
* cvidp_mkcb.s itself stays as it is for the 020+ builds.
*
* Register use for CLUT
*   a0 from   a1 pattern block   a2 word block   a3 R8 large   a4 G8 large
*   a5 B8 large   a6 entry   d0 cr   d1 cg   d2 cb   d3 _y   d4 counter
*   d5 scratch   d6 upper pair   d7 lower pair

MP_FROM   equ  0
MP_CEND   equ  4
MP_CM     equ  8
MP_CMEND  equ 12
MP_YTAB   equ 16      ; word block: yTab at 0, UB -2048, UG -1536, VR -1024, VG -512
MP_R8     equ 20
MP_G8     equ 24
MP_B8     equ 28
MP_PAT    equ 32

NCOUNT  macro
        move.l  MP_CEND(a0),d4
        sub.l   MP_FROM(a0),d4
        bmi     \1
        cmp.l   #$5FFFF,d4
        bls     \2
        move.l  #$5FFFF,d4
\2:     divu    #6,d4
        swap    d4
        clr.w   d4
        swap    d4
        move.l  MP_CMEND(a0),d6
        sub.l   MP_CM(a0),d6
        bls     \1
        add.l   #63,d6
        lsr.l   #6,d6
        cmp.l   d6,d4
        bls     \3
        move.l  d6,d4
\3:     subq.l  #1,d4
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

* Add the index of a y (a0)+ into \1 (\1 cleared or shifted accordingly before).
IDXADD  macro
        moveq   #0,d5
        move.b  (a0)+,d5
        add.w   d5,d5
        move.w  (a2,d5.w),d3
        move.w  d3,d5
        add.w   d0,d5
        add.b   (a3,d5.w),\1
        move.w  d3,d5
        add.w   d1,d5
        add.b   (a4,d5.w),\1
        add.w   d2,d3
        add.b   (a5,d3.w),\1
        endm

PAIRSN  macro
        moveq   #0,d6
        IDXADD  d6
        lsl.w   #5,d6
        IDXADD  d6
        moveq   #0,d7
        IDXADD  d7
        lsl.w   #5,d7
        IDXADD  d7
        addq.l  #2,a0
        endm

COPY10  macro
        move.l  (a1,\1.w),(a6)+
        move.l  4(a1,\1.w),(a6)+
        move.w  8(a1,\1.w),(a6)+
        endm

COPY20  macro
        move.l  (a1,\1.w),(a6)+
        move.l  4(a1,\1.w),(a6)+
        move.l  8(a1,\1.w),(a6)+
        move.l  12(a1,\1.w),(a6)+
        move.l  16(a1,\1.w),(a6)+
        endm

MPENTER macro
        movem.l d2-d7/a2-a6,-(sp)            ; 44 bytes + return address
        movea.l 48(sp),a0
        move.l  MP_CMEND(a0),-(sp)           ; -> 4(sp)
        move.l  MP_CEND(a0),-(sp)            ; -> (sp)
        movea.l MP_CM(a0),a6
        movea.l MP_YTAB(a0),a2
        movea.l MP_R8(a0),a3
        movea.l MP_G8(a0),a4
        movea.l MP_B8(a0),a5
        movea.l MP_PAT(a0),a1
        movea.l MP_FROM(a0),a0
        endm

MPLEAVE macro
        addq.l  #8,sp                        ; discard cend, cmend
        movem.l (sp)+,d2-d7/a2-a6
        rts
        endm

* One more entry?  \1 = target if not.
MPHEAD  macro
        move.l  a0,d5
        addq.l  #6,d5
        cmp.l   (sp),d5                      ; from + 6 > cend ?
        bhi     \1
        cmpa.l  4(sp),a6                     ; codebook full ?
        bcc     \1
        endm

* One grey level index into d4: 32 levels, like cvid_set_gray(32).
IDXG    macro
        moveq   #0,d4
        move.b  (a0)+,d4
        lsr.b   #3,d4
        endm

* The two index pairs into d6 (y0 y1) and d7 (y2 y3). \1 = IDXC or IDXG.
PAIRS   macro
        \1
        move.w  d4,d6
        lsl.w   #5,d6
        \1
        or.w    d4,d6                        ; oben  = i0 << 5 | i1
        \1
        move.w  d4,d7
        lsl.w   #5,d7
        \1
        or.w    d4,d7                        ; unten = i2 << 5 | i3
        addq.l  #2,a0                        ; u and v
        endm

* V1: bytes 0-9 top left, 10-19 bottom left, 20-29 top right,
* 30-39 bottom right.
MAKE1   macro
        lsl.w   #4,d6
        lsl.w   #4,d7
        COPY10  d6
        COPY10  d7
        add.w   #$4000,d6                    ; rechte Position
        add.w   #$4000,d7
        COPY10  d6
        COPY10  d7
        lea     24(a6),a6                    ; 40 + 24 = 64 bytes per entry
        endm

* V4: bytes 0-19 from the upper pair, 20-39 from the lower one.
MAKE4   macro
        lsl.w   #5,d6
        eori.w  #$8000,d6                    ; -32768 + p << 5
        lsl.w   #5,d7
        eori.w  #$8000,d7
        COPY20  d6
        COPY20  d7
        lea     24(a6),a6
        endm

        section code

        xdef    _cvidp_mkcbfull1_clut
_cvidp_mkcbfull1_clut:
        movem.l d2-d7/a2-a6,-(sp)
        movea.l 48(sp),a0
        NCOUNT  np_d1,np_a1,np_b1
        NLOAD
np_l1:  CHROMAN
        PAIRSN
        lsl.w   #4,d6
        lsl.w   #4,d7
        COPY10  d6
        COPY10  d7
        add.w   #$4000,d6
        add.w   #$4000,d7
        COPY10  d6
        COPY10  d7
        lea     24(a6),a6
        dbra    d4,np_l1
np_d1:  movem.l (sp)+,d2-d7/a2-a6
        rts

        xdef    _cvidp_mkcbfull4_clut
_cvidp_mkcbfull4_clut:
        movem.l d2-d7/a2-a6,-(sp)
        movea.l 48(sp),a0
        NCOUNT  np_d4,np_a4,np_b4
        NLOAD
np_l4:  CHROMAN
        PAIRSN
        lsl.w   #5,d6
        eori.w  #$8000,d6
        lsl.w   #5,d7
        eori.w  #$8000,d7
        COPY20  d6
        COPY20  d7
        lea     24(a6),a6
        dbra    d4,np_l4
np_d4:  movem.l (sp)+,d2-d7/a2-a6
        rts

        xdef    _cvidp_mkcbfull1_gray
_cvidp_mkcbfull1_gray:
        MPENTER
mp_l1g: MPHEAD  mp_d1g
        PAIRS   IDXG
        MAKE1
        bra     mp_l1g
mp_d1g: MPLEAVE

        xdef    _cvidp_mkcbfull4_gray
_cvidp_mkcbfull4_gray:
        MPENTER
mp_l4g: MPHEAD  mp_d4g
        PAIRS   IDXG
        MAKE4
        bra     mp_l4g
mp_d4g: MPLEAVE

        end
