/* player.c - CyberPak, playback of CPKS (builds from the 68040 on).
 *
 * Call: CyberPak <file> [HAM6|DHAM6|DHAM8|GRAY|HICOLOR] [NOVIDEO] [NOAUDIO]
 *                [STATS] [QUIET] [NOSER] [ABUF=n] [ANUM=n]
 *
 * Display (020+ rework): without an option the graphics card if it is usable,
 * otherwise AGA with DHAM8, otherwise ECS with HAM6. HAM6/DHAM6/DHAM8/GRAY
 * force the chipset, HICOLOR the graphics card with 15/16 bit; if a requested
 * mode is not possible, there is a reason, a suggestion and return code 10. The
 * chipset path is the same assembler display as in the 020/030 player
 * (src/kern.h), the graphics card stays C (src/video.c).
 *
 * ONE container: CPKS, Cinepak with timestamps. The sound IS the clock, `pts`
 * counts in samples, and the drift between two clocks thereby disappears
 * by construction.
 *
 * The AVI path is gone. It had the picture from timer.device and the sound
 * from Paula - two clocks that inevitably drift apart (on real
 * hardware -907 ppm, measured over 215 s: -195 ms of offset and 20
 * skipped frames; the same film as CPKS: no drift, 0
 * skipped). Maintaining both paths in parallel is thus settled.
 * The AVI version stands in the history up to the commit "AVI out of the
 * player", should it ever be needed.
 *
 * The file is read STREAMING, not loaded into memory in full -
 * with 70 MB films and 128 MB of fast RAM that would otherwise be the hard
 * limit. The sound lead-in arises from the queue of compressed
 * video frames in src/cpks.c: what is held ready as picture has already been
 * put out as sound.
 */
#include <stdlib.h>
#include <string.h>

#include "cpu.h"
#include "plat.h"
#include "bytes.h"
#include "yuv.h"
#include "sync.h"
#include "timing.h"
#include "video.h"
#include "vout.h"
#include "kern.h"
#include "audio.h"
#include "cpks.h"
#include "codec/cvid.h"

#ifdef __m68k__
#include <exec/types.h>
#include <proto/exec.h>
#include <proto/dos.h>
#else
#include <stdio.h>
#endif

