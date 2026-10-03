; cpks.s - reading a CPKS stream (file), video packets without a copy.
;
; Format: CPKS-FORMAT.md in the encoder project cinepakfast. The model is
; src/cpks.c; same behaviour, except that video packets are no longer copied
; into queue slots.
;
; READ BUFFER AS AN ARENA. 256 KB in one piece; reading always goes up to the
; next 64 KB boundary of the FILE (measured with src/cpks.c: the expensive part
; is not the copy but a Read() that starts in the middle of a block).
; Video packets stay where they were read - the queue (16 slots) holds
; pointers. When room runs short at the back, `verdichten` moves everything
; alive (from the oldest waiting packet or the read position onwards) to the
; front and adjusts the pointers. That copies only what is waiting right now,
; and only every few hundred KB.
;
; POINTERS from cpks_next/cpks_peek are valid until the next cpks_pump.
;
; Audio packets go to the callback at once (a0 = data, d0 = bytes; it may
; change d0/d1/a0/a1). Packets larger than MAXPKT are skipped and counted -
; src/cpks.c truncated them at 32 KB and decoded fragments.
;
; Routines (registers as in player.i, otherwise stated):
;   cpks_open     a0 = name, d1 = bytes per Read (power of two, 0 = 64 KB;
;                 the player passes READ, default 16 KB)
;                 -> d0 = 0 good, 1 cannot open, 2 not CPKS, 3 no memory.
;                 Reads up to the first header packet.
;
; READ SIZE (READ=n, default 16). For a disk 64 KB would be cheapest (few
; reads on block boundaries). A network stream (NETSTREAM:) on the other hand
; delivers each read only once the full amount is there - on the A600 170 ms on
; average, and the whole playback loop stands still for that long. Hence it is
; adjustable, and every read is measured (cp_readticks, cp_readmax,
; cp_readlang > cp_langgrenze) as soon as the clock runs.
;   cpks_close    frees everything, may be called any number of times; preserves all registers
;   cpks_pump     a0 = audio callback or 0; reads until the queue is full, no
;                 room is left, or the stream has ended
;   cpks_next     -> d0 = entry of the oldest frame (removed) or 0
;   cpks_drop     discard the oldest frame
;   cpks_peek     d0 = i -> d0 = entry i (0 = oldest) or 0
;   cpks_advance  d0 = position -> d0 = frames due, d1 = frames discarded
;                 (specification 5.3/5.4; skip threshold cp_sprung in ticks,
;                 0 = one second)

        include "player.i"

        xdef    cpks_open,cpks_close,cpks_pump,cpks_next,cpks_drop,cpks_peek,cpks_advance
        xdef    cp_width,cp_height,cp_fpsnum,cp_fpsden,cp_timebase,cp_arate
        xdef    cp_achans,cp_abits,cp_prebuffer,cp_codec,cp_queued,cp_eof
        xdef    cp_asamples,cp_aptsbase,cp_bytes,cp_reads,cp_resyncs,cp_toobig,cp_moved
        xdef    cp_bis_key,cp_sprung,cp_leserverw,cp_spruenge,cp_ohnelesen,cp_readletzt,cp_chunk,cp_readticks,cp_readmax,cp_readlang,cp_langgrenze
        xref    _SysBase,_DOSBase,_TimerBase,zeit_now

ARENA   equ     256*1024
CHUNK   equ     64*1024
QSLOTS  equ     16
PKTHDR  equ     16
MAXPKT  equ     128*1024
T_HEAD  equ     1
T_VIDEO equ     2
T_AUDIO equ     3

        section code,code

; --- opening and closing -----------------------------------------------------

cpks_open:
        movem.l d2-d7/a2-a6,-(sp)
        move.l  a0,d7
        move.l  d1,d6
        lea     cp_state,a0
        move.w  #cp_state_end-cp_state-1,d0
.leeren:
        clr.b   (a0)+
        dbra    d0,.leeren
        move.l  d6,cp_chunk
        bne     .chunk
        move.l  #CHUNK,cp_chunk
.chunk:
        move.l  d7,d1
        move.l  #MODE_OLDFILE,d2
        DOS     Open
        move.l  d0,cp_fh
        beq     .e_open
        move.l  #ARENA,d0
        moveq   #0,d1
        EXEC    AllocMem
        move.l  d0,cp_arena
        beq     .e_mem
        moveq   #4,d0
        bsr     brauche
        tst.l   d0
        beq     .e_format
        move.l  cp_arena,a0
        add.l   cp_rpos,a0
        bsr     ist_magic
        beq     .kopf
        ; No sync word right at the front: search, as with a truncated stream.
        bsr     sync_suchen
        tst.l   d0
        beq     .e_format
