/* beep2 - four variants of addressing the device, compared.
 *
 * All play the same tone (period 254, 32 samples -> 436 Hz, ~1.5 s).
 * What differs is ONLY how the request to audio.device is made.
 * The measured duration reveals which variant drives the device correctly:
 * with a correct period it has to be about 1500 ms.
 */
#include <exec/types.h>
#include <exec/memory.h>
#include <devices/audio.h>
#include <devices/timer.h>
#include <proto/exec.h>
#include <proto/dos.h>
#include <proto/timer.h>
#include <clib/debug_protos.h>

static void out(const char *s)
{
    long n = 0; const char *p = s; BPTR o;
    while (*p++) n++;
    o = Output(); if (o) Write(o, (CONST APTR)s, n);
    KPutStr((CONST_STRPTR)s);
}
static void outnum(const char *label, long v)
{
    char b[80], *p = b; const char *l = label; char t[12]; int n = 0;
    while (*l) *p++ = *l++;
    if (v < 0) { *p++ = '-'; v = -v; }
    do { t[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (n) *p++ = t[--n];
    *p++ = '\n'; *p = 0; out(b);
}

struct Device *TimerBase;
static struct MsgPort *tport; static struct timerequest *treq; static ULONG efreq;
static ULONG ticks(void){ struct EClockVal e; if(!TimerBase) return 0; ReadEClock(&e); return e.ev_lo; }
static void timer_up(void){ struct EClockVal e;
    tport=CreateMsgPort(); if(!tport) return;
    treq=(struct timerequest*)CreateIORequest(tport,sizeof(*treq)); if(!treq) return;
    if(OpenDevice((CONST_STRPTR)TIMERNAME,UNIT_ECLOCK,(struct IORequest*)treq,0)) return;
    TimerBase=treq->tr_node.io_Device; efreq=ReadEClock(&e); }
static void timer_down(void){ if(TimerBase){CloseDevice((struct IORequest*)treq);TimerBase=NULL;}
    if(treq)DeleteIORequest((struct IORequest*)treq); if(tport)DeleteMsgPort(tport); }

static UBYTE anychannel[] = { 1, 2, 4, 8 };

#define PER 254
#define LEN 32

int main(void)
{
    struct MsgPort *port;
    struct IOAudio *alloc, *w;
    BYTE *wave;
    int i, k;
    ULONG t0, t1, cyc;

    port = CreateMsgPort();
    alloc = (struct IOAudio *)CreateIORequest(port, sizeof(struct IOAudio));
    if (!port || !alloc) { out("kein Port/Request\n"); return 20; }

    alloc->ioa_Request.io_Message.mn_Node.ln_Pri = 10;
    alloc->ioa_Data = anychannel; alloc->ioa_Length = sizeof(anychannel);
    if (OpenDevice((CONST_STRPTR)"audio.device", 0, (struct IORequest *)alloc, 0)) {
        out("audio.device liess sich nicht oeffnen\n"); return 20;
    }
    outnum("belegte Kanalmaske: ", (long)(ULONG)alloc->ioa_Request.io_Unit);
    outnum("ioa_AllocKey:       ", (long)alloc->ioa_AllocKey);

    wave = (BYTE *)AllocVec(LEN, MEMF_CHIP | MEMF_CLEAR);
    if (!wave) { out("kein Chip-RAM\n"); goto done; }
    for (k = 0; k < LEN; k++) wave[k] = (k < LEN/2) ? 100 : -100;

    cyc = ((3546895UL / PER) * 3UL / 2UL) / LEN;
    timer_up();

    for (i = 0; i < 4; i++) {
        struct IOAudio *r;

        switch (i) {
        case 0: out("--- A: dieselbe Struktur wie fuer die Belegung\n"); r = alloc; break;
        case 1: out("--- B: eigene Struktur, Kopie der Belegung (laut Spezifikation)\n");
                w = (struct IOAudio *)AllocVec(sizeof(struct IOAudio), MEMF_ANY|MEMF_CLEAR);
                *w = *alloc; w->ioa_Request.io_Message.mn_ReplyPort = port; r = w; break;
        case 2: out("--- C: wie B, aber Periode/Lautstaerke vorher per ADCMD_PERVOL\n"); r = w; break;
        case 3: out("--- D: wie B, aber DoIO statt SendIO/WaitIO\n"); r = w; break;
        default: r = alloc;
        }

        if (i == 2) {
            r->ioa_Request.io_Command = ADCMD_PERVOL;
            r->ioa_Request.io_Flags   = 0;
            r->ioa_Period = PER; r->ioa_Volume = 64;
            DoIO((struct IORequest *)r);
            outnum("      ADCMD_PERVOL io_Error ", (long)r->ioa_Request.io_Error);
        }

        r->ioa_Request.io_Command = CMD_WRITE;
        r->ioa_Request.io_Flags   = ADIOF_PERVOL;
        r->ioa_Request.io_Error   = 0;
        r->ioa_Data   = (UBYTE *)wave;
        r->ioa_Length = LEN;
        r->ioa_Period = PER;
        r->ioa_Volume = 64;
        r->ioa_Cycles = (UWORD)cyc;

        t0 = ticks();
        if (i == 3) DoIO((struct IORequest *)r);
        else { SendIO((struct IORequest *)r); WaitIO((struct IORequest *)r); }
        t1 = ticks();
        outnum("      io_Error    ", (long)r->ioa_Request.io_Error);
        outnum("      gedauert ms ", efreq ? (long)((t1-t0)/(efreq/1000)) : -1);
        out("      erwartet ms 1500\n");
    }

    timer_down();
    if (w) FreeVec(w);
    FreeVec(wave);
done:
    CloseDevice((struct IORequest *)alloc);
    DeleteIORequest((struct IORequest *)alloc);
    DeleteMsgPort(port);
    return 0;
}
