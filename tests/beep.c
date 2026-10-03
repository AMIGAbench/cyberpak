/* beep - a minimal audio.device test, independent of src/audio.c.
 *
 * Purpose: take my own code out of the equation. If this program is
 * audible, the fault is in audio.c; if not, it is in the machine
 * or in the basic setup.
 *
 * Deliberately as close as possible to the textbook example: ONE channel, a
 * short square wave sample, repeated through ioa_Cycles.
 */
#include <exec/types.h>
#include <exec/memory.h>
#include <devices/audio.h>
#include <proto/exec.h>
#include <proto/dos.h>
#include <clib/debug_protos.h>
#include <devices/timer.h>
#include <proto/timer.h>

static void out(const char *s)
{
    long n = 0; const char *p = s;
    BPTR o;
    while (*p++) n++;
    o = Output();
    if (o) Write(o, (CONST APTR)s, n);
    KPutStr((CONST_STRPTR)s);
}
static void outnum(const char *label, long v)
{
    char b[64], *p = b; const char *l = label;
    char t[12]; int n = 0;
    while (*l) *p++ = *l++;
    if (v < 0) { *p++ = '-'; v = -v; }
    do { t[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (n) *p++ = t[--n];
    *p++ = '\n'; *p = 0;
    out(b);
}

/* Any single voice will do - we only want some sound at all. */
static UBYTE anychannel[] = { 1, 2, 4, 8 };

/* A timer of our own only for measuring - the duration is the most telling
 * value here: 3.5 s of sound has to take about 3.5 s too. If WaitIO returns
 * at once, the Paula DMA is not running at all, whatever io_Error says. */
struct Device *TimerBase;
static struct MsgPort     *tport;
static struct timerequest *treq;
static ULONG efreq;

static ULONG ticks(void)
{
    struct EClockVal ev;
    if (!TimerBase) return 0;
    ReadEClock(&ev);
    return ev.ev_lo;
}
static void timer_up(void)
{
    struct EClockVal ev;
    tport = CreateMsgPort(); if (!tport) return;
    treq = (struct timerequest *)CreateIORequest(tport, sizeof(*treq));
    if (!treq) return;
    if (OpenDevice((CONST_STRPTR)TIMERNAME, UNIT_ECLOCK, (struct IORequest *)treq, 0)) return;
    TimerBase = treq->tr_node.io_Device;
    efreq = ReadEClock(&ev);
}
static void timer_down(void)
{
    if (TimerBase) { CloseDevice((struct IORequest *)treq); TimerBase = NULL; }
    if (treq)  DeleteIORequest((struct IORequest *)treq);
    if (tport) DeleteMsgPort(tport);
}

int main(void)
{
    struct MsgPort *port;
    struct IOAudio *io;
    BYTE *wave;
    int i;
    ULONG t0, t1;

    port = CreateMsgPort();
    if (!port) { out("no MsgPort\n"); return 20; }

    io = (struct IOAudio *)CreateIORequest(port, sizeof(struct IOAudio));
    if (!io) { out("no IORequest\n"); DeleteMsgPort(port); return 20; }

    io->ioa_Request.io_Message.mn_Node.ln_Pri = 10;
    io->ioa_Data   = anychannel;
    io->ioa_Length = sizeof(anychannel);

    if (OpenDevice((CONST_STRPTR)"audio.device", 0, (struct IORequest *)io, 0)) {
        out("audio.device could not be opened\n");
        DeleteIORequest((struct IORequest *)io); DeleteMsgPort(port);
        return 20;
    }
    outnum("belegte Kanalmaske: ", (long)(ULONG)io->ioa_Request.io_Unit);

    wave = (BYTE *)AllocVec(256, MEMF_CHIP | MEMF_CLEAR);
    if (!wave) { out("no chip RAM\n"); goto done; }

    timer_up();

    /* Several variants in one run. The measured duration reveals whether the
     * period is taken over at all: it has to change proportionally with the
     * period. If it does not, the device ignores
     * ioa_Period - and then the pitch is never right. */
    for (i = 0; i < 5; i++) {
        static const UWORD per[5] = { 320, 160, 640, 254, 124 };
        static const UWORD len[5] = { 256,  64,  64,  32,  32 };
        static const UWORD vol[5] = {  64,  64,  64,  64,  32 };
        UWORD  p = per[i], l = len[i], v = vol[i];
        ULONG  cyc, k;
        long   ms;

        for (k = 0; k < l; k++) wave[k] = (k < (ULONG)(l / 2)) ? 100 : -100;

        /* about 1.5 seconds per variant */
        cyc = (ULONG)((3546895UL / p) * 3UL / 2UL) / l;
        if (!cyc) cyc = 1;

        io->ioa_Request.io_Command = CMD_WRITE;
        io->ioa_Request.io_Flags   = ADIOF_PERVOL;
        io->ioa_Request.io_Error   = 0;
        io->ioa_Data    = (UBYTE *)wave;
        io->ioa_Length  = l;
        io->ioa_Period  = p;
        io->ioa_Volume  = v;
        io->ioa_Cycles  = (UWORD)cyc;

        outnum("--- Variante, Periode ", (long)p);
        outnum("      Wellenlaenge ", (long)l);
        outnum("      Lautstaerke  ", (long)v);
        outnum("      Grundton Hz  ", (long)(3546895L / p / l));

        t0 = ticks();
        SendIO((struct IORequest *)io);
        WaitIO((struct IORequest *)io);
        t1 = ticks();
        ms = efreq ? (long)((t1 - t0) / (efreq / 1000)) : -1;
        outnum("      io_Error     ", (long)io->ioa_Request.io_Error);
        outnum("      gedauert ms  ", ms);
        outnum("      erwartet ms  ", (long)((long)cyc * l * 1000L / (3546895L / p)));
    }

    timer_down();

    FreeVec(wave);
done:
    CloseDevice((struct IORequest *)io);
    DeleteIORequest((struct IORequest *)io);
    DeleteMsgPort(port);
    return 0;
}
