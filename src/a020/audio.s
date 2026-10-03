; audio.s - sound, two paths: audio.device (Paula) and ahi.device.
;
; PAULA is the default; AHI is asked for with the option AHI and never chosen
; by itself (if ahi.device is missing, audio_open returns 4 and the player
; reports it). What AHI brings: 16 bit instead of 8, the exact sample rate
; instead of Paula's integer period, and the sound of a card or of SAGA.
;
; Both paths share everything that makes the sound the clock - the ring in
; fast RAM, the FIFO of sent buffers, abholen and audio_played. They differ in
; three places only:
;
;   buffers   Paula: one 8-bit buffer per channel in CHIP RAM, Paula plays one
;             channel per request. AHI: one interleaved buffer per slot in any
;             memory, one request per slot.
;   order     Paula: the channel plays the requests in the order they were
;             sent. AHI: ahir_Link points BACKWARDS at a request already sent
;             and delays this one until that one is finished
;             (ahi.device/CMD_WRITE). In both cases what finishes is a prefix
;             of the FIFO, which is what abholen relies on.
;   format    Paula gets 8-bit signed per channel (16 bit loses its low byte).
;             AHI gets what it announces: 8 bit signed, or 16 bit signed in
;             m68k word order - audio_write converts while filling the ring,
;             so audio_service stays a plain copy.
;
; Model: src/audio.c (state 3f04d85, with the remainder at the end of the
; stream) and the mono patch P1. The behaviour is the same, the reasoning is
; written up there:
;
; - Feeding never blocks: audio packets land in a ring in fast RAM (2 s),
;   audio_service pushes from there into free chip buffers.
; - NBUF short buffers (rate / ABUF samples, default 32 -> 31 ms, ANUM = 16):
;   the clock can only answer per buffer; in between it interpolates linearly,
;   capped at the shortest buffer still running.
; - The clock counts what Paula has received - the ring does not count. If
;   Paula runs dry the position stands still, and the picture waits with it.
; - If Paula is empty and less than one buffer is in the ring, the remainder
;   goes out as a short buffer (even length) - otherwise the last frame of the
;   stream would never fall due.
; - ADCMD_PERVOL before the first write: ADIOF_PERVOL alone has no effect on
;   real hardware (the volume stayed 0).
; - Colour clock = EClock frequency x 5, period rounded.
; - MONO: one ring and one chip buffer per slot; both channels play the same
;   memory. 8 bit: copy and flip the sign a longword at a time.
;
;   audio_open    d0 = rate, d1 = channels, d2 = bits, d3 = ABUF, d4 = ANUM
;                 -> d0 = 0 good, 1 format, 2 audio.device, 3 memory
;   audio_close   waits for running buffers and frees everything; any number of times
;   audio_write   a0 = PCM as in the stream, d0 = bytes
;   audio_service ring -> free chip buffers, never blocks
;   audio_played  -> d0 = samples played (the clock)

        include "player.i"
        include "devices/audio.i"
        include "devices/ahi.i"

        xdef    audio_open,audio_close,audio_write,audio_service,audio_played
        xdef    audio_weg_setzen
        xdef    au_rate,au_period,au_effrate,au_mask,au_bytes,au_sent,au_lost,au_under,au_ende
        xdef    au_err,au_minpend,au_maxring,au_checkio,au_bufsz,au_nbuf,au_rcount
        xdef    au_weg,au_ahiunit
        xref    _SysBase,zt_freq,zeit_now,muldiv32

NBUF    equ     16

        section code,code

; audio_weg_setzen  d0 = 0 Paula / 1 AHI, d1 = ahi.device unit
; BEFORE audio_open - afterwards nothing switches any more: a path change in
; mid-stream would mean a gap, and the clock hangs on the buffer chain.
audio_weg_setzen:
        tst.l   d0
        sne     au_weg
        move.l  d1,au_ahiunit
        rts

audio_open:
        movem.l d2-d7/a2-a6,-(sp)
        tst.l   d0
        beq     .e_format
        cmp.l   #100,d0
        blo     .e_format
        cmp.l   #1,d1
        blo     .e_format
        cmp.l   #2,d1
        bhi     .e_format
        cmp.l   #8,d2
        beq     .bits
        cmp.l   #16,d2
        bne     .e_format
.bits:  move.l  d1,au_chans
        move.l  d2,au_bits
        cmp.l   #1,d1
        seq     au_mono
        cmp.l   #8,d2                   ; 8 bit mono: flip the sign only while
        seq     au_vzchip               ; copying into the chip buffer
        move.b  au_mono,d6
        and.b   d6,au_vzchip
        cmp.l   #4,d3                   ; ABUF 4..128, otherwise 32 (audio_config)
        blo     .div_std
        cmp.l   #128,d3
        bls     .div_gut
.div_std:
        moveq   #32,d3
.div_gut:
        cmp.l   #2,d4                   ; ANUM 2..16, otherwise 16
        blo     .nb_std
        cmp.l   #NBUF,d4
        bls     .nb_gut
.nb_std:
        moveq   #NBUF,d4
