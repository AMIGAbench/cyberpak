; screen.s - bitplanes, screen, palette, keys.
;
; Model: src/aga.c, path B (single buffered, own BitMap through SA_BitMap) and
; chipset_mode(). The player allocates the planes itself as ONE chip RAM block:
; 320x256 per plane, distance 10240, in one piece - exactly the way the block
; loops address them. On the real A600 the BitMap that Intuition allocates for
; a screen was not contiguous.
;
; The display mode is computed, not asked for: monitor of the chipset (PAL/NTSC
; from GfxBase) plus LORES_KEY or HAM_KEY. The display database only says
; whether it exists and whether it carries the depth (ECS lores: 5 planes,
; HAM: 6).
;
; HAM6: the control planes 4/5 carry the fixed pattern $DD/$77 across the image
; area (pixel column mod 4 = blue, green, red, green). HAM6 needs the palette
; only for control code 00 - the black border; 16 grey levels, entry 0 black.
;
; CONTROL PLANES REWRITTEN AFTER OPENING. First A600 run: HAM was on (ViewPort
; HAM, BPLCON0 $6A01), the picture grey all the same, with vertical stripes -
; the control planes were empty, and control code 00 shows the grey palette.
; They had been written before OpenScreen/OpenWindow; filling the background
; cleared them, and the decoder never touches them again. Now: screen and
; window without backfill, and after opening we look at what is there
; (sc_steuer) and write them again.
;
;   planes_open    d0 = planes (5 or 6), d1 = image height
;                  -> d0 = address of plane 0, 0 = no chip RAM
;   planes_close   any number of times; preserves all registers
;   screen_open    d0 = mode (MODUS_*), planes open -> d0 = 0 or SC_E_*
;   screen_close   any number of times; preserves all registers
;   screen_input   -> d0 = 0 nothing, 1 quit (ESC, q), 2 pause (space)
;   screen_sigmask -> d0 = signal mask of the window (0 = no window)

        include "player.i"
        include "graphics/gfx.i"
        include "graphics/gfxbase.i"
        include "graphics/view.i"
        include "graphics/modeid.i"
        include "graphics/displayinfo.i"
        include "graphics/rastport.i"
        include "graphics/copper.i"
        include "graphics/layers.i"
        include "intuition/intuition.i"
        include "intuition/screens.i"
        include "utility/tagitem.i"
        include "lvo/graphics_lib.i"
        include "lvo/intuition_lib.i"

        xdef    planes_open,planes_close,sc_planes,sc_nplanes
        xdef    screen_open,screen_close,screen_input,screen_sigmask,sc_modeid,sc_gfxver
        xdef    sc_vpid,sc_vpmodes,sc_bplcon0,sc_steuer
        xref    _SysBase

BPL     equ     10240
RB      equ     40


        section code,code

planes_open:
        movem.l d2-d3/a2/a6,-(sp)
        bsr     planes_close
        move.l  d0,d2
        move.l  d1,d3
        move.l  d2,d0
        mulu    #BPL,d0
        move.l  #MEMF_CHIP|MEMF_CLEAR,d1
        EXEC    AllocMem
        move.l  d0,sc_planes
        beq     .raus
        move.l  d2,sc_nplanes
        cmp.l   #6,d2
        bne     .gut
        moveq   #-4,d0
        and.l   d0,d3
        move.l  d3,sc_hoehe
        move.l  #256,d0
        sub.l   d3,d0
        lsr.l   #1,d0
        mulu    #RB,d0
        add.l   sc_planes,d0
        add.l   #4*BPL,d0
        move.l  d0,sc_steuerzeile       ; plane 4, first image row
        bsr     steuer_schreiben
.gut:   move.l  sc_planes,d0
.raus:  movem.l (sp)+,d2-d3/a2/a6
        rts

; HAM6 control planes 4/5 inside the image: $DD/$77. Preserves all registers.
steuer_schreiben:
        movem.l d0/a0-a1,-(sp)
        move.l  sc_steuerzeile,d0
        beq     .raus
        move.l  d0,a0
        lea     BPL(a0),a1
        move.l  sc_hoehe,d0
        mulu    #RB,d0
        subq.l  #1,d0
        bmi     .raus
.muster:
        move.b  #$DD,(a0)+
        move.b  #$77,(a1)+
        dbra    d0,.muster
