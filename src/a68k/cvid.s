; cvid.s - one Cinepak frame straight into the bitplanes: header, strips, chunks.
;
; The model is decode() in src/codec/cvidplanar.c, namely the path with the
; assembler loops: the same checks, the same codebook inheritance between
; strips, the same places to give up. The work per block is done by the
; generated pair loops (src/asm/cvidp_blk.s for 5 planes, cvidh_blk.s for
; HAM6), the entries by the codebook routines (cvidp_mkcb.s, cvidh_mkcb.s).
; Both take their state as a pointer on the stack (C call).
;
; Partial codebooks (0x2100/0x2300) build every entry with the same routine as
; the full form - range 6 bytes, target one entry.
;
; FRAME DATA IS READ BYTE BY BYTE. A frame sits in the read buffer where its
; packet was; after a damaged stream that can be an odd address, and a word
; access there is an address error on the 68000.
;
; Geometry: 320 wide, at most 256 tall, planes in one piece at a distance of
; 10240 (320x256), the frame centred vertically.
;
;   cvid_open    d0 = mode (MODUS_*), a0 = plane 0, d1 = width, d2 = height
;                -> d0 = 0 good, 1 geometry impossible, 2 no memory for the
;                large clamp tables (CLUT 119 KB, HAM6 80 KB)
;   cvid_decode  a0 = frame, d0 = length, d1 = pts -> d0 = 0 good, else CV_E_*
;   cvid_vorbauen a0 = frame, d0 = length, d1 = pts -> d0 = 0 prepared
;   cvid_close   free the codebooks; any number of times; preserves all registers
;
; PREBUILDING CODEBOOKS. Keyframes and frames with a new codebook are the peaks
; (goku12b HAM6: 84 instead of 36 ms, 12.7 ms of it codebook). The player calls
; cvid_vorbauen for the next frame in the free time before it: only strip
; headers, allocation and inheritance and the codebook chunks; blocks are
; skipped. cvid_decode with the same pts then leaves out exactly that. This
; works because blocks never write into codebooks and codebook chunks are
; idempotent. If a strip has a codebook chunk BEHIND blocks, nothing is
; prebuilt (the blocks before it need the old state); what has already been fed
; in does no harm, cvid_decode simply feeds it again.

        include "player.i"
        include "tabellen.i"

        xdef    cvid_open,cvid_close,cvid_decode,cvid_vorbauen
        xref    _SysBase
        xref    _cvidp_blk3000,_cvidp_blk3100,_cvidp_blk3200
        xref    _cvidh_blk3000,_cvidh_blk3100,_cvidh_blk3200
        xref    _cvidp_mkcbfull1_clut,_cvidp_mkcbfull4_clut
        xref    _cvidp_mkcbfull1_gray,_cvidp_mkcbfull4_gray
        xref    _cvidh_mkcbfull1,_cvidh_mkcbfull4
        xref    tab_wort,tab_r8,tab_g8,tab_b8,tab_pat,tab_n4hi,tab_n4lo,tab_h6

MAXSTR  equ     16
MOD_VOLL    equ 0
MOD_NUR_CB  equ 1
MOD_OHNE_CB equ 2
CBSIZE  equ     256*64
BPL     equ     10240
RB      equ     40
BCOLS   equ     80

; State of the block loops (cvidp_asmst)
ST_FROM  equ    0
ST_CEND  equ    4
ST_Q     equ    8
ST_CB0   equ    12
ST_CB1   equ    16
ST_REM   equ    20
ST_COL   equ    24
ST_WRAP  equ    28
ST_ROWS  equ    32
ST_BCOLS equ    36
ST_SIZE  equ    60

; State of the codebook routines (cvidp_mkst)
MK_FROM  equ    0
MK_CEND  equ    4
MK_CM    equ    8
MK_CMEND equ    12
MK_YTAB  equ    16
MK_R8    equ    20
MK_G8    equ    24
MK_B8    equ    28
MK_PAT   equ    32

        section code,code