.nb_gut:
        move.l  d4,au_nbuf
        tst.b   au_weg
        bne     ahi_oeffnen             ; d0 rate, d1 channels, d2 bits, d3 ABUF
        move.l  #ioa_SIZEOF,au_reqsize
        move.l  zt_freq,d5              ; colour clock = EClock x 5
        move.l  d5,d6
        add.l   d5,d5
        add.l   d5,d5
        add.l   d6,d5
        cmp.l   #3000000,d5
        blo     .notnagel
        cmp.l   #4000000,d5
        bls     .takt
.notnagel:
        move.l  #3546895,d5
.takt:  move.l  d5,au_clock
        cmp.l   #28000,d0
        bls     .rate
        move.l  #28000,d0
.rate:  move.l  d0,au_rate
        move.l  d0,d1                   ; period = (clock + rate/2) / rate
        lsr.l   #1,d1
        add.l   d5,d1
        divu    d0,d1
        bvs     .e_format
        and.l   #$ffff,d1
        cmp.l   #124,d1
        bhs     .periode
        moveq   #124,d1
.periode:
        move.l  d1,au_period
        move.l  d5,d2
        divu    d1,d2
        and.l   #$ffff,d2
        move.l  d2,au_effrate
        movem.l d0-d1,-(sp)             ; ticks per sample x 256, for divu
        move.l  zt_freq,d0
        move.l  #256,d1
        bsr     muldiv32
        cmp.l   #$ffff,d0
        bls     .tps
        moveq   #0,d0                   ; does not fit in a word
.tps:   move.l  d0,au_tps8
        movem.l (sp)+,d0-d1
        move.l  d0,d1                   ; buffer = rate / ABUF, to 4, >= 512
        divu    d3,d1
        and.l   #$ffff,d1
        moveq   #-4,d2
        and.l   d2,d1
        cmp.l   #512,d1
        bhs     .puffer
        move.l  #512,d1
.puffer:
        move.l  d1,au_bufsz
        move.l  d1,au_bufbytes          ; Paula: one byte per sample

        EXEC    CreateMsgPort
        move.l  d0,au_port
        beq     .e_device
        move.l  d0,a0
        moveq   #ioa_SIZEOF,d0
        EXEC    CreateIORequest
        move.l  d0,au_alloc
        beq     .e_device
        move.l  d0,a1
        move.b  #10,LN_PRI(a1)
        move.l  #kombis,ioa_Data(a1)
        move.l  #4,ioa_Length(a1)
        lea     audioname,a0
        moveq   #0,d0
        moveq   #0,d1
        EXEC    OpenDevice
        tst.b   d0
        bne     .e_device
        st      au_offen
        move.l  au_alloc,a1
        move.l  IO_UNIT(a1),au_mask

        moveq   #0,d6                   ; slot
.platz: cmp.l   au_nbuf,d6
        bhs     .pervol
        moveq   #0,d7                   ; channel
.kanal: move.l  au_mask,d0
        tst.l   d7
        bne     .rechts
        and.l   #$09,d0                 ; left: 0 or 3
        bra     .frei
.rechts:
        and.l   #$06,d0                 ; right: 1 or 2
.frei:  beq     .weiter
        move.l  d0,d4
        neg.l   d4
        and.l   d0,d4                   ; lowest bit that is set
        moveq   #ioa_SIZEOF,d0
        move.l  #MEMF_CLEAR,d1
        EXEC    AllocMem
        tst.l   d0
        beq     .e_mem
        move.l  d0,a2
        move.l  d6,d0                   ; index (2 * slot + channel) * 4
        add.l   d0,d0
        add.l   d7,d0
        add.l   d0,d0
        add.l   d0,d0
        lea     au_req,a0
        move.l  a2,0(a0,d0.l)
        move.l  au_alloc,a0
        move.l  a2,a1
        moveq   #ioa_SIZEOF,d0
        EXEC    CopyMem
        move.l  au_port,MN_REPLYPORT(a2)
        move.l  d4,IO_UNIT(a2)
        move.l  d7,d0                   ; chip buffer: mono has only one per slot
        tst.b   au_mono
        beq     .bufindex
        moveq   #0,d0
.bufindex:
        move.l  d6,d1
        add.l   d1,d1
        add.l   d0,d1
        add.l   d1,d1
        add.l   d1,d1
        lea     au_buf,a3
        add.l   d1,a3
        tst.l   (a3)
        bne     .weiter
        move.l  au_bufsz,d0
        move.l  #MEMF_CHIP|MEMF_CLEAR,d1
        EXEC    AllocMem
        move.l  d0,(a3)
        beq     .e_mem
.weiter:
        addq.l  #1,d7
        cmp.l   #2,d7
        blo     .kanal
        addq.l  #1,d6
        bra     .platz

.pervol:
        moveq   #0,d7
.pv:    lea     au_req,a0
        move.l  d7,d0
        add.l   d0,d0
        add.l   d0,d0
        move.l  0(a0,d0.l),d0
        beq     .pv_weiter
        move.l  d0,a1
        move.w  #ADCMD_PERVOL,IO_COMMAND(a1)
        clr.b   IO_FLAGS(a1)
        move.w  au_period+2,ioa_Period(a1)
        move.w  #64,ioa_Volume(a1)
        EXEC    DoIO
        tst.b   d0
        beq     .pv_weiter
        ext.w   d0
        ext.l   d0
        move.l  d0,au_err
