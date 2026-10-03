; zeit.s - timer.device: read the EClock and wake up at an absolute time.
;
; Model: src/sync.c and src/timing.c. ONE request on UNIT_WAITECLOCK serves
; both: its device base is the library base for ReadEClock(), and it wakes up
; at an absolute EClock time. TimerBase MUST be in place before the first
; ReadEClock() - a call with base 0 jumps into nowhere and the machine freezes
; (sync.c).
;
;   zeit_open     -> d0 = 0 good, 1 timer.device cannot be opened
;   zeit_close    any number of times; preserves all registers
;   zeit_now      -> d0 = EClock high, d1 = low
;   zeit_zuletzt  -> d0/d1 as zeit_now, but the value read last, without
;                 ReadEClock (for places right after a zeit_now)
;   zeit_arm      d0 = high, d1 = low: wake up at that point in time
;   zeit_consume  collect the expired request (if one is running)
;   zeit_sigmask  -> d0 = signal mask of the timer (0 = not open)
;   zeit_ms       d0 = ticks -> d0 = milliseconds
;   zt_freq       EClock ticks per second (after zeit_open)

        include "player.i"
        include "devices/timer.i"
        include "lvo/timer_lib.i"

        xdef    zeit_open,zeit_close,zeit_now,zeit_zuletzt,zeit_arm,zeit_consume,zeit_sigmask,zeit_ms
        xdef    zt_freq,_TimerBase
        xref    _SysBase,muldiv32

        section code,code

zeit_open:
        movem.l d2-d7/a2-a6,-(sp)
        EXEC    CreateMsgPort
        move.l  d0,zt_port
        beq     .fehl
        move.l  d0,a0
        moveq   #IOTV_SIZE,d0
        EXEC    CreateIORequest
        move.l  d0,zt_req
        beq     .fehl
        lea     timername,a0
        move.l  #UNIT_WAITECLOCK,d0
        move.l  zt_req,a1
        moveq   #0,d1
        EXEC    OpenDevice
        tst.b   d0
        bne     .fehl
        st      zt_offen
        move.l  zt_req,a0
        move.l  IO_DEVICE(a0),_TimerBase
        move.w  #TR_ADDREQUEST,IO_COMMAND(a0)
        lea     zt_ev,a0
        move.l  _TimerBase,a6
        jsr     _LVOReadEClock(a6)
        tst.l   d0
        bne     .frequenz
        move.l  #709379,d0              ; PAL fallback
.frequenz:
        move.l  d0,zt_freq
        moveq   #0,d0
        bra     .raus
.fehl:  bsr     zeit_close
        moveq   #1,d0
.raus:  movem.l (sp)+,d2-d7/a2-a6
        rts

zeit_close:
        movem.l d0-d1/a0-a1/a6,-(sp)
        tst.b   zt_laeuft
        beq     .device
        move.l  zt_req,a1
        EXEC    AbortIO
        move.l  zt_req,a1
        jsr     _LVOWaitIO(a6)
        clr.b   zt_laeuft
.device:
        tst.b   zt_offen
        beq     .req
        move.l  zt_req,a1
        EXEC    CloseDevice
        clr.b   zt_offen
        clr.l   _TimerBase
.req:   move.l  zt_req,d0
        beq     .port
        move.l  d0,a0
        EXEC    DeleteIORequest
        clr.l   zt_req
.port:  move.l  zt_port,d0
        beq     .raus
        move.l  d0,a0
        EXEC    DeleteMsgPort
        clr.l   zt_port
.raus:  movem.l (sp)+,d0-d1/a0-a1/a6
        rts

zeit_now:
        move.l  a6,-(sp)
        lea     zt_ev,a0
        move.l  _TimerBase,a6
        jsr     _LVOReadEClock(a6)
        move.l  zt_ev+EV_HI,d0
        move.l  zt_ev+EV_LO,d1
        move.l  (sp)+,a6
        rts

zeit_zuletzt:
        move.l  zt_ev+EV_HI,d0
        move.l  zt_ev+EV_LO,d1
        rts

zeit_arm:
        move.l  a6,-(sp)
        move.l  zt_req,a1
        move.l  d0,IOTV_TIME+TV_SECS(a1)
        move.l  d1,IOTV_TIME+TV_MICRO(a1)
        move.w  #TR_ADDREQUEST,IO_COMMAND(a1)
        EXEC    SendIO
        st      zt_laeuft
        move.l  (sp)+,a6
        rts

zeit_consume:
        move.l  a6,-(sp)
        tst.b   zt_laeuft
        beq     .raus
        move.l  zt_req,a1
        EXEC    WaitIO
        clr.b   zt_laeuft
.raus:  move.l  (sp)+,a6
        rts

zeit_sigmask:
        moveq   #0,d0
        move.l  zt_port,d1
        beq     .raus
        move.l  d1,a0
        move.b  MP_SIGBIT(a0),d1
        bset    d1,d0
.raus:  rts

zeit_ms:
        move.l  d2,-(sp)
        move.l  #1000,d1
        move.l  zt_freq,d2
        bsr     muldiv32
        move.l  (sp)+,d2
        rts

        section data,data
timername:  dc.b    "timer.device",0

        section bss,bss
_TimerBase: ds.l    1
zt_port:    ds.l    1
zt_req:     ds.l    1
zt_freq:    ds.l    1
zt_ev:      ds.l    2
zt_offen:   ds.b    1
zt_laeuft:  ds.b    1
