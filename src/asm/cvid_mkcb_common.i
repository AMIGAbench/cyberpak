* cvid_mkcb_common.i - shared part of building codebooks (0x2100/0x2300)
*
* Included by cvid_blk_020.s (16 bit) and cvid_blk8_020.s (8 bit). The colour
* computation is the same in both cases; only how the four finished pixel
* values are packed into the 16 bytes of a codebook entry differs - and that
* lives in the respective files.
*
* Register use
*   a0 from   a1 cend   a2 &yTab[0]   a3 tabR  a4 tabG  a5 tabB  a6 dst
*   d0 cr     d1 cg     d2 cbb        d3 _y    d4 pixel d5 index
*   d6 flag word        d7 remaining bits
*   (sp) holds cmend - the only value for which no register was left; it is
*   read once per entry, not per bit.
*
* The chroma tables lie contiguously before yTab, so ONE address register is
* enough for all five:
*   ubTab -4096   vrTab -3072   ugTab -2048   vgTab -1024   yTab 0

MK_FROM   equ  0
MK_CEND   equ  4
MK_CM     equ  8
MK_CMEND  equ 12
MK_YTAB   equ 16
MK_TABR   equ 20
MK_TABG   equ 24
MK_TABB   equ 28
MK_GSH    equ 32

* --- Colour computation -------------------------------------------------
*
* A version can replace PIXEL and CHROMA by setting CVX_OWN_PIXEL and defining
* both itself BEFORE including this file. The 68000 variant did exactly that:
* the version here uses scaling and full extension words, and both exist only
* from the 68020 on.

        IFND    CVX_OWN_PIXEL

* One pixel: y from (a0)+, the result is folded into \1.
*   \1  target register
*   \2  operation: `or` for 16 bit, `add` for 8 bit
*
* Why two operations: at 16 bit R, G and B lie in disjoint bit fields, so `or`
* is the natural one. With the 8-bit palette the fields overlap when the number
* of levels is not a power of two (6-7-6), and there it has to be added. On 68k
* both cost the same.
*
* The target has to be prepared (clr, or a predecessor already shifted).
* Internally d3 and d5 are used - \1 must not be either of them. That is
* exactly what the first version got wrong: it wrote to d5 in the V4 path, and
* the next line of the macro overwrote the result right away.
PIXEL   macro
        moveq   #0,d5
        move.b  (a0)+,d5
        move.l  (a2,d5.l*4),d3               ; _y = yTab[y]
        move.l  d3,d5
        add.l   d0,d5
        asr.l   #6,d5
        \2.l    (a3,d5.l*4),\1               ; tabR[(_y+cr)>>6]
        move.l  d3,d5
        add.l   d1,d5
        asr.l   #6,d5
        \2.l    (a4,d5.l*4),\1               ; tabG[...]
        move.l  d3,d5
        add.l   d2,d5
        asr.l   #6,d5
        \2.l    (a5,d5.l*4),\1               ; tabB[...]
        endm

* Chroma once per entry. u and v sit at 4(a0) and 5(a0).
CHROMA  macro
        moveq   #0,d5
        move.b  4(a0),d5
        eori.b  #$80,d5                      ; u
        move.l  (-4096,a2,d5.l*4),d2         ; ubTab[u]  -> cbb
        move.l  (-2048,a2,d5.l*4),d1         ; ugTab[u]
        moveq   #0,d5
        move.b  5(a0),d5
        eori.b  #$80,d5                      ; v
        move.l  (-3072,a2,d5.l*4),d0         ; vrTab[v]  -> cr
        add.l   (-1024,a2,d5.l*4),d1         ; + vgTab[v] -> cg
        endm

        ENDC

MKENTER macro
        movem.l d2-d7/a2-a6,-(sp)
        movea.l 48(sp),a0
        move.l  MK_CMEND(a0),-(sp)           ; cmend to (sp)
        movea.l MK_CEND(a0),a1
        movea.l MK_CM(a0),a6
        movea.l MK_YTAB(a0),a2
        movea.l MK_TABR(a0),a3
        movea.l MK_TABG(a0),a4
        movea.l MK_TABB(a0),a5
        movea.l MK_FROM(a0),a0
        moveq   #0,d6
        moveq   #0,d7
        endm