.pv_weiter:
        addq.l  #1,d7
        cmp.l   #2,d7
        blo     .pv

        move.l  au_rate,d0              ; rings: 2 s per channel
        add.l   d0,d0
        move.l  d0,au_ringsz
        move.l  d0,au_ringbytes
        move.l  #MEMF_CLEAR,d1
        EXEC    AllocMem
        move.l  d0,au_ring
        beq     .e_mem
        tst.b   au_mono
        bne     .ringe
        move.l  au_ringsz,d0
        move.l  #MEMF_CLEAR,d1
        EXEC    AllocMem
        move.l  d0,au_ring+4
        beq     .e_mem
.ringe: move.l  #$ffffffff,au_minpend
        bsr     zeit_now
        move.l  d1,au_post0
        moveq   #0,d0
        bra     .raus
.e_format:
        moveq   #1,d0
        bra     .raus
.e_device:
        bsr     audio_close
        moveq   #2,d0
        bra     .raus
.e_mem: bsr     audio_close
        moveq   #3,d0
.raus:  movem.l (sp)+,d2-d7/a2-a6
        rts

; --- Opening the AHI path ------------------------------------------------
;
; Entered out of audio_open with d0 = rate, d1 = channels, d2 = bits,
; d3 = ABUF (already clamped), au_nbuf set. No colour clock and no period:
; ahi.device takes the rate as it is, so au_effrate == au_rate and the rate
; deviation that Paula's integer period forces does not exist here.
;
; Return like audio_open: 0 good, 1 format, 3 memory, 4 no ahi.device. The
; frame is the one of audio_open - the exit labels belong to it.
ahi_oeffnen:
        clr.b   au_vzchip               ; audio_write already converts
        move.l  d2,d4                   ; frame = channels x bytes per sample
        lsr.l   #3,d4
        mulu.l  d1,d4
        move.l  d4,au_fs
        moveq   #AHIST_M8S,d5           ; type from channels and bits
        cmp.l   #16,d2
        bne     .typ8
        moveq   #AHIST_M16S,d5
        cmp.l   #2,d1
        bne     .typ
        moveq   #AHIST_S16S,d5
        bra     .typ
.typ8:  cmp.l   #2,d1
        bne     .typ
        moveq   #AHIST_S8S,d5
.typ:   move.l  d5,au_type
        move.l  d0,au_rate              ; no 28 kHz cap - that is Paula's limit
        move.l  d0,au_effrate
        clr.l   au_period
        clr.l   au_clock
        move.l  #AHIRequest_SIZEOF,au_reqsize

        movem.l d0-d1,-(sp)             ; ticks per sample x 256, as for Paula
        move.l  zt_freq,d0
        move.l  #256,d1
        bsr     muldiv32
        cmp.l   #$ffff,d0
        bls     .tps
        moveq   #0,d0
.tps:   move.l  d0,au_tps8
        movem.l (sp)+,d0-d1

        move.l  d0,d1                   ; buffer = rate / ABUF, to 4, >= 512
        divu    d3,d1
        and.l   #$ffff,d1
        moveq   #-4,d2
        and.l   d2,d1
        cmp.l   #512,d1
        bhs     .puffer
        move.l  #512,d1
.puffer:
        move.l  d1,au_bufsz
        move.l  au_fs,d0                ; bytes per buffer
        mulu.l  d1,d0
        move.l  d0,au_bufbytes

        EXEC    CreateMsgPort
        move.l  d0,au_port
        beq     .e_ahi
        move.l  d0,a0
        move.l  #AHIRequest_SIZEOF,d0
        EXEC    CreateIORequest
        move.l  d0,au_alloc
        beq     .e_ahi
        move.l  d0,a1
        move.w  #4,ahir_Version(a1)     ; MUST be set before OpenDevice
        lea     ahiname,a0
        move.l  au_ahiunit,d0
        moveq   #0,d1
        EXEC    OpenDevice
        tst.b   d0
        bne     .e_ahi
        st      au_offen
        move.l  au_ahiunit,au_mask      ; STATS shows the unit here

        moveq   #0,d6                   ; one request and one buffer per slot
.platz: cmp.l   au_nbuf,d6
        bhs     .ringe
        move.l  #AHIRequest_SIZEOF,d0
        move.l  #MEMF_CLEAR,d1
        EXEC    AllocMem
        tst.l   d0
        beq     .e_mem
        move.l  d0,a2
        move.l  d6,d0
        lsl.l   #3,d0                   ; slot x 8: entry 0 of the pair
        lea     au_req,a0
        move.l  a2,0(a0,d0.l)
        move.l  au_alloc,a0
        move.l  a2,a1
        move.l  #AHIRequest_SIZEOF,d0
        EXEC    CopyMem
        move.l  au_port,MN_REPLYPORT(a2)
        move.l  au_bufbytes,d0
        move.l  #MEMF_CLEAR,d1          ; any memory - AHI does not need chip
        EXEC    AllocMem
        tst.l   d0
        beq     .e_mem
        move.l  d6,d1
        lsl.l   #3,d1
        lea     au_buf,a0
        move.l  d0,0(a0,d1.l)
        addq.l  #1,d6
        bra     .platz

