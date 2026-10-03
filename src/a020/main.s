; main.s - start, options, error exit and cleanup of the 020/030 player.
;
; Invocation (dos ReadArgs):
;   CyberPak.020 DATEI/A,HAM6/S,DHAM6/S,DHAM8/S,GRAY=GREY/S,HICOLOR=16BIT/S,
;                  STATS/S,QUIET/S,NOAUDIO/S,NOVIDEO/S,NOSER/S,ABUF/K/N,ANUM/K/N,READ/K/N,
;                  BENCH/K/N
; NOSER is accepted and ignored (same invocation as the C builds).
; BENCH=n is a measuring run: decode the first n frames (0 = all) without
; clock and sound, then report the decoder time per frame (spielen.s).
;
; Return codes: 0 good, 5 invalid invocation (ReadArgs, more than one mode),
; 10 the requested mode is not available here (message with fixed openings,
; see modus_fehlt), 20 any other error.
;
; Error exit: `fehler` and `modus_fehlt` jump to the end from any call depth -
; the stack pointer from program start is saved. `aufraeumen` calls the
; release routine of every module; each one may be called any number of times
; and frees only what is allocated.

        include "player.i"

        xdef    _SysBase,_DOSBase
        xdef    opt_file,opt_ham6,opt_gray,opt_stats,opt_quiet
        xdef    opt_noaudio,opt_novideo,opt_abuf,opt_anum,opt_read
        xdef    opt_dham6,opt_dham8,opt_hicolor,opt_noser,opt_bench
        xdef    fehler,modus_fehlt
        xref    out_str,out_nl,out_unum
        xref    spielen,cpks_close,cvid_close,planes_close,screen_close
        xref    zeit_close,audio_close,rtg_close

        section code,code

start:
        move.l  sp,savesp
        move.l  4.w,a6
        move.l  a6,_SysBase
        sub.l   a1,a1
        jsr     _LVOFindTask(a6)
        move.l  d0,a4
        tst.l   pr_CLI(a4)
        bne     .cli
        ; Workbench start: fetch the startup message, reply to it at the end.
        lea     pr_MsgPort(a4),a0
        jsr     _LVOWaitPort(a6)
        lea     pr_MsgPort(a4),a0
        jsr     _LVOGetMsg(a6)
        move.l  d0,wbmsg
        moveq   #RETURN_FAIL,d0
        bra     ende

.cli:   lea     dosname,a1
        moveq   #36,d0
        jsr     _LVOOpenLibrary(a6)
        move.l  d0,_DOSBase
        bne     .dos_ok
        moveq   #RETURN_FAIL,d0
        bra     ende
.dos_ok:
        move.l  d0,a6
        move.l  #template,d1
        move.l  #argarray,d2
        moveq   #0,d3
        jsr     _LVOReadArgs(a6)
        move.l  d0,rdargs
        bne     .args_ok
        jsr     _LVOIoErr(a6)
        move.l  d0,d1
        move.l  #progname,d2
        jsr     _LVOPrintFault(a6)
        moveq   #RETURN_WARN,d0
        bra     ende

.args_ok:
        bsr     optionen
        bsr     optionen_zeigen
        bsr     spielen
        bra     ende

; --- Options --------------------------------------------------------------------------

optionen:
        lea     argarray,a0
        move.l  (a0)+,opt_file
        move.l  (a0)+,opt_ham6
        move.l  (a0)+,opt_dham6
        move.l  (a0)+,opt_dham8
        move.l  (a0)+,opt_gray
        move.l  (a0)+,opt_hicolor
        move.l  (a0)+,opt_stats
        move.l  (a0)+,opt_quiet
        move.l  (a0)+,opt_noaudio
        move.l  (a0)+,opt_novideo
        move.l  (a0)+,opt_noser
        move.l  (a0)+,d0                ; ABUF: pointer to LONG or 0
        beq     .anum
        move.l  d0,a1
        move.l  (a1),d0
        ble     .falsch_abuf
        move.l  d0,opt_abuf
.anum:  move.l  (a0)+,d0
        beq     .lese
        move.l  d0,a1
        move.l  (a1),d0
        ble     .falsch_anum
        move.l  d0,opt_anum