.raus:  movem.l (sp)+,d0/a0-a1
        rts

planes_close:
        movem.l d0-d1/a0-a1/a6,-(sp)
        move.l  sc_planes,d0
        beq     .raus
        move.l  d0,a1
        move.l  sc_nplanes,d0
        mulu    #BPL,d0
        EXEC    FreeMem
        clr.l   sc_planes
        clr.l   sc_steuerzeile
.raus:  movem.l (sp)+,d0-d1/a0-a1/a6
        rts

; --- Screen ----------------------------------------------------------------------

screen_open:
        movem.l d2-d7/a2-a6,-(sp)
        move.l  d0,sc_modus
        lea     gfxname,a1
        moveq   #36,d0
        EXEC    OpenLibrary
        move.l  d0,_GfxBase
        beq     .e_lib
        move.l  d0,a0
        moveq   #0,d1
        move.w  LIB_VERSION(a0),d1
        move.l  d1,sc_gfxver
        lea     intname,a1
        moveq   #36,d0
        jsr     _LVOOpenLibrary(a6)
        move.l  d0,_IntuitionBase
        beq     .e_lib

        move.l  _GfxBase,a0             ; monitor of the chipset
        move.l  #NTSC_MONITOR_ID,d2
        move.w  gb_DisplayFlags(a0),d0
        and.w   #PAL,d0
        beq     .schluessel
        move.l  #PAL_MONITOR_ID,d2
.schluessel:
        cmp.l   #MODUS_HAM6,sc_modus
        bne     .modus
        or.l    #HAM_KEY,d2
.modus: move.l  d2,sc_modeid
        move.l  d2,d0
        move.l  _GfxBase,a6
        jsr     _LVOFindDisplayInfo(a6)
        tst.l   d0
        beq     .e_modus
        move.l  d0,a0
        lea     sc_dims,a1
        move.l  #dim_SIZEOF,d0
        move.l  #DTAG_DIMS,d1
        move.l  sc_modeid,d2
        jsr     _LVOGetDisplayInfoData(a6)
        cmp.l   #qh_SIZEOF,d0
        blt     .e_modus
        moveq   #0,d0
        move.w  sc_dims+dim_MaxDepth,d0
        cmp.l   sc_nplanes,d0
        blo     .e_tiefe

        lea     sc_bm,a0                ; our own BitMap
        move.w  #RB,bm_BytesPerRow(a0)
        move.w  #256,bm_Rows(a0)
        clr.b   bm_Flags(a0)
        move.b  sc_nplanes+3,bm_Depth(a0)
        clr.w   bm_Pad(a0)
        lea     bm_Planes(a0),a1
        move.l  sc_planes,d0
        moveq   #0,d2
.plane: cmp.l   sc_nplanes,d2
        bhs     .leer
        move.l  d0,(a1)+
        add.l   #BPL,d0
        bra     .plane_weiter