cvid_open:
        movem.l d2-d7/a2,-(sp)
        move.l  d0,d7                   ; mode
        bsr     cvid_close
        cmp.l   #320,d1
        bne     .falsch
        moveq   #-4,d3
        and.l   d3,d2
        beq     .falsch
        cmp.l   #256,d2
        bhi     .falsch
        move.l  d2,cv_height
        move.l  #256,d3                 ; row 0 of the frame in plane 2
        sub.l   d2,d3
        lsr.l   #1,d3
        mulu    #RB,d3
        add.l   #2*BPL,d3
        add.l   a0,d3
        move.l  d3,cv_q0
        lea     cv_mk,a1
        move.l  #tab_wort,MK_YTAB(a1)
        cmp.l   #MODUS_HAM6,d7
        beq     .ham6
        move.l  #tab_pat,MK_PAT(a1)
        move.l  #_cvidp_blk3000,cv_b3000
        move.l  #_cvidp_blk3100,cv_b3100
        move.l  #_cvidp_blk3200,cv_b3200
        cmp.l   #MODUS_GRAY,d7
        beq     .gray
        move.l  #_cvidp_mkcbfull1_clut,cv_mk1
        move.l  #_cvidp_mkcbfull4_clut,cv_mk4
        lea     gross_clut,a2
        bra     .gross
.gray:  move.l  #_cvidp_mkcbfull1_gray,cv_mk1
        move.l  #_cvidp_mkcbfull4_gray,cv_mk4
        bra     .gut
.ham6:  move.l  #tab_h6+2048,MK_B8(a1)
        move.l  #tab_h6,MK_PAT(a1)
        move.l  #_cvidh_blk3000,cv_b3000
        move.l  #_cvidh_blk3100,cv_b3100
        move.l  #_cvidh_blk3200,cv_b3200
        move.l  #_cvidh_mkcbfull1,cv_mk1
        move.l  #_cvidh_mkcbfull4,cv_mk4
        lea     gross_ham6,a2
.gross: bsr     gross_anlegen
        tst.l   d0
        beq     .gut
        moveq   #2,d0
        bra     .raus
.gut:   moveq   #0,d0
        bra     .raus
.falsch:
        moveq   #1,d0
.raus:  movem.l (sp)+,d2-d7/a2
        rts

; a2 = list (dc.w count; per table dc.l small table at index 0, dc.w lo,
; length, field in cv_mk). Allocate and fill all large clamp tables in ONE
; piece: entry (_y + c) = small[(_y + c) >> 6], that is runs of 64 equal bytes.
; The field receives the pointer to sum 0.
; -> d0 = 0 good, 1 no memory
gross_anlegen:
        movem.l d2-d7/a2-a6,-(sp)
        move.w  (a2)+,d7
        subq.w  #1,d7
        moveq   #0,d0                   ; total length
        move.l  a2,a3
        move.w  d7,d6
.summe: moveq   #0,d1
        move.w  6(a3),d1
        add.l   d1,d0
        lea     10(a3),a3
        dbra    d6,.summe
        move.l  d0,cv_glen
        moveq   #0,d1                   ; MEMF_ANY: fast RAM if there is any
        EXEC    AllocMem
        move.l  d0,cv_gmem
        beq     .kein
        move.l  d0,a1
.tabelle:
        move.l  (a2)+,a4
        move.w  (a2)+,d2                ; lo
        moveq   #0,d3
        move.w  (a2)+,d3                ; length
        move.w  (a2)+,d4                ; field
        move.w  d2,d0
        ext.l   d0
        move.l  a1,d1
        sub.l   d0,d1
        lea     cv_mk,a5
        move.l  d1,0(a5,d4.w)
        move.w  d2,d5
        asr.w   #6,d5                   ; small index of the first run
        moveq   #63,d6
        and.w   d2,d6
        neg.w   d6
        add.w   #64,d6                  ; bytes up to the next multiple of 64
.lauf:  move.b  0(a4,d5.w),d0
        move.l  d6,d1
        cmp.l   d3,d1
        bls     .stueck
        move.l  d3,d1
.stueck:
        sub.l   d1,d3
        subq.w  #1,d1
.f:     move.b  d0,(a1)+
        dbra    d1,.f
        addq.w  #1,d5
        moveq   #64,d6
        tst.l   d3
        bne     .lauf
        dbra    d7,.tabelle
        moveq   #0,d0
        bra     .raus
