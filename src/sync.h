/* sync.h - the frame clock.
 *
 * Ported from CyberAVISync.mod. The trick there is the drift-free time base:
 * timer.device UNIT_WAITECLOCK gets an ABSOLUTE target time, and `nextTime` is
 * raised by the frame period for every frame. Rounding errors therefore do not
 * add up, unlike waiting for a difference.
 *
 * The second trick: when a frame is skipped the target time is NOT set anew.
 * The request then returns at once (the time is long gone) while `nextTime`
 * keeps running all the same - that is how the player catches up without a
 * special case.
 */
#ifndef CYBERPAK_SYNC_H
#define CYBERPAK_SYNC_H

#include <stdint.h>

int      sync_open(uint32_t micros_per_frame);
void     sync_close(void);

void     sync_start(void);              /* Nullpunkt setzen           */
uint32_t sync_sigmask(void);            /* for Wait()                 */
void     sync_arm(int skipping);        /* naechsten Frame anfordern  */
/* Anchor the deadline anew instead of collecting a backlog. Only for paths in
 * which the timer is a mere heartbeat (CPKS) - in the AVI path that would be
 * Aufholen gewollt. Siehe sync.c. */
void     sync_resync(void);
void     sync_consume(void);            /* Antwort abholen            */

/* Are we behind the plan? The basis of the skip decision. */
int      sync_is_behind(void);

/* Backlog against the schedule in ms, negative = ahead. */
int32_t  sync_lag_ms(void);

uint32_t sync_elapsed_ms(void);         /* since sync_start()         */
void     sync_set_frame_time(uint32_t micros_per_frame);

#endif
