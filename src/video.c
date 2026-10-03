#include <exec/types.h>
#include <intuition/intuition.h>
#include <intuition/screens.h>
#include <graphics/gfx.h>
#include <cybergraphx/cybergraphics.h>
#include <proto/exec.h>
#include <proto/intuition.h>
#include <proto/graphics.h>
#include <proto/cybergraphics.h>
#include <libraries/Picasso96.h>
#include <proto/Picasso96.h>

#include "cpu.h"
#include "video.h"
#include "vout.h"
#include "timing.h"

/* Both bases WITH an initialiser, so that they are strong definitions.
 * Without the initialiser gcc creates a common symbol; to resolve it the
 * linker then pulls in the auto-open object from libc.a, whose
 * constructor opens cybergraphics.library BEFORE main() and, if it is
 * missing, aborts with "CyberGfx.library failed to load". On a machine
 * without a graphics card (AGA/ECS) the program could thus not even start.
 * It is opened solely down here, at run time and checkably. */
struct Library *CyberGfxBase = NULL;
struct Library *P96Base      = NULL;

static struct Screen *g_screen;
static struct Window *g_window;
static uint32_t       g_w, g_h, g_depth, g_pixfmt;
static int            g_left, g_top;
static uint64_t       g_show_ticks;

/* 16-bit output: halves the bus traffic to the graphics card.
 *
 * WritePixelArray CANNOT do it - cybergraphics.library knows only
 * RECTFMT_RGB/RGBA/ARGB/LUT8/GREY8, so 1, 3 or 4 bytes per pixel; a
 * 15/16-bit source format does not exist there (looked up in the NDK and in
 * the original CGX SDK of 1998). The way leads through
 * p96WritePixelArray from Picasso96API.library, which takes a RenderInfo with
 * RGBFB_R5G6B5 and relatives directly - and does the clipping itself,
 * unlike p96LockBitMap.
 *
 * If the library is missing or the screen format does not fit, it stays with
 * the proven 32-bit path. */
/* Full screen: a screen of our own instead of a window on the public screen.
 *
 * g_ownscreen tells HOW the cleanup has to be done - a screen of our own
 * needs CloseScreen(), the public screen UnlockPubScreen(). Confusing the
 * two crashes on exit. */
static int      g_fullscreen;
static int      g_ownscreen;
static char     g_title[64];

static int      g_want16;        /* wanted by the caller             */
static int      g_use16;         /* actually active                  */
static int      g_pix16;         /* CVX_PIX16_* for the decoder      */
static ULONG    g_rgbfb;         /* RGBFB_* for the RenderInfo       */

uint32_t rtg_depth(void) { return g_depth; }
uint32_t rtg_pixfmt(void) { return g_pixfmt; }
uint64_t rtg_show_ticks(void) { return g_show_ticks; }

void     rtg_prefer_hicolor(int on) { g_want16 = on; }
int      rtg_is_hicolor(void)       { return g_use16; }
uint32_t rtg_bpp(void)              { return g_use16 ? 2u : 4u; }
int      rtg_pix16(void)            { return g_pix16; }

/* --- No fallback: reason and suggestion ---------------------------------
 *
 * rtg_open() fails instead of delivering something other than what was
 * asked for - and then says what went wrong and what could be used instead.
 * Previously HICOLOR silently stayed with the 32-bit path, and above all
 * that the chipset stepped in inside vout.c. */
static const char *g_rtg_err  = "not opened";
static const char *g_rtg_hint = "";
static char        g_rtg_buf[160];
const char *rtg_status(void) { return g_rtg_err; }
const char *rtg_hint(void)   { return g_rtg_hint; }

static char *rput(char *q, const char *t) { while (*t) *q++ = *t++; return q; }
static char *rnum(char *q, unsigned long v)
{
    char t[12]; int n = 0;
    do { t[n++] = (char)('0' + v % 10u); v /= 10u; } while (v);
    while (n) *q++ = t[--n];
    return q;
}
static int rtg_fail(int rc, const char *reason, const char *hint)
{
    g_rtg_err  = reason;
    g_rtg_hint = hint;
    return rc;
}