.leer:  clr.l   (a1)+
.plane_weiter:
        addq.l  #1,d2
        cmp.l   #8,d2
        blo     .plane

        lea     sc_tags,a0
        move.l  #SA_Width,(a0)+
        move.l  #320,(a0)+
        move.l  #SA_Height,(a0)+
        move.l  #256,(a0)+
        move.l  #SA_Depth,(a0)+
        move.l  sc_nplanes,(a0)+
        move.l  #SA_DisplayID,(a0)+
        move.l  sc_modeid,(a0)+
        move.l  #SA_Type,(a0)+
        move.l  #CUSTOMSCREEN,(a0)+
        move.l  #SA_Quiet,(a0)+
        move.l  #1,(a0)+
        move.l  #SA_ShowTitle,(a0)+
        clr.l   (a0)+
        move.l  #SA_Draggable,(a0)+
        clr.l   (a0)+
        move.l  #SA_Exclusive,(a0)+
        move.l  #1,(a0)+
        move.l  #SA_BitMap,(a0)+
        move.l  #sc_bm,(a0)+
        move.l  #SA_BackFill,(a0)+      ; V39 and up; older: ignored
        move.l  #LAYERS_NOBACKFILL,(a0)+
        move.l  #TAG_DONE,(a0)+
        clr.l   (a0)+
        sub.l   a0,a0
        lea     sc_tags,a1
        move.l  _IntuitionBase,a6
        jsr     _LVOOpenScreenTagList(a6)
        move.l  d0,sc_screen
        beq     .e_schirm
        move.l  d0,a0                   ; did it really take our BitMap?
        move.l  sc_RastPort+rp_BitMap(a0),d0
        beq     .e_bitmap
        move.l  d0,a1
        moveq   #0,d0
        move.b  bm_Depth(a1),d0
        cmp.l   sc_nplanes,d0
        blo     .e_bitmap
        move.l  bm_Planes(a1),d0
        cmp.l   sc_planes,d0
        bne     .e_bitmap

        bsr     palette_laden

        lea     sc_wtags,a0             ; borderless window, only for the keys
        move.l  #WA_Left,(a0)+
        clr.l   (a0)+
        move.l  #WA_Top,(a0)+
        clr.l   (a0)+
        move.l  #WA_Width,(a0)+
        move.l  #320,(a0)+
        move.l  #WA_Height,(a0)+
        move.l  #256,(a0)+
        move.l  #WA_CustomScreen,(a0)+
        move.l  sc_screen,(a0)+
        move.l  #WA_Borderless,(a0)+
        move.l  #1,(a0)+
        move.l  #WA_Activate,(a0)+
        move.l  #1,(a0)+
        move.l  #WA_RMBTrap,(a0)+
        move.l  #1,(a0)+
        move.l  #WA_NoCareRefresh,(a0)+
        move.l  #1,(a0)+
        move.l  #WA_IDCMP,(a0)+
        move.l  #IDCMP_VANILLAKEY|IDCMP_RAWKEY,(a0)+
        move.l  #WA_BackFill,(a0)+      ; the window must not clear the planes
        move.l  #LAYERS_NOBACKFILL,(a0)+
        move.l  #TAG_DONE,(a0)+
        clr.l   (a0)+
        sub.l   a0,a0
        lea     sc_wtags,a1
        move.l  _IntuitionBase,a6
        jsr     _LVOOpenWindowTagList(a6)
        move.l  d0,sc_window
        beq     .e_fenster
        move.l  sc_screen,a0
        jsr     _LVOScreenToFront(a6)
        bsr     anzeige_lesen
        cmp.l   #MODUS_HAM6,sc_modus    ; control planes: what is in them now? rewrite.
        bne     .fertig
        move.l  sc_steuerzeile,a0
        moveq   #0,d0
        move.b  (a0),d0
        lsl.w   #8,d0
        move.b  BPL(a0),d0
        move.l  d0,sc_steuer
        bsr     steuer_schreiben
.fertig:
        moveq   #0,d0
        bra     .raus
.e_lib: moveq   #SC_E_LIB,d0
        bra     .fehl
.e_modus:
        moveq   #SC_E_MODUS,d0
        bra     .fehl
.e_tiefe:
        moveq   #SC_E_TIEFE,d0
        bra     .fehl
.e_schirm:
        moveq   #SC_E_SCHIRM,d0
        bra     .fehl
.e_bitmap:
        moveq   #SC_E_BITMAP,d0
        bra     .fehl
.e_fenster:
        moveq   #SC_E_FENSTER,d0
.fehl:  bsr     screen_close
.raus:  movem.l (sp)+,d2-d7/a2-a6
        rts

; What the screen REALLY got: modes and ID of the ViewPort, and the BPLCON0
; from the copper list that is running (bit 11 = HAM, 14-12 = planes; HAM6
; lores $6A00, EHB $6200). Asked for is not got.
anzeige_lesen:
        movem.l d2-d4/a2-a3/a6,-(sp)
        move.l  sc_screen,a2
        lea     sc_ViewPort(a2),a2
        moveq   #0,d0
        move.w  vp_Modes(a2),d0
        move.l  d0,sc_vpmodes
        move.l  a2,a0
        move.l  _GfxBase,a6
        jsr     _LVOGetVPModeID(a6)
        move.l  d0,sc_vpid
        moveq   #-1,d4
        cmp.l   #39,sc_gfxver           ; the semaphore exists from V39 on
        blo     .raus
        move.l  _GfxBase,a3
        move.l  gb_ActiViewCprSemaphore(a3),d3
        beq     .raus
        move.l  d3,a0
        EXEC    ObtainSemaphore
        move.l  gb_ActiView(a3),d0
        beq     .frei
        move.l  d0,a0
        move.l  v_LOFCprList(a0),d0
