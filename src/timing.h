/* timing.h - EClock-Zeitbasis, portiert aus CyberAVISync.mod:142-151.
 * On the host a stub, so that the same measuring loop builds everywhere. */
#ifndef CYBERPAK_TIMING_H
#define CYBERPAK_TIMING_H
#include <stdint.h>

int      timing_open(void);
void     timing_close(void);
uint64_t timing_now(void);        /* EClock-Ticks bzw. Mikrosekunden */
uint32_t timing_freq(void);       /* ticks per second                */
#endif