.kein:  moveq   #1,d0
.raus:  movem.l (sp)+,d2-d7/a2-a6
        rts

cvid_close:
        movem.l d0-d2/a0-a2/a6,-(sp)
        move.l  cv_gmem,d0
        beq     .maps
        move.l  d0,a1
        move.l  cv_glen,d0
        EXEC    FreeMem
        clr.l   cv_gmem
.maps:
        lea     cv_maps0,a2
        moveq   #2*MAXSTR-1,d2
.frei:  move.l  (a2),d0
        beq     .weiter
        move.l  d0,a1
        move.l  #CBSIZE,d0
        EXEC    FreeMem
        clr.l   (a2)
.weiter:
        addq.l  #4,a2
        dbra    d2,.frei
        lea     cv_vmap0,a0
        moveq   #2*MAXSTR-1,d0
.vmap:  clr.b   (a0)+
        dbra    d0,.vmap
        clr.b   cv_vor
        movem.l (sp)+,d0-d2/a0-a2/a6
        rts

; --- one frame ------------------------------------------------------------------
;
; Registers: a2 from   a3 end of frame   a4 block state   a5 end of chunk
;            d2 strips   d3 strip kk   d4 ytop   d5 block row   d6 top
;            d7 chunk id

cvid_decode:
        clr.b   cv_modus                ; MOD_VOLL
        tst.b   cv_vor
        beq     cv_bild
        clr.b   cv_vor
        cmp.l   cv_vor_pts,d1
        bne     cv_bild
        move.b  #MOD_OHNE_CB,cv_modus   ; the codebooks are already there
        bra     cv_bild

; If prebuilding fails (broken frame, codebook behind blocks), cvid_decode has
; to see the inheritance marks from BEFORE: a full codebook clears the marks of
; ALL strips, and cvid_decode would otherwise let strip 0 inherit anew. The
; codebooks themselves do no harm - cvid_decode writes them again right away.
cvid_vorbauen:
        movem.l d2/a2-a3,-(sp)
        lea     cv_vmap0,a2             ; cv_vmap0 and cv_vmap1 in one piece
        lea     cv_vmsich,a3
        moveq   #2*MAXSTR-1,d2
.sich:  move.b  (a2)+,(a3)+
        dbra    d2,.sich
        clr.b   cv_vor
        move.l  d1,cv_vor_pts
        move.b  #MOD_NUR_CB,cv_modus
        bsr     cv_bild
        tst.l   d0
        bne     .zurueck
        st      cv_vor
        bra     .raus
.zurueck:
        lea     cv_vmsich,a2
        lea     cv_vmap0,a3
        moveq   #2*MAXSTR-1,d2
.z:     move.b  (a2)+,(a3)+
        dbra    d2,.z
.raus:  movem.l (sp)+,d2/a2-a3
        rts

cv_bild:
        movem.l d2-d7/a2-a6,-(sp)
        move.l  a0,a2
        lea     0(a0,d0.l),a3
        cmp.l   #10,d0
        blo     .e_kurz
        moveq   #0,d1                   ; length in the frame header, 24 bit
        move.b  1(a2),d1
        lsl.l   #8,d1
        move.b  2(a2),d1
        lsl.l   #8,d1
        move.b  3(a2),d1
        cmp.l   d0,d1
        beq     .laenge_gut
        btst    #0,d1
        beq     .gerade
        addq.l  #1,d1
.gerade:
        cmp.l   d0,d1
        bne     .e_laenge
.laenge_gut:
        moveq   #0,d2
        move.b  8(a2),d2
        lsl.w   #8,d2
        move.b  9(a2),d2
        cmp.l   #MAXSTR,d2
        bls     .strips
        moveq   #MAXSTR,d2
.strips:
        lea     10(a2),a2
        moveq   #0,d3
        moveq   #0,d4
        moveq   #0,d5
        lea     cv_st,a4

.strip: cmp.l   d2,d3
        bhs     .fertig
        clr.b   cv_bl                   ; no blocks in this strip yet
        cmp.b   #MOD_OHNE_CB,cv_modus
        beq     .cb_stehen
        bsr     cb_anlegen
        tst.l   d0
        bne     .e_speicher
        bsr     cb_erben