.kopf:  move.w  #4096-1,d7
.paket: tst.b   cp_haveinfo
        bne   .pruefen
        bsr     ein_paket
        tst.l   d0
        bmi   .pruefen
        dbra    d7,.paket
.pruefen:
        tst.b   cp_haveinfo
        beq     .e_format
        tst.l   cp_width
        beq     .e_format
        tst.l   cp_height
        beq     .e_format
        tst.l   cp_timebase
        beq     .e_format
        ; Samples per byte block (channels x bytes per sample) as a shift
        ; count; -1 = not countable.
        move.l  cp_abits,d1
        lsr.l   #3,d1
        move.l  cp_achans,d0
        mulu    d0,d1
        moveq   #-1,d0
        cmp.l   #1,d1
        bne   .b2
        moveq   #0,d0
.b2:    cmp.l   #2,d1
        bne   .b4
        moveq   #1,d0
.b4:    cmp.l   #4,d1
        bne   .bset
        moveq   #2,d0
.bset:  move.l  d0,cp_ashift
        moveq   #0,d0
        bra   .raus
.e_open:
        moveq   #1,d0
        bra   .fehl
.e_mem: moveq   #3,d0
        bra   .fehl
.e_format:
        moveq   #2,d0
.fehl:  bsr     cpks_close
.raus:  movem.l (sp)+,d2-d7/a2-a6
        rts

cpks_close:
        movem.l d0-d1/a0-a1/a6,-(sp)
        move.l  cp_arena,d0
        beq   .datei
        move.l  d0,a1
        move.l  #ARENA,d0
        EXEC    FreeMem
        clr.l   cp_arena
.datei: move.l  cp_fh,d1
        beq   .raus
        DOS     Close
        clr.l   cp_fh
.raus:  clr.l   cp_queued
        movem.l (sp)+,d0-d1/a0-a1/a6
        rts

; --- Arena ---------------------------------------------------------------------

; Move what is alive to the front. Preserves all registers. Copies in blocks of
; 10 longwords per movem (19.8 instead of 30 cycles per longword); the target
; lies before the source, every block is read before it is written.
verdichten:
        movem.l d0-d7/a0-a6,-(sp)
        move.l  cp_rpos,d2              ; from here on it is alive
        tst.l   cp_queued
        beq   .anfang
        lea     cp_queue,a2
        move.l  cp_tail,d0
        lsl.l   #4,d0
        move.l  Q_PTR(a2,d0.l),d1
        sub.l   cp_arena,d1
        cmp.l   d2,d1
        bhs   .anfang
        move.l  d1,d2
.anfang:
        tst.l   d2
        beq   .raus
        move.l  cp_arena,a1
        move.l  a1,a0
        add.l   d2,a0
        move.l  cp_rlen,d1
        sub.l   d2,d1
        add.l   d1,cp_moved
        move.l  d1,d0
        btst    #0,d2                   ; odd source: bytes only (address error)
        bne     .b_weiter
        divu    #40,d0                  ; blocks, < 65536 at 256 KB
        move.l  d0,d3
        swap    d3                      ; d3.w = remaining bytes
        subq.w  #1,d0
        bmi     .rest
.block: movem.l (a0)+,d1/d4-d7/a2-a6
        movem.l d1/d4-d7/a2-a6,(a1)
        lea     40(a1),a1
        dbra    d0,.block
.rest:  move.w  d3,d0
        lsr.w   #2,d0
        bra     .l_weiter
.l_kopie:
        move.l  (a0)+,(a1)+
.l_weiter:
        dbra    d0,.l_kopie
        moveq   #3,d0
        and.w   d3,d0
        bra     .b_weiter
.b_kopie:
        move.b  (a0)+,(a1)+
.b_weiter:
        subq.l  #1,d0
        bpl     .b_kopie
        sub.l   d2,cp_rpos
        sub.l   d2,cp_rlen
        lea     cp_queue,a2             ; all slots, free ones do no harm
        moveq   #QSLOTS-1,d0
.zeiger:
        sub.l   d2,(a2)
        lea     16(a2),a2
        dbra    d0,.zeiger
.raus:  movem.l (sp)+,d0-d7/a0-a6
        rts

