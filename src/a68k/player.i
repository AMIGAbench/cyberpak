; player.i - shared definitions of the 68000 player (pure assembler).
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

; Display mode (cvid.s)
MODUS_CLUT      equ     0       ; 5 planes, fixed palette 4-4-2
MODUS_GRAY      equ     1       ; 5 planes, 32 grey levels
MODUS_HAM6      equ     2       ; HAM6 LORES, 4 data planes + 2 fixed

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