.ringe: move.l  au_rate,d0              ; ONE ring, interleaved, 2 s
        add.l   d0,d0
        move.l  d0,au_ringsz
        move.l  au_fs,d1
        mulu.l  d1,d0
        move.l  d0,au_ringbytes
        move.l  #MEMF_CLEAR,d1
        EXEC    AllocMem
        move.l  d0,au_ring
        beq     .e_mem
        move.l  #$ffffffff,au_minpend
        bsr     zeit_now
        move.l  d1,au_post0
        clr.l   au_last
        moveq   #0,d0
        bra     .raus
.e_ahi: bsr     audio_close
        moveq   #4,d0
        bra     .raus
.e_mem: bsr     audio_close
        moveq   #3,d0
.raus:  movem.l (sp)+,d2-d7/a2-a6
        rts

audio_close:
        movem.l d0-d7/a0-a6,-(sp)
        tst.b   au_weg                  ; AHI: abort first, then collect -
        beq     .warten                 ; otherwise closing would wait until
        moveq   #0,d6                   ; everything in the chain has played,
.abbruch:                               ; up to half a second after "q".
        cmp.l   #NBUF,d6
        bhs     .warten
        lea     au_queued,a0
        tst.b   0(a0,d6.l)
        beq     .ab_weiter
        move.l  d6,d0
        lsl.l   #3,d0
        lea     au_req,a0
        move.l  0(a0,d0.l),d0
        beq     .ab_weiter
        move.l  d0,a1
        EXEC    AbortIO
.ab_weiter:
        addq.l  #1,d6
        bra     .abbruch
.warten:
        moveq   #0,d6
.w:     cmp.l   #NBUF,d6
        bhs     .frei
        bsr     warte_puffer
        addq.l  #1,d6
        bra     .w
.frei:  lea     au_buf,a2
        lea     au_req,a3
        moveq   #2*NBUF-1,d7
.eins:  move.l  (a2),d0
        beq     .req
        move.l  d0,a1
        move.l  au_bufbytes,d0
        EXEC    FreeMem
        clr.l   (a2)
.req:   move.l  (a3),d0
        beq     .naechstes
        move.l  d0,a1
        move.l  au_reqsize,d0
        EXEC    FreeMem
        clr.l   (a3)
.naechstes:
        addq.l  #4,a2
        addq.l  #4,a3
        dbra    d7,.eins
        lea     au_ring,a2
        moveq   #1,d7
.ring:  move.l  (a2),d0
        beq     .ring_weiter
        move.l  d0,a1
        move.l  au_ringbytes,d0
        EXEC    FreeMem
        clr.l   (a2)
.ring_weiter:
        addq.l  #4,a2
        dbra    d7,.ring
        tst.b   au_offen
        beq     .alloc
        move.l  au_alloc,a1
        EXEC    CloseDevice
        clr.b   au_offen
.alloc: move.l  au_alloc,d0
        beq     .port
        move.l  d0,a0
        EXEC    DeleteIORequest
        clr.l   au_alloc
.port:  move.l  au_port,d0
        beq     .raus
        move.l  d0,a0
        EXEC    DeleteMsgPort
        clr.l   au_port
.raus:  movem.l (sp)+,d0-d7/a0-a6
        rts

; --- Buffers -------------------------------------------------------------------

; d6 = slot -> d0 = 1 done (or free), 0 still playing. Once done, always done,
; until it is sent again (au_bdone saves a CheckIO).
puffer_fertig:
        movem.l d2/a2/a6,-(sp)
        lea     au_queued,a0
        tst.b   0(a0,d6.l)
        beq     .ja
        lea     au_bdone,a0
        tst.b   0(a0,d6.l)
        bne     .ja
        move.l  d6,d2
        lsl.l   #3,d2
        lea     au_req,a2
        add.l   d2,a2
        moveq   #1,d2
.kanal: move.l  (a2)+,d0
        beq     .naechster
        addq.l  #1,au_checkio
        move.l  d0,a1
        EXEC    CheckIO
        tst.l   d0
        beq     .nein
.naechster:
        dbra    d2,.kanal
        lea     au_bdone,a0
        st      0(a0,d6.l)
.ja:    moveq   #1,d0
        bra     .raus
.nein:  moveq   #0,d0
.raus:  movem.l (sp)+,d2/a2/a6
        rts

; d6 = slot: collect a finished buffer (WaitIO), remember io_Error.
warte_puffer:
        movem.l d0-d2/a0-a2/a6,-(sp)
        lea     au_queued,a0
        tst.b   0(a0,d6.l)
        beq     .raus
        bsr     puffer_fertig
        tst.l   d0
        bne     .kanaele
        addq.l  #1,au_blocked
.kanaele:
        move.l  d6,d2
        lsl.l   #3,d2
        lea     au_req,a2
        add.l   d2,a2
        moveq   #1,d2
.k:     move.l  (a2)+,d0
        beq     .weiter
        move.l  d0,a1
        EXEC    WaitIO
        move.l  -4(a2),a1
        move.b  IO_ERROR(a1),d0
        beq     .weiter
        ext.w   d0
        ext.l   d0
        move.l  d0,au_err
.weiter:
        dbra    d2,.k
        lea     au_queued,a0
        clr.b   0(a0,d6.l)
        move.l  d6,d0                   ; AHI: nothing may link to it any more
        addq.l  #1,d0
        cmp.l   au_last,d0
        bne     .raus
        clr.l   au_last
