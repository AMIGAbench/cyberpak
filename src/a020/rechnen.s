; rechnen.s - wide arithmetic for the 68000.
;
; The 68000 multiplies only 16 x 16 and divides only 32 / 16. The player's
; clock needs more: EClock ticks times sample rate divided by EClock frequency,
; milliseconds from ticks, wake-up times. All of it here, once and tested,
; instead of scattered and approximated.
;
;   mul64     d0 * d1 -> d2 (high) : d3 (low)               touches only d2/d3
;   muldiv32  d0 * d1 / d2 -> d0 quotient, d1 remainder     touches only d0/d1
;             (quotient >= 2^32: d0 = $FFFFFFFF, d1 = 0)
;   udiv32    d0 / d1 -> d0 quotient, d1 remainder          touches only d0/d1

        include "player.i"

        xdef    mul64,muldiv32,udiv32

        section code,code

mul64:
        movem.l d4-d7,-(sp)
        moveq   #0,d4
        move.w  d0,d4                   ; a low
        moveq   #0,d5
        move.w  d1,d5                   ; b low
        move.l  d0,d6
        clr.w   d6
        swap    d6                      ; a high
        move.l  d1,d7
        clr.w   d7
        swap    d7                      ; b high
        move.l  d4,d3
        mulu    d5,d3                   ; low  = al * bl
        move.l  d6,d2
        mulu    d7,d2                   ; high = ah * bh
        mulu    d7,d4                   ; al * bh
        mulu    d5,d6                   ; ah * bl
        moveq   #0,d5
        add.l   d6,d4                   ; middle (33 bit)
        bcc     .ohne
        move.l  #$10000,d5              ; carry of the middle -> high bit 16
.ohne:  move.l  d4,d7
        clr.w   d7
        swap    d7
        add.l   d7,d5                   ; middle >> 16
        swap    d4
        clr.w   d4                      ; middle << 16 (low word)
        add.l   d4,d3
        bcc     .ohne2
        addq.l  #1,d5
.ohne2: add.l   d5,d2
        movem.l (sp)+,d4-d7
        rts

muldiv32:
        movem.l d2-d5,-(sp)
        move.l  d2,d5                   ; divisor
        bsr     mul64
        cmp.l   d5,d2
        blo     .teilen
        moveq   #-1,d0                  ; does not fit in 32 bit
        moveq   #0,d1
        bra     .raus
.teilen:
        moveq   #32-1,d4
.bit:   add.l   d3,d3
        roxl.l  #1,d2
        bcs     .ab                     ; 33rd bit set: certainly >= divisor
        cmp.l   d5,d2
        blo     .weiter
.ab:    sub.l   d5,d2
        addq.l  #1,d3
.weiter:
        dbra    d4,.bit
        move.l  d3,d0
        move.l  d2,d1
.raus:  movem.l (sp)+,d2-d5
        rts

udiv32:
        move.l  d2,-(sp)
        move.l  d1,d2
        moveq   #1,d1
        bsr     muldiv32
        move.l  (sp)+,d2
        rts
