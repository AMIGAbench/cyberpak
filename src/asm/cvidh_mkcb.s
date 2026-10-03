* cvidh_mkcb.s - codebook entries for HAM6 LORES PLANAR, 68000 player
*
* Like cvidp_mkcb.s, but the entries carry HAM instructions instead of palette
* indices. Model and yardstick: make_v1_h6()/make_v4_h6() in
* src/codec/cvidplanar.c; the planar bench checked frame by frame against
* CVID_OUT_HAM6_1X + C2P in 6 planes.
*
* Only the FULL form (0x2000/0x2200), the partial one stays with the C code.
*
* HAM6 single width: the pixel column mod 4 sets blue, green, red, green. The
* control planes 4/5 are fixed ($DD/$77); an entry holds only the four data
* planes, byte k of a 4-byte group = plane k. A group is therefore exactly one
* longword.
*
*   V1   0..15  left, rows 0..3: B(y0) G(y0) R(y1) G(y1) at bits 7..4
*               (rows 2/3: y2 y3)           16..31  right: at bits 3..0
*   V4   group 0-3 (top row): B(y0)G(y1) at 7-6, R(y0)G(y1) at 5-4,
*               BG at 3-2, RG at 1-0; group 4-7 likewise with y2 y3
*
* Per pixel pair one index p = hi << 4 | lo from two byte clamp tables
* (n4hi = level << 4, n4lo = level, level = (value * 15 + 127) / 255, rounded:
* adding instead of shifting), then p << 3 into a table with 8 bytes per p: at
* 0(a1,p) the four plane bytes with the two bits at 7-6, at 4(a1,p) at 3-2; a5
* likewise for 5-4 and 1-0. A V4 entry is four longword copies per row, a V1
* entry two combined longwords whose right-hand form is an lsr.l #4 (every byte
* has only its upper nibble filled, so nothing wanders into the next byte).
*
*
* Against CLUT (cvidp_mkcb.s): 6 or 8 clamp accesses per entry instead of 12.
*
* FAST FORM (about 27 % fewer cycles per entry than the first version; checked
* byte for byte over all entries of goku12b and mib12, all u/v pairs and the
* edge cases):
*   - the count once per call: min((cend - from) / 6, (cmend - cm + 63) / 64),
*     then dbra instead of a check per entry
*   - chroma tables as words, indexed with the RAW u/v byte (rotated by 128):
*     no eori, add.w instead of lsl.l
*   - yTab as words
*   - large clamp tables, indexed directly with (_y + c) as a word index: no
*     asr #6. cvid_open builds them for the chosen mode (cvid.s, gross_anlegen).
*
* Register use
*   a0 from   a1 table 7-6/3-2   a2 word block   a3 n4hi large   a4 n4lo large
*   a5 table 5-4/1-0             a6 entry
*   d0 cr   d1 cg   d2 cb   d3 _y   d4/d6 pair index   d5 scratch   d7 counter
*
* State (cvidp_mkst): MP_YTAB -> word block, MP_R8 -> n4hi large (at sum 0),
* MP_G8 -> n4lo large, MP_B8 -> table 5-4/1-0 (h6 + 2048), MP_PAT -> table
* 7-6/3-2 (h6).

MP_FROM   equ  0
MP_CEND   equ  4
MP_CM     equ  8
MP_CMEND  equ 12
MP_YTAB   equ 16      ; word block: yTab at 0, UB -2048, UG -1536, VR -1024, VG -512
MP_R8     equ 20
MP_G8     equ 24
MP_B8     equ 28
MP_PAT    equ 32

* Counter: d7 = count - 1, branches to \1 at 0 entries. a0 = state.
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

HALF1   macro
        moveq   #0,d5
        move.b  (a0)+,d5
        add.w   d5,d5
        move.w  (a2,d5.w),d3
        move.w  d3,d5
        add.w   d2,d5
        moveq   #0,d4
        move.b  (a3,d5.w),d4
        add.w   d1,d3
        add.b   (a4,d3.w),d4
        moveq   #0,d5
        move.b  (a0)+,d5
        add.w   d5,d5
        move.w  (a2,d5.w),d3
        move.w  d3,d5
        add.w   d0,d5
        moveq   #0,d6
        move.b  (a3,d5.w),d6
        add.w   d1,d3
        add.b   (a4,d3.w),d6
        lsl.w   #3,d4
        lsl.w   #3,d6
        move.l  (a1,d4.w),d3
        or.l    (a5,d6.w),d3
        move.l  d3,(a6)+
        move.l  d3,(a6)+
        lsr.l   #4,d3
        move.l  d3,8(a6)
        move.l  d3,12(a6)
        endm

ROW4N   macro
        moveq   #0,d5
        move.b  (a0)+,d5
        add.w   d5,d5
        move.w  (a2,d5.w),d3
        move.w  d3,d5
        add.w   d2,d5
        moveq   #0,d4
        move.b  (a3,d5.w),d4
        add.w   d0,d3
        moveq   #0,d6
        move.b  (a3,d3.w),d6
        moveq   #0,d5
        move.b  (a0)+,d5
        add.w   d5,d5
        move.w  (a2,d5.w),d5
        add.w   d1,d5
        move.b  (a4,d5.w),d5
        add.b   d5,d4
        add.b   d5,d6
        lsl.w   #3,d4
        lsl.w   #3,d6
        move.l  (a1,d4.w),(a6)+
        move.l  (a5,d6.w),(a6)+
        move.l  4(a1,d4.w),(a6)+
        move.l  4(a5,d6.w),(a6)+
        endm

        section code

        xdef    _cvidh_mkcbfull1
_cvidh_mkcbfull1:
        movem.l d2-d7/a2-a6,-(sp)
        movea.l 48(sp),a0
        NCOUNT  nh_d1,nh_a1,nh_b1
        NLOAD
nh_l1:  CHROMAN
        HALF1
        HALF1
        addq.l  #2,a0
        lea     48(a6),a6
        dbra    d7,nh_l1
nh_d1:  movem.l (sp)+,d2-d7/a2-a6
        rts

        xdef    _cvidh_mkcbfull4
_cvidh_mkcbfull4:
        movem.l d2-d7/a2-a6,-(sp)
        movea.l 48(sp),a0
        NCOUNT  nh_d4,nh_a4,nh_b4
        NLOAD
nh_l4:  CHROMAN
        ROW4N
        ROW4N
        addq.l  #2,a0
        lea     32(a6),a6
        dbra    d7,nh_l4
nh_d4:  movem.l (sp)+,d2-d7/a2-a6
        rts

        end