; Read once more, up to the next 64 KB boundary of the file.
; -> d0 = bytes read, 0 = end or no room (cp_feof tells them apart).
nachladen:
        movem.l d1-d6/a0-a1/a6,-(sp)
        tst.b   cp_feof
        bne   .nichts
        tst.b   cp_ohnelesen            ; the loop has no time for a Read
        bne   .nichts
        moveq   #0,d4                   ; clock open? (not yet at the header packet)
        tst.l   _TimerBase
        beq     .platz
        bsr     zeit_now
        move.l  d1,d5                   ; start, including compaction
        move.l  d1,d6                   ; start of the Read
        moveq   #1,d4
.platz: move.l  #ARENA,d3
        sub.l   cp_rlen,d3
        cmp.l   cp_chunk,d3
        bhs   .menge
        bsr     verdichten
        tst.l   d4
        beq     .verdichtet
        bsr     zeit_now
        move.l  d1,d6
.verdichtet:
        move.l  #ARENA,d3
        sub.l   cp_rlen,d3
        beq   .nichts
.menge: move.l  cp_bytes,d0
        move.l  cp_chunk,d1
        subq.l  #1,d1
        and.l   d1,d0
        move.l  cp_chunk,d1
        sub.l   d0,d1                   ; up to the block boundary
        cmp.l   d1,d3
        bls   .lesen
        move.l  d1,d3
.lesen:
.read:  move.l  cp_fh,d1
        move.l  cp_arena,d2
        add.l   cp_rlen,d2
        DOS     Read
        addq.l  #1,cp_reads
        tst.l   d4
        beq     .ergebnis
        move.l  d0,-(sp)
        bsr     zeit_now
        move.l  d1,d0
        sub.l   d5,d0
        move.l  d0,cp_readletzt         ; this long the loop stood: for the timing
        sub.l   d6,d1                   ; duration of this Read in ticks
        add.l   d1,cp_readticks
        cmp.l   cp_readmax,d1
        bls     .kein_max
        move.l  d1,cp_readmax
.kein_max:
        tst.l   cp_langgrenze
        beq     .kurz
        cmp.l   cp_langgrenze,d1
        bls     .kurz
        addq.l  #1,cp_readlang
.kurz:  move.l  (sp)+,d0
.ergebnis:
        tst.l   d0
        bgt   .gut
        st      cp_feof
.nichts:
        moveq   #0,d0
        bra   .raus
.gut:   add.l   d0,cp_rlen
        add.l   d0,cp_bytes
.raus:  movem.l (sp)+,d1-d6/a0-a1/a6
        rts

; d0 = bytes from cp_rpos on, contiguous -> d0 = 1 there, 0 not
; (end or no room). Reads repeatedly: a network stream delivers short.
brauche:
        move.l  d2,-(sp)
        move.l  d0,d2
.pruef: move.l  cp_rlen,d0
        sub.l   cp_rpos,d0
        cmp.l   d2,d0
        bhs   .ja
        bsr   nachladen
        tst.l   d0
        bne   .pruef
        move.l  (sp)+,d2
        rts
.ja:    moveq   #1,d0
        move.l  (sp)+,d2
        rts

; Skip cp_skipleft bytes -> d0 = 1 done, 0 continue later, -1 end.
ueberlesen:
        movem.l d1-d2,-(sp)
.runde: move.l  cp_skipleft,d2
        beq   .fertig
        move.l  cp_rlen,d1
        sub.l   cp_rpos,d1
        bne   .nehmen
        bsr   nachladen
        tst.l   d0
        bne   .runde
        tst.b   cp_feof
        beq   .raus
        moveq   #-1,d0
        bra   .raus
.nehmen:
        cmp.l   d2,d1
        bls   .n
        move.l  d2,d1
.n:     add.l   d1,cp_rpos
        sub.l   d1,cp_skipleft
        bra   .runde
.fertig:
        moveq   #1,d0
.raus:  movem.l (sp)+,d1-d2
        rts

; Next sync word from cp_rpos on -> d0 = 1 found (cp_rpos points before it),
; 0 not (end or no room). The last three bytes stay - they may be the
; beginning of the word.
sync_suchen:
        movem.l d1-d2/a0,-(sp)
.runde: move.l  cp_rlen,d1
        sub.l   cp_rpos,d1
        subq.l  #3,d1
        ble   .mehr
        move.l  cp_arena,a0
        add.l   cp_rpos,a0
.such:  cmp.b   #'C',(a0)
        bne     .vorbei
        bsr     ist_magic
        beq   .treffer