MKLEAVE macro
        addq.l  #4,sp                        ; discard cmend
        movea.l 48(sp),a1
        move.l  a0,MK_FROM(a1)
        movem.l (sp)+,d2-d7/a2-a6
        rts
        endm

* Head of the bit loop: fetch the next flag word, test the bit, is the entry
* allowed? \1 = target at end of stream, \2 = target "bit not set", \3 = target
* when the remainder is too short (discard the flag word as the C code does).
MKBIT   macro
        subq.l  #1,d7                        ; any bits left?
        bge.s   .bit\@
        move.l  a0,d5                        ; from + 4 <= cend ?
        addq.l  #4,d5
        cmpa.l  d5,a1
        bcs     \1
        move.l  (a0)+,d6
        moveq   #31,d7
.bit\@:
        add.l   d6,d6
        bcc     \2                           ; bit not set
        cmpa.l  (sp),a6                      ; ci < 256 ?
        bcc     \2
        move.l  a0,d5                        ; from + 6 <= cend ?
        addq.l  #6,d5
        cmpa.l  d5,a1
        bcs     \3
        endm

* ======================================================================
* Full codebook form (0x2000 / 0x2200)
* ======================================================================
*
* Simpler than the partial one: no flag word, no bit counter, no flush path.
* The entries follow one another, six bytes per entry, and the index is the
* running index.
*
* It stops on TWO conditions, and both are there already:
*
*   from + 6 <= cend    that is how many entries the chunk holds
*   a6 < cmend          the codebook has 256 entries
*
* The second one is NEW against the C code. The partial form checks `ci < 256`
* (cvid_body.h), the full form checks nothing at all - there `n = cSize/6`, and
* cSize can go up to 65531. That writes far beyond the 256-entry block into the
* shared pool. With real material it does not happen; a broken stream triggers
* it.
*
* This also means the loop needs NO division by 6 - the number of entries
* follows from the abort condition itself.
*
* \1 = name of the entry macro (ENT4_16, ENT1_16, ENT4_8, ENT1_8, ...)
MKFULL  macro
        MKENTER
.loop\@:
        move.l  a0,d5                        ; from + 6 <= cend ?
        addq.l  #6,d5
        cmpa.l  d5,a1
        bcs     .done\@
        cmpa.l  (sp),a6                      ; still room in the codebook ?
        bcc     .done\@
        \1                                   ; one entry
        lea     16(a6),a6                    ; ci++
        bra     .loop\@
.done\@:
        MKLEAVE
        endm

* ======================================================================
* Building an entry - one per output mode
* ======================================================================
*
* Each of these macros builds EXACTLY ONE codebook entry (16 bytes from a6) out
* of the six bytes from a0 and advances a0 past the two chroma bytes. The four
* Y values are fetched by PIXEL itself through (a0)+.
*
* WHY THEY ARE MACROS OF THEIR OWN: the layout is identical in both chunk
* forms - the partial form (0x2100/0x2300) and the full one (0x2000/0x2200)
* differ ONLY in how they get to the next entry. The partial one reads a flag
* word and counts skipped indices, the full one runs through sequentially.
* Everything before and after is the same.
*
* The macros are free of branches and use no labels of their own - so they can
* be dropped in anywhere.
*
*
* State afterwards: a0 points at the next entry, a6 still points at THIS entry
* (advancing it is done by the respective loop).

* --- 16 bit per pixel --------------------------------------------------
* V4: q0 = (a<<16)|b, q1 = (d<<16)|e, q2 = q3 = 0
ENT4_16 macro
        CHROMA
        clr.l   d4
        PIXEL   d4,or                        ; d4 = a
        swap    d4                           ; a into the upper half
        PIXEL   d4,or                        ; d4 = (a<<16) | b
        move.l  d4,(a6)
        clr.l   d4
        PIXEL   d4,or
        swap    d4
        PIXEL   d4,or                        ; d4 = (d<<16) | e
        move.l  d4,4(a6)
        clr.l   8(a6)
        clr.l   12(a6)
        addq.l  #2,a0                        ; skip u and v
        endm

