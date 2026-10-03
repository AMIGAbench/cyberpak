#include "sync.h"

#ifdef __m68k__

#include <exec/types.h>
#include <exec/io.h>
#include <exec/memory.h>
#include <devices/timer.h>
#include <proto/exec.h>
#include <proto/timer.h>

/* TimerBase is the library base for ReadEClock(). timing.c sets it as well, but
 * only once timing_open() has run - and the player does not call that. If
 * ReadEClock() is called with TimerBase == NULL, the call jumps into nowhere
 * and the SYSTEM FREEZES. sync_open() therefore sets the base itself as soon as
 * OpenDevice has succeeded. Both units (UNIT_ECLOCK and UNIT_WAITECLOCK) belong
 * to the same device, so the base is the same.
 */
extern struct Device *TimerBase;

static struct MsgPort     *sport;
static struct timerequest *sreq;
static int                 sopen;
static int                 spending;

static uint64_t s_freq;        /* EClock ticks per second   */
static uint64_t s_frame;       /* Frameperiode in Ticks     */
static uint64_t s_next;        /* absolute Zielzeit         */
static uint64_t s_start;

static uint64_t eclock_now(void)
{
    struct EClockVal ev;
    if (!TimerBase) return 0;          /* defensive: never jump through NULL */
    ReadEClock(&ev);
    return ((uint64_t)ev.ev_hi << 32) | (uint32_t)ev.ev_lo;
}

static void set_time(uint64_t t)
{
    /* With UNIT_WAITECLOCK tv_secs/tv_micro carry the 64-bit EClock value. */
    sreq->tr_time.tv_secs  = (ULONG)(t >> 32);
    sreq->tr_time.tv_micro = (ULONG)(t & 0xffffffffu);
}

int sync_open(uint32_t micros_per_frame)
{
    struct EClockVal ev;

    sport = CreateMsgPort();
    if (!sport) return 0;
    sreq = (struct timerequest *)CreateIORequest(sport, sizeof(*sreq));
    if (!sreq) { DeleteMsgPort(sport); sport = NULL; return 0; }
    if (OpenDevice((CONST_STRPTR)TIMERNAME, UNIT_WAITECLOCK,
                   (struct IORequest *)sreq, 0) != 0) {
        DeleteIORequest((struct IORequest *)sreq); sreq = NULL;
        DeleteMsgPort(sport); sport = NULL;
        return 0;
    }
    sopen = 1;
    sreq->tr_node.io_Command = TR_ADDREQUEST;

    /* MUST be in place before the first ReadEClock() - see the comment above. */
    TimerBase = sreq->tr_node.io_Device;

    s_freq = ReadEClock(&ev);
    if (!s_freq) s_freq = 709379;   /* PAL fallback, should the device act up */
    sync_set_frame_time(micros_per_frame);
    return 1;
}

void sync_set_frame_time(uint32_t micros_per_frame)
{
    if (!micros_per_frame) micros_per_frame = 40000;   /* 25 fps */
    s_frame = (s_freq * micros_per_frame) / 1000000u;
    if (!s_frame) s_frame = 1;
}

void sync_close(void)
{
    if (spending) {
        AbortIO((struct IORequest *)sreq);
        WaitIO((struct IORequest *)sreq);
        spending = 0;
    }
    if (sopen)  { CloseDevice((struct IORequest *)sreq); sopen = 0; TimerBase = NULL; }
    if (sreq)   { DeleteIORequest((struct IORequest *)sreq); sreq = NULL; }
    if (sport)  { DeleteMsgPort(sport); sport = NULL; }
}

void sync_start(void)
{
    s_start    = eclock_now();
    s_next     = s_start;
}

uint32_t sync_sigmask(void)
{
    return sport ? (1UL << sport->mp_SigBit) : 0;
}

/* Do not leave the deadline in the past.
 *
 * sync_arm() pushes s_next on by one period stubbornly and never compares it
 * against the wall clock. In the AVI path that is exactly right: there the
 * timer IS the time base, and a backlog has to be caught up.
 *
 * In the CPKS path, by contrast, the sound sets the clock and the timer is only
 * a heartbeat. If it falls behind - starting over the network, prebuffering
 * takes seconds instead of milliseconds - the deadline afterwards lies far in
 * the past, every request returns at once, and the loop spins at full speed
 * until it has caught up. Measured on real hardware: 100 % CPU for the first
 * seconds, normal afterwards.
 *
 * This function anchors the deadline anew instead of collecting the backlog.
 * It belongs ONLY in the CPKS path. */
void sync_resync(void)
{
    uint64_t now = eclock_now();
    if (s_next < now) s_next = now;
}

void sync_arm(int skipping)
{
    s_next += s_frame;
    /* When skipping, leave the old - long expired - time standing, then the
     * request returns at once. */
    if (!skipping) set_time(s_next);
    SendIO((struct IORequest *)sreq);
    spending = 1;
}

void sync_consume(void)
{
    if (spending) { WaitIO((struct IORequest *)sreq); spending = 0; }
}

int sync_is_behind(void)
{
    uint64_t now = eclock_now();

    /* We are behind when the TARGET time of the next frame already lies more
     * than one frame period in the past.
     *
     * s_next is the absolute target time and grows by exactly s_frame per
     * frame - so it is the schedule. The deviation from the clock is the
     * backlog itself. That can be followed and checked.
     *
     * Its predecessor was a port of the original's IsSync() logic with a
     * one-second grid (`syncTime`). In practice that never triggered:
     * measured, the player ran 4 % too slow and skipped no frame at all. The
     * logic there is also commented in a contradictory way - a clear
     * formulation of our own is worth more here than textual fidelity to the
     * original. */
    if (now <= s_next) return 0;
    return (now - s_next) > s_frame;
}

/* Backlog against the schedule, in milliseconds. Negative = ahead. */
int32_t sync_lag_ms(void)
{
    uint64_t now = eclock_now();
    if (!s_freq) return 0;
    if (now >= s_next) return  (int32_t)(((now - s_next) * 1000u) / s_freq);
    return -(int32_t)(((s_next - now) * 1000u) / s_freq);
}

uint32_t sync_elapsed_ms(void)
{
    uint64_t d = eclock_now() - s_start;
    return s_freq ? (uint32_t)((d * 1000u) / s_freq) : 0;
}

#else  /* host stubs, so that the player compiles natively as well */

int      sync_open(uint32_t m)     { (void)m; return 1; }
void     sync_close(void)          { }
void     sync_start(void)          { }
uint32_t sync_sigmask(void)        { return 0; }
void     sync_arm(int s)           { (void)s; }
void     sync_consume(void)        { }
int      sync_is_behind(void)      { return 0; }
uint32_t sync_elapsed_ms(void)     { return 0; }
void     sync_set_frame_time(uint32_t m) { (void)m; }
int32_t  sync_lag_ms(void)         { return 0; }

#endif
