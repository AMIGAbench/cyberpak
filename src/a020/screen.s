; screen.s - bitplanes, screen, palette, keys (020/030 player).
;
; From src/a68k/screen.s, for the modes of the 020+ rework: GRAY5 (5 planes),
; HAM6 (6, single width), GRAY8 (8), DHAM6 (6, 640 wide), DHAM8 (8, 640 wide).
; Double width means HIRES_KEY and 80 bytes per row, plane 20480 bytes.
; anzeige_erkennen finds out beforehand: PAL/NTSC and nominal height, AGA chip
; (gb_ChipRevBits0) and whether the display database knows the AGA depths
; (without SetPatch it reports only ECS depths, even on AGA). sc_aga = both.
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
;   anzeige_erkennen  -> d0 = 0 or SC_E_LIB; sets sc_aga, sc_aachip,
;                  sc_nominal; opens graphics/intuition (screen_close closes them)
;   planes_open    d0 = mode, d1 = image height (anzeige_erkennen first)
;                  -> d0 = address of plane 0, 0 = no chip RAM
;                  Modes that go through C2P also get the chunky buffer
;                  sc_chunky in fast RAM and Kalms' converter, set up for the image
;   planes_wandeln chunky buffer -> planes (only with KERN_C2P); preserves all registers
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
        xdef    anzeige_erkennen,sc_aga,sc_aachip,sc_nominal
        xdef    planes_wandeln,sc_chunky
; Which chipset modes go through chunky + CPU C2P is fixed by the build
; (measurement direct against C2P on real hardware): the 020/030 player none,
; KERN_C2P (C builds 040/060) GRAY, KERN_C2P_HAM (68080) the HAM modes as well.
        ifd     KERN_C2P
        xdef    sc_c2pmodi
        xref    c2p1x1_8_c5_040_init,c2p1x1_8_c5_040
        xref    c2p1x1_5_c5_030_smcinit,c2p1x1_5_c5_030_init,c2p1x1_5_c5_030
        endc
        ifd     KERN_C2P_HAM
        xref    c2p1x1_6_c5_030_2_smcinit,c2p1x1_6_c5_030_2,c2p1x1_6_c5_030_2w_smcinit,c2p1x1_6_c5_030_2w
        xref    c2p1x1_8_c5_030_2w_smcinit,c2p1x1_8_c5_030_2w
        endc
        xref    _SysBase

BPL     equ     10240
RB      equ     40


        section code,code

planes_open:
        movem.l d2-d4/a2/a6,-(sp)
        bsr     planes_close
        move.l  d0,sc_modus
        move.l  d1,d3
        moveq   #5,d2                   ; planes
        move.l  #BPL,d4                 ; size of one plane
        moveq   #RB,d1                  ; bytes per row
        cmp.l   #MODUS_GRAY5,d0
        beq     .geo
        moveq   #6,d2
        cmp.l   #MODUS_HAM6,d0
        beq     .geo
        moveq   #8,d2
        cmp.l   #MODUS_GRAY8,d0
        beq     .geo
        move.l  #2*BPL,d4
        moveq   #2*RB,d1
        moveq   #6,d2
        cmp.l   #MODUS_DHAM6,d0
        beq     .geo
        moveq   #8,d2
.geo:   move.l  d2,sc_nplanes
        move.l  d4,sc_bpl
        move.l  d1,sc_rb
        move.l  d4,d0
        mulu.w  d2,d0
        move.l  #MEMF_CHIP|MEMF_CLEAR,d1
        EXEC    AllocMem
        move.l  d0,sc_planes
        beq     .raus
        move.l  sc_modus,d0
        ifd     KERN_C2P
        move.l  sc_c2pmodi,d1           ; this mode through C2P? (HAM: the control
        btst    d0,d1                   ; bits then live in the chunky buffer)
        bne     .c2p
        endc
        move.l  #MODI_HAM,d1            ; HAM: control planes inside the image
        btst    d0,d1
        beq     .gut
        moveq   #-4,d0
        and.l   d0,d3
        move.l  d3,sc_hoehe
        moveq   #4,d2                   ; first control plane: 4, with DHAM8 6
        cmp.l   #MODUS_DHAM8,sc_modus
        bne     .st
        moveq   #6,d2
.st:    move.l  sc_nominal,d0
        sub.l   d3,d0
        lsr.l   #1,d0
        mulu.w  sc_rb+2,d0
        move.l  sc_bpl,d1
        mulu.w  d2,d1
        add.l   d1,d0
        add.l   sc_planes,d0
        move.l  d0,sc_steuerzeile       ; first control plane, first image row
        bsr     steuer_schreiben
