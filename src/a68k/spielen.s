; spielen.s - the playback.
;
; Model: play_cpks() in src/player.c, plus patches P2 (diagnostics: lateness,
; underruns, where the hunks live) and P4 (wake up at a deadline). Order and
; rules from the CPKS specification, section 5:
;
; - 5.2 Prebuffer: read packets until `prebuffer` ticks of sound are fed in.
; - 5.1 Position: with sound the samples played plus the stream's time base;
;   without sound the local clock (time base then in milliseconds).
; - 5.3 DECODE everything that is due - Cinepak frames build on each other.
;   PLANAR writes into the visible screen, so every decoded frame is shown.
; - 5.4 More than a second behind: cpks_advance jumps to the keyframe.
;
; WAKE UP AT A DEADLINE (P4): the player used to put the next tick at NOW plus
; half a frame interval - if a frame took longer than the tick (A600: 49 ms
; against 41.7 ms), it slept once more after EVERY frame, even when the next
; one was long overdue. Now it wakes up when the next frame (minus the lead) is
; due, at the latest after one tick. The lead is half the mean decoder time:
; the picture appears from top to bottom, so its middle should on average fall
; on pts.
;
; Hooks for the test bench (no function):
;   bild_da      a0 = queue entry, before decoding
;   bild_fertig  after decoding
;   ton_sink     a0 = audio data, d0 = bytes (callback of the reader)
;
;   spielen      -> d0 = return code; errors leave through `fehler`

        include "player.i"

        xdef    spielen,bild_da,bild_fertig,ton_sink,sp_kein_vorbau
        xref    _SysBase
        xref    opt_file,opt_ham6,opt_gray,opt_stats,opt_quiet,opt_noaudio,opt_novideo
        xref    opt_abuf,opt_anum,opt_read,fehler,modus_fehlt
        xref    out_str,out_nl,out_chr,out_unum,out_num,out_hex
        xref    cpks_open,cpks_close,cpks_pump,cpks_next,cpks_peek,cpks_advance
        xref    cp_width,cp_height,cp_fpsnum,cp_fpsden,cp_timebase,cp_arate,cp_achans
        xref    cp_abits,cp_prebuffer,cp_codec,cp_queued,cp_eof,cp_asamples,cp_aptsbase
        xref    cp_bytes,cp_reads,cp_resyncs,cp_toobig
        xref    cp_sprung,cp_leserverw,cp_spruenge,cp_ohnelesen,cp_readletzt,cp_chunk,cp_readticks,cp_readmax,cp_readlang,cp_langgrenze
        xref    cvid_open,cvid_close,cvid_decode,cvid_vorbauen
        xref    planes_open,planes_close,sc_planes,screen_open,screen_close
        xref    screen_input,screen_sigmask,sc_modeid,sc_gfxver
        xref    sc_vpid,sc_vpmodes,sc_bplcon0,sc_steuer
        xref    zeit_zuletzt,zeit_open,zeit_close,zeit_now,zeit_arm,zeit_consume,zeit_sigmask,zeit_ms,zt_freq
        xref    audio_open,audio_close,audio_write,audio_service,audio_played
        xref    au_rate,au_period,au_effrate,au_mask,au_bytes,au_sent,au_lost,au_under
        xref    au_err,au_minpend,au_maxring,au_checkio,au_bufsz,au_nbuf,au_rcount
        xref    muldiv32,udiv32

QLOW    equ     4

        section code,code

spielen:
        movem.l d2-d7/a2-a6,-(sp)
        lea     sp_state,a0
        move.w  #sp_state_end-sp_state-1,d0
.leeren:
        clr.b   (a0)+
        dbra    d0,.leeren
        tst.l   opt_stats               ; measure only if STATS shows it
        beq     .ohne_messen
        tst.l   opt_quiet
        bne     .ohne_messen
        st      sp_messen
.ohne_messen:

; --- Stream ----------------------------------------------------------------------
        move.l  opt_read,d1             ; KB per Read -> bytes
        moveq   #10,d0
        lsl.l   d0,d1
        move.l  opt_file,a0
        bsr     cpks_open
        tst.l   d0
        beq     .offen
        lea     t_e_open,a0
        cmp.l   #1,d0
        beq     .dateifehler
        lea     t_e_format,a0
        cmp.l   #2,d0
        beq     .dateifehler
        lea     t_e_mem,a0
.dateifehler:
        bra     fehler
.offen: move.l  cp_codec,d0
        cmp.l   #'cvid',d0
        beq     .codec
        cmp.l   #'CVID',d0
        beq     .codec
        lea     t_e_codec,a0
        bra     fehler
.codec: move.l  #40000,d0               ; microseconds per frame
        move.l  cp_fpsnum,d2
        beq     .upf
        move.l  #1000000,d0
        move.l  cp_fpsden,d1
        bsr     muldiv32
.upf:   move.l  d0,sp_upf
        lsr.l   #1,d0                   ; tick: half a frame interval, >= 5 ms
        cmp.l   #5000,d0
        bhs     .takt
        move.l  #5000,d0
.takt:  move.l  d0,sp_takt_us
        tst.l   opt_quiet
        bne     .bild
        bsr     strom_zeigen

; --- Picture ---------------------------------------------------------------------
.bild:  tst.l   opt_novideo
        bne     .uhr
        moveq   #MODUS_CLUT,d0
        lea     t_m_clut,a0
        tst.l   opt_gray
        beq     .m1
        moveq   #MODUS_GRAY,d0
        lea     t_m_gray,a0
.m1:    tst.l   opt_ham6
        beq     .m2
        moveq   #MODUS_HAM6,d0
        lea     t_m_ham6,a0
.m2:    move.l  d0,sp_modus
        move.l  a0,sp_modusname
        moveq   #5,d0
        cmp.l   #MODUS_HAM6,sp_modus
        bne     .np
        moveq   #6,d0