.raus:  movem.l (sp)+,d0-d2/a0-a2/a6
        rts

; d6 = slot, d7 = sample frames: one request to ahi.device. ahir_Link points
; backwards at a request still outstanding, so this buffer is delayed until
; that one is finished; if the predecessor is already done the link stays NULL
; and the buffer starts at once. CMD_WRITE trashes the fields, so all of them
; are filled again every time.
sende_ahi:
        movem.l d0-d2/a0-a3/a6,-(sp)
        move.l  d6,d2
        lsl.l   #3,d2
        lea     au_req,a2
        move.l  0(a2,d2.l),a1           ; the request of this slot
        lea     au_buf,a3
        move.l  0(a3,d2.l),d0
        move.w  #CMD_WRITE,IO_COMMAND(a1)
        clr.b   IO_FLAGS(a1)
        move.l  d0,IO_DATA(a1)
        move.l  d7,d1                   ; io_Length in bytes
        move.l  au_fs,d0
        mulu.l  d0,d1
        move.l  d1,IO_LENGTH(a1)
        clr.l   IO_OFFSET(a1)
        move.l  au_type,ahir_Type(a1)
        move.l  au_rate,ahir_Frequency(a1)
        move.l  #$10000,ahir_Volume(a1) ; 1.0 - full volume
        move.l  #$8000,ahir_Position(a1); centre (ignored for stereo types)
        clr.l   ahir_Link(a1)
        move.l  au_last,d0              ; predecessor still outstanding?
        beq     .senden
        subq.l  #1,d0
        move.l  a1,-(sp)
        move.l  d6,-(sp)
        move.l  d0,d6
        lea     au_queued,a0
        tst.b   0(a0,d6.l)
        beq     .kein_link
        bsr     puffer_fertig
        tst.l   d0
        bne     .kein_link
        move.l  d6,d0
        lsl.l   #3,d0
        lea     au_req,a0
        move.l  0(a0,d0.l),d1
        move.l  (sp),d6
        move.l  4(sp),a1
        move.l  d1,ahir_Link(a1)
        bra     .link_fertig
.kein_link:
        move.l  (sp),d6
        move.l  4(sp),a1
.link_fertig:
        addq.l  #8,sp
.senden:
        EXEC    SendIO
        move.l  d6,d0
        addq.l  #1,d0
        move.l  d0,au_last
        movem.l (sp)+,d0-d2/a0-a3/a6
        rts

; d6 = slot, d7 = samples: send both channels.
sende_puffer:
        movem.l d0-d2/a0-a3/a6,-(sp)
        tst.b   au_weg
        beq     .paula
        bsr     sende_ahi
        bra     .buch
.paula: move.l  d6,d2
        lsl.l   #3,d2
        lea     au_req,a2
        add.l   d2,a2
        lea     au_buf,a3
        add.l   d2,a3
        moveq   #0,d2
.k:     move.l  0(a2,d2.l),d0
        beq     .weiter
        move.l  d0,a1
        move.w  #CMD_WRITE,IO_COMMAND(a1)
        move.b  #ADIOF_PERVOL,IO_FLAGS(a1)
        move.l  (a3),d0                 ; mono: both play buffer 0
        tst.b   au_mono
        bne     .daten
        move.l  0(a3,d2.l),d0
.daten: move.l  d0,ioa_Data(a1)
        move.l  d7,ioa_Length(a1)
        move.w  au_period+2,ioa_Period(a1)
        move.w  #64,ioa_Volume(a1)
        move.w  #1,ioa_Cycles(a1)
        EXEC    SendIO
.weiter:
        addq.l  #4,d2
        cmp.l   #8,d2
        blo     .k
.buch:  addq.l  #1,au_sent
        lea     au_bdone,a0
        clr.b   0(a0,d6.l)
        lea     au_queued,a0
        st      0(a0,d6.l)
        move.l  d6,d0
        add.l   d0,d0
        add.l   d0,d0
        lea     au_buflen,a0
        move.l  d7,0(a0,d0.l)
        add.l   d7,au_sentsamples
        move.l  au_fhead,d0             ; FIFO: append at the back
        add.l   au_fcount,d0
        moveq   #NBUF-1,d1
        and.l   d1,d0
        lea     au_fifo,a0
        move.b  d6,0(a0,d0.l)
        addq.l  #1,au_fcount
        movem.l (sp)+,d0-d2/a0-a3/a6
        rts

; Collect finished buffers from the front of the FIFO (WaitIO) until the front
; one is still playing. Paula plays per channel in the order sent: what is
; finished is always a prefix of the FIFO - one CheckIO per call, not per slot.
abholen:
        movem.l d6,-(sp)
.vorn:  tst.l   au_fcount
        beq     .raus
        moveq   #0,d6
        move.l  au_fhead,d0
        lea     au_fifo,a0
        move.b  0(a0,d0.l),d6
        bsr     puffer_fertig
        tst.l   d0
        beq     .raus
        bsr     warte_puffer
        move.l  d6,d0
        add.l   d0,d0
        add.l   d0,d0
        lea     au_buflen,a0
        move.l  0(a0,d0.l),d0
        add.l   d0,au_donesamples
        move.l  au_fhead,d0
        addq.l  #1,d0
        moveq   #NBUF-1,d1
        and.l   d1,d0
        move.l  d0,au_fhead
        subq.l  #1,au_fcount
        bra     .vorn