.gut:   move.l  sc_planes,d0
.raus:  movem.l (sp)+,d2-d4/a2/a6
        rts
        ifd     KERN_C2P
; Chunky buffer and Kalms' CPU C2P for the modes in sc_c2pmodi: GRAY with 5
; planes c2p1x1_5_c5_030, with 8 planes the 040 version; HAM (68080 only)
; through the 030_2 versions, for 640 pixels the copies ending in w.
.c2p:   moveq   #-4,d0
        and.l   d0,d3
        move.l  d3,sc_hoehe
        move.l  sc_rb,d0                ; screen pixels per row: 320 or 640
        lsl.l   #3,d0
        move.l  d0,sc_cbreite
        mulu.w  d3,d0
        move.l  d0,sc_chunkylen
        move.l  #MEMF_CLEAR,d1
        EXEC    AllocMem
        move.l  d0,sc_chunky
        bne     .c2p_init
        bsr     planes_close
        moveq   #0,d0
        bra     .raus
.c2p_init:
        movem.l d0-d7/a0-a6,-(sp)
        ifd     KERN_C2P_HAM
        move.l  #MODI_HAM,d1            ; HAM: pixels never written as in the
        move.l  sc_modus,d2             ; direct path - level 0 with control bits,
        btst    d2,d1                   ; there the control planes are fixed
        beq     .c2p_geo
        move.l  #$10302030,d1
        cmp.l   #MODUS_DHAM8,d2
        bne     .c2p_muster
        move.l  #$40C080C0,d1
.c2p_muster:
        move.l  d0,a0                   ; d0 = chunky buffer
        move.l  sc_chunkylen,d2
        lsr.l   #2,d2
        subq.l  #1,d2
.c2p_f: move.l  d1,(a0)+
        dbra    d2,.c2p_f
.c2p_geo:
        endc
        move.l  sc_nominal,d4           ; image row inside the screen
        sub.l   d3,d4
        lsr.l   #1,d4
        move.l  sc_planes,sc_c2pziel    ; 030 versions: plane 0, scroffsy shifts
        move.l  sc_modus,d0
        cmp.l   #MODUS_GRAY5,d0
        beq     .c2p5
        cmp.l   #MODUS_GRAY8,d0
        beq     .c2p8
        ifd     KERN_C2P_HAM
        cmp.l   #MODUS_HAM6,d0
        beq     .c2p6
        cmp.l   #MODUS_DHAM6,d0
        beq     .c2p6w
        lea     c2p1x1_8_c5_030_2w_smcinit,a2   ; DHAM8
        lea     c2p1x1_8_c5_030_2w,a3
        bra     .smc
.c2p6:  lea     c2p1x1_6_c5_030_2_smcinit,a2
        lea     c2p1x1_6_c5_030_2,a3
        bra     .smc
.c2p6w: lea     c2p1x1_6_c5_030_2w_smcinit,a2
        lea     c2p1x1_6_c5_030_2w,a3
.smc:   move.l  a3,sc_c2pfn             ; d0 chunkyx, d1 chunkyy, d3 scroffsy, d5 bplsize
        move.l  sc_cbreite,d0
        move.l  d3,d1
        move.l  d4,d3
        move.l  sc_bpl,d5
        jsr     (a2)
        bra     .c2p_fertig
        endc
.c2p8:  move.l  d4,d0                   ; 040 version: pointer to the image row,
        mulu.w  #RB,d0                  ; bplsize stays the whole plane
        add.l   sc_planes,d0
        move.l  d0,sc_c2pziel
        move.l  #c2p1x1_8_c5_040,sc_c2pfn
        move.l  #320,d0
        move.l  d3,d1
        moveq   #0,d2
        moveq   #0,d3
        moveq   #RB,d4
        move.l  #BPL,d5
        move.l  #320,d6
        jsr     c2p1x1_8_c5_040_init
        bra     .c2p_fertig
.c2p5:  move.l  #c2p1x1_5_c5_030,sc_c2pfn ; 5 planes: scroffsy shifts
        move.l  d4,d7
        move.l  #320,d0
        move.l  d3,d1
        move.l  d7,d3
        move.l  #BPL,d5
        jsr     c2p1x1_5_c5_030_smcinit
        move.l  #320,d0
        move.l  sc_hoehe,d1
        move.l  d7,d3
        jsr     c2p1x1_5_c5_030_init