.np:    move.l  cp_height,d1
        bsr     planes_open
        tst.l   d0
        bne     .planes
        lea     t_r_chip,a1
        bra     .modus_fehlt
.planes:
        move.l  d0,a0
        move.l  sp_modus,d0
        move.l  cp_width,d1
        move.l  cp_height,d2
        bsr     cvid_open
        tst.l   d0
        beq     .schirm
        lea     t_r_geometrie,a1
        cmp.l   #1,d0
        beq     .modus_fehlt
        lea     t_r_tabellen,a1
        bra     .modus_fehlt
.schirm:
        move.l  sp_modus,d0
        bsr     screen_open
        tst.l   d0
        beq     .ausgabe
        lsl.l   #2,d0
        lea     t_r_schirm,a1
        move.l  -4(a1,d0.l),a1
.modus_fehlt:
        move.l  sp_modusname,a0
        lea     t_h_novideo,a2
        bra     modus_fehlt
.ausgabe:
        tst.l   opt_quiet
        bne     .uhr
        lea     t_ausgabe,a0
        bsr     out_str
        move.l  sp_modusname,a0
        bsr     out_str
        lea     t_modusid,a0
        bsr     out_str
        move.l  sc_modeid,d0
        moveq   #8,d1
        bsr     out_hex
        lea     t_planesadr,a0
        bsr     out_str
        move.l  sc_planes,d0
        moveq   #6,d1
        bsr     out_hex
        lea     t_gfx,a0
        bsr     out_str
        move.l  sc_gfxver,d0
        bsr     out_unum
        bsr     out_nl
        lea     t_anzeige,a0            ; what the screen really got
        bsr     out_str
        move.l  sc_vpid,d0
        moveq   #8,d1
        bsr     out_hex
        lea     t_vpmodes,a0
        bsr     out_str
        move.l  sc_vpmodes,d0
        moveq   #4,d1
        bsr     out_hex
        lea     t_ohneham,a0
        move.l  sc_vpmodes,d0
        btst    #11,d0
        beq     .kein_ham
        lea     t_ham,a0
        bra     .modes
.kein_ham:
        btst    #7,d0
        beq     .modes
        lea     t_ehb,a0
.modes: bsr     out_str
        lea     t_bplcon0,a0
        bsr     out_str
        move.l  sc_bplcon0,d0
        cmp.l   #-1,d0
        bne     .bplcon0
        lea     t_unbekannt,a0
        bsr     out_str
        bra     .weg
.bplcon0:
        moveq   #4,d1
        bsr     out_hex
.weg:   cmp.l   #MODUS_HAM6,sp_modus
        bne     .anzeige_ende
        lea     t_steuer,a0
        bsr     out_str
        move.l  sc_steuer,d0
        moveq   #4,d1
        bsr     out_hex
        lea     t_steuer2,a0
        bsr     out_str
.anzeige_ende:
        bsr     out_nl

; --- Clock and sound ---------------------------------------------------------
.uhr:   bsr     zeit_open
        tst.l   d0
        beq     .ton
        lea     t_e_timer,a0
        bra     fehler
.ton:   move.l  sp_upf,d0               ; one frame interval in ticks: the limit
        move.l  zt_freq,d1              ; for a "long read"
        move.l  #1000000,d2
        bsr     muldiv32
        move.l  d0,cp_langgrenze
        tst.l   opt_noaudio
        bne     .vorpuffern
        tst.l   cp_arate                ; 0 = no sound (do not ask achans)
        beq     .vorpuffern
        move.l  cp_arate,d0
        move.l  cp_achans,d1
        move.l  cp_abits,d2
        move.l  opt_abuf,d3
        move.l  opt_anum,d4
        bsr     audio_open
        tst.l   d0
        beq     .ton_da
        lea     t_r_tonformat,a1
        cmp.l   #1,d0
        beq     .ton_fehlt
        lea     t_r_audio,a1
.ton_fehlt:
        lea     t_m_ton,a0
        lea     t_h_noaudio,a2
        bra     modus_fehlt
.ton_da:
        st      sp_ton
        tst.l   opt_quiet
        bne     .vorpuffern
        lea     t_ton,a0
        bsr     out_str
        move.l  au_rate,d0
        bsr     out_unum
        lea     t_hz,a0
        bsr     out_str
        move.l  cp_achans,d0
        bsr     out_unum
        lea     t_kanaele,a0
        bsr     out_str
        move.l  cp_abits,d0
        bsr     out_unum
        lea     t_periode,a0
        bsr     out_str
        move.l  au_period,d0
        bsr     out_unum
        lea     t_tatsaechlich,a0
        bsr     out_str
        move.l  au_effrate,d0
        bsr     out_unum
        lea     t_hzzeile,a0
        bsr     out_str

; --- 5.2 Prebuffer ------------------------------------------------------------
.vorpuffern:
        tst.b   sp_ton
        beq     .start
        move.w  #4096-1,d7
.vp:    bsr     pumpen
        bsr     audio_service
        move.l  cp_asamples,d0
        cmp.l   cp_prebuffer,d0
        bhs     .vp_fertig
        cmp.l   #16,cp_queued           ; queue full: pump reads nothing more
        bhs     .vp_fertig
        tst.b   cp_eof
        bne     .vp_fertig
        dbra    d7,.vp
.vp_fertig:
        tst.l   opt_quiet
        bne     .start
        lea     t_vorgeladen,a0
        bsr     out_str
        move.l  cp_queued,d0
        bsr     out_unum
        lea     t_frames,a0
        bsr     out_str
        move.l  cp_asamples,d0
        bsr     out_unum
        lea     t_tonsamples,a0
        bsr     out_str