.raus:  movem.l (sp)+,d6
        rts

; --- Clock ---------------------------------------------------------------------

audio_played:
        movem.l d2-d7,-(sp)
        tst.b   au_offen
        beq     .null
        bsr     abholen
        move.l  au_sentsamples,d2
        sub.l   au_donesamples,d2       ; still in Paula
        move.l  au_bufsz,d3             ; limit: length of the front buffer
        tst.l   au_fcount
        beq     .summe
        moveq   #0,d0
        move.l  au_fhead,d1
        lea     au_fifo,a0
        move.b  0(a0,d1.l),d0
        add.l   d0,d0
        add.l   d0,d0
        lea     au_buflen,a0
        move.l  0(a0,d0.l),d3
.summe: move.l  au_sentsamples,d4
        sub.l   d2,d4                   ; played
        bsr     zeit_now
        move.l  d1,d5
        move.l  d4,d0
        sub.l   au_poslast,d0           ; finished since the last look
        beq     .gleich
        move.l  d4,au_poslast
        tst.b   au_lief                 ; did Paula run without a gap since then?
        beq     .anker_jetzt
        move.l  au_tps8,d1              ; d0 samples -> ticks: x tps8 / 256
        beq     .ticks_lang
        cmp.l   #$ffff,d0
        bhi     .ticks_lang
        mulu    d1,d0
        lsr.l   #8,d0
        bra     .ticks
.ticks_lang:
        move.l  d2,-(sp)
        move.l  zt_freq,d1
        move.l  au_effrate,d2
        bsr     muldiv32
        move.l  (sp)+,d2
.ticks:
        add.l   au_post0,d0             ; limit from the prediction ...
        move.l  d0,d1
        sub.l   au_tlast,d1
        bpl     .nicht_frueher
        move.l  au_tlast,d0             ; ... not before the last look
.nicht_frueher:
        move.l  d5,d1
        sub.l   d0,d1
        bpl     .anker                  ; ... and not after now
.anker_jetzt:
        move.l  d5,d0
.anker: move.l  d0,au_post0
.gleich:
        move.l  d5,au_tlast
        tst.l   d2
        sne     au_lief
        move.l  d4,d0
        tst.l   d2
        beq     .raus                   ; Paula empty: standing still
        move.l  d5,d0
        sub.l   au_post0,d0             ; since the last limit
        move.l  zt_freq,d1
        lsr.l   #4,d1
        cmp.l   d1,d0
        bls     .dt
        move.l  d1,d0
.dt:    move.l  au_tps8,d1
        beq     .dt_lang
        move.l  d0,d2
        lsl.l   #8,d0                   ; dt <= frequency/16
        divu    d1,d0
        bvs     .dt_lang2
        swap    d0
        clr.w   d0
        swap    d0
        bra     .dt_ok
.dt_lang2:
        move.l  d2,d0
.dt_lang:
        move.l  au_effrate,d1
        move.l  zt_freq,d2
        bsr     muldiv32
.dt_ok:
        cmp.l   d3,d0
        blo     .d
        move.l  d3,d0
        subq.l  #1,d0
.d:     add.l   d4,d0
        bra     .raus
.null:  moveq   #0,d0
.raus:  movem.l (sp)+,d2-d7
        rts

; --- Feeding ---------------------------------------------------------------------

audio_service:
        movem.l d2-d7/a2-a6,-(sp)
        tst.b   au_offen
        beq     .raus
        bsr     abholen
        move.l  au_fcount,d5            ; buffers running
.gezaehlt:
        tst.l   d5
        bne     .laeuft
        clr.b   au_lief                 ; Paula empty: next anchor is "now"
.laeuft:
        tst.l   au_sent
        beq     .schleife
        cmp.l   au_minpend,d5
        bhs     .mp
        move.l  d5,au_minpend
.mp:    move.l  au_rcount,d0
        cmp.l   au_maxring,d0
        bls     .mr
        move.l  d0,au_maxring
.mr:    tst.l   d5
        bne     .schleife
        tst.l   au_rcount
        beq     .schleife
        addq.l  #1,au_under
.schleife:
        move.l  au_bufsz,d7
        move.l  au_rcount,d0
        cmp.l   d7,d0
        bhs     .suchen
        tst.b   au_ende                 ; end of stream: the remainder goes right
        bne     .rest                   ; behind the running buffers, otherwise a
        tst.l   d5                      ; gap would open before it. Mid-stream
        bne     .raus                   ; only to an empty Paula.
.rest:  cmp.l   #2,d0
        blo     .raus
        move.l  d0,d7                   ; AHI counts frames, Paula words
        tst.b   au_weg
        bne     .suchen
        moveq   #-2,d7
        and.l   d0,d7
.suchen:
        move.l  au_fcount,d0
        cmp.l   au_nbuf,d0
        bhs     .raus                   ; all busy
        moveq   #0,d6
        lea     au_queued,a0
.s:     tst.b   0(a0,d6.l)              ; collected = free
        beq     .gefunden
        addq.l  #1,d6
        bra     .s