.cb_stehen:
        move.l  a3,d0
        sub.l   a2,d0
        cmp.l   #12,d0
        blt     .e_strip
        moveq   #0,d6                   ; top = strip size - 12
        move.b  2(a2),d6
        lsl.w   #8,d6
        move.b  3(a2),d6
        sub.l   #12,d6
        moveq   #0,d0                   ; ytop += y1
        move.b  8(a2),d0
        lsl.w   #8,d0
        move.b  9(a2),d0
        add.l   d0,d4
        lea     12(a2),a2
        move.l  d4,d0                   ; ylim = min(ytop, height)
        cmp.l   cv_height,d0
        bls     .ylim
        move.l  cv_height,d0
.ylim:  addq.l  #3,d0
        lsr.l   #2,d0                   ; block rows up to the end of the strip
        sub.l   d5,d0
        bhi     .rem
        moveq   #0,d0
.rem:   move.l  d0,ST_REM(a4)
        move.l  d0,cv_rem0
        move.l  d5,d0
        mulu    #4*RB,d0
        add.l   cv_q0,d0
        move.l  d0,ST_Q(a4)
        move.l  #BCOLS,ST_COL(a4)
        move.l  #4*RB-BCOLS/2+1,ST_WRAP(a4)
        clr.l   ST_ROWS(a4)
        move.l  #BCOLS,ST_BCOLS(a4)
        move.l  d3,d0
        add.l   d0,d0
        add.l   d0,d0
        lea     cv_maps0,a0
        move.l  0(a0,d0.l),ST_CB0(a4)
        lea     cv_maps1,a0
        move.l  0(a0,d0.l),ST_CB1(a4)

.chunk: tst.l   d6
        ble     .strip_ende
        move.l  a3,d0
        sub.l   a2,d0
        cmp.l   #4,d0
        blt     .e_chunk
        moveq   #0,d7
        move.b  (a2),d7
        lsl.w   #8,d7
        move.b  1(a2),d7
        moveq   #0,d1
        move.b  2(a2),d1
        lsl.w   #8,d1
        move.b  3(a2),d1
        addq.l  #4,a2
        sub.l   d1,d6                   ; top -= chunk size
        subq.l  #4,d1
        bmi     .e_chunk
        move.l  a3,d0
        sub.l   a2,d0
        cmp.l   d1,d0
        blt     .e_chunk
        lea     0(a2,d1.l),a5
        cmp.w   #$3000,d7
        beq     .b3000
        cmp.w   #$3100,d7
        beq     .b3100
        cmp.w   #$3200,d7
        beq     .b3200
        lea     .voll4,a0
        cmp.w   #$2000,d7
        beq     .codebook
        lea     .voll1,a0
        cmp.w   #$2200,d7
        beq     .codebook
        lea     .teil4,a0
        cmp.w   #$2100,d7
        beq     .codebook
        lea     .teil1,a0
        cmp.w   #$2300,d7
        beq     .codebook
        bra     .e_chunkid
.codebook:
        move.b  cv_modus,d0
        beq     .cb_los                 ; MOD_VOLL
        subq.b  #MOD_NUR_CB,d0
        bne     .chunk_ende             ; MOD_OHNE_CB: already there
        tst.b   cv_bl                   ; MOD_NUR_CB behind blocks: do not prebuild
        bne     .e_chunk
.cb_los:
        jmp     (a0)

.b3000: move.l  cv_b3000,a0
        bra     .bloecke
.b3100: move.l  cv_b3100,a0
        bra     .bloecke
.b3200: move.l  cv_b3200,a0
.bloecke:
        cmp.b   #MOD_NUR_CB,cv_modus
        bne     .bl_los
        st      cv_bl                   ; codebooks only: skip the blocks
        bra     .chunk_ende
.bl_los:
        move.l  a2,ST_FROM(a4)
        move.l  a5,ST_CEND(a4)
        move.l  a4,-(sp)
        jsr     (a0)
        addq.l  #4,sp
        bra     .chunk_ende