; --- Loop -----------------------------------------------------------------------
.start: move.l  sp_takt_us,d0           ; tick in ticks
        move.l  zt_freq,d1
        move.l  #1000000,d2
        bsr     muldiv32
        tst.l   d0
        bne     .takt_ticks
        moveq   #1,d0
.takt_ticks:
        move.l  d0,sp_takt
        move.l  cp_timebase,d0          ; samples per frame
        move.l  sp_upf,d1
        move.l  #1000000,d2
        bsr     muldiv32
        move.l  d0,sp_per
        tst.b   sp_ton                  ; EClock ticks per sample, 8.8
        beq     .masken
        move.l  zt_freq,d0
        move.l  #256,d1
        move.l  cp_timebase,d2
        bsr     muldiv32
        move.l  d0,sp_tps88
        move.l  au_bufsz,d0             ; audio ring low: below half a Paula
        mulu    au_nbuf+2,d0            ; filling (default 4096 samples)
        move.l  d0,-(sp)
        lsr.l   #1,d0
        move.l  d0,sp_tonknapp
        move.l  (sp)+,d0                ; the whole Paula queue in ticks
        move.l  zt_freq,d1
        move.l  au_effrate,d2
        bsr     muldiv32
        move.l  d0,sp_tdgrenze
.masken:
        bsr     zeit_sigmask
        move.l  d0,sp_tmaske
        bsr     screen_sigmask
        move.l  d0,sp_fmaske
        bsr     zeit_now
        move.l  d0,sp_next_hi
        move.l  d1,sp_next_lo
        move.l  d1,sp_start
        bsr     wecker_raster

        st      cp_ohnelesen
        move.l  cp_timebase,d0          ; frame skip already at half a second
        lsr.l   #1,d0                   ; behind: the sound sets the time
        move.l  d0,cp_sprung
        clr.l   sp_pumpmax              ; peaks only from here, without prebuffering
.schleife:
        move.l  sp_tmaske,d6
        or.l    sp_fmaske,d6
        beq     .ende
        clr.b   sp_gefeuert
.warten:
        tst.b   sp_gefeuert
        beq     .wait
        tst.b   sp_pause
        beq     .gewartet
.wait:  bsr     zeit_zuletzt            ; just read: wecker_in or end of Wait
        move.l  d1,sp_t
        move.l  d6,d0
        EXEC    Wait
        move.l  d0,d4
        tst.b   sp_messen
        beq     .gewacht
        bsr     zeit_now
        sub.l   sp_t,d1
        add.l   d1,sp_leerlauf
.gewacht:
        move.l  d4,d0
        and.l   sp_fmaske,d0
        beq     .timer
        bsr     screen_input
        cmp.l   #1,d0
        beq     .beenden
        cmp.l   #2,d0
        bne     .timer
        not.b   sp_pause
.timer: and.l   sp_tmaske,d4
        beq     .warten
        st      sp_gefeuert
        bra     .warten
.beenden:
        st      sp_quit
        bra     .ende
.gewartet:
        bsr     zeit_consume
; One round: read, sound, frames that are due. If the picture lags behind, the
; loop comes back here after EVERY frame (without Wait): the audio ring gets
; more data, and cpks_advance sees the backlog at once and jumps.
.runde:
        cmp.l   #QLOW,cp_queued         ; queue low: read right away
        scc     cp_ohnelesen
        tst.b   sp_ton                  ; audio ring low: read as well - otherwise
        beq     .lesen                  ; Paula runs dry while frames wait
        move.l  au_rcount,d0            ; (A600, network: 10x dry)
        cmp.l   sp_tonknapp,d0
        bhs     .lesen
        clr.b   cp_ohnelesen
.lesen: bsr     pumpen
        st      cp_ohnelesen
        tst.b   sp_ton
        beq     .position
        bsr     tondienst

.position:
        bsr     vorlauf_kopf
        bsr     position
        add.l   sp_vorlauf,d0
        bsr     cpks_advance
        move.l  d0,d7                   ; due
        add.l   d1,sp_verworfen
        moveq   #0,d3
.dekodieren:
        cmp.l   d7,d3
        bhs     .dekodiert
        bsr     cpks_next
        tst.l   d0
        beq     .dekodiert
        move.l  d0,a2
        move.l  a2,a0
        bsr     bild_da
        tst.l   Q_KEY(a2)
        beq     .nokey
        addq.l  #1,sp_keys
.nokey: tst.l   opt_novideo
        bne     .gezaehlt
        bsr     zeit_zuletzt            ; position, or end of the previous frame
        move.l  d1,sp_t
        move.l  Q_PTR(a2),a0
        move.l  Q_LEN(a2),d0
        move.l  Q_PTS(a2),d1
        bsr     cvid_decode
        tst.l   d0
        beq     .ohne_fehler
        addq.l  #1,sp_decfehler
.ohne_fehler:
        bsr     zeit_now
        sub.l   sp_t,d1
        add.l   d1,sp_dec
        cmp.l   sp_decmax,d1
        bls     .dec_kein_max
        move.l  d1,sp_decmax
.dec_kein_max:
        move.l  d1,-(sp)
        move.l  Q_LEN(a2),d1            ; mean packet length, weight 1/8
        move.l  sp_lema,d0
        bne     .lema_mit
        move.l  d1,sp_lema
        bra     .lema_da
.lema_mit:
        move.l  d0,d2
        lsr.l   #3,d2
        sub.l   d2,d0
        lsr.l   #3,d1
        add.l   d1,d0
        move.l  d0,sp_lema
.lema_da:
        move.l  (sp)+,d1
        cmp.l   #$fffff,d1              ; moving average, weight 1/8
        bls     .ema
        move.l  #$fffff,d1
.ema:   move.l  sp_ema,d0
        bne     .ema_mit
        move.l  d1,sp_ema
        bra     .verzug