/* Clear pending IDCMP messages and close the window.
 *
 * If messages stay in the port, they afterwards belong to a
 * freed window - a classic source of crashes. So clear them under
 * Forbid(), not only on exit but also when switching. */
static void close_window(void)
{
    struct IntuiMessage *msg;
    struct MsgPort *up;
    if (!g_window) return;
    up = g_window->UserPort;
    Forbid();
    while ((msg = (struct IntuiMessage *)GetMsg(up)))
        ReplyMsg((struct Message *)msg);
    CloseWindow(g_window);
    Permit();
    g_window = NULL;
}

/* Open a window on `sc`. In full screen borderless and centred in the screen -
 * we have no scaler, the picture stays 1:1. */
static int open_window_on(struct Screen *sc, int borderless)
{
    if (borderless) {
        g_window = OpenWindowTags(NULL,
            WA_Width,        (ULONG)sc->Width,
            WA_Height,       (ULONG)sc->Height,
            WA_Left,         0UL,
            WA_Top,          0UL,
            WA_Borderless,   TRUE,
            WA_Backdrop,     TRUE,
            WA_Activate,     TRUE,
            WA_SimpleRefresh, TRUE,
            WA_NoCareRefresh, TRUE,
            WA_CustomScreen, (ULONG)sc,
            WA_IDCMP,        IDCMP_VANILLAKEY | IDCMP_RAWKEY,
            TAG_DONE);
        if (!g_window) return 0;
        g_left = (sc->Width  > (WORD)g_w) ? (sc->Width  - (WORD)g_w) / 2 : 0;
        g_top  = (sc->Height > (WORD)g_h) ? (sc->Height - (WORD)g_h) / 2 : 0;
        return 1;
    }

    g_window = OpenWindowTags(NULL,
        WA_Title,        (ULONG)g_title,
        WA_InnerWidth,   (ULONG)g_w,
        WA_InnerHeight,  (ULONG)g_h,
        WA_Left,         (ULONG)((sc->Width  > (WORD)g_w) ? (sc->Width  - (WORD)g_w) / 2 : 0),
        WA_Top,          (ULONG)((sc->Height > (WORD)g_h) ? (sc->Height - (WORD)g_h) / 2 : 0),
        WA_DragBar,      TRUE,
        WA_DepthGadget,  TRUE,
        WA_CloseGadget,  TRUE,
        WA_Activate,     TRUE,
        WA_SimpleRefresh, TRUE,
        WA_NoCareRefresh, TRUE,
        WA_PubScreen,    (ULONG)sc,
        WA_IDCMP,        IDCMP_CLOSEWINDOW | IDCMP_VANILLAKEY | IDCMP_RAWKEY,
        TAG_DONE);
    if (!g_window) return 0;
    /* Drawing origin inside the window borders. */
    g_left = g_window->BorderLeft;
    g_top  = g_window->BorderTop;
    return 1;
}

/* Take over depth and pixel format of the current screen. */
static void read_screen_fmt(struct Screen *sc)
{
    g_depth  = GetCyberMapAttr(sc->RastPort.BitMap, CYBRMATTR_DEPTH);
    /* The depth alone is not enough: it distinguishes neither RGB16 from
     * RGB16PC nor ARGB32 from RGBA32. On a wrong assumption
     * WritePixelArray shifts every pixel byte by byte instead of copying. */
    g_pixfmt = GetCyberMapAttr(sc->RastPort.BitMap, CYBRMATTR_PIXFMT);
}