.c2p_fertig:
        movem.l (sp)+,d0-d7/a0-a6
        bra     .gut
        endc

; Chunky buffer sc_chunky into the planes (only with KERN_C2P, otherwise there
; is none). Preserves all registers.
planes_wandeln:
        movem.l d0-d7/a0-a6,-(sp)
        move.l  sc_chunky,d0
        beq     .raus
        move.l  d0,a0
        move.l  sc_c2pziel,a1
        move.l  sc_c2pfn,a2
        jsr     (a2)
.raus:  movem.l (sp)+,d0-d7/a0-a6
        rts

; HAM control planes inside the image: $DD (lower), $77 (upper). Preserves all registers.
steuer_schreiben:
        movem.l d0/a0-a1,-(sp)
        move.l  sc_steuerzeile,d0
        beq     .raus
        move.l  d0,a0
        move.l  d0,a1
        adda.l  sc_bpl,a1
        move.l  sc_hoehe,d0
        mulu.w  sc_rb+2,d0
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
        move.l  sc_bpl,d0
        mulu.w  sc_nplanes+2,d0
        EXEC    FreeMem
        clr.l   sc_planes
        clr.l   sc_steuerzeile
        move.l  sc_chunky,d0
        beq     .raus
        move.l  d0,a1
        move.l  sc_chunkylen,d0
        EXEC    FreeMem
        clr.l   sc_chunky
.raus:  movem.l (sp)+,d0-d1/a0-a1/a6
        rts

; --- Detecting the display -----------------------------------------------------
; Once is enough; further calls return 0 as long as the libraries are open.
anzeige_erkennen:
        movem.l d2-d7/a2-a6,-(sp)
        tst.l   _IntuitionBase
        bne     .fertig
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
        move.l  #200,sc_nominal
        move.w  gb_DisplayFlags(a0),d0
        and.w   #PAL,d0
        beq     .mon
        move.l  #PAL_MONITOR_ID,d2
        move.l  #256,sc_nominal
.mon:   move.l  d2,sc_monitor
        move.l  d2,d0                   ; nominal height from the database
        move.l  _GfxBase,a6
        jsr     _LVOFindDisplayInfo(a6)
        tst.l   d0
        beq     .chip
        move.l  d0,a0
        lea     sc_dims,a1
        move.l  #dim_SIZEOF,d0
        move.l  #DTAG_DIMS,d1
        move.l  sc_monitor,d2
        jsr     _LVOGetDisplayInfoData(a6)
        cmp.l   #dim_Nominal+ra_SIZEOF,d0
        blt     .chip
        moveq   #0,d0
        move.w  sc_dims+dim_Nominal+ra_MaxY,d0
        addq.l  #1,d0
        cmp.l   #100,d0
        blo     .chip
        cmp.l   #256,d0                 ; the planes have 256 rows
        bhi     .chip
        move.l  d0,sc_nominal
.chip:  cmp.l   #39,sc_gfxver
        blo     .fertig
        move.l  _GfxBase,a0
        btst    #GFXB_AA_ALICE,gb_ChipRevBits0(a0)
        beq     .fertig
        st      sc_aachip
        move.l  sc_monitor,d2           ; does the database know HAM8 double width?
        or.l    #HIRES_KEY|HAM_KEY,d2
        move.l  d2,d0
        move.l  _GfxBase,a6
        jsr     _LVOFindDisplayInfo(a6)
        tst.l   d0
        beq     .fertig
        move.l  d0,a0
        lea     sc_dims,a1
        move.l  #dim_SIZEOF,d0
        move.l  #DTAG_DIMS,d1
        jsr     _LVOGetDisplayInfoData(a6)
        cmp.l   #qh_SIZEOF,d0
        blt     .fertig
        cmp.w   #8,sc_dims+dim_MaxDepth
        blo     .fertig
        st      sc_aga
.fertig:
        moveq   #0,d0
        bra     .raus
.e_lib: moveq   #SC_E_LIB,d0
.raus:  movem.l (sp)+,d2-d7/a2-a6
        rts

; --- Screen ----------------------------------------------------------------------

screen_open:
        movem.l d2-d7/a2-a6,-(sp)
        move.l  d0,sc_modus
        bsr     anzeige_erkennen
        tst.l   d0
        bne     .fehl
        cmp.l   #MODUS_DHAM6,sc_modus   ; double width needs AGA
        blo     .id
        tst.b   sc_aga
        bne     .id
        moveq   #SC_E_ECS,d0
        tst.b   sc_aachip
        beq     .fehl
        moveq   #SC_E_SETPATCH,d0
        bra     .fehl