.gefunden:
        tst.b   au_weg
        beq     .paula
        move.l  d6,d0                   ; AHI: one piece per ring end, the
        lsl.l   #3,d0                   ; data is already in AHI's format
        lea     au_buf,a0
        move.l  0(a0,d0.l),a3           ; target buffer
        move.l  au_ring,a2
        move.l  au_ringsz,d2            ; first piece up to the end of the ring
        sub.l   au_rtail,d2
        cmp.l   d7,d2
        bls     .a_erstes
        move.l  d7,d2
.a_erstes:
        move.l  au_fs,d3
        move.l  au_rtail,d0
        mulu.l  d3,d0
        lea     0(a2,d0.l),a0
        move.l  a3,a1
        move.l  d2,d0
        mulu.l  d3,d0
        EXEC    CopyMem
        move.l  d7,d0
        sub.l   d2,d0
        beq     .kopiert
        move.l  a2,a0
        move.l  d2,d1
        mulu.l  d3,d1
        lea     0(a3,d1.l),a1
        mulu.l  d3,d0
        EXEC    CopyMem
        bra     .kopiert
.paula: moveq   #0,d4                   ; channel
.kopie: move.l  d6,d0
        add.l   d0,d0
        add.l   d4,d0
        add.l   d0,d0
        add.l   d0,d0
        lea     au_buf,a0
        move.l  0(a0,d0.l),d0
        beq     .k_weiter
        move.l  d0,a3                   ; chip buffer
        move.l  d4,d0
        add.l   d0,d0
        add.l   d0,d0
        lea     au_ring,a0
        move.l  0(a0,d0.l),d0
        beq     .k_weiter
        move.l  d0,a2                   ; ring
        move.l  au_ringsz,d2            ; first piece up to the end of the ring
        sub.l   au_rtail,d2
        cmp.l   d7,d2
        bls     .erstes
        move.l  d7,d2
.erstes:
        move.l  a2,a0
        add.l   au_rtail,a0
        move.l  a3,a1
        move.l  d2,d0
        bsr     kopie_chip
        move.l  d7,d0
        sub.l   d2,d0
        beq     .k_weiter
        move.l  a2,a0
        lea     0(a3,d2.l),a1
        bsr     kopie_chip
.k_weiter:
        tst.b   au_mono
        bne     .kopiert
        addq.l  #1,d4
        cmp.l   #2,d4
        blo     .kopie
.kopiert:
        move.l  au_rtail,d0
        add.l   d7,d0
        cmp.l   au_ringsz,d0
        blo     .tail
        sub.l   au_ringsz,d0
.tail:  move.l  d0,au_rtail
        sub.l   d7,au_rcount
        bsr     sende_puffer
        addq.l  #1,d5                   ; no short remainder behind this one
        bra     .schleife
.raus:  movem.l (sp)+,d2-d7/a2-a6
        rts

audio_write:
        movem.l d2-d7/a2-a6,-(sp)
        tst.b   au_offen
        beq     .raus
        move.l  a0,a2
        moveq   #0,d1                   ; bytes per sample as a shift count
        cmp.l   #2,au_chans
        bne     .s1
        addq.l  #1,d1
.s1:    cmp.l   #16,au_bits
        bne     .s2
        addq.l  #1,d1
.s2:    lsr.l   d1,d0
        move.l  d0,d6                   ; samples
.lauf:  tst.l   d6
        beq     .raus
        move.l  au_ringsz,d2
        sub.l   au_rcount,d2            ; room in the ring
        bne     .platz
        addq.l  #1,au_lost
        bra     .raus
.platz: move.l  au_ringsz,d3
        sub.l   au_rhead,d3             ; up to the end of the ring
        cmp.l   d2,d3
        bls     .r1
        move.l  d2,d3
.r1:    cmp.l   d6,d3
        bls     .r2
        move.l  d6,d3
.r2:    move.l  au_ring,a3
        tst.b   au_weg                  ; AHI: frames, so rhead x frame size
        beq     .pring
        move.l  au_rhead,d0
        move.l  au_fs,d1
        mulu.l  d1,d0
        add.l   d0,a3
        bra     .kopf
.pring: add.l   au_rhead,a3
        move.l  au_ring+4,d0
        beq     .kopf
        move.l  d0,a4
        add.l   au_rhead,a4
.kopf:  move.l  au_rhead,d0
        add.l   d3,d0
        cmp.l   au_ringsz,d0
        bne     .h
        moveq   #0,d0
.h:     move.l  d0,au_rhead
        add.l   d3,au_rcount
        add.l   d3,au_bytes
        sub.l   d3,d6
        tst.b   au_weg
        bne     .ahi
        cmp.l   #8,au_bits
        bne     .b16
        tst.b   au_mono
        beq     .st8
        move.l  a2,a0                   ; 8 bit mono
        move.l  a3,a1
        move.l  d3,d0
        EXEC    CopyMem
        add.l   d3,a2
        bra     .lauf                   ; sign: kopie_chip
.st8:   moveq   #-128,d7                ; 8 bit stereo: L R L R
.st8l:  move.b  (a2)+,d0
        eor.b   d7,d0
        move.b  d0,(a3)+
        move.b  (a2)+,d0
        eor.b   d7,d0
        move.b  d0,(a4)+
        subq.l  #1,d3
        bne     .st8l
        bra     .lauf