int rtg_open(uint32_t w, uint32_t h, const char *title)
{
    int i;
    g_w = w; g_h = h;
    for (i = 0; i < 63 && title[i]; i++) g_title[i] = title[i];
    g_title[i] = 0;

    CyberGfxBase = OpenLibrary((CONST_STRPTR)"cybergraphics.library", 41);
    if (!CyberGfxBase)
        return rtg_fail(VIDEO_ERR_LIB,
                        "cybergraphics.library is missing (no graphics card?)",
                        "(no options)");

    g_screen = LockPubScreen(NULL);
    if (!g_screen) {
        CloseLibrary(CyberGfxBase); CyberGfxBase = NULL;
        return rtg_fail(VIDEO_ERR_WINDOW,
                        "the Workbench screen could not be locked",
                        "DHAM8  or  HAM6  or  GRAY");
    }
    g_ownscreen = 0;

    read_screen_fmt(g_screen);

    /* Is the Workbench on the graphics card at all? An installed
     * CyberGraphX on an AGA screen is not a card. */
    if (!GetCyberMapAttr(g_screen->RastPort.BitMap, CYBRMATTR_ISCYBERGFX)) {
        UnlockPubScreen(NULL, g_screen); g_screen = NULL;
        CloseLibrary(CyberGfxBase); CyberGfxBase = NULL;
        return rtg_fail(VIDEO_ERR_LIB,
                        "cybergraphics.library is missing or the Workbench is not on the graphics card",
                        "DHAM8  or  HAM6  or  GRAY");
    }

    if (!open_window_on(g_screen, 0)) {
        UnlockPubScreen(NULL, g_screen); g_screen = NULL;
        CloseLibrary(CyberGfxBase); CyberGfxBase = NULL;
        return rtg_fail(VIDEO_ERR_WINDOW,
                        "the window on the Workbench screen could not be opened",
                        "DHAM8  or  HAM6  or  GRAY");
    }

    /* Below 15 bit WritePixelArray would have to reduce colours per pixel -
     * that would be orders of magnitude slower than the decoding and is
     * not the purpose of this path. The AGA path is there for that. */
    if (g_depth < 15) {
        char *q = rput(g_rtg_buf, "the Workbench screen has ");
        q = rnum(q, (unsigned long)g_depth);
        q = rput(q, " bit - the graphics card needs 15 bit or more"
                    " (Bildschirmmodus umstellen)");
        *q = 0;
        rtg_close();
        return rtg_fail(VIDEO_ERR_DEPTH, g_rtg_buf,
                        "DHAM8  or  HAM6  or  GRAY");
    }

    /* The 16-bit path only if it really fits: the library is there AND the
     * screen format is one of the four the decoder can pack for.
     * Otherwise p96 would convert per pixel and the advantage would be gone.
     *
     * HICOLOR is a REQUIREMENT. Previously it silently stayed with the
     * 32-bit path here, and the player only printed a note in the
     * status line. Now the call fails. */
    if (g_want16) {
        P96Base = OpenLibrary((CONST_STRPTR)"Picasso96API.library", 2);
        if (!P96Base) {
            rtg_close();
            return rtg_fail(VIDEO_ERR_DEPTH,
                            "HICOLOR needs Picasso96API.library - it is missing",
                            "(no options)");
        }
        switch (g_pixfmt) {
        case PIXFMT_RGB16:   g_pix16 = CVX_PIX16_R5G6B5;   g_rgbfb = RGBFB_R5G6B5;   g_use16 = 1; break;
        case PIXFMT_RGB16PC: g_pix16 = CVX_PIX16_R5G6B5PC; g_rgbfb = RGBFB_R5G6B5PC; g_use16 = 1; break;
        case PIXFMT_RGB15:   g_pix16 = CVX_PIX16_R5G5B5;   g_rgbfb = RGBFB_R5G5B5;   g_use16 = 1; break;
        case PIXFMT_RGB15PC: g_pix16 = CVX_PIX16_R5G5B5PC; g_rgbfb = RGBFB_R5G5B5PC; g_use16 = 1; break;
        default: break;      /* BGR variants and truecolor: see below */
        }
        if (!g_use16) {
            char *q = rput(g_rtg_buf, "HICOLOR: screen format ");
            q = rnum(q, (unsigned long)g_pixfmt);
            q = rput(q, " is none of the four 15/16 bit formats the decoder can pack for");
            *q = 0;
            rtg_close();
            return rtg_fail(VIDEO_ERR_DEPTH, g_rtg_buf, "(no options)");
        }
    }
    g_rtg_err = "RTG open"; g_rtg_hint = "";
    return 0;
}