/* --- text output without stdio ------------------------------------------ */
static char obuf[200];
static char *pstr(char *p, const char *s) { while (*s) *p++ = *s++; return p; }
static char *pnum(char *p, long v)
{
    char t[12]; int n = 0;
    if (v < 0) { *p++ = '-'; v = -v; }
    do { t[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (n) *p++ = t[--n];
    return p;
}
static char *phex4(char *p, unsigned long v)
{
    int i;
    for (i = 4; i >= 0; i -= 4) *p++ = "0123456789abcdef"[(v >> i) & 15];
    return p;
}
static char *phex8(char *p, unsigned long v)
{
    int i;
    for (i = 28; i >= 0; i -= 4) *p++ = "0123456789abcdef"[(v >> i) & 15];
    return p;
}
static void emit(char *e) { *e = 0; PLAT_PUTS(obuf); }
static void say(const char *s) { PLAT_PUTS(s); }

/* "ABUF=32" -> value 32. Returns 0 if the prefix does not match. */
static uint32_t kwvalue(const char *a, const char *kw)
{
    uint32_t v = 0;
    while (*kw) {
        char c = *a++;
        if (c >= 'a' && c <= 'z') c = (char)(c - 32);
        if (c != *kw++) return 0;
    }
    if (*a++ != '=') return 0;
    while (*a >= '0' && *a <= '9') v = v * 10u + (uint32_t)(*a++ - '0');
    return *a ? 0 : v;
}

static int kwmatch(const char *a, const char *kw)
{
    while (*a && *kw) {
        char c = *a++;
        if (c >= 'a' && c <= 'z') c = (char)(c - 32);
        if (c != *kw++) return 0;
    }
    return (*a == 0 && *kw == 0);
}

/* Does a begin with kw (case-insensitively)? For dropped keywords
 * with a value (PLANES=). */
static int kwprefix(const char *a, const char *kw)
{
    while (*kw) {
        char c = *a++;
        if (c >= 'a' && c <= 'z') c = (char)(c - 32);
        if (c != *kw++) return 0;
    }
    return 1;
}

static int g_have_audio;

static cpks_stream *g_cs;
static void cpks_sink(const uint8_t *pcm, uint32_t n)
{
    if (g_have_audio) audio_write(pcm, n);
}

/* Two lines with fixed beginnings - the server passes them on. */
static void modus_fehlt(const char *modus, const char *grund, const char *hint)
{
    say("Mode \""); say(modus); say("\" not available: "); say(grund);
    say("\nPlease try a different mode");
    if (hint && *hint) { say(", e.g.: "); say(hint); }
    say("\n");
}

#define WEG_RTG   1
#define WEG_KERN  2

#ifdef __m68k__
static const char *kern_grund(uint32_t e)
{
    switch (e) {
    case KERN_SC_LIB:      return "graphics.library or intuition.library V36 or later is missing";
    case KERN_SC_MODUS:    return "the display mode does not exist on this machine";
    case KERN_SC_TIEFE:    return "the display mode does not carry that many bitplanes";
    case KERN_SC_SCHIRM:   return "the screen could not be opened (chip RAM?)";
    case KERN_SC_BITMAP:   return "the screen does not take over our own BitMap (SA_BitMap)";
    case KERN_SC_FENSTER:  return "the window on the screen could not be opened";
    case KERN_SC_ECS:      return "needs AGA (ECS chipset detected)";
    case KERN_SC_SETPATCH: return "needs AGA depths in the display database (AGA chipset - has SetPatch run?)";
    default:               return "unknown error";
    }
}
#endif

/* --- CPKS: playback with the sound as the clock -------------------------- */

/* forced: 0 or KERN_*; gray: GRAY requested (depth follows the chipset) */
static int play_cpks(const char *fn, int novideo, int noaudio, int stats, int quiet,
                     int hicolor, uint32_t erzwungen, int gray)
{
    cpks_stream *s;
    const cpks_info *in;
    cvid_ctx *ctx = NULL;
    uint8_t *fb = NULL;
    uint32_t w, h, stride = 0, upf;
    uint32_t shown = 0, decoded = 0, dropped = 0, tb, tick;
    int paused = 0, quit = 0, err, weg = 0;
    uint32_t modus = 0;
    const char *name = "";
    uint64_t dec_ticks = 0, anz_ticks = 0;
    int fail_rc = 20;
    char *p;

    s = cpks_open(fn, 16, &err);
    if (!s) {
        switch (err) {
        case CPKS_ERR_OPEN:   say("File not found or not readable\n"); break;
        case CPKS_ERR_FORMAT: say("Not a usable CPKS stream (no header packet?)\n"); break;
        default:              say("Not enough memory\n"); break;
        }
        return 20;
    }
    g_cs = s;
    in = cpks_get_info(s);

    if (in->codec != FOURCC('c','v','i','d') && in->codec != FOURCC('C','V','I','D')) {
        say("Only Cinepak is supported so far\n"); cpks_close(s); return 20;
    }

    w = in->width & ~3u;
    h = in->height & ~3u;
    tb = in->timebase;
    upf = in->fps_num ? (uint32_t)((uint64_t)1000000u * in->fps_den / in->fps_num)
                      : 40000u;
    /* The clock runs at half the frame spacing (see history). */
    tick = upf / 2u;
    if (tick < 5000u) tick = 5000u;

    if (!quiet) {
        p = pstr(obuf, "  "); p = pnum(p, (long)w); *p++ = 'x'; p = pnum(p, (long)h);
        p = pstr(p, "  Cinepak  ");
        p = pnum(p, (long)(in->fps_den ? in->fps_num / in->fps_den : 0));
        p = pstr(p, " fps  CPKS, timebase "); p = pnum(p, (long)tb);
        p = pstr(p, "\n"); emit(p);
    }

    /* --- choose and open the display ---------------------------------------
     *
     * HICOLOR: graphics card with 15/16 bit. One chipset mode: exactly that one.
     * Without an option: the graphics card if usable - if the Workbench is on
     * it but below 15 bit, that is an error, not a switch to the chipset -,
     * otherwise AGA with DHAM8, otherwise ECS with HAM6. */
    if (!novideo) {
        if (hicolor) {
            weg = WEG_RTG; name = "HICOLOR";
        } else if (erzwungen || gray) {
            weg = WEG_KERN;
        } else {
            int r = rtg_probe();
            name = "RTG 32 bit (no options)";
            if (r == 0) weg = WEG_RTG;
            else if (r == VIDEO_ERR_DEPTH) {
                modus_fehlt(name, rtg_status(), rtg_hint());
                fail_rc = 10; goto cfail;
            } else weg = WEG_KERN;
        }
    }

    if (weg == WEG_RTG) {
        int hi;
        rtg_prefer_hicolor(hicolor);
        if (rtg_open(w, h, "CyberPak") != 0) {
            modus_fehlt(name, rtg_status(), rtg_hint());
            fail_rc = 10; goto cfail;
        }
        hi = rtg_is_hicolor();
        stride = STRIDE_ALIGN(w * (hi ? 2u : 4u));
        ctx = cvid_open(w, h, hi ? CVID_OUT_RGB16 : CVID_OUT_RGB32);
        fb  = (uint8_t *)calloc((size_t)stride * h, 1);
        if (!ctx || !fb) { say("Not enough memory for the picture buffer\n"); goto cfail; }
        if (hi) cvid_set_pix16(ctx, rtg_pix16());
        if (!quiet) {
            p = pstr(obuf, "  Output: "); p = pstr(p, name);
            p = pstr(p, ", graphics card "); p = pnum(p, (long)(hi ? 16 : 32));
            p = pstr(p, " bit, depth "); p = pnum(p, (long)rtg_depth());
            p = pstr(p, ", pixel format "); p = pnum(p, (long)rtg_pixfmt());
            *p++ = '\n'; emit(p);
        }
    }
#ifdef __m68k__
    else if (weg == WEG_KERN) {
        uint32_t aga, planes, r;
        uint8_t *ziel;
        if (kern_anzeige_erkennen() != 0) {
            modus_fehlt("(no options)", kern_grund(KERN_SC_LIB), "NOVIDEO");
            fail_rc = 10; goto cfail;
        }
        aga = kern_aga();
        if (erzwungen) modus = erzwungen;
        else if (gray) modus = aga ? KERN_GRAY8 : KERN_GRAY5;
        else modus = aga ? KERN_DHAM8 : KERN_HAM6;
        switch (modus) {
        case KERN_HAM6:  name = erzwungen ? "HAM6"  : "HAM6 (no options)"; break;
        case KERN_DHAM6: name = "DHAM6"; break;
        case KERN_DHAM8: name = erzwungen ? "DHAM8" : "DHAM8 (no options)"; break;
        default:         name = "GRAY"; break;
        }
        if ((modus == KERN_DHAM6 || modus == KERN_DHAM8) && !aga) {
            modus_fehlt(name, kern_grund(kern_aachip() ? KERN_SC_SETPATCH : KERN_SC_ECS),
                        "HAM6  or  GRAY");
            fail_rc = 10; goto cfail;
        }
        planes = kern_planes_open(modus, in->height);
        if (!planes) {
            modus_fehlt(name, "no contiguous chip RAM block for the bitplanes",
                        (modus == KERN_DHAM6 || modus == KERN_DHAM8) ? "DHAM6  or  HAM6" : "NOVIDEO");
            fail_rc = 10; goto cfail;
        }
        /* Modes this build sends through C2P (screen.s, sc_c2pmodi) have a chunky picture */
        ziel = kern_chunky() ? (uint8_t *)kern_chunky() : (uint8_t *)planes;
        r = kern_cvid_open(modus, ziel, in->width, in->height, kern_nominal());
        if (r) {
            modus_fehlt(name, r == 1 ? "Picture size does not fit (320 wide, at most as high as the screen)"
                                     : "Not enough memory for the colour tables (up to 110 KB)", "NOVIDEO");
            fail_rc = 10; goto cfail;
        }
        r = kern_screen_open(modus);
        if (r) {
            modus_fehlt(name, kern_grund(r), "NOVIDEO");
            fail_rc = 10; goto cfail;
        }
        if (!quiet) {
            p = pstr(obuf, "  Output: "); p = pstr(p, name);
            p = pstr(p, ", chipset, single buffered, ");
            p = pstr(p, kern_chunky() ? "C2P" : "straight into the planes");
            p = pstr(p, ", mode 0x"); p = phex8(p, kern_modeid());
            *p++ = '\n'; emit(p);
        }
    }
#endif

    timing_open();     /* MUST come before audio_open() - supplies the colour clock */

    /* `arate == 0` means "no sound". Do NOT ask `achans`: the encoder
     * fills in channel count and bit depth even when there is no sound track. */
    if (!noaudio && in->arate) {
        int aerr = audio_open(in->arate, in->achans, in->abits);
        if (aerr == 0) {
            g_have_audio = 1;
            if (!quiet) {
                p = pstr(obuf, "  Sound: "); p = pnum(p, (long)audio_rate());
                p = pstr(p, " Hz, "); p = pnum(p, (long)in->achans);
                p = pstr(p, " channels, "); p = pnum(p, (long)in->abits);
                if (audio_weg() == AUDIO_WEG_AHI) {
                    /* No period: ahi.device takes the rate as it is, so there
                     * is no rate deviation to report either. */
                    p = pstr(p, " bit  ->  AHI unit ");
                    p = pnum(p, (long)audio_ahi_unit());
                } else {
                    p = pstr(p, " bit  ->  period ");
                    p = pnum(p, (long)audio_period());
                    p = pstr(p, ", actually "); p = pnum(p, (long)audio_eff_rate());
                    p = pstr(p, " Hz");
                }
                *p++ = '\n'; emit(p);
            }
        } else {
            modus_fehlt("Sound",
                        aerr == AUDIO_ERR_AHI
                          ? "ahi.device could not be opened (is AHI installed?)"
                        : aerr == AUDIO_ERR_FORMAT
                          ? "Sound format is not supported"
                          : "audio.device could not be opened (in use?)",
                        aerr == AUDIO_ERR_AHI ? "(no options)" : "NOAUDIO");
            fail_rc = 10;
            goto cfail;
        }
    }

    if (!sync_open(tick)) { say("timer.device not available\n"); goto cfail; }

    /* 5.2 prebuffering. */
    {
        uint32_t guard = 4096u;
        for (;;) {
            cpks_pump(s, cpks_sink);
            if (g_have_audio && cpks_eof(s)) audio_ende();
            if (g_have_audio) audio_service();
            if (!g_have_audio) break;
            if (cpks_audio_samples(s) >= in->prebuffer) break;
            if (cpks_queued(s) >= 16u) break;
            if (cpks_eof(s) || !guard--) break;
        }
        if (!quiet) {
            p = pstr(obuf, "  prebuffered: "); p = pnum(p, (long)cpks_queued(s));
            p = pstr(p, " Frames, "); p = pnum(p, (long)cpks_audio_samples(s));
            p = pstr(p, " audio samples\n"); emit(p);
        }
    }

    sync_start();
    sync_arm(0);

    for (;;) {
        uint32_t sigs, wanted, pos, due, drop, i, anzmask = 0;

#ifdef __m68k__
        if (weg == WEG_KERN) anzmask = kern_screen_sigmask();
#endif
        if (weg == WEG_RTG) anzmask = rtg_sigmask();
        wanted = sync_sigmask() | anzmask;
        if (!wanted) break;
        {
            int fired = 0;
            for (;;) {
                if (fired && !paused) break;
#ifdef __m68k__
                sigs = Wait(wanted);
#else
                sigs = wanted;
#endif
                if (sigs & anzmask) {
                    int inp = VIDEO_INPUT_NONE;
#ifdef __m68k__
                    if (weg == WEG_KERN) inp = (int)kern_screen_input();
#endif
                    if (weg == WEG_RTG) inp = rtg_handle_input();
                    if (inp == VIDEO_INPUT_QUIT)  { quit = 1; break; }
                    if (inp == VIDEO_INPUT_PAUSE) paused = !paused;
                    if (inp == VIDEO_INPUT_FULLSCREEN && weg == WEG_RTG) {
                        /* New window, new signal bit: the outer
                         * loop builds the mask anew. */
                        if (rtg_toggle_fullscreen()) {
                            rtg_show(fb, stride);
                        } else if (!quiet) {
                            switch (rtg_fs_error()) {
                            case VIDEO_FS_FORMAT:
                                say("  Full screen: the mode has a different pixel format, staying in the window\n");
                                break;
                            case VIDEO_FS_NOMODE:
                                say("  Full screen: no suitable RTG mode found\n");
                                break;
                            default:
                                say("  Full screen: the screen or the window could not be opened\n");
                                break;
                            }
                        }
                        break;
                    }
                }
                if (sigs & sync_sigmask()) fired = 1;
            }
        }
        if (quit) break;
        sync_consume();

        cpks_pump(s, cpks_sink);
        if (g_have_audio && cpks_eof(s)) audio_ende();
        if (g_have_audio) audio_service();

        /* 5.1 position: with sound in samples, without sound the local clock. */
        if (g_have_audio)
            pos = cpks_audio_base(s) + audio_played_samples();
        else
            pos = (uint32_t)((uint64_t)sync_elapsed_ms() * tb / 1000u);

        due = cpks_advance(s, pos, &drop);
        dropped += drop;

        /* 5.3: DECODE all that are due. Chunky picture (graphics card, GRAY):
         * show only the last one. Straight into the planes: each one is there already. */
        for (i = 0; i < due; i++) {
            const uint8_t *fdata; uint32_t fsize;
            uint64_t t0;
            if (!cpks_next_video(s, &fdata, &fsize, NULL, NULL)) break;
            t0 = timing_now();
            if (weg == WEG_RTG) cvid_decode(ctx, fdata, fsize, fb, stride);
#ifdef __m68k__
            else if (weg == WEG_KERN) kern_cvid_decode(fdata, fsize, 0);
#endif
            dec_ticks += timing_now() - t0;
            decoded++;
        }
        if (i && weg) {
            uint64_t t0 = timing_now();
            if (weg == WEG_RTG) { rtg_show(fb, stride); shown++; }
#ifdef __m68k__
            else if (kern_chunky()) { kern_planes_wandeln(); shown++; }
            else shown += i;
#endif
            anz_ticks += timing_now() - t0;
        }

        if (cpks_eof(s) && !cpks_queued(s)) break;
        sync_resync();
        sync_arm(0);
    }

    if (novideo && !quiet) say("[OK] playback loop completed\n");

    if (stats && !quiet) {
        uint32_t ms = sync_elapsed_ms();
        uint32_t f  = timing_freq();
        if (g_have_audio) {
            p = pstr(obuf, audio_weg() == AUDIO_WEG_AHI ? "  Sound: AHI unit 0x"
                                                         : "  Sound: channel mask 0x");
            p = phex4(p, audio_dbg_mask());
            p = pstr(p, ", "); p = pnum(p, (long)audio_dbg_samples());
            p = pstr(p, " samples, "); p = pnum(p, (long)audio_dbg_sent());
            p = pstr(p, " buffers, "); p = pnum(p, (long)audio_dbg_lost());
            p = pstr(p, " dropped, "); p = pnum(p, (long)audio_dbg_under());
            p = pstr(p, "x ran dry, io_Error="); p = pnum(p, (long)audio_dbg_error());
            *p++ = '\n'; emit(p);
            p = pstr(obuf, "  Audio buffers: "); p = pnum(p, (long)audio_dbg_nbuf());
            p = pstr(p, " x "); p = pnum(p, (long)audio_dbg_bufsz());
            p = pstr(p, " samples, min. filled "); p = pnum(p, (long)audio_dbg_minpend());
            p = pstr(p, ", max. backlog "); p = pnum(p, (long)audio_dbg_maxring());
            p = pstr(p, " samples, CheckIO "); p = pnum(p, (long)audio_dbg_checkio());
            *p++ = '\n'; emit(p);
        }
        if (f) {
            p = pstr(obuf, "  Time: disk ");
            p = pnum(p, (long)((cpks_read_ticks(s) * 1000u) / f));
            p = pstr(p, " ms, sound ");
            p = pnum(p, (long)((cpks_sink_ticks(s) * 1000u) / f));
            p = pstr(p, " ms, display ");
            p = pnum(p, (long)((anz_ticks * 1000u) / f));
            p = pstr(p, " ms, decoder ");
            p = pnum(p, (long)((dec_ticks * 1000u) / f));
            p = pstr(p, " ms, total "); p = pnum(p, (long)ms);
            p = pstr(p, " ms\n"); emit(p);
            if (decoded) {
                p = pstr(obuf, "  Decoder per frame ");
                p = pnum(p, (long)((dec_ticks * 1000u) / f / decoded));
                p = pstr(p, " ms, budget per frame "); p = pnum(p, (long)(upf / 1000u));
                p = pstr(p, " ms\n"); emit(p);
            }
        }
        p = pstr(obuf, "  shown "); p = pnum(p, (long)shown);
        p = pstr(p, ", decoded "); p = pnum(p, (long)decoded);
        p = pstr(p, ", not shown "); p = pnum(p, (long)(decoded - shown));
        p = pstr(p, ", dropped without decoding "); p = pnum(p, (long)dropped);
        p = pstr(p, ", resyncs "); p = pnum(p, (long)cpks_dbg_resyncs(s));
        p = pstr(p, ", read "); p = pnum(p, (long)(cpks_bytes_read(s) / 1024u));
        p = pstr(p, " KB\n"); emit(p);
    }

    /* Closing mark for tools/run.sh (only with STATS). */
    if (stats) say("[OK] playback finished\n");

    timing_close();
    sync_close();
    if (g_have_audio) audio_close();
    if (weg == WEG_RTG) rtg_close();
#ifdef __m68k__
    if (weg == WEG_KERN) { kern_screen_close(); kern_cvid_close(); kern_planes_close(); }
#endif
    if (ctx) cvid_close(ctx);
    free(fb);
    cpks_close(s);
    return 0;

cfail:
    sync_close();
    audio_close();
    rtg_close();
#ifdef __m68k__
    kern_screen_close();
    kern_cvid_close();
    kern_planes_close();
#endif
    if (ctx) cvid_close(ctx);
    if (fb) free(fb);
    cpks_close(s);
    return fail_rc;
}

int main(int argc, char **argv)
{
    const char *fn = NULL;
    int i, stats = 0, quiet = 0, novideo = 0, noaudio = 0, hicolor = 0, gray = 0, modi = 0;
    uint32_t abuf = 0, anum = 0, erzwungen = 0, ahiunit = 0;
    int ahi = 0;

    for (i = 1; i < argc; i++) {
        const char *a = argv[i];
        if      (kwmatch(a, "NOVIDEO"))  novideo = 1;
        else if (kwmatch(a, "NOAUDIO"))  noaudio = 1;
        else if (kwmatch(a, "STATS"))    stats   = 1;
        else if (kwmatch(a, "QUIET"))    quiet   = 1;
        else if (kwmatch(a, "NOSER"))    plat_serial(0);
        else if (kwmatch(a, "HICOLOR") || kwmatch(a, "16BIT")) { hicolor = 1; modi++; }
        else if (kwmatch(a, "GRAY") || kwmatch(a, "GREY"))     { gray = 1; modi++; }
        else if (kwmatch(a, "HAM6"))     { erzwungen = KERN_HAM6;  modi++; }
        else if (kwmatch(a, "DHAM6"))    { erzwungen = KERN_DHAM6; modi++; }
        else if (kwmatch(a, "DHAM8"))    { erzwungen = KERN_DHAM8; modi++; }
        else if (kwmatch(a, "AHI"))      ahi     = 1;
        else if (kwvalue(a, "AHIUNIT"))  ahiunit = kwvalue(a, "AHIUNIT");
        else if (kwvalue(a, "ABUF"))     abuf    = kwvalue(a, "ABUF");
        else if (kwvalue(a, "ANUM"))     anum    = kwvalue(a, "ANUM");
        else if (kwmatch(a, "AGA") || kwprefix(a, "PLANES=") || kwmatch(a, "PLANAR") ||
                 kwmatch(a, "LORES") || kwmatch(a, "HAM") || kwmatch(a, "HAM8") ||
                 kwmatch(a, "FIXPAL") || kwmatch(a, "NODBUF") || kwmatch(a, "BLIT") ||
                 kwmatch(a, "NOBLIT") || kwmatch(a, "CACHE")) {
            say("Invalid call: "); say(a);
            say(" does not exist any more - the modes are HAM6, DHAM6, DHAM8, GRAY and"
                " HICOLOR, without one the player chooses itself\n");
            return 5;
        }
        else if (!fn) fn = a;
        else { say("Unknown option: "); say(a); say("\n"); return 5; }
    }
    if (!fn) {
        say("CyberPak <file.cpks> [options]\n"
            "  Display - at most one mode:\n"
            "            (nothing given) graphics card (32 bit), otherwise AGA with DHAM8,\n"
            "                            otherwise ECS with HAM6\n"
            "            [HICOLOR]       graphics card, 15/16 bit (Picasso96)\n"
            "            [HAM6]          HAM6, single width - ECS and AGA\n"
            "            [DHAM6]         HAM6, double width - AGA only\n"
            "            [DHAM8]         HAM8, double width - AGA only\n"
            "            [GRAY]          grey levels: ECS 5 planes, AGA 8 planes\n"
            "  If a requested mode is not possible, the player names the reason and a\n"
            "  suggestion and ends with return code 10.\n"
            "  Sound: nothing given    audio.device (Paula), 8 bit\n"
            "         [AHI]           ahi.device: 16 bit and the exact rate\n"
            "         [AHIUNIT=n]     ahi.device unit, 0 = the preferred one\n"
            "  Other: [NOVIDEO] [NOAUDIO] [STATS] [QUIET] [NOSER]\n"
            "         [ABUF=n] [ANUM=n]  audio buffers: size rate/n, count n\n"
            "  Return codes: 5 invalid call, 10 mode not available here,\n"
            "  20 other error. Keys: space pause, return full screen\n"
            "  (graphics card), q or ESC quit\n");
        return 5;
    }
    if (modi > 1) {
        say("Invalid call: only one mode - HAM6, DHAM6, DHAM8, GRAY or HICOLOR\n");
        return 5;
    }
    if (abuf || anum) audio_config(abuf, anum);
    /* The path is decided before opening; AHI is never chosen by itself. */
    if (ahi || ahiunit) audio_config_weg(ahi ? AUDIO_WEG_AHI : AUDIO_WEG_PAULA, ahiunit);

    if (yuv_selftest()) { say("colour tables are faulty\n"); return 20; }

    /* Deliberately WITHOUT a check for 'CPKS' at position 0 (NETSTREAM: enters
     * in the middle of a stream; the reader looks for the next sync word). */
    return play_cpks(fn, novideo, noaudio, stats, quiet, hicolor, erzwungen, gray);
}