.id:    move.l  sc_monitor,d2           ; monitor + HAM_KEY + HIRES_KEY
        move.l  sc_modus,d0
        move.l  #MODI_HAM,d1
        btst    d0,d1
        beq     .hires
        or.l    #HAM_KEY,d2
.hires: cmp.l   #MODUS_DHAM6,d0
        blo     .modus
        or.l    #HIRES_KEY,d2
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
        move.w  sc_rb+2,bm_BytesPerRow(a0)
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
        add.l   sc_bpl,d0
        bra     .plane_weiter
.leer:  clr.l   (a1)+
.plane_weiter:
        addq.l  #1,d2
        cmp.l   #8,d2
        blo     .plane

        lea     sc_tags,a0
        move.l  #SA_Width,(a0)+
        move.l  sc_rb,d0
        lsl.l   #3,d0
        move.l  d0,(a0)+
        move.l  #SA_Height,(a0)+
        move.l  sc_nominal,(a0)+
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
        move.l  sc_rb,d0
        lsl.l   #3,d0
        move.l  d0,(a0)+
        move.l  #WA_Height,(a0)+
        move.l  sc_nominal,(a0)+
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
        move.l  sc_steuerzeile,d0       ; control planes: what is in them now? rewrite.
        beq     .fertig
        move.l  d0,a0
        move.l  d0,a1
        adda.l  sc_bpl,a1
        moveq   #0,d0
        move.b  (a0),d0
        lsl.w   #8,d0
        move.b  (a1),d0
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
; from the copper list that is running (bit 15 = HIRES, 11 = HAM, 14-12 and 4 =
; planes; HAM6 lores $6A00, DHAM8 $8A10). Asked for is not got.
; bekommen.
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
        and.w   #$7010,d1
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

; Palette per mode, always a grey ramp: GRAY5 32, GRAY8 256, HAM6/DHAM6 16,
; DHAM8 64 levels, share = i * 255 / (levels - 1). HAM needs the palette only
; for control code 00, the black border: entry 0 is black.
palette_laden:
        movem.l d2-d7/a2-a6,-(sp)
        move.l  sc_modus,d6
        moveq   #32,d5
        cmp.l   #MODUS_GRAY5,d6
        beq     .farben
        move.l  #256,d5
        cmp.l   #MODUS_GRAY8,d6
        beq     .farben
        moveq   #64,d5
        cmp.l   #MODUS_DHAM8,d6
        beq     .farben
        moveq   #16,d5
.farben:
        lea     sc_farben,a2
        moveq   #0,d2
.eine:  cmp.l   d5,d2
        bhs     .laden
        move.l  d2,d0
        mulu    #255,d0
        move.l  d5,d1
        subq.l  #1,d1
        divu    d1,d0
        and.l   #$ffff,d0
        move.l  d0,d1
        lsl.l   #8,d1
        or.l    d0,d1
        lsl.l   #8,d1
        or.l    d0,d1
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

        ifd     KERN_C2P
        ifd     KERN_C2P_HAM
sc_c2pmodi:     dc.l    MODI_C2P_GRAY|MODI_HAM  ; 68080: GRAY and HAM through C2P
        else
sc_c2pmodi:     dc.l    MODI_C2P_GRAY           ; 68040/68060: GRAY through C2P
        endc
        endc
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
sc_farben:      ds.l    256
sc_rgb32:       ds.l    1+256*3+1
sc_rgb4:        ds.w    32
                cnop    0,4
sc_vpid:        ds.l    1
sc_vpmodes:     ds.l    1
sc_bplcon0:     ds.l    1
sc_steuer:      ds.l    1
sc_steuerzeile: ds.l    1
sc_hoehe:       ds.l    1
sc_monitor:     ds.l    1
sc_nominal:     ds.l    1
sc_bpl:         ds.l    1
sc_rb:          ds.l    1
sc_chunky:      ds.l    1
sc_chunkylen:   ds.l    1
sc_c2pziel:     ds.l    1
sc_c2pfn:       ds.l    1               ; converter for planes_wandeln
sc_cbreite:     ds.l    1               ; chunky buffer: pixels per row
sc_aga:         ds.b    1
sc_aachip:      ds.b    1