.vorbei:
        addq.l  #1,a0
        subq.l  #1,d1
        bne   .such
        sub.l   cp_arena,a0
        move.l  a0,cp_rpos
.mehr:  bsr     nachladen
        tst.l   d0
        bne   .runde
        bra   .raus
.treffer:
        sub.l   cp_arena,a0
        move.l  a0,cp_rpos
        moveq   #1,d0
.raus:  movem.l (sp)+,d1-d2/a0
        rts

; a0 = place -> Z set if 'CPKS' is there. Byte by byte.
ist_magic:
        cmp.b   #'C',(a0)
        bne     .raus
        cmp.b   #'P',1(a0)
        bne     .raus
        cmp.b   #'K',2(a0)
        bne     .raus
        cmp.b   #'S',3(a0)
.raus:  rts

; --- Packets ------------------------------------------------------------------

; Exactly one packet -> d0 = 1 carry on, 0 stop (queue full, no room),
; -1 end of stream.
ein_paket:
        movem.l d2-d6/a2-a3,-(sp)
        tst.l   cp_skipleft
        beq   .kopf
        bsr     ueberlesen
        tst.l   d0
        ble     .raus
.kopf:  moveq   #PKTHDR,d0
        bsr     brauche
        tst.l   d0
        beq     .mangel
        move.l  cp_arena,a2
        add.l   cp_rpos,a2
        move.l  a2,a0
        bsr     ist_magic
        beq   .sync
        addq.l  #1,cp_resyncs
        bsr     sync_suchen
        tst.l   d0
        beq     .mangel
        moveq   #PKTHDR,d0
        bsr     brauche
        tst.l   d0
        beq     .mangel
        move.l  cp_arena,a2
        add.l   cp_rpos,a2
.sync:  move.l  a2,d0                   ; header at an odd place: copy it first
        btst    #0,d0
        beq     .gerade
        lea     cp_kopf,a0
        move.l  a2,a1
        moveq   #PKTHDR-1,d0
.kopie: move.b  (a1)+,(a0)+
        dbra    d0,.kopie
        lea     cp_kopf,a2
.gerade:
        moveq   #0,d2
        move.b  4(a2),d2                ; type
        moveq   #0,d3
        move.b  5(a2),d3                ; flags
        move.l  8(a2),d4                ; pts
        move.l  12(a2),d5               ; length
        move.l  d5,d6
        neg.l   d6
        moveq   #3,d0
        and.l   d0,d6                   ; padding bytes
        cmp.b   #T_HEAD,d2
        beq     .kopfpaket
        tst.b   cp_haveinfo
        beq   .ueberlesen
        cmp.b   #T_VIDEO,d2
        beq   .video
        cmp.b   #T_AUDIO,d2
        beq     .ton
; Unknown, tick, before the first header, or too large: skip by its length.
.ueberlesen:
        add.l   #PKTHDR,cp_rpos
        add.l   d6,d5
        move.l  d5,cp_skipleft
        bsr     ueberlesen
        tst.l   d0
        bmi     .raus
        moveq   #1,d0
        bra     .raus
.zugross:
        addq.l  #1,cp_toobig
        bra   .ueberlesen

.video: tst.b   cp_bis_key              ; behind: discard frame packets up to
        beq     .v_platz                ; the next keyframe, keep reading the
        btst    #0,d3                   ; sound behind them
        bne     .v_key
        addq.l  #1,cp_leserverw
        bra     .ueberlesen
.v_key: clr.b   cp_bis_key
.v_platz:
        cmp.l   #QSLOTS,cp_queued
        bhs     .halt                   ; leave the packet where it is
        cmp.l   #MAXPKT,d5
        bhi   .zugross
        moveq   #PKTHDR,d0
        add.l   d5,d0
        bsr     brauche
        tst.l   d0
        beq     .mangel
        move.l  cp_arena,a2             ; brauche may have compacted
        add.l   cp_rpos,a2
        lea     cp_queue,a3
        move.l  cp_head,d0
        lsl.l   #4,d0
        add.l   d0,a3
        lea     PKTHDR(a2),a0
        move.l  a0,Q_PTR(a3)
        move.l  d5,Q_LEN(a3)
        move.l  d4,Q_PTS(a3)
        moveq   #1,d0
        and.l   d3,d0
        move.l  d0,Q_KEY(a3)
        move.l  cp_head,d0
        addq.l  #1,d0
        moveq   #QSLOTS-1,d1
        and.l   d1,d0
        move.l  d0,cp_head
        addq.l  #1,cp_queued
        add.l   #PKTHDR,d5
        add.l   d5,cp_rpos
        bra     .fuellbytes