.ema_mit:
        move.l  d0,d2
        lsr.l   #3,d2
        sub.l   d2,d0
        lsr.l   #3,d1
        add.l   d1,d0
        move.l  d0,sp_ema
.verzug:
        tst.b   sp_messen               ; only for the lateness line
        beq     .fertig
        tst.b   sp_ton                  ; frame done - how far after its pts?
        beq     .fertig
        bsr     position
        sub.l   Q_PTS(a2),d0
        bmi     .fertig
        add.l   d0,sp_verzug
        cmp.l   sp_per,d0
        bls     .fertig
        addq.l  #1,sp_spaet
.fertig:
        addq.l  #1,sp_angezeigt
        bsr     bild_fertig
.gezaehlt:
        addq.l  #1,sp_dekodiert
        addq.l  #1,sp_folge
        addq.l  #1,d3
        cmp.l   d7,d3                   ; more frames due: read again first and
        blo     .runde                  ; refill sound - otherwise the audio ring
        bra     .dekodieren             ; runs dry while frames are caught up
.dekodiert:
        move.l  sp_folge,d0             ; frames without a Wait in between
        clr.l   sp_folge
        cmp.l   sp_rundemax,d0
        bls     .runde_kein_max
        move.l  d0,sp_rundemax
.runde_kein_max:
        tst.b   cp_eof
        beq     .vorlauf
        tst.l   cp_queued
        beq     .ende
.vorlauf:
.wecken:
        bsr     cb_vorbauen
        tst.l   sp_tps88
        beq     .raster
        bsr     vorlauf_kopf
        moveq   #0,d0
        bsr     cpks_peek
        tst.l   d0
        beq     .raster
        move.l  d0,a2
        bsr     position
        move.l  Q_PTS(a2),d1
        sub.l   d0,d1
        sub.l   sp_vorlauf,d1
        ble     .sofort
        cmp.l   #16384,d1
        bls     .ds
        move.l  #16384,d1
.ds:    move.l  sp_tps88,d0
        cmp.l   #$ffff,d0
        bhi     .ds_lang
        mulu    d1,d0                   ; d1 <= 16384
        lsr.l   #8,d0
        bra     .ds_ok
.ds_lang:
        move.l  d1,d0
        move.l  sp_tps88,d1
        move.l  #256,d2
        bsr     muldiv32
.ds_ok: tst.b   sp_gelesen              ; already read in this round
        bne     .in
        cmp.l   cp_readletzt,d0         ; is there time until the deadline?
        blo     .in
        st      sp_gelesen
        clr.b   cp_ohnelesen
        bsr     pumpen
        st      cp_ohnelesen
        bra     .wecken
.sofort:
        moveq   #0,d0
.in:    clr.b   sp_gelesen
        bsr     wecker_in
        bra     .schleife
.raster:
        bsr     wecker_raster
        bra     .schleife

; --- End and statistics -------------------------------------------------------------
; FADING OUT: the last frame falls due while Paula is still playing the last
; full buffer - the remainder below it (508 samples with goku12b) would never
; go out. It only goes to an empty Paula, so keep serving in time until the
; ring is empty. Not after ESC.
.ende:  tst.b   sp_ton
        beq     .gesamt
        tst.b   sp_quit
        bne     .gesamt
        move.w  #200-1,d7
.klingen:
        bsr     audio_service
        tst.l   au_rcount
        beq     .gesamt
        bsr     wecker_raster
        move.l  sp_tmaske,d0
        EXEC    Wait
        bsr     zeit_consume
        dbra    d7,.klingen
.gesamt:
        bsr     zeit_now
        sub.l   sp_start,d1
        move.l  d1,sp_gesamt
        tst.l   opt_stats
        beq     .schliessen
        tst.l   opt_quiet
        bne     .schliessen
        bsr     statistik
.schliessen:
        bsr     zeit_close
        bsr     audio_close
        bsr     screen_close
        bsr     cvid_close
        bsr     planes_close
        bsr     cpks_close
        moveq   #RETURN_OK,d0
        movem.l (sp)+,d2-d7/a2-a6
        rts

; --- Helpers --------------------------------------------------------------------------

bild_da:
        rts
bild_fertig:
        rts

; Callback of the reader: a0 = audio data, d0 = bytes.
ton_sink:
        tst.b   sp_ton
        beq     .raus
        tst.b   sp_messen
        beq     audio_write             ; without measuring: feed it straight in
        movem.l d2/a2,-(sp)
        move.l  a0,a2
        move.l  d0,d2
        bsr     zeit_now
        move.l  d1,sp_st
        move.l  a2,a0
        move.l  d2,d0
        bsr     audio_write
        bsr     zeit_now
        sub.l   sp_st,d1
        add.l   d1,sp_sink
        movem.l (sp)+,d2/a2
.raus:  rts

pumpen: lea     ton_sink,a0
        tst.b   sp_messen
        beq     cpks_pump
        bsr     zeit_zuletzt            ; end of Wait, or position
        move.l  d1,sp_pt
        lea     ton_sink,a0
        bsr     cpks_pump
        bsr     zeit_now
        sub.l   sp_pt,d1
        add.l   d1,sp_pump
        cmp.l   sp_pumpmax,d1
        bls     .raus
        move.l  d1,sp_pumpmax
.raus:  rts

; Refill Paula. With STATS additionally: the longest gap between two calls in
; the loop, and how often it was longer than the whole Paula queue - then Paula
; runs dry although the ring holds data.
tondienst:
        tst.b   sp_messen
        beq     audio_service
        move.l  d2,-(sp)
        bsr     zeit_now
        move.l  d1,d2
        sub.l   sp_tdletzt,d1
        move.l  d2,sp_tdletzt
        tst.b   sp_td_da
        beq     .erst
        cmp.l   sp_tdmax,d1
        bls     .kein_max
        move.l  d1,sp_tdmax