* V1: q0=(a<<16)|a, q1=(b<<16)|b, q2/q3 from d,e
ENT1_16 macro
        CHROMA
        clr.l   d4
        PIXEL   d4,or
        move.l  d4,d3
        swap    d3
        move.w  d4,d3
        move.l  d3,(a6)                      ; (a<<16)|a
        clr.l   d4
        PIXEL   d4,or
        move.l  d4,d3
        swap    d3
        move.w  d4,d3
        move.l  d3,4(a6)
        clr.l   d4
        PIXEL   d4,or
        move.l  d4,d3
        swap    d3
        move.w  d4,d3
        move.l  d3,8(a6)
        clr.l   d4
        PIXEL   d4,or
        move.l  d4,d3
        swap    d3
        move.w  d4,d3
        move.l  d3,12(a6)
        addq.l  #2,a0
        endm

* --- 8 bit per pixel (CLUT8) -------------------------------------------
* V4: q0 = a:b:0:0, q1 = d:e:0:0, q2 = 0:0:a:b, q3 = 0:0:d:e
* q0 is q2 shifted left by 16 bit - so build q2 and `swap`.
*
* The intermediate value goes through the target memory instead of a register:
* PIXEL uses d3 and d5 internally, d0-d2 hold the chroma, and only d4 is left.
ENT4_8  macro
        CHROMA
        clr.l   d4
        PIXEL   d4,add                       ; a
        lsl.l   #8,d4
        move.l  d4,8(a6)                     ; a<<8
        clr.l   d4
        PIXEL   d4,add                       ; b
        or.l    d4,8(a6)                     ; q2 = 0:0:a:b
        move.l  8(a6),d3
        swap    d3
        move.l  d3,(a6)                      ; q0 = a:b:0:0
        clr.l   d4
        PIXEL   d4,add                       ; d
        lsl.l   #8,d4
        move.l  d4,12(a6)
        clr.l   d4
        PIXEL   d4,add                       ; e
        or.l    d4,12(a6)                    ; q3 = 0:0:d:e
        move.l  12(a6),d3
        swap    d3
        move.l  d3,4(a6)                     ; q1 = d:e:0:0
        addq.l  #2,a0                        ; skip u and v
        endm

* V1: q0 = q1 = a:a:b:b, q2 = q3 = d:d:e:e
* One V1 entry covers 4x4 pixels: every value stands twice side by side and the
* row twice one below the other.
ENT1_8  macro
        CHROMA
        clr.l   d4
        PIXEL   d4,add                       ; a
        move.l  d4,d3
        lsl.l   #8,d3
        or.l    d4,d3                        ; 0:0:a:a
        swap    d3                           ; a:a:0:0
        move.l  d3,(a6)
        clr.l   d4
        PIXEL   d4,add                       ; b
        move.l  d4,d3
        lsl.l   #8,d3
        or.l    d4,d3                        ; 0:0:b:b
        or.l    d3,(a6)                      ; q0 = a:a:b:b
        move.l  (a6),d3
        move.l  d3,4(a6)                     ; q1 = q0
        clr.l   d4
        PIXEL   d4,add                       ; d
        move.l  d4,d3
        lsl.l   #8,d3
        or.l    d4,d3
        swap    d3
        move.l  d3,8(a6)
        clr.l   d4
        PIXEL   d4,add                       ; e
        move.l  d4,d3
        lsl.l   #8,d3
        or.l    d4,d3
        or.l    d3,8(a6)                     ; q2 = d:d:e:e
        move.l  8(a6),d3
        move.l  d3,12(a6)                    ; q3 = q2
        addq.l  #2,a0
        endm

* --- 32 bit per pixel --------------------------------------------------
* The simplest entry of all: four finished ARGB longwords, no packing at all.
* V1 and V4 use the same macro - with RGB32 CVID_MKCB1 and CVID_MKCB4 in
* cvid.c are the same as well.
ENT_32  macro
        CHROMA
        clr.l   d4
        PIXEL   d4,or
        move.l  d4,(a6)
        clr.l   d4
        PIXEL   d4,or
        move.l  d4,4(a6)
        clr.l   d4
        PIXEL   d4,or
        move.l  d4,8(a6)
        clr.l   d4
        PIXEL   d4,or
        move.l  d4,12(a6)
        addq.l  #2,a0                        ; skip u and v
        endm
