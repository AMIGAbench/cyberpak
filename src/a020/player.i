; player.i - shared definitions of the 020/030 player (pure assembler).
; Grew out of src/a68k/player.i; the 68000 player stays separate from it.
;
; Calling convention inside the player: routines preserve d2-d7/a2-a6,
; d0/d1/a0/a1 are free - as with the OS calls. Exceptions are noted at the
; head of the routine in question. Global variables live in the BSS sections
; of the modules and are addressed absolutely; hot loops fetch them into
; registers first.

        include "exec/types.i"
        include "exec/memory.i"
        include "exec/ports.i"
        include "exec/io.i"
        include "dos/dos.i"
        include "dos/dosextens.i"
        include "lvo/exec_lib.i"
        include "lvo/dos_lib.i"

; Calling an exec or dos function; a6 holds the library base afterwards.
EXEC    macro
        move.l  _SysBase,a6
        jsr     _LVO\1(a6)
        endm

DOS     macro
        move.l  _DOSBase,a6
        jsr     _LVO\1(a6)
        endm

; Entry of the frame queue (cpks.s)
Q_PTR   equ     0               ; payload (Cinepak frame)
Q_LEN   equ     4
Q_PTS   equ     8
Q_KEY   equ     12              ; 1 = keyframe

; Display mode (cvid.s, screen.s). From MODUS_DHAM6 on the mode needs AGA.
MODUS_GRAY5     equ     1       ; GRAY on ECS: 5 planes, 32 grey levels, 320 wide
MODUS_HAM6      equ     2       ; HAM6 single width: 4 data planes + 2 fixed
MODUS_GRAY8     equ     3       ; GRAY on AGA: 8 planes, 256 grey levels
MODUS_DHAM6     equ     4       ; DHAM6 double width (640): 4 data planes + 2 fixed
MODUS_DHAM8     equ     5       ; DHAM8 double width (640): 6 data planes + 2 fixed
MODI_HAM        equ     (1<<MODUS_HAM6)|(1<<MODUS_DHAM6)|(1<<MODUS_DHAM8)

; Errors from cvid_decode
CV_E_KURZ       equ     1
CV_E_LAENGE     equ     2
CV_E_STRIP      equ     3
CV_E_CHUNK      equ     4
CV_E_CHUNKID    equ     5
CV_E_SPEICHER   equ     6

; Errors from screen_open
SC_E_LIB        equ     1
SC_E_MODUS      equ     2
SC_E_TIEFE      equ     3
SC_E_SCHIRM     equ     4
SC_E_BITMAP     equ     5
SC_E_FENSTER    equ     6
SC_E_ECS        equ     7       ; mode needs AGA, chipset is ECS
SC_E_SETPATCH   equ     8       ; AGA chipset, database knows only ECS depths

; Graphics card (rtg.s). MODUS_RGB32/RGB16 are its chunky modes; GRAY goes
; through a chunky buffer and CPU C2P as well, where the measurement says so.
MODUS_RGB32     equ     6       ; RTG 32 bit (ARGB)
MODUS_RGB16     equ     7       ; RTG 15/16 bit (HICOLOR), format rt_pix16
MODI_CHUNKY     equ     (1<<MODUS_RGB32)|(1<<MODUS_RGB16)
; Chipset modes through chunky + CPU C2P exist only with KERN_C2P (C builds):
; sc_c2pmodi in screen.s, fixed per CPU at assembly time.
MODI_C2P_GRAY   equ     (1<<MODUS_GRAY5)|(1<<MODUS_GRAY8)

RT_E_LIB        equ     1
RT_E_SCHIRM     equ     2
RT_E_TIEFE      equ     3
RT_E_FENSTER    equ     4
RT_E_P96        equ     5
RT_E_FORMAT     equ     6
RT_E_SPEICHER   equ     7

RT_F_MODUS      equ     1       ; no suitable graphics card mode
RT_F_SCHIRM     equ     2
RT_F_FORMAT     equ     3       ; full screen would need another pixel format
RT_F_FENSTER    equ     4
