/* audio.h - sound output, two paths: audio.device (Paula) and ahi.device.
 *
 * PAULA is the default. Our material is 8-bit PCM at 22 kHz - exactly what
 * Paula can do natively, and audio.device is present on every Amiga from the
 * 68000 on, without any third-party software.
 *
 * AHI is the second path, requested with the option AHI. It pays off where
 * Paula is the limit and not the medium: 16 bit instead of 8, any sample rate
 * instead of Paula's integer periods (so no rate deviation at all), and the
 * sound of a card or of SAGA instead of the chipset. It is never chosen by
 * itself - if ahi.device is missing, the call fails with a reason instead of
 * quietly falling back (see CLIENT-PARAMETER.md).
 *
 * What both paths share is the part that makes the sound the clock: the ring
 * in fast RAM, the buffer chain whose completions are counted, and
 * audio_played_samples(). The differences are the buffer format (Paula wants
 * one 8-bit buffer per channel in chip RAM, AHI one interleaved buffer in any
 * RAM) and how the next buffer is announced (Paula: one request per channel,
 * AHI: ahir_Link to the request sent before it).
 *
 * The Paula path is ported after the pattern of CyberAVIAudio.mod: double
 * buffers in chip RAM, separately for left and right.
 */
#ifndef CYBERPAK_AUDIO_H
#define CYBERPAK_AUDIO_H

#include <stdint.h>

#define AUDIO_ERR_DEVICE   -1   /* audio.device/channels not obtained  */
#define AUDIO_ERR_FORMAT   -2   /* format is not supported             */
#define AUDIO_ERR_MEMORY   -3   /* no memory for buffers or ring       */
#define AUDIO_ERR_AHI      -4   /* ahi.device not obtained             */

/* Which output path. PAULA is the default; AHI has to be asked for, and if it
 * is not there audio_open() returns AUDIO_ERR_AHI instead of using Paula. Set
 * it BEFORE audio_open(); `unit` is the ahi.device unit (0 = the user's
 * preferred one). */
#define AUDIO_WEG_PAULA  0
#define AUDIO_WEG_AHI    1
void     audio_config_weg(int weg, uint32_t unit);
int      audio_weg(void);        /* AUDIO_WEG_* actually in use */
uint32_t audio_ahi_unit(void);

/* rate in Hz, channels 1 or 2, bits 8 or 16. On the Paula path 16 bit is
 * reduced to 8 - Paula cannot do more; the AHI path plays 16 bit as it is. */
/* Set the buffer geometry BEFORE audio_open(): a_bufsz = rate/bufdiv, nbuf
 * pieces. Default 32 and 16 (31 ms per buffer, 0.5 s in reserve). Adjustable,
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
 * the ring in fast RAM does not count (what lies there the device has never
 * seen), and on an underrun the value stands still instead of running on -
 * the picture then waits along by itself. The resolution is one buffer, see
 * NBUF in audio.c; in between it is interpolated. */
uint32_t audio_played_samples(void);

/* Diagnostics: channel mask taken (Paula) or AHI unit, samples fed in,
 * buffers sent. */
uint32_t audio_dbg_mask(void);
uint32_t audio_dbg_samples(void);
uint32_t audio_dbg_sent(void);
int32_t  audio_dbg_error(void);
uint32_t audio_dbg_blocked(void);
uint32_t audio_dbg_lost(void);   /* samples discarded, the ring was full */
uint32_t audio_dbg_under(void);  /* underruns: the device ran dry        */
uint32_t audio_dbg_minpend(void);/* lowest fill level of the buffer chain */
uint32_t audio_dbg_maxring(void);/* largest backlog in the fast RAM ring */
/* CheckIO calls performed - evidence for the note in buf_done(). */
uint32_t audio_dbg_checkio(void);
uint32_t audio_dbg_bufsz(void);
uint32_t audio_dbg_nbuf(void);

/* Actual playback rate. Paula can only do integer periods, so the requested
 * rate is never hit exactly - the difference is direct A/V drift and therefore
 * deserves to be made visible. On the AHI path the rate is passed on as it is,
 * so it equals the requested one and audio_period() is 0. */
uint32_t audio_eff_rate(void);
uint32_t audio_period(void);
uint32_t audio_clock(void);

/* 1 s of square wave through the same output chain - for narrowing things down. */
void     audio_testtone(void);

#endif