.kein_max:
        cmp.l   sp_tdgrenze,d1
        bls     .dienst
        addq.l  #1,sp_tdlang
        bra     .dienst
.erst:  st      sp_td_da
.dienst:
        move.l  (sp)+,d2
        bra     audio_service

; sp_vorlauf for the oldest waiting frame: half the PREDICTED decoder time,
; prediction = ema * (len + lema) / (2 * lema), at most one frame interval.
; The decoder time follows the packet length closely; a keyframe thus starts
; earlier than a small intermediate frame. Computed only when another frame is
; at the front or the average has changed.
vorlauf_kopf:
        movem.l d2/a2,-(sp)
        tst.l   opt_novideo
        bne     .raus
        tst.l   sp_tps88
        beq     .raus
        move.l  sp_lema,d2
        beq     .raus                   ; no frame yet: keep the old value
        moveq   #0,d0
        bsr     cpks_peek
        tst.l   d0
        beq     .raus
        move.l  d0,a2
        move.l  Q_PTS(a2),d0
        cmp.l   sp_vk_pts,d0
        bne     .rechnen
        move.l  sp_ema,d0
        cmp.l   sp_vk_ema,d0
        beq     .raus                   ; already computed
.rechnen:
        move.l  Q_PTS(a2),sp_vk_pts
        move.l  sp_ema,sp_vk_ema
        move.l  Q_LEN(a2),d0
        add.l   d2,d0
        move.l  sp_ema,d1
        add.l   d2,d2
        bsr     muldiv32                ; predicted ticks
        lsr.l   #1,d0
        move.l  sp_tps88,d2
        cmp.l   #$ffff,d2
        bhi     .lang
        cmp.l   #$ffffff,d0
        bhi     .deckel
        lsl.l   #8,d0                   ; ticks x 256 / tps88 -> time base ticks
        divu    d2,d0
        bvs     .deckel
        swap    d0
        clr.w   d0
        swap    d0
        bra     .vgl
.lang:  move.l  #256,d1
        bsr     muldiv32
.vgl:   cmp.l   sp_per,d0
        bls     .vl
.deckel:
        move.l  sp_per,d0
.vl:    move.l  d0,sp_vorlauf
.raus:  movem.l (sp)+,d2/a2
        rts

; Build the codebooks of the next frame now, in the free time before its
; deadline (cvid.s, PREBUILDING CODEBOOKS). Once per frame; the time counts
; towards the decoder time in STATS, not towards the moving average.
cb_vorbauen:
        movem.l d2/a2,-(sp)
        tst.l   opt_novideo
        bne     .raus
        tst.b   sp_kein_vorbau          ; test bench: the path without prebuilding
        bne     .raus
        moveq   #0,d0
        bsr     cpks_peek
        tst.l   d0
        beq     .raus
        move.l  d0,a2
        move.l  Q_PTS(a2),d1
        tst.b   sp_vb_da
        beq     .bauen
        cmp.l   sp_vb_pts,d1
        beq     .raus                   ; already tried for this frame
.bauen: move.l  d1,sp_vb_pts
        st      sp_vb_da
        tst.b   sp_messen
        beq     .los
        bsr     zeit_zuletzt
        move.l  d1,sp_vbt
.los:   move.l  Q_PTR(a2),a0
        move.l  Q_LEN(a2),d0
        move.l  Q_PTS(a2),d1
        bsr     cvid_vorbauen
        tst.b   sp_messen
        beq     .raus
        bsr     zeit_now
        sub.l   sp_vbt,d1
        add.l   d1,sp_dec
.raus:  movem.l (sp)+,d2/a2
        rts

; -> d0 = position in time base ticks (5.1)
position:
        tst.b   sp_ton
        beq     .uhr
        bsr     audio_played
        add.l   cp_aptsbase,d0
        rts
.uhr:   move.l  d2,-(sp)
        bsr     zeit_now
        sub.l   sp_start,d1
        move.l  d1,d0
        bsr     zeit_ms
        move.l  cp_timebase,d1
        move.l  #1000,d2
        bsr     muldiv32
        move.l  (sp)+,d2
        rts

; Next deadline = max(deadline, now) + tick.
wecker_raster:
        bsr     zeit_now
        cmp.l   sp_next_hi,d0
        bhi     .jetzt
        blo     .plus
        cmp.l   sp_next_lo,d1
        bls     .plus
.jetzt: move.l  d0,sp_next_hi
        move.l  d1,sp_next_lo
.plus:  move.l  sp_next_hi,d0           ; load FIRST, then add: move clears
        move.l  sp_next_lo,d1           ; the carry
        add.l   sp_takt,d1
        bcc     .arm
        addq.l  #1,d0
.arm:   move.l  d0,sp_next_hi
        move.l  d1,sp_next_lo
        bsr     zeit_arm
        rts

; d0 = ticks from now, at most one tick.
wecker_in:
        cmp.l   sp_takt,d0
        bls     .t
        move.l  sp_takt,d0
.t:     move.l  d0,-(sp)
        bsr     zeit_zuletzt            ; position has just read the clock
        add.l   (sp)+,d1
        bcc     .arm
        addq.l  #1,d0
.arm:   move.l  d0,sp_next_hi
        move.l  d1,sp_next_lo
        bsr     zeit_arm
        rts

strom_zeigen:
        lea     t_zwei,a0
        bsr     out_str
        move.l  cp_width,d0
        bsr     out_unum
        moveq   #'x',d0
        bsr     out_chr
        move.l  cp_height,d0
        bsr     out_unum
        lea     t_cinepak,a0
        bsr     out_str
        move.l  cp_fpsnum,d0
        move.l  cp_fpsden,d1
        beq     .fps
        bsr     udiv32
.fps:   bsr     out_unum
        lea     t_fpstb,a0
        bsr     out_str
        move.l  cp_timebase,d0
        bsr     out_unum
        bsr     out_nl
        rts