.lese:  move.l  (a0)+,d0                ; READ: KB per Read, power of two 1..64
        beq     .bench
        move.l  d0,a1
        move.l  (a1),d0
        ble     .falsch_read
        cmp.l   #64,d0
        bhi     .falsch_read
        move.l  d0,d1
        subq.l  #1,d1
        and.l   d0,d1
        bne     .falsch_read
        move.l  d0,opt_read
.bench: move.l  (a0)+,d0                ; BENCH: frames, 0 = all
        beq     .kombi
        move.l  d0,a1
        move.l  (a1),d0
        bgt     .b_n
        move.l  #$7fffffff,d0
.b_n:   move.l  d0,opt_bench
.kombi: moveq   #0,d0                   ; at most one mode
        tst.l   opt_ham6
        beq     .k1
        addq.l  #1,d0
.k1:    tst.l   opt_dham6
        beq     .k2
        addq.l  #1,d0
.k2:    tst.l   opt_dham8
        beq     .k3
        addq.l  #1,d0
.k3:    tst.l   opt_gray
        beq     .k4
        addq.l  #1,d0
.k4:    tst.l   opt_hicolor
        beq     .k5
        addq.l  #1,d0
.k5:    cmp.l   #1,d0
        bls     .ok
        lea     t_einmodus,a0
        bra     aufruf_fehler
.ok:    rts
.falsch_abuf:
        lea     t_abuf,a0
        bra     fehler
.falsch_anum:
        lea     t_anum,a0
        bra     fehler
.falsch_read:
        lea     t_read,a0
        bra     fehler

; Only with STATS: what was understood.
optionen_zeigen:
        tst.l   opt_stats
        beq     .raus
        tst.l   opt_quiet
        bne     .raus
        lea     t_kopf,a0
        bsr     out_str
        move.l  opt_file,a0
        bsr     out_str
        lea     t_modusauto,a0
        tst.l   opt_ham6
        beq     .m1
        lea     t_modush6,a0
.m1:    tst.l   opt_dham6
        beq     .m2
        lea     t_modusd6,a0
.m2:    tst.l   opt_dham8
        beq     .m3
        lea     t_modusd8,a0
.m3:    tst.l   opt_gray
        beq     .m4
        lea     t_modusgr,a0
.m4:    tst.l   opt_hicolor
        beq     .modus
        lea     t_modushc,a0
.modus: bsr     out_str
        lea     t_abufk,a0
        bsr     out_str
        move.l  opt_abuf,d0
        bsr     out_unum
        lea     t_anumk,a0
        bsr     out_str
        move.l  opt_anum,d0
        bsr     out_unum
        lea     t_readk,a0
        bsr     out_str
        move.l  opt_read,d0
        bsr     out_unum
        lea     t_noaudio,a0
        tst.l   opt_noaudio
        beq     .nov
        bsr     out_str
.nov:   lea     t_novideo,a0
        tst.l   opt_novideo
        beq     .zeile
        bsr     out_str
.zeile: bsr     out_nl
.raus:  rts

; --- Errors and end -----------------------------------------------------------------

; a0 = text (without line end). Return code 20. Does not return.
fehler:
        tst.l   _DOSBase
        beq     .ohne_text
        move.l  a0,-(sp)
        lea     t_fehler,a0
        bsr     out_str
        move.l  (sp)+,a0
        bsr     out_str
        bsr     out_nl
.ohne_text:
        moveq   #RETURN_FAIL,d0
        bra     ende

; Invalid invocation: a0 = text (without line end). Return code 5.
aufruf_fehler:
        move.l  a0,-(sp)
        lea     t_fehler,a0
        bsr     out_str
        move.l  (sp)+,a0
        bsr     out_str
        bsr     out_nl
        moveq   #RETURN_WARN,d0
        bra     ende