.ton:   tst.l   cp_arate
        beq     .ueberlesen
        cmp.l   #MAXPKT,d5
        bhi   .zugross
        moveq   #PKTHDR,d0
        add.l   d5,d0
        bsr     brauche
        tst.l   d0
        beq     .mangel
        ; Adjust the time base: in a gapless stream this has no effect, after
        ; a break the absolute sample index sets the position anew.
        move.l  cp_aptsbase,d0
        add.l   cp_asamples,d0
        cmp.l   d4,d0
        beq   .basis
        move.l  d4,d0
        sub.l   cp_asamples,d0
        move.l  d0,cp_aptsbase
.basis: move.l  cp_sink,d0
        beq   .zaehlen
        tst.l   d5
        beq   .zaehlen
        move.l  d0,a1
        move.l  cp_arena,a0
        add.l   cp_rpos,a0
        lea     PKTHDR(a0),a0
        move.l  d5,d0
        jsr     (a1)
.zaehlen:
        move.l  cp_ashift,d0
        bmi   .ton_weiter
        move.l  d5,d1
        lsr.l   d0,d1
        add.l   d1,cp_asamples
.ton_weiter:
        add.l   #PKTHDR,d5
        add.l   d5,cp_rpos
        bra   .fuellbytes

; Only the first header packet counts; the repetitions are there for joining
; in the middle.
.kopfpaket:
        tst.b   cp_haveinfo
        bne     .ueberlesen
        cmp.l   #36,d5
        blo     .ueberlesen
        moveq   #PKTHDR+36,d0
        bsr     brauche
        tst.l   d0
        beq   .mangel
        move.l  cp_arena,a0
        add.l   cp_rpos,a0
        lea     PKTHDR(a0),a0
        move.l  a0,d0
        btst    #0,d0
        beq     .kopf_gerade
        lea     cp_kopf36,a1
        moveq   #36-1,d0
.kopf_kopie:
        move.b  (a0)+,(a1)+
        dbra    d0,.kopf_kopie
        lea     cp_kopf36,a0
.kopf_gerade:
        moveq   #0,d0
        move.w  4(a0),d0
        move.l  d0,cp_width
        move.w  6(a0),d0
        move.l  d0,cp_height
        move.l  8(a0),cp_fpsnum
        move.l  12(a0),cp_fpsden
        move.l  16(a0),cp_timebase
        move.l  20(a0),cp_arate
        moveq   #0,d0
        move.b  24(a0),d0
        move.l  d0,cp_achans
        move.b  25(a0),d0
        move.l  d0,cp_abits
        move.l  28(a0),cp_codec
        move.l  32(a0),cp_prebuffer
        st      cp_haveinfo
        bra     .ueberlesen

.fuellbytes:
        move.l  d6,cp_skipleft
        beq   .eins
        bsr     ueberlesen
        tst.l   d0
        bmi   .raus
.eins:  moveq   #1,d0
        bra   .raus
.halt:  moveq   #0,d0
        bra   .raus
.mangel:
        moveq   #0,d0
        tst.b   cp_feof
        beq   .raus
        moveq   #-1,d0
.raus:  movem.l (sp)+,d2-d6/a2-a3
        rts

; --- Queue ---------------------------------------------------------------------

cpks_pump:
        move.l  a0,cp_sink
.runde: tst.b   cp_eof
        bne   .raus
        cmp.l   #QSLOTS,cp_queued
        bhs   .raus
        bsr     ein_paket
        tst.l   d0
        bgt   .runde
        beq   .raus
        st      cp_eof
.raus:  rts

cpks_next:
        move.l  cp_queued,d0
        beq   .raus
        subq.l  #1,cp_queued
        move.l  cp_tail,d0
        move.l  d0,d1
        addq.l  #1,d1
        and.l   #QSLOTS-1,d1
        move.l  d1,cp_tail
        lsl.l   #4,d0
        lea     cp_queue,a0
        add.l   a0,d0
.raus:  rts

cpks_drop:
        bra   cpks_next

cpks_peek:
        cmp.l   cp_queued,d0
        bhs   .nichts
        add.l   cp_tail,d0
        moveq   #QSLOTS-1,d1
        and.l   d1,d0
        lsl.l   #4,d0
        lea     cp_queue,a0
        add.l   a0,d0
        rts
.nichts:
        moveq   #0,d0
        rts