; Print ticks (d0) as milliseconds, then text a0.
ms_aus: move.l  a0,-(sp)
        bsr     zeit_ms
        bsr     out_unum
        move.l  (sp)+,a0
        bsr     out_str
        rts

statistik:
        movem.l d2-d7/a2-a6,-(sp)
        tst.b   sp_ton
        beq     .zeit
        lea     s_ton1,a0
        bsr     out_str
        move.l  au_mask,d0
        moveq   #2,d1
        bsr     out_hex
        lea     s_ton2,a0
        bsr     out_str
        move.l  au_bytes,d0
        bsr     out_unum
        lea     s_ton3,a0
        bsr     out_str
        move.l  au_sent,d0
        bsr     out_unum
        lea     s_ton4,a0
        bsr     out_str
        move.l  au_lost,d0
        bsr     out_unum
        lea     s_ton5,a0
        bsr     out_str
        move.l  au_under,d0
        bsr     out_unum
        lea     s_ton6,a0
        bsr     out_str
        move.l  au_err,d0
        bsr     out_num
        bsr     out_nl
        lea     s_puf1,a0
        bsr     out_str
        move.l  au_nbuf,d0
        bsr     out_unum
        lea     s_puf2,a0
        bsr     out_str
        move.l  au_bufsz,d0
        bsr     out_unum
        lea     s_puf3,a0
        bsr     out_str
        move.l  au_minpend,d0
        cmp.l   #$ffffffff,d0
        bne     .mp
        moveq   #0,d0
.mp:    bsr     out_unum
        lea     s_puf4,a0
        bsr     out_str
        move.l  au_maxring,d0
        bsr     out_unum
        lea     s_puf5,a0
        bsr     out_str
        move.l  au_checkio,d0
        bsr     out_unum
        bsr     out_nl
.zeit:  lea     s_zeit1,a0
        bsr     out_str
        move.l  sp_pump,d0
        sub.l   sp_sink,d0
        lea     s_zeit2,a0
        bsr     ms_aus
        move.l  sp_sink,d0
        lea     s_zeit3,a0
        bsr     ms_aus
        move.l  sp_dec,d0
        lea     s_zeit4,a0
        bsr     ms_aus
        move.l  sp_gesamt,d0
        lea     s_zeit5,a0
        bsr     ms_aus
        move.l  sp_leerlauf,d0
        lea     s_zeit6,a0
        bsr     ms_aus
        lea     s_strom1,a0
        bsr     out_str
        move.l  sp_dekodiert,d0
        bsr     out_unum
        lea     s_strom2,a0
        bsr     out_str
        move.l  sp_keys,d0
        bsr     out_unum
        lea     s_strom3,a0
        bsr     out_str
        move.l  cp_asamples,d0
        bsr     out_unum
        lea     s_strom4,a0
        bsr     out_str
        move.l  cp_resyncs,d0
        bsr     out_unum
        lea     s_strom5,a0
        bsr     out_str
        move.l  cp_toobig,d0
        bsr     out_unum
        lea     s_strom6,a0
        bsr     out_str
        move.l  cp_reads,d0
        bsr     out_unum
        lea     s_strom7,a0
        bsr     out_str
        lea     s_lesen1,a0             ; reading: does the network block the loop?
        bsr     out_str
        move.l  cp_reads,d0
        bsr     out_unum
        lea     s_lesen2,a0
        bsr     out_str
        move.l  cp_chunk,d0
        moveq   #10,d1
        lsr.l   d1,d0
        bsr     out_unum
        lea     s_lesen3,a0
        bsr     out_str
        move.l  cp_readticks,d0
        lea     s_lesen4,a0
        bsr     ms_aus
        move.l  cp_readmax,d0
        lea     s_lesen5,a0
        bsr     ms_aus
        move.l  cp_readlang,d0
        bsr     out_unum
        bsr     out_nl
        tst.l   opt_novideo
        bne     .speicher
        tst.l   sp_angezeigt
        beq     .speicher
        lea     s_planar1,a0
        bsr     out_str
        move.l  sp_dec,d0
        bsr     zeit_ms
        move.l  sp_angezeigt,d1
        bsr     udiv32
        bsr     out_unum
        lea     s_planar2,a0
        bsr     out_str
        move.l  sp_upf,d0
        move.l  #1000,d1
        bsr     udiv32
        bsr     out_unum
        lea     s_planar3,a0
        bsr     out_str
        move.l  sp_decfehler,d0
        bsr     out_unum
        bsr     out_nl
        lea     s_spitz1,a0             ; peaks: what makes a round long
        bsr     out_str
        move.l  sp_decmax,d0
        lea     s_spitz2,a0
        bsr     ms_aus
        move.l  sp_pumpmax,d0
        lea     s_spitz3,a0
        bsr     ms_aus
        move.l  sp_rundemax,d0
        bsr     out_unum
        bsr     out_nl
        tst.b   sp_ton
        beq     .speicher
        lea     s_verzug1,a0            ; lateness: frame done after its pts
        bsr     out_str
        move.l  sp_verzug,d0
        move.l  #1000,d1
        move.l  cp_timebase,d2
        bsr     muldiv32
        move.l  sp_angezeigt,d1
        bsr     udiv32
        bsr     out_unum
        lea     s_verzug2,a0
        bsr     out_str
        move.l  sp_spaet,d0
        bsr     out_unum
        lea     s_verzug3,a0
        bsr     out_str
        move.l  sp_angezeigt,d0
        bsr     out_unum
        bsr     out_nl
        lea     s_td1,a0                ; audio service: gaps where Paula runs dry
        bsr     out_str
        move.l  sp_tdmax,d0
        lea     s_td2,a0
        bsr     ms_aus
        move.l  sp_tdgrenze,d0
        lea     s_td3,a0
        bsr     ms_aus
        move.l  sp_tdlang,d0
        bsr     out_unum
        bsr     out_nl
        lea     s_sprung1,a0            ; frame skip: the picture gives way, not the sound
        bsr     out_str
        move.l  cp_spruenge,d0
        bsr     out_unum
        lea     s_sprung2,a0
        bsr     out_str
        move.l  cp_leserverw,d0
        bsr     out_unum
        lea     s_sprung3,a0
        bsr     out_str