.liste: tst.l   d0
        beq     .frei
        move.l  d0,a1
        move.l  crl_start(a1),d1
        beq     .naechste
        move.l  d1,a0
        move.w  crl_MaxCount(a1),d2
        ext.l   d2
        ble     .naechste
        subq.l  #1,d2
.wort:  move.w  (a0),d1                 ; MOVE: bit 0 free, register $100
        btst    #0,d1
        bne     .weiter
        and.w   #$1fe,d1
        cmp.w   #$100,d1
        bne     .weiter
        tst.l   d4                      ; the first one with planes counts - later
        bpl     .weiter                 ; the list sets BPLCON0 back to 0
        move.w  2(a0),d1
        and.w   #$7000,d1
        beq     .weiter
        moveq   #0,d4
        move.w  2(a0),d4
.weiter:
        addq.l  #4,a0
        dbra    d2,.wort
.naechste:
        move.l  crl_Next(a1),d0
        bra     .liste
.frei:  move.l  d3,a0
        EXEC    ReleaseSemaphore
.raus:  move.l  d4,sc_bplcon0
        movem.l (sp)+,d2-d4/a2-a3/a6
        rts

; Palette per mode: 4-4-2 (32), 32 grey levels, HAM6 16 grey levels. As in
; yuv_clut_palette/yuv_gray_palette: share * 255 / (levels - 1).
palette_laden:
        movem.l d2-d7/a2-a6,-(sp)
        move.l  sc_modus,d6
        moveq   #32,d5
        cmp.l   #MODUS_HAM6,d6
        bne     .farben
        moveq   #16,d5
.farben:
        lea     sc_farben,a2
        moveq   #0,d2
.eine:  cmp.l   d5,d2
        bhs     .laden
        cmp.l   #MODUS_CLUT,d6
        bne     .grau
        move.l  d2,d3                   ; r = i >> 3
        lsr.l   #3,d3
        mulu    #85,d3
        move.l  d2,d4                   ; g = (i >> 1) & 3
        lsr.l   #1,d4
        and.l   #3,d4
        mulu    #85,d4
        moveq   #1,d0                   ; b = i & 1
        and.l   d2,d0
        mulu    #255,d0
        bra     .farbe
.grau:  move.l  d2,d0
        mulu    #255,d0
        move.l  d5,d1
        subq.l  #1,d1
        divu    d1,d0
        and.l   #$ffff,d0
        move.l  d0,d3
        move.l  d0,d4
.farbe: moveq   #0,d1
        move.b  d3,d1
        lsl.l   #8,d1
        move.b  d4,d1
        lsl.l   #8,d1
        move.b  d0,d1
        move.l  d1,(a2)+
        addq.l  #1,d2
        bra     .eine
.laden: move.l  sc_screen,a3
        lea     sc_ViewPort(a3),a3
        cmp.l   #39,sc_gfxver
        blo     .rgb4
        lea     sc_rgb32,a1             ; LoadRGB32: count << 16 | first colour
        move.l  d5,d0
        swap    d0
        clr.w   d0
        move.l  d0,(a1)+
        lea     sc_farben,a2
        move.l  d5,d2
        subq.l  #1,d2
.c32:   move.l  (a2)+,d7
        moveq   #16,d4
        bsr     .anteil
        moveq   #8,d4
        bsr     .anteil
        moveq   #0,d4
        bsr     .anteil
        dbra    d2,.c32
        clr.l   (a1)
        move.l  a3,a0
        lea     sc_rgb32,a1
        move.l  _GfxBase,a6
        jsr     _LVOLoadRGB32(a6)
        bra     .raus
; d7 = 0x00RRGGBB, d4 = shift -> (a1)+ = byte * $01010101
.anteil:
        move.l  d7,d0
        lsr.l   d4,d0
        and.l   #$ff,d0
        move.l  d0,d1
        lsl.l   #8,d1
        or.l    d1,d0
        move.l  d0,d1
        swap    d1
        or.l    d1,d0
        move.l  d0,(a1)+
        rts
.rgb4:  lea     sc_rgb4,a1              ; LoadRGB4 (before V39): 4 bit per share
        lea     sc_farben,a2
        move.l  d5,d2
        subq.l  #1,d2