; Requested mode not available here - two lines with fixed openings (the
; server passes them on), return code 10. No silent substitute.
;   a0 = mode, a1 = reason, a2 = suggestion or 0
modus_fehlt:
        move.l  a0,-(sp)
        lea     t_mf1,a0
        bsr     out_str
        move.l  (sp)+,a0
        bsr     out_str
        lea     t_mf2,a0
        bsr     out_str
        move.l  a1,a0
        bsr     out_str
        lea     t_mf3,a0
        bsr     out_str
        move.l  a2,d0
        beq     .zeile
        lea     t_mf4,a0
        bsr     out_str
        move.l  a2,a0
        bsr     out_str
.zeile: bsr     out_nl
        moveq   #RETURN_ERROR,d0
        bra     ende

; d0 = return code
ende:
        move.l  savesp,sp
        move.l  d0,rueckgabe
        bsr     aufraeumen
        move.l  rueckgabe,d0
        rts

aufraeumen:
        bsr     rtg_close
        bsr     zeit_close
        bsr     audio_close
        bsr     screen_close
        bsr     cvid_close
        bsr     planes_close
        bsr     cpks_close
        move.l  rdargs,d1
        beq     .dos
        DOS     FreeArgs
        clr.l   rdargs
.dos:   move.l  _DOSBase,d0
        beq     .wb
        move.l  d0,a1
        EXEC    CloseLibrary
        clr.l   _DOSBase
.wb:    move.l  wbmsg,d0
        beq     .raus
        EXEC    Forbid
        move.l  wbmsg,a1
        jsr     _LVOReplyMsg(a6)
.raus:  rts

        section data,data

opt_abuf:   dc.l    32
opt_anum:   dc.l    16
opt_read:   dc.l    16
dosname:    dc.b    "dos.library",0
progname:   dc.b    "CyberPak",0
template:   dc.b    "DATEI/A,HAM6/S,DHAM6/S,DHAM8/S,GRAY=GREY/S,HICOLOR=16BIT/S,STATS/S,QUIET/S,NOAUDIO/S,NOVIDEO/S,NOSER/S,ABUF/K/N,ANUM/K/N,READ/K/N,BENCH/K/N",0
t_fehler:   dc.b    "[FAIL] ",0
t_einmodus: dc.b    "Nur ein Modus: HAM6, DHAM6, DHAM8, GRAY oder HICOLOR",0
t_abuf:     dc.b    "ABUF muss groesser als 0 sein",0
t_anum:     dc.b    "ANUM muss groesser als 0 sein",0
t_read:     dc.b    "READ muss 1, 2, 4, 8, 16, 32 oder 64 (KB) sein",0
t_readk:    dc.b    ", READ ",0
t_kopf:     dc.b    "CyberPak 020/030: ",0
t_modusauto: dc.b   ", Modus automatisch",0
t_modusgr:  dc.b    ", GRAY",0
t_modush6:  dc.b    ", HAM6",0
t_modusd6:  dc.b    ", DHAM6",0
t_modusd8:  dc.b    ", DHAM8",0
t_modushc:  dc.b    ", HICOLOR",0
t_abufk:    dc.b    ", ABUF ",0
t_anumk:    dc.b    ", ANUM ",0
t_noaudio:  dc.b    ", NOAUDIO",0
t_novideo:  dc.b    ", NOVIDEO",0
t_mf1:      dc.b    "Modus ",34,0
t_mf2:      dc.b    34," nicht verfuegbar: ",0
t_mf3:      dc.b    10,"Bitte einen anderen Modus probieren",0
t_mf4:      dc.b    ", z. B.: ",0

        section bss,bss

_SysBase:   ds.l    1
_DOSBase:   ds.l    1
savesp:     ds.l    1
rueckgabe:  ds.l    1
wbmsg:      ds.l    1
rdargs:     ds.l    1
argarray:   ds.l    15
opt_file:   ds.l    1
opt_ham6:   ds.l    1
opt_gray:   ds.l    1
opt_stats:  ds.l    1
opt_quiet:  ds.l    1
opt_noaudio: ds.l   1
opt_novideo: ds.l   1
opt_dham6:  ds.l    1
opt_dham8:  ds.l    1
opt_hicolor: ds.l   1
opt_noser:  ds.l    1
opt_bench:  ds.l    1