/* Without an option the player picks the graphics card if it is usable -
 * otherwise the chipset. The libraries stay closed afterwards. */
int rtg_probe(void)
{
    struct Screen *sc;
    ULONG is;

    CyberGfxBase = OpenLibrary((CONST_STRPTR)"cybergraphics.library", 41);
    if (!CyberGfxBase)
        return rtg_fail(VIDEO_ERR_LIB, "cybergraphics.library is missing (no graphics card?)",
                        "(no options)");
    sc = LockPubScreen(NULL);
    if (!sc) {
        CloseLibrary(CyberGfxBase); CyberGfxBase = NULL;
        return rtg_fail(VIDEO_ERR_WINDOW, "the Workbench screen could not be locked",
                        "DHAM8  or  HAM6  or  GRAY");
    }
    is      = GetCyberMapAttr(sc->RastPort.BitMap, CYBRMATTR_ISCYBERGFX);
    g_depth = GetCyberMapAttr(sc->RastPort.BitMap, CYBRMATTR_DEPTH);
    UnlockPubScreen(NULL, sc);
    CloseLibrary(CyberGfxBase); CyberGfxBase = NULL;
    if (!is)
        return rtg_fail(VIDEO_ERR_LIB,
                        "cybergraphics.library is missing or the Workbench is not on the graphics card",
                        "DHAM8  or  HAM6  or  GRAY");
    if (g_depth < 15) {
        char *q = rput(g_rtg_buf, "the Workbench screen has ");
        q = rnum(q, (unsigned long)g_depth);
        q = rput(q, " bit - the graphics card needs 15 bit or more (change the screen mode)");
        *q = 0;
        return rtg_fail(VIDEO_ERR_DEPTH, g_rtg_buf, "DHAM8  or  HAM6  or  GRAY");
    }
    return 0;
}

/* Switch between window and full screen.
 *
 * Return: 1 = switched, 0 = stayed (reason through rtg_fs_error()).
 *
 * The decoder packs its codebook entries for ONE pixel format in advance
 * (cvid_set_pix16). If the full screen mode reports a different one, it is
 * therefore NOT switched - the colours would not be right otherwise. The
 * format depends on the card, not on the mode, so the case should be rare. */
static int g_fs_err;

int rtg_fs_error(void) { return g_fs_err; }