.speicher:
        bsr     hunks_zeigen
        lea     s_ang1,a0
        bsr     out_str
        move.l  sp_angezeigt,d0
        bsr     out_unum
        lea     s_ang2,a0
        bsr     out_str
        move.l  sp_dekodiert,d0
        bsr     out_unum
        lea     s_ang3,a0
        bsr     out_str
        move.l  sp_dekodiert,d0
        tst.l   opt_novideo
        bne     .nicht
        sub.l   sp_angezeigt,d0
.nicht: bsr     out_unum
        lea     s_ang4,a0
        bsr     out_str
        move.l  sp_verworfen,d0
        bsr     out_unum
        lea     s_ang5,a0
        bsr     out_str
        move.l  cp_resyncs,d0
        bsr     out_unum
        lea     s_ang6,a0
        bsr     out_str
        move.l  cp_bytes,d0
        moveq   #10,d1
        lsr.l   d1,d0
        bsr     out_unum
        lea     s_ang7,a0
        bsr     out_str
        lea     s_ok,a0
        bsr     out_str
        movem.l (sp)+,d2-d7/a2-a6
        rts

; The segments of the running command: where do they lie, chip or fast? LoadSeg
; allocates every hunk separately; if the fast RAM is fragmented, a hunk lands
; in chip RAM unnoticed - and there every instruction fetch costs a bus cycle.
hunks_zeigen:
        movem.l d2-d3/a2/a6,-(sp)
        lea     s_hunks,a0
        bsr     out_str
        sub.l   a1,a1
        EXEC    FindTask
        move.l  d0,a0
        move.l  pr_CLI(a0),d0
        beq     .zeile
        lsl.l   #2,d0
        move.l  d0,a0
        move.l  cli_Module(a0),d2
        moveq   #12-1,d3
.seg:   tst.l   d2
        beq     .zeile
        lsl.l   #2,d2
        move.l  d2,a2
        move.l  a2,a1
        EXEC    TypeOfMem
        moveq   #' ',d1
        exg     d0,d1
        bsr     out_chr
        moveq   #'F',d0
        btst    #MEMB_CHIP,d1
        beq     .art
        moveq   #'C',d0
.art:   bsr     out_chr
        moveq   #':',d0
        bsr     out_chr
        move.l  -4(a2),d0
        moveq   #10,d1
        lsr.l   d1,d0
        bsr     out_unum
        moveq   #'K',d0
        bsr     out_chr
        move.l  (a2),d2
        dbra    d3,.seg
.zeile: bsr     out_nl
        movem.l (sp)+,d2-d3/a2/a6
        rts

        section data,data