.b16:   tst.b   au_mono
        beq     .st16
.m16l:  move.b  1(a2),(a3)+             ; 16 bit: high byte (little endian)
        addq.l  #2,a2
        subq.l  #1,d3
        bne     .m16l
        bra     .lauf
.st16:  move.b  1(a2),(a3)+
        move.b  3(a2),(a4)+
        addq.l  #4,a2
        subq.l  #1,d3
        bne     .st16
        bra     .lauf

; AHI: interleaved, in the format the request announces. 8 bit unsigned (as in
; the stream) becomes signed; 16 bit little endian becomes m68k word order -
; that is where the 16 bit stays 16 bit, while Paula drops the low byte.
.ahi:   move.l  d3,d0                   ; values = frames x channels
        cmp.l   #2,au_chans
        bne     .a_eins
        add.l   d0,d0
.a_eins:
        cmp.l   #8,au_bits
        bne     .a16
        moveq   #-128,d7
.a8:    move.b  (a2)+,d1
        eor.b   d7,d1
        move.b  d1,(a3)+
        subq.l  #1,d0
        bne     .a8
        bra     .lauf
.a16:   move.b  1(a2),(a3)+
        move.b  (a2),(a3)+
        addq.l  #2,a2
        subq.l  #1,d0
        bne     .a16
        bra     .lauf
.raus:  movem.l (sp)+,d2-d7/a2-a6
        rts

; Ring -> chip buffer: a0 source, a1 target (both even: rtail only grows by
; even lengths), d0 bytes. 8 bit mono flips the sign on the way, six longwords
; per movem. Preserves d2-d7/a2-a6.
kopie_chip:
        tst.b   au_vzchip
        bne     .vz
        EXEC    CopyMem
        rts
.vz:    movem.l d2-d7,-(sp)
        move.l  #$80808080,d7
        divu    #24,d0                  ; ring < 2^16 * 24
        move.w  d0,d6
        swap    d0
        move.w  d0,-(sp)                ; remaining bytes
        subq.w  #1,d6
        bmi     .rest
.blk:   movem.l (a0)+,d0-d5
        eor.l   d7,d0
        eor.l   d7,d1
        eor.l   d7,d2
        eor.l   d7,d3
        eor.l   d7,d4
        eor.l   d7,d5
        movem.l d0-d5,(a1)
        lea     24(a1),a1
        dbf     d6,.blk
.rest:  move.w  (sp)+,d6
        subq.w  #1,d6
        bmi     .raus
.b:     move.b  (a0)+,d0
        eor.b   d7,d0
        move.b  d0,(a1)+
        dbf     d6,.b
.raus:  movem.l (sp)+,d2-d7
        rts

        section data,data
audioname:  dc.b    "audio.device",0
ahiname:    dc.b    "ahi.device",0
        cnop    0,2
; Paula: 0 and 3 left, 1 and 2 right - one from each side.
kombis:     dc.b    $03,$05,$0a,$0c

        section bss,bss
au_port:        ds.l    1
au_alloc:       ds.l    1
au_req:         ds.l    2*NBUF
au_buf:         ds.l    2*NBUF
au_buflen:      ds.l    NBUF
au_ring:        ds.l    2
au_queued:      ds.b    NBUF
au_bdone:       ds.b    NBUF
au_fifo:        ds.b    NBUF
        cnop    0,4
au_fhead:       ds.l    1
au_fcount:      ds.l    1
au_donesamples: ds.l    1
au_rate:        ds.l    1
au_chans:       ds.l    1
au_bits:        ds.l    1
au_clock:       ds.l    1
au_period:      ds.l    1
au_effrate:     ds.l    1
au_tps8:        ds.l    1
au_bufsz:       ds.l    1
au_nbuf:        ds.l    1
au_mask:        ds.l    1
au_ringsz:      ds.l    1
au_rhead:       ds.l    1
au_rtail:       ds.l    1
au_rcount:      ds.l    1
au_sentsamples: ds.l    1
au_poslast:     ds.l    1
au_post0:       ds.l    1
au_tlast:       ds.l    1
au_bytes:       ds.l    1
au_sent:        ds.l    1
au_lost:        ds.l    1
au_under:       ds.l    1
au_ende:        ds.b    1               ; spielen sets it at the end of the stream
                cnop    0,4
au_blocked:     ds.l    1
au_err:         ds.l    1
au_minpend:     ds.l    1
au_maxring:     ds.l    1
au_checkio:     ds.l    1
au_offen:       ds.b    1
au_lief:        ds.b    1
au_mono:        ds.b    1
au_vzchip:      ds.b    1
au_weg:         ds.b    1               ; 0 Paula, 1 AHI
                cnop    0,4
au_ahiunit:     ds.l    1
au_fs:          ds.l    1               ; bytes per sample frame (AHI)
au_type:        ds.l    1               ; AHIST_* (AHI)
au_last:        ds.l    1               ; slot of the last request SENT, +1
au_reqsize:     ds.l    1               ; bytes per request
au_bufbytes:    ds.l    1               ; bytes per buffer
au_ringbytes:   ds.l    1               ; bytes of one ring
