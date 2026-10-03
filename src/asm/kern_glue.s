* kern_glue.s - C entry points into the chipset path of the 020/030 player.
*
* The C builds from the 68040 on no longer show HAM6, DHAM6, DHAM8 and GRAY
* with C code of their own but with the same assembler modules as the 020/030
* player (src/a020/cvid.s, screen.s, tabellen.s) - checked in the test bench
* and in the emulator. This file gives them C names (with a leading underscore)
* and offers the variables as functions. Parameters in registers, see
* src/kern.h; the modules preserve d2-d7/a2-a6 as the C call requires.
*
* Jumping with jmp instead of bra: the targets live in other objects
* (sections), and PC-relative references across sections do not exist in the
* hunk format.
        xref    anzeige_erkennen,planes_open,planes_close,planes_wandeln
        xref    cvid_open,cvid_decode,cvid_close
        xref    screen_open,screen_close,screen_input,screen_sigmask
        xref    sc_aga,sc_aachip,sc_nominal,sc_chunky,sc_modeid

        section code,code

        xdef    _kern_anzeige_erkennen,_kern_planes_open,_kern_planes_close,_kern_planes_wandeln
        xdef    _kern_cvid_open,_kern_cvid_decode,_kern_cvid_close
        xdef    _kern_screen_open,_kern_screen_close,_kern_screen_input,_kern_screen_sigmask
        xdef    _kern_aga,_kern_aachip,_kern_nominal,_kern_chunky,_kern_modeid

_kern_anzeige_erkennen: jmp     anzeige_erkennen
_kern_planes_open:      jmp     planes_open
_kern_planes_close:     jmp     planes_close
_kern_planes_wandeln:   jmp     planes_wandeln
_kern_cvid_open:        jmp     cvid_open
_kern_cvid_decode:      jmp     cvid_decode
_kern_cvid_close:       jmp     cvid_close
_kern_screen_open:      jmp     screen_open
_kern_screen_close:     jmp     screen_close
_kern_screen_input:     jmp     screen_input
_kern_screen_sigmask:   jmp     screen_sigmask

_kern_aga:
        moveq   #0,d0
        move.b  sc_aga,d0
        rts
_kern_aachip:
        moveq   #0,d0
        move.b  sc_aachip,d0
        rts
_kern_nominal:
        move.l  sc_nominal,d0
        rts
_kern_chunky:
        move.l  sc_chunky,d0
        rts
_kern_modeid:
        move.l  sc_modeid,d0
        rts

        end
