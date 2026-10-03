#include "timing.h"

#ifdef __m68k__
#include <exec/types.h>
#include <exec/io.h>
#include <devices/timer.h>
#include <proto/exec.h>
#include <proto/timer.h>

/* timer.device UNIT_ECLOCK: the same time base the original used for
 * synchronisation and statistics (CyberAVISync.mod). */
static struct MsgPort     *tport;
static struct timerequest *treq;
static uint32_t            efreq;
struct Device *TimerBase;

int timing_open(void)
{
    struct EClockVal ev;
    tport = CreateMsgPort();
    if (!tport) return 0;
    treq = (struct timerequest *)CreateIORequest(tport, sizeof(*treq));
    if (!treq) return 0;
    if (OpenDevice((CONST_STRPTR)TIMERNAME, UNIT_ECLOCK,
                   (struct IORequest *)treq, 0) != 0) return 0;
    TimerBase = treq->tr_node.io_Device;
    efreq = ReadEClock(&ev);
    return 1;
}

void timing_close(void)
{
    if (treq) {
        if (TimerBase) { CloseDevice((struct IORequest *)treq); }
        DeleteIORequest((struct IORequest *)treq);
        treq = NULL;
    }
    if (tport) { DeleteMsgPort(tport); tport = NULL; }
}

uint64_t timing_now(void)
{
    struct EClockVal ev;
    ReadEClock(&ev);
    return ((uint64_t)ev.ev_hi << 32) | (uint32_t)ev.ev_lo;
}

uint32_t timing_freq(void) { return efreq; }

#else
#include <time.h>
int      timing_open(void)  { return 1; }
void     timing_close(void) { }
uint64_t timing_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)(ts.tv_nsec / 1000);
}
uint32_t timing_freq(void) { return 1000000u; }
#endif