.c4:    move.l  (a2)+,d0
        moveq   #0,d3
        move.l  d0,d1
        swap    d1
        and.w   #$f0,d1
        lsl.w   #4,d1
        or.w    d1,d3
        move.w  d0,d1
        lsr.w   #8,d1
        and.w   #$f0,d1
        or.w    d1,d3
        moveq   #0,d1
        move.b  d0,d1
        lsr.b   #4,d1
        or.w    d1,d3
        move.w  d3,(a1)+
        dbra    d2,.c4
        move.l  a3,a0
        lea     sc_rgb4,a1
        move.l  d5,d0
        move.l  _GfxBase,a6
        jsr     _LVOLoadRGB4(a6)
.raus:  movem.l (sp)+,d2-d7/a2-a6
        rts

screen_close:
        movem.l d0-d1/a0-a1/a6,-(sp)
        move.l  sc_window,d0
        beq     .schirm
        move.l  d0,a0
        move.l  _IntuitionBase,a6
        jsr     _LVOCloseWindow(a6)
        clr.l   sc_window
.schirm:
        move.l  sc_screen,d0
        beq     .libs
        move.l  d0,a0
        move.l  _IntuitionBase,a6
        jsr     _LVOCloseScreen(a6)
        clr.l   sc_screen
.libs:  move.l  _IntuitionBase,d0
        beq     .gfx
        move.l  d0,a1
        EXEC    CloseLibrary
        clr.l   _IntuitionBase
.gfx:   move.l  _GfxBase,d0
        beq     .raus
        move.l  d0,a1
        EXEC    CloseLibrary
        clr.l   _GfxBase
.raus:  movem.l (sp)+,d0-d1/a0-a1/a6
        rts

screen_input:
        movem.l d2/a2/a6,-(sp)
        moveq   #0,d2
        move.l  sc_window,d0
        beq     .raus
        move.l  d0,a0
        move.l  wd_UserPort(a0),a2
.msg:   move.l  a2,a0
        EXEC    GetMsg
        tst.l   d0
        beq     .raus
        move.l  d0,a1
        move.l  im_Class(a1),-(sp)
        move.w  im_Code(a1),-(sp)
        jsr     _LVOReplyMsg(a6)
        move.w  (sp)+,d1
        move.l  (sp)+,d0
        cmp.l   #IDCMP_VANILLAKEY,d0
        bne     .msg
        cmp.w   #27,d1
        beq     .ende
        cmp.w   #'q',d1
        beq     .ende
        cmp.w   #'Q',d1
        beq     .ende
        cmp.w   #32,d1
        bne     .msg
        moveq   #2,d2
        bra     .msg
.ende:  moveq   #1,d2
        bra     .msg
.raus:  move.l  d2,d0
        movem.l (sp)+,d2/a2/a6
        rts

screen_sigmask:
        moveq   #0,d0
        move.l  sc_window,d1
        beq     .raus
        move.l  d1,a0
        move.l  wd_UserPort(a0),a0
        moveq   #0,d1
        move.b  MP_SIGBIT(a0),d1
        bset    d1,d0
.raus:  rts

        section data,data
gfxname:    dc.b    "graphics.library",0
intname:    dc.b    "intuition.library",0

        section bss,bss
_GfxBase:       ds.l    1
_IntuitionBase: ds.l    1
sc_planes:      ds.l    1
sc_nplanes:     ds.l    1
sc_modus:       ds.l    1
sc_modeid:      ds.l    1
sc_gfxver:      ds.l    1
sc_screen:      ds.l    1
sc_window:      ds.l    1
sc_bm:          ds.b    bm_SIZEOF
                ds.b    1
                cnop    0,4
sc_dims:        ds.b    dim_SIZEOF
                cnop    0,4
sc_tags:        ds.l    32
sc_wtags:       ds.l    32
sc_farben:      ds.l    32
sc_rgb32:       ds.l    1+32*3+1
sc_rgb4:        ds.w    32
                cnop    0,4
sc_vpid:        ds.l    1
sc_vpmodes:     ds.l    1
sc_bplcon0:     ds.l    1
sc_steuer:      ds.l    1
sc_steuerzeile: ds.l    1
sc_hoehe:       ds.l    1
