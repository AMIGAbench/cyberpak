; out.s - text output of the player.
;
; All routines preserve ALL registers - that way messages can be dropped into
; the middle of a computation without saving anything. Output goes through
; dos PutStr (V36 and up).
;
;   out_str   a0 = null-terminated text
;   out_nl    line end
;   out_chr   d0.b = one character
;   out_unum  d0 = unsigned number, decimal
;   out_num   d0 = signed number, decimal
;   out_hex   d0 = number, d1 = number of digits (1..8), lower case
;   udiv10    d0 = d0 / 10, d1 = remainder (only d0/d1 touched)

        include "player.i"

        xdef    out_str,out_nl,out_chr,out_unum,out_num,out_hex,udiv10
        xref    _DOSBase

        section code,code

out_str:
        movem.l d0-d1/a0-a1/a6,-(sp)
        move.l  a0,d1
        move.l  _DOSBase,a6
        jsr     _LVOPutStr(a6)
        movem.l (sp)+,d0-d1/a0-a1/a6
        rts

out_nl:
        move.l  a0,-(sp)
        lea     nltext,a0
        bsr   out_str
        move.l  (sp)+,a0
        rts

out_chr:
        move.l  a0,-(sp)
        lea     chrbuf,a0
        move.b  d0,(a0)
        clr.b   1(a0)
        bsr   out_str
        move.l  (sp)+,a0
        rts

; 32 bit by 10 without a 32-bit division: first the high word, then its
; remainder together with the low word. The second quotient always fits in a
; word, because the high word's remainder is below 10 (9*65536+65535 < 655360).
udiv10:
        movem.l d2-d3,-(sp)
        moveq   #0,d2
        move.w  d0,d2           ; d2 = low word
        clr.w   d0
        swap    d0              ; d0 = high word
        divu    #10,d0          ; d0 = rem_h << 16 | quot_h
        moveq   #0,d3
        move.w  d0,d3
        swap    d3              ; d3 = quot_h << 16
        clr.w   d0
        or.l    d2,d0           ; d0 = rem_h << 16 | low word
        divu    #10,d0          ; d0 = rem << 16 | quot_l
        move.w  d0,d3           ; d3 = quotient
        clr.w   d0
        swap    d0
        move.l  d0,d1           ; d1 = remainder
        move.l  d3,d0
        movem.l (sp)+,d2-d3
        rts

out_unum:
        movem.l d0-d1/a0,-(sp)
        lea     numend,a0
        clr.b   (a0)
.ziffer:
        bsr   udiv10
        add.b   #'0',d1
        move.b  d1,-(a0)
        tst.l   d0
        bne   .ziffer
        bsr     out_str
        movem.l (sp)+,d0-d1/a0
        rts

out_num:
        tst.l   d0
        bpl   out_unum
        movem.l d0,-(sp)
        move.l  d0,-(sp)
        moveq   #'-',d0
        bsr   out_chr
        move.l  (sp)+,d0
        neg.l   d0
        bsr   out_unum
        movem.l (sp)+,d0
        rts

out_hex:
        movem.l d0-d2/a0,-(sp)
        lea     numend,a0
        clr.b   (a0)
        subq.w  #1,d1
.stelle:
        moveq   #15,d2
        and.b   d0,d2
        cmp.b   #10,d2
        blo   .dez
        add.b   #'a'-'0'-10,d2
.dez:   add.b   #'0',d2
        move.b  d2,-(a0)
        lsr.l   #4,d0
        dbra    d1,.stelle
        bsr     out_str
        movem.l (sp)+,d0-d2/a0
        rts

        section data,data
nltext: dc.b    10,0

        section bss,bss
chrbuf: ds.b    2
numbuf: ds.b    12
numend: ds.b    1
