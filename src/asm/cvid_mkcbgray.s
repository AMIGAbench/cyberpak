* cvid_mkcbgray.s - building codebooks for CVID_OUT_GRAY8, full form.
*
* Grey levels are the cheapest of the four output modes: no chroma, no clamp
* tables, no lookup. From the four Y bytes of an entry only the bits that fit
* the screen are shifted out (`gsh`: 0 at 256 levels, 3 at 32 for ECS), and
* then packed.
*
* WHY A FILE OF ITS OWN and not MKFULL with an entry macro: MKENTER loads five
* pointers this version never touches - yTab and the three clamp tables. A
* leaner frame of its own saves them, and half of the saved registers as well.
*
*
* IT RUNS ON EVERY CPU. No scaling, no full extension words, only register
* shifts - so on the 68000 too. That is no accident but the reason why grey
* levels are the recommended choice for ECS: there every computation saved is
* worth the most.
*
* Register use
*   a0 from   a1 cend   a6 cm        d2 cmend   d3 gsh
*   d0/d1/d4/d5  scratch

        include "src/asm/cvid_mkcb_common.i"

        section code

* Read two Y values, quantise them and put them as a:a:b:b to \1(a6) and
* \1+4(a6) - the V1 form, where every value stands twice side by side and the
* row twice one below the other.
GPAIR1  macro
        moveq   #0,d4
        move.b  (a0)+,d4
        lsr.l   d3,d4                        ; a
        move.l  d4,d0
        lsl.l   #8,d0
        or.l    d4,d0                        ; 0:0:a:a
        swap    d0                           ; a:a:0:0
        moveq   #0,d4
        move.b  (a0)+,d4
        lsr.l   d3,d4                        ; b
        move.l  d4,d1
        lsl.l   #8,d1
        or.l    d4,d1                        ; 0:0:b:b
        or.l    d1,d0                        ; a:a:b:b
        move.l  d0,\1(a6)
        move.l  d0,\1+4(a6)
        endm

* Two Y values for the V4 form: \1(a6) gets a:b:0:0, \1+8(a6) gets 0:0:a:b.
* One is the other shifted by 16 bit - so build it once and `swap`.
*
GPAIR4  macro
        moveq   #0,d4
        move.b  (a0)+,d4
        lsr.l   d3,d4                        ; a
        lsl.l   #8,d4
        move.l  d4,d0                        ; a<<8
        moveq   #0,d4
        move.b  (a0)+,d4
        lsr.l   d3,d4                        ; b
        or.l    d4,d0                        ; 0:0:a:b
        move.l  d0,\1+8(a6)
        swap    d0                           ; a:b:0:0
        move.l  d0,\1(a6)
        endm

* Frame. It stops on the same two conditions as MKFULL: enough bytes in the
* chunk, and still room in the 256-entry codebook.
GENTER  macro
        movem.l d2-d5/a6,-(sp)
        movea.l 24(sp),a0
        movea.l MK_CEND(a0),a1
        movea.l MK_CM(a0),a6
        move.l  MK_CMEND(a0),d2
        move.l  MK_GSH(a0),d3
        movea.l MK_FROM(a0),a0
        endm

GLEAVE  macro
        movea.l 24(sp),a1
        move.l  a0,MK_FROM(a1)
        movem.l (sp)+,d2-d5/a6
        rts
        endm

GTEST   macro
        move.l  a0,d5                        ; from + 6 <= cend ?
        addq.l  #6,d5
        cmpa.l  d5,a1
        bcs     \1
        cmpa.l  d2,a6                        ; still room in the codebook ?
        bcc     \1
        endm

* -------- 0x2200: V1 ---------------------------------------------------
        xdef _cvid_mkcbfull1_gray
_cvid_mkcbfull1_gray:
        GENTER
.loop:
        GTEST   .done
        GPAIR1  0                            ; q0 = q1 aus y0,y1
        GPAIR1  8                            ; q2 = q3 aus y2,y3
        addq.l  #2,a0                        ; skip u and v
        lea     16(a6),a6
        bra     .loop
.done:
        GLEAVE

* -------- 0x2000: V4 ---------------------------------------------------
        xdef _cvid_mkcbfull4_gray
_cvid_mkcbfull4_gray:
        GENTER
.loop:
        GTEST   .done
        GPAIR4  0                            ; q0 / q2 aus y0,y1
        GPAIR4  4                            ; q1 / q3 aus y2,y3
        addq.l  #2,a0
        lea     16(a6),a6
        bra     .loop
.done:
        GLEAVE

        end