; Full codebooks: all strips of this frame lose their inheritance, this one
; has it.
.voll4: lea     cv_vmap0,a0
        lea     cv_maps0,a1
        move.l  cv_mk4,d7
        bra     .voll
.voll1: lea     cv_vmap1,a0
        lea     cv_maps1,a1
        move.l  cv_mk1,d7
.voll:  move.l  d2,d0
        bra     .v_weiter
.v_null:
        clr.b   0(a0,d0.l)
.v_weiter:
        subq.l  #1,d0
        bpl     .v_null
        st      0(a0,d3.l)
        move.l  d3,d0
        add.l   d0,d0
        add.l   d0,d0
        move.l  0(a1,d0.l),d0           ; codebook of the strip
        lea     cv_mk,a0
        move.l  a2,MK_FROM(a0)
        move.l  a5,MK_CEND(a0)
        move.l  d0,MK_CM(a0)
        add.l   #CBSIZE,d0
        move.l  d0,MK_CMEND(a0)
        move.l  d7,a1
        move.l  a0,-(sp)
        jsr     (a1)
        addq.l  #4,sp
        bra     .chunk_ende

; Partial codebooks: 32 flag bits, one entry per bit that is set.
.teil4: lea     cv_maps0,a1
        move.l  cv_mk4,cv_mkfn
        bra     .teil
.teil1: lea     cv_maps1,a1
        move.l  cv_mk1,cv_mkfn
.teil:  move.l  d3,d0
        add.l   d0,d0
        add.l   d0,d0
        move.l  0(a1,d0.l),cv_cm        ; codebook of the strip
        clr.l   cv_ci
.t_wort:
        move.l  a5,d0
        sub.l   a2,d0
        cmp.l   #4,d0
        blt     .chunk_ende
        moveq   #0,d0                   ; flag word byte by byte
        move.b  (a2)+,d0
        lsl.l   #8,d0
        move.b  (a2)+,d0
        lsl.l   #8,d0
        move.b  (a2)+,d0
        lsl.l   #8,d0
        move.b  (a2)+,d0
        move.l  d0,cv_flag
        moveq   #32-1,d7
.t_bit: move.l  cv_flag,d0              ; look at the top bit, then shift
        move.l  d0,d1                   ; (move clears the carry - so do not
        add.l   d1,d1                   ;  test the carry of the add)
        move.l  d1,cv_flag
        tst.l   d0
        bpl     .t_naechstes
        cmp.l   #256,cv_ci
        bhs     .t_naechstes
        move.l  a5,d0
        sub.l   a2,d0
        cmp.l   #6,d0
        blt     .t_wort                 ; as in C: only the bit loop ends
        lea     cv_mk,a0
        move.l  a2,MK_FROM(a0)
        lea     6(a2),a1
        move.l  a1,MK_CEND(a0)
        move.l  cv_ci,d0
        lsl.l   #6,d0
        add.l   cv_cm,d0
        move.l  d0,MK_CM(a0)
        add.l   #64,d0
        move.l  d0,MK_CMEND(a0)
        move.l  cv_mkfn,a1
        move.l  a0,-(sp)
        jsr     (a1)
        addq.l  #4,sp
        addq.l  #6,a2
.t_naechstes:
        addq.l  #1,cv_ci
        dbra    d7,.t_bit
        bra     .t_wort

.chunk_ende:
        move.l  a5,a2
        bra     .chunk

.strip_ende:
        move.l  cv_rem0,d0
        sub.l   ST_REM(a4),d0
        add.l   d0,d5
        addq.l  #1,d3
        bra     .strip

.fertig:
        moveq   #0,d0
        bra     .raus
.e_kurz:
        moveq   #CV_E_KURZ,d0
        bra     .raus
.e_laenge:
        moveq   #CV_E_LAENGE,d0
        bra     .raus
.e_strip:
        moveq   #CV_E_STRIP,d0
        bra     .raus
.e_chunk:
        moveq   #CV_E_CHUNK,d0
        bra     .raus
.e_chunkid:
        moveq   #CV_E_CHUNKID,d0
        bra     .raus
.e_speicher:
        moveq   #CV_E_SPEICHER,d0
.raus:  movem.l (sp)+,d2-d7/a2-a6
        rts