t_e_open:       dc.b    "Cannot open or read the file",0
t_e_format:     dc.b    "Not a CPKS stream (no header packet?)",0
t_e_mem:        dc.b    "Not enough memory for the read buffer",0
t_e_codec:      dc.b    "Only Cinepak is supported",0
t_e_timer:      dc.b    "timer.device not available",0
t_m_clut:       dc.b    "5 planes",0
t_m_gray:       dc.b    "GRAY",0
t_m_ham6:       dc.b    "HAM6",0
t_m_ton:        dc.b    "Sound",0
t_h_novideo:    dc.b    "NOVIDEO",0
t_h_noaudio:    dc.b    "NOAUDIO",0
t_r_chip:       dc.b    "no contiguous chip RAM block for the bitplanes",0
t_r_geometrie:  dc.b    "Picture size does not fit (320 wide, at most 256 high)",0
t_r_tabellen:   dc.b    "Not enough memory for the colour tables (up to 119 KB)",0
t_r_tonformat:  dc.b    "Sound format is not supported",0
t_r_audio:      dc.b    "audio.device could not be opened (in use?)",0
t_r_lib:        dc.b    "graphics.library or intuition.library V36 or later is missing",0
t_r_modus:      dc.b    "the display mode does not exist on this machine",0
t_r_tiefe:      dc.b    "the display mode does not carry that many bitplanes",0
t_r_schirmauf:  dc.b    "the screen could not be opened (chip RAM?)",0
t_r_bitmap:     dc.b    "the screen does not take over our own BitMap (SA_BitMap)",0
t_r_fenster:    dc.b    "the window on the screen could not be opened",0
t_zwei:         dc.b    "  ",0
t_cinepak:      dc.b    "  Cinepak  ",0
t_fpstb:        dc.b    " fps  CPKS, timebase ",0
t_ausgabe:      dc.b    "  Output: ",0
t_modusid:      dc.b    ", single buffered, PLANAR, mode 0x",0
t_planesadr:    dc.b    ", planes 0x",0
t_gfx:          dc.b    ", graphics V",0
t_anzeige:      dc.b    "  Display: VP 0x",0
t_vpmodes:      dc.b    ", Modes 0x",0
t_ham:          dc.b    " HAM",0
t_ehb:          dc.b    " EHB",0
t_ohneham:      dc.b    " without HAM",0
t_bplcon0:      dc.b    ", BPLCON0 0x",0
t_unbekannt:    dc.b    "unknown",0
t_steuer:       dc.b    ", control planes after opening 0x",0
t_steuer2:      dc.b    " (now 0xdd77)",0
t_ton:          dc.b    "  Sound: ",0
t_hz:           dc.b    " Hz, ",0
t_kanaele:      dc.b    " channels, ",0
t_periode:      dc.b    " bit  ->  period ",0
t_tatsaechlich: dc.b    ", actually ",0
t_hzzeile:      dc.b    " Hz",10,0
t_vorgeladen:   dc.b    "  prebuffered: ",0
t_frames:       dc.b    " frames, ",0
t_tonsamples:   dc.b    " audio samples",10,0
s_ton1:         dc.b    "  Sound: channel mask 0x",0
s_ton2:         dc.b    ", ",0
s_ton3:         dc.b    " samples, ",0
s_ton4:         dc.b    " buffers, ",0
s_ton5:         dc.b    " dropped, ",0
s_ton6:         dc.b    "x ran dry, io_Error=",0
s_puf1:         dc.b    "  Audio buffers: ",0
s_puf2:         dc.b    " x ",0
s_puf3:         dc.b    " samples, min. filled ",0
s_puf4:         dc.b    ", max. backlog ",0
s_puf5:         dc.b    " samples, CheckIO ",0
s_zeit1:        dc.b    "  Time: disk ",0
s_zeit2:        dc.b    " ms, sound ",0
s_zeit3:        dc.b    " ms, display 0 ms, decoder ",0
s_zeit4:        dc.b    " ms, total ",0
s_zeit5:        dc.b    " ms, idle ",0
s_zeit6:        dc.b    " ms",10,0
s_strom1:       dc.b    "  Stream: ",0
s_strom2:       dc.b    " frames, ",0
s_strom3:       dc.b    " keyframes, ",0
s_strom4:       dc.b    " audio samples, ",0
s_strom5:       dc.b    " resyncs, ",0
s_strom6:       dc.b    " too large, ",0
s_strom7:       dc.b    " Read()",10,0
s_lesen1:       dc.b    "  Read: ",0
s_lesen2:       dc.b    " Read() of up to ",0
s_lesen3:       dc.b    " KB, total ",0
s_lesen4:       dc.b    " ms, longest ",0
s_lesen5:       dc.b    " ms, above one frame spacing: ",0
s_planar1:      dc.b    "  PLANAR: decoder per frame ",0
s_planar2:      dc.b    " ms, budget per frame ",0
s_planar3:      dc.b    " ms, decoder errors: ",0
s_verzug1:      dc.b    "  Lateness (frame ready after its pts): mean ",0
s_verzug2:      dc.b    " ms, later than one frame spacing: ",0
s_verzug3:      dc.b    " of ",0
s_spitz1:       dc.b    "  Peaks: longest frame ",0
s_spitz2:       dc.b    " ms, longest pump ",0
s_spitz3:       dc.b    " ms, most frames per round ",0
s_td1:          dc.b    "  Sound service: longest gap ",0
s_td2:          dc.b    " ms, longer than the Paula queue (",0
s_td3:          dc.b    " ms): ",0
s_sprung1:      dc.b    "  Frame jump: ",0
s_sprung2:      dc.b    "x to the keyframe, dropped in the reader ",0
s_sprung3:      dc.b    " frames",10,0
s_hunks:        dc.b    "  Memory: hunks",0
s_ang1:         dc.b    "  shown ",0
s_ang2:         dc.b    ", decoded ",0
s_ang3:         dc.b    ", not shown ",0
s_ang4:         dc.b    ", dropped without decoding ",0
s_ang5:         dc.b    ", resyncs ",0
s_ang6:         dc.b    ", read ",0
s_ang7:         dc.b    " KB",10,0
s_ok:           dc.b    "[OK] playback finished",10,0
                cnop    0,4
; Reasons for screen_open (SC_E_1..6)
t_r_schirm:     dc.l    t_r_lib,t_r_modus,t_r_tiefe,t_r_schirmauf,t_r_bitmap,t_r_fenster

        section bss,bss
sp_state:
sp_upf:         ds.l    1
sp_takt_us:     ds.l    1
sp_takt:        ds.l    1
sp_per:         ds.l    1
sp_tps88:       ds.l    1
sp_vorlauf:     ds.l    1
sp_ema:         ds.l    1
sp_lema:        ds.l    1
sp_vk_pts:      ds.l    1
sp_tonknapp:    ds.l    1
sp_tdgrenze:    ds.l    1
sp_tdletzt:     ds.l    1
sp_tdmax:       ds.l    1
sp_tdlang:      ds.l    1
sp_decmax:      ds.l    1
sp_pumpmax:     ds.l    1
sp_rundemax:    ds.l    1
sp_folge:       ds.l    1
sp_vk_ema:      ds.l    1
sp_vb_pts:      ds.l    1
sp_vbt:         ds.l    1
sp_modus:       ds.l    1
sp_modusname:   ds.l    1
sp_tmaske:      ds.l    1
sp_fmaske:      ds.l    1
sp_next_hi:     ds.l    1
sp_next_lo:     ds.l    1
sp_start:       ds.l    1
sp_t:           ds.l    1
sp_st:          ds.l    1
sp_pt:          ds.l    1
sp_pump:        ds.l    1
sp_sink:        ds.l    1
sp_dec:         ds.l    1
sp_leerlauf:    ds.l    1
sp_gesamt:      ds.l    1
sp_angezeigt:   ds.l    1
sp_dekodiert:   ds.l    1
sp_verworfen:   ds.l    1
sp_keys:        ds.l    1
sp_decfehler:   ds.l    1
sp_verzug:      ds.l    1
sp_spaet:       ds.l    1
sp_ton:         ds.b    1
sp_pause:       ds.b    1
sp_quit:        ds.b    1
sp_gefeuert:    ds.b    1
sp_gelesen:     ds.b    1
sp_messen:      ds.b    1
sp_vb_da:       ds.b    1
sp_td_da:       ds.b    1
sp_state_end:
sp_kein_vorbau: ds.b    1               ; test bench sets it (not in the state)
