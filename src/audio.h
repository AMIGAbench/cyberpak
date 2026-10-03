/* audio.h - sound output through audio.device (Paula).
 *
 * Why audio.device and not AHI: our material is 8-bit PCM at 22 kHz - exactly
 * what Paula can do natively. audio.device is present on every Amiga from the
 * 68000 on and needs no third-party software. AHI would only pay off at 16
 * bit, higher rates or SAGA audio, and could then be put beside this one
 * as a second path.
 *
 * Ported after the pattern of CyberAVIAudio.mod: double buffers in chip RAM,
 * separately for left and right.
 */
#ifndef CYBERPAK_AUDIO_H
#define CYBERPAK_AUDIO_H

#include <stdint.h>

#define AUDIO_ERR_DEVICE   -1   /* audio.device/channels not obtained  */
#define AUDIO_ERR_FORMAT   -2   /* format is not supported             */
#define AUDIO_ERR_MEMORY   -3   /* no chip RAM                         */

/* rate in Hz, channels 1 or 2, bits 8 or 16 (16 is reduced to 8 - Paula
 * cannot do more). */
/* Puffergeometrie VOR audio_open() setzen: a_bufsz = rate/bufdiv, nbuf
 * piece. Default 32 and 16 (31 ms per buffer, 0.5 s in reserve). Adjustable,
 * so that the old and the new layout can be compared in the same binary -
 * without that every statement about it stays a guess. */
void audio_config(uint32_t bufdiv, uint32_t nbuf);

int  audio_open(uint32_t rate, uint32_t channels, uint32_t bits);
void audio_close(void);

/* Feed interleaved PCM data from the AVI in. NEVER blocks - the data lands in
 * a ring in fast RAM. */
void audio_write(const uint8_t *pcm, uint32_t bytes);

/* Pushes from the ring into free chip buffers. Call it regularly, once per
 * video frame is enough. Never blocks either. */
void audio_service(void);

/* End of stream: no more sound is coming. From now on the short remainder
 * (less than one buffer) goes right behind the buffers already running instead
 * of waiting for an empty Paula - otherwise a gap would open before it. */
void audio_ende(void);

/* Requested rate after any limiting (Paula/DMA). */
uint32_t audio_rate(void);

/* Playback position in samples: sent MINUS what is still inside Paula.
 *
 * This is the clock of the CPKS path. Two properties are essential for that:
 * the ring in fast RAM does not count (what lies there Paula has never seen),
 * and on an underrun the value stands still instead of running on - the
 * picture then waits along by itself. The resolution is one chip buffer,
 * siehe NBUF in audio.c. */
uint32_t audio_played_samples(void);

/* Diagnostics: channel mask taken, samples fed in, buffers sent. */
uint32_t audio_dbg_mask(void);
uint32_t audio_dbg_samples(void);
uint32_t audio_dbg_sent(void);
int32_t  audio_dbg_error(void);
uint32_t audio_dbg_blocked(void);
uint32_t audio_dbg_lost(void);   /* samples discarded, the ring was full */
uint32_t audio_dbg_under(void);  /* Unterdeckungen: Paula lief leer      */
uint32_t audio_dbg_minpend(void);/* lowest fill level of the chip chain  */
uint32_t audio_dbg_maxring(void);/* groesster Rueckstau im Fast-RAM-Ring */
/* CheckIO calls performed - evidence for the note in buf_done(). */
uint32_t audio_dbg_checkio(void);
uint32_t audio_dbg_bufsz(void);
uint32_t audio_dbg_nbuf(void);

/* Actual playback rate. Paula can only do integer periods, so the requested
 * rate is never hit exactly - the difference is direct A/V drift and therefore
 * deserves to be made visible. */
uint32_t audio_eff_rate(void);
uint32_t audio_period(void);
uint32_t audio_clock(void);

/* 1 s of square wave through the same output chain - for narrowing things down. */
void     audio_testtone(void);

#endif