; d3 = strip: allocate both codebooks unless they exist -> d0 = 0 good
cb_anlegen:
        movem.l d1-d2/a0-a2/a6,-(sp)
        move.l  d3,d2
        add.l   d2,d2
        add.l   d2,d2
        lea     cv_maps0,a2
        bsr     .eins
        tst.l   d0
        bne     .raus
        lea     cv_maps1,a2
        bsr     .eins
.raus:  movem.l (sp)+,d1-d2/a0-a2/a6
        rts
.eins:  moveq   #0,d0
        tst.l   0(a2,d2.l)
        bne     .da
        move.l  #CBSIZE,d0
        move.l  #MEMF_CLEAR,d1
        EXEC    AllocMem
        move.l  d0,0(a2,d2.l)
        seq     d0                      ; 0 = error -> d0 != 0
        ext.w   d0
        ext.l   d0
.da:    rts

; d2 = strips, d3 = kk: codebooks without a valid state inherit from their
; predecessor (kk = 0 from the last strip), like inherit() in C.
cb_erben:
        movem.l d0-d1/d4/a0-a3/a6,-(sp)
        move.l  d3,d4                   ; source: kk - 1 or strips - 1
        subq.l  #1,d4
        bpl     .quelle
        move.l  d2,d4
        subq.l  #1,d4
.quelle:
        add.l   d4,d4
        add.l   d4,d4
        lea     cv_vmap0,a2
        lea     cv_maps0,a3
        bsr     .eins
        lea     cv_vmap1,a2
        lea     cv_maps1,a3
        bsr     .eins
        movem.l (sp)+,d0-d1/d4/a0-a3/a6
        rts
.eins:  tst.b   0(a2,d3.l)
        bne     .fertig
        st      0(a2,d3.l)
        move.l  d3,d1                   ; CopyMem destroys d1: set it per call
        add.l   d1,d1
        add.l   d1,d1
        move.l  0(a3,d1.l),a1           ; target
        move.l  0(a3,d4.l),d0           ; source
        beq     .leeren
        cmp.l   a1,d0
        beq     .fertig
        move.l  d0,a0
        move.l  #CBSIZE,d0
        EXEC    CopyMem
        rts
.leeren:
        move.w  #CBSIZE/4-1,d0
.l:     clr.l   (a1)+
        dbra    d0,.l
.fertig:
        rts

        section data,data

; Large clamp tables per mode (gross_anlegen). Bounds come from tabellen.i.
gross_ham6:
        dc.w    2
        dc.l    tab_n4hi
        dc.w    GR_N4HI_LO,GR_N4HI_LEN,MK_R8
        dc.l    tab_n4lo
        dc.w    GR_N4LO_LO,GR_N4LO_LEN,MK_G8
gross_clut:
        dc.w    3
        dc.l    tab_r8
        dc.w    GR_R8_LO,GR_R8_LEN,MK_R8
        dc.l    tab_g8
        dc.w    GR_G8_LO,GR_G8_LEN,MK_G8
        dc.l    tab_b8
        dc.w    GR_B8_LO,GR_B8_LEN,MK_B8

        section bss,bss

cv_gmem:    ds.l    1
cv_glen:    ds.l    1
cv_st:      ds.b    ST_SIZE
cv_mk:      ds.l    9
cv_maps0:   ds.l    MAXSTR
cv_maps1:   ds.l    MAXSTR
cv_vmap0:   ds.b    MAXSTR
cv_vmap1:   ds.b    MAXSTR
cv_vmsich:  ds.b    2*MAXSTR
cv_height:  ds.l    1
cv_q0:      ds.l    1
cv_rem0:    ds.l    1
cv_b3000:   ds.l    1
cv_b3100:   ds.l    1
cv_b3200:   ds.l    1
cv_mk1:     ds.l    1
cv_mk4:     ds.l    1
cv_mkfn:    ds.l    1
cv_cm:      ds.l    1
cv_ci:      ds.l    1
cv_flag:    ds.l    1
cv_vor_pts: ds.l    1
cv_modus:   ds.b    1
cv_bl:      ds.b    1
cv_vor:     ds.b    1
