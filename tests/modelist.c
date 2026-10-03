/* modelist - lists the display modes the machine really offers.
 *
 * Built because BestModeIDA() returned INVALID_ID for 320x180 at
 * 8 bitplanes on the emulated A1200, and guessing is more expensive than looking.
 * The native output path needs this list anyway: eight planes for AGA,
 * later five or six for ECS.
 *
 * Output per mode: ID, nominal size, MaxDepth, and what BestModeIDA
 * returns for the interesting depths.
 */
#include <exec/types.h>
#include <graphics/displayinfo.h>
#include <graphics/gfxbase.h>
#include <intuition/screens.h>
#include <proto/intuition.h>
#include <graphics/modeid.h>
#include <proto/exec.h>
#include <proto/graphics.h>

#include "plat.h"

static char *pstr(char *p, const char *s) { while (*s) *p++ = *s++; return p; }

static char *phex(char *p, unsigned long v)
{
    static const char d[] = "0123456789ABCDEF";
    int i;
    for (i = 28; i >= 0; i -= 4) *p++ = d[(v >> i) & 15u];
    return p;
}

static char *pnum(char *p, long v)
{
    char t[12]; int n = 0;
    if (v < 0) { *p++ = '-'; v = -v; }
    do { t[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (n) *p++ = t[--n];
    return p;
}

static char *ppad(char *p, char *from, int width)
{
    while (p - from < width) *p++ = ' ';
    return p;
}

int main(void)
{
    char buf[256], *p;
    ULONG id = INVALID_ID;
    int n = 0;

    PLAT_PUTS("[BOOT] modelist\n");
    PLAT_PUTS("ID        Breite Hoehe Tiefe  Flags\n");

    while ((id = NextDisplayInfo(id)) != (ULONG)INVALID_ID) {
        struct DimensionInfo dim;
        struct DisplayInfo   dsp;
        DisplayInfoHandle h = FindDisplayInfo(id);
        if (!h) continue;
        if (!GetDisplayInfoData(h, (UBYTE *)&dim, sizeof dim, DTAG_DIMS, 0)) continue;
        if (!GetDisplayInfoData(h, (UBYTE *)&dsp, sizeof dsp, DTAG_DISP, 0)) continue;

        /* Only modes that are really usable on this machine. */
        if (!(dsp.NotAvailable == 0)) continue;

        p = buf;
        p = phex(p, id); *p++ = ' ';
        { char *f = p; p = pnum(p, (long)(dim.Nominal.MaxX - dim.Nominal.MinX + 1)); p = ppad(p, f, 7); }
        { char *f = p; p = pnum(p, (long)(dim.Nominal.MaxY - dim.Nominal.MinY + 1)); p = ppad(p, f, 6); }
        { char *f = p; p = pnum(p, (long)dim.MaxDepth); p = ppad(p, f, 7); }
        p = phex(p, dsp.PropertyFlags);
        *p++ = '\n'; *p = 0;
        PLAT_PUTS(buf);
        n++;
    }

    p = pstr(buf, "verfuegbare Modi: "); p = pnum(p, n); *p++ = '\n'; *p = 0;
    PLAT_PUTS(buf);

    /* And now exactly the request aga_open() makes - once freely and
     * once fixed to the chipset monitor.
     *
     * The difference is the reason these lines exist: on a
     * machine with a graphics card its monitor is in the
     * display database too, and the free request then returns a mode on
     * the wrong output. On a Vampire 0x52001000 came out that way - the
     * player drew cleanly, only the chipset saw nothing of it. */
    {
        UWORD df  = ((struct GfxBase *)GfxBase)->DisplayFlags;
        ULONG mon = (df & PAL) ? (ULONG)PAL_MONITOR_ID : (ULONG)NTSC_MONITOR_ID;
        int d;

        p = pstr(buf, "DisplayFlags 0x"); p = phex(p, df);
        p = pstr(p, "  Chipsatzmonitor 0x"); p = phex(p, mon);
        p = pstr(p, (df & PAL) ? "  (PAL)" : "  (NTSC)");
        *p++ = '\n'; *p = 0; PLAT_PUTS(buf);

        for (d = 8; d >= 4; d--) {
            struct TagItem tags[6];
            ULONG frei, fest;
            tags[0].ti_Tag = BIDTAG_NominalWidth;  tags[0].ti_Data = 320;
            tags[1].ti_Tag = BIDTAG_NominalHeight; tags[1].ti_Data = 180;
            tags[2].ti_Tag = BIDTAG_Depth;         tags[2].ti_Data = (ULONG)d;
            tags[3].ti_Tag = TAG_DONE;
            frei = BestModeIDA(tags);
            tags[3].ti_Tag = BIDTAG_MonitorID;     tags[3].ti_Data = mon;
            tags[4].ti_Tag = TAG_DONE;
            fest = BestModeIDA(tags);

            p = pstr(buf, "BestModeIDA 320x180 Tiefe "); p = pnum(p, d);
            p = pstr(p, "  frei ");
            if (frei == (ULONG)INVALID_ID) p = pstr(p, "INVALID_ID");
            else                           p = phex(p, frei);
            p = pstr(p, "  Chipsatz ");
            if (fest == (ULONG)INVALID_ID) p = pstr(p, "INVALID_ID");
            else                           p = phex(p, fest);
            /* And whether the answer keeps to the request. */
            if (fest != (ULONG)INVALID_ID && (fest & MONITOR_ID_MASK) != mon)
                p = pstr(p, "  ACHTUNG: fremder Monitor");
            *p++ = '\n'; *p = 0;
            PLAT_PUTS(buf);
        }
    }

    /* What graphics.library itself thinks about the chipset. The
     * display database can be wrong or conservative - ChipRevBits0 is
     * the direct information. GFXF_AA_ALICE/AA_LISA are the AGA bits. */
    {
        UBYTE cr = ((struct GfxBase *)GfxBase)->ChipRevBits0;
        p = pstr(buf, "ChipRevBits0 = "); p = phex(p, (unsigned long)cr);
        p = pstr(p, "  (HR_AGNUS 1, HR_DENISE 2, AA_ALICE 4, AA_LISA 8)\n");
        *p = 0; PLAT_PUTS(buf);
    }

    /* The actual test: can a screen with eight bitplanes be
     * opened at all? BestModeIDA goes by the database's MaxDepth -
     * OpenScreen does not have to keep to that. */
    {
        static const ULONG ids[]   = { 0x00021000UL, 0x00000000UL };
        static const char *names[] = { "PAL:Lores ", "Default   " };
        int k, d;
        for (k = 0; k < 2; k++) for (d = 8; d >= 6; d -= 2) {
            struct Screen *sc = OpenScreenTags(NULL,
                SA_Width, 320UL, SA_Height, 180UL,
                SA_Depth, (ULONG)d, SA_DisplayID, ids[k],
                SA_Type, (ULONG)CUSTOMSCREEN,
                SA_Quiet, TRUE, SA_ShowTitle, FALSE,
                TAG_DONE);
            p = pstr(buf, "OpenScreen "); p = pstr(p, names[k]);
            p = pstr(p, "Tiefe "); p = pnum(p, d); p = pstr(p, " -> ");
            if (!sc) p = pstr(p, "FEHLER");
            else {
                p = pstr(p, "ok, BitMap->Depth = ");
                p = pnum(p, (long)sc->RastPort.BitMap->Depth);
                CloseScreen(sc);
            }
            *p++ = '\n'; *p = 0; PLAT_PUTS(buf);
        }
    }

    PLAT_PUTS("[OK] modelist\n");
    return 0;
}