cpks_advance:
        movem.l d2-d5/a2,-(sp)
        move.l  d0,d2                   ; position
        moveq   #0,d4                   ; discarded
        moveq   #0,d5                   ; due
        tst.l   cp_queued
        beq   .ende
        moveq   #0,d0
        bsr   cpks_peek
        move.l  d0,a2
        move.l  d2,d0
        sub.l   Q_PTS(a2),d0
        move.l  cp_sprung,d1            ; threshold; 0 = one second as in 5.4
        bne     .grenze
        move.l  cp_timebase,d1
.grenze:
        cmp.l   d1,d0
        ble   .faellig
        ; BEHIND: the sound sets the time, the picture skips. The target is the
        ; NEWEST keyframe with pts <= position, otherwise the FIRST one after it
        ; (the picture stands still until then). If none is in the queue,
        ; everything goes, and the reader discards frame packets up to the next
        ; keyframe - audio packets it keeps reading. Formerly the reader stopped
        ; when the queue was full, the sound behind it never arrived, Paula ran
        ; dry and the clock stood still: then it never skipped at all.
        moveq   #-1,d4
        moveq   #0,d3
.suche: cmp.l   cp_queued,d3
        bhs   .gesucht
        move.l  d3,d0
        bsr   cpks_peek
        move.l  d0,a2
        tst.l   Q_KEY(a2)
        beq   .weiter
        move.l  d2,d0
        sub.l   Q_PTS(a2),d0
        bmi   .danach
        move.l  d3,d4                   ; pts <= position: remember, keep looking
        bra   .weiter
.danach:
        tst.l   d4
        bpl   .gesucht                  ; there was one before it already
        move.l  d3,d4                   ; the first keyframe after the position
        bra   .gesucht
.weiter:
        addq.l  #1,d3
        bra   .suche
.gesucht:
        tst.l   d4
        bpl   .verwerfen
        move.l  cp_queued,d4            ; no keyframe in the queue
        st      cp_bis_key
.verwerfen:
        tst.l   d4
        beq   .faellig                  ; the keyframe is at the front already
        addq.l  #1,cp_spruenge
        move.l  d4,d3
        bra   .v_weiter
.v:     bsr     cpks_next
.v_weiter:
        subq.l  #1,d3
        bpl   .v
.faellig:
        moveq   #0,d3
.f:     cmp.l   cp_queued,d3
        bhs   .ende
        move.l  d3,d0
        bsr     cpks_peek
        move.l  d0,a2
        move.l  d2,d0
        sub.l   Q_PTS(a2),d0
        bmi   .ende
        addq.l  #1,d5
        addq.l  #1,d3
        bra   .f
.ende:  move.l  d5,d0
        move.l  d4,d1
        movem.l (sp)+,d2-d5/a2
        rts

        section bss,bss

cp_state:
cp_fh:          ds.l    1
cp_arena:       ds.l    1
cp_rpos:        ds.l    1
cp_rlen:        ds.l    1
cp_skipleft:    ds.l    1
cp_sink:        ds.l    1
cp_head:        ds.l    1
cp_tail:        ds.l    1
cp_queued:      ds.l    1
cp_width:       ds.l    1
cp_height:      ds.l    1
cp_fpsnum:      ds.l    1
cp_fpsden:      ds.l    1
cp_timebase:    ds.l    1
cp_arate:       ds.l    1
cp_achans:      ds.l    1
cp_abits:       ds.l    1
cp_prebuffer:   ds.l    1
cp_codec:       ds.l    1
cp_ashift:      ds.l    1
cp_asamples:    ds.l    1
cp_aptsbase:    ds.l    1
cp_bytes:       ds.l    1
cp_reads:       ds.l    1
cp_resyncs:     ds.l    1
cp_toobig:      ds.l    1
cp_moved:       ds.l    1
cp_chunk:       ds.l    1
cp_readticks:   ds.l    1
cp_readmax:     ds.l    1
cp_readlang:    ds.l    1
cp_langgrenze:  ds.l    1
cp_readletzt:   ds.l    1
cp_sprung:      ds.l    1
cp_leserverw:   ds.l    1
cp_spruenge:    ds.l    1
cp_feof:        ds.b    1
cp_eof:         ds.b    1
cp_haveinfo:    ds.b    1
cp_ohnelesen:   ds.b    1
cp_bis_key:     ds.b    1
                ds.b    1
cp_queue:       ds.l    QSLOTS*4
cp_state_end:
cp_kopf:        ds.l    4               ; packet header, aligned
cp_kopf36:      ds.l    9               ; header packet, aligned