int rtg_toggle_fullscreen(void)
{
    struct Screen *sc;
    ULONG mode;

    g_fs_err = VIDEO_FS_OK;
    if (!g_window || !CyberGfxBase) { g_fs_err = VIDEO_FS_NOWIN; return 0; }

    if (g_fullscreen) {
        /* back into the window */
        close_window();
        CloseScreen(g_screen); g_screen = NULL; g_ownscreen = 0;
        g_screen = LockPubScreen(NULL);
        if (!g_screen) { g_fs_err = VIDEO_FS_NOSCREEN; return 0; }
        read_screen_fmt(g_screen);
        if (!open_window_on(g_screen, 0)) { g_fs_err = VIDEO_FS_NOWIN; return 0; }
        g_fullscreen = 0;
        return 1;
    }

    mode = BestCModeIDTags(CYBRBIDTG_NominalWidth,  (ULONG)g_w,
                           CYBRBIDTG_NominalHeight, (ULONG)g_h,
                           CYBRBIDTG_Depth,         (ULONG)g_depth,
                           TAG_DONE);
    if (mode == (ULONG)INVALID_ID) { g_fs_err = VIDEO_FS_NOMODE; return 0; }

    sc = OpenScreenTags(NULL,
        SA_DisplayID,  mode,
        SA_Depth,      (ULONG)g_depth,
        SA_Type,       CUSTOMSCREEN,
        SA_Quiet,      TRUE,
        SA_ShowTitle,  FALSE,
        TAG_DONE);
    if (!sc) { g_fs_err = VIDEO_FS_NOSCREEN; return 0; }

    /* Check the format BEFORE we change the window. */
    {
        uint32_t fmt = GetCyberMapAttr(sc->RastPort.BitMap, CYBRMATTR_PIXFMT);
        if (fmt != g_pixfmt) {
            CloseScreen(sc);
            g_fs_err = VIDEO_FS_FORMAT;
            return 0;
        }
    }

    close_window();
    UnlockPubScreen(NULL, g_screen);
    g_screen    = sc;
    g_ownscreen = 1;
    if (!open_window_on(g_screen, 1)) {
        /* Emergency: back to the public screen */
        CloseScreen(g_screen); g_screen = LockPubScreen(NULL); g_ownscreen = 0;
        if (g_screen) open_window_on(g_screen, 0);
        g_fs_err = VIDEO_FS_NOWIN;
        return 0;
    }
    g_fullscreen = 1;
    return 1;
}

int rtg_is_fullscreen(void) { return g_fullscreen; }

void rtg_close(void)
{
    close_window();
    if (g_screen) {
        if (g_ownscreen) CloseScreen(g_screen);
        else             UnlockPubScreen(NULL, g_screen);
        g_screen = NULL; g_ownscreen = 0;
    }
    g_fullscreen = 0;
    if (P96Base) { CloseLibrary(P96Base); P96Base = NULL; g_use16 = 0; }
    if (CyberGfxBase) { CloseLibrary(CyberGfxBase); CyberGfxBase = NULL; }
}

void rtg_show(const uint8_t *fb, uint32_t stride)
{
    uint64_t t0;
    if (!g_window) return;
    if (stride > 65535u) return;      /* both paths take only a UWORD */

    t0 = timing_now();
    if (g_use16) {
        struct RenderInfo ri;
        ri.Memory      = (APTR)fb;
        ri.BytesPerRow = (WORD)stride;
        ri.pad         = 0;
        ri.RGBFormat   = (RGBFTYPE)g_rgbfb;
        p96WritePixelArray(&ri, 0, 0, g_window->RPort,
                           (UWORD)g_left, (UWORD)g_top,
                           (UWORD)g_w, (UWORD)g_h);
    } else {
        /* RECTFMT_ARGB expects exactly our memory bytes A,R,G,B. */
        WritePixelArray((APTR)fb, 0, 0, (UWORD)stride,
                        g_window->RPort, (UWORD)g_left, (UWORD)g_top,
                        (UWORD)g_w, (UWORD)g_h, RECTFMT_ARGB);
    }
    g_show_ticks += timing_now() - t0;
}

uint32_t rtg_sigmask(void)
{
    if (!g_window) return 0;
    return 1UL << g_window->UserPort->mp_SigBit;
}

int rtg_handle_input(void)
{
    struct IntuiMessage *msg;
    int ret = VIDEO_INPUT_NONE;

    if (!g_window) return VIDEO_INPUT_QUIT;

    while ((msg = (struct IntuiMessage *)GetMsg(g_window->UserPort))) {
        ULONG cls  = msg->Class;
        UWORD code = msg->Code;
        ReplyMsg((struct Message *)msg);

        if (cls == IDCMP_CLOSEWINDOW) ret = VIDEO_INPUT_QUIT;
        else if (cls == IDCMP_VANILLAKEY) {
            if (code == 27 || code == 'q' || code == 'Q') ret = VIDEO_INPUT_QUIT;
            else if (code == 32)                          ret = VIDEO_INPUT_PAUSE;
            else if (code == 13)                          ret = VIDEO_INPUT_FULLSCREEN;
        }
    }
    return ret;
}
