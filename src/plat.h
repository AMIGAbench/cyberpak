/* plat.h - the thin layer between the host and the Amiga build.
 * Alles darunter (Codecs, yuv.c) bleibt plattformfrei. */
#ifndef CYBERPAK_PLAT_H
#define CYBERPAK_PLAT_H

#include <stdint.h>

#ifdef __m68k__

void plat_puts(const char *s);

/* Read the CACR without changing anything. On 68020/030 the 256-byte
 * instruction cache makes a noticeable difference; with it off one measures a
 * anderen Ziel als angenommen. */
uint32_t plat_cache_state(void);
/* Switch the caches on, return the old state. Not done automatically. */
uint32_t plat_cache_enable(void);
void     plat_cache_restore(uint32_t prev);
/* Does the CPU have caches at all? The 68000 and 68010 do not. */
int      plat_has_caches(void);
/* Switch the serial output off. On real hardware KPutStr costs about 1 ms per
 * character at 9600 baud - irrelevant for the measurement (which brackets only
 * the decoder), but wall clock time all the same. The shell output stays. */
void plat_serial(int on);

/* Chip RAM. The blitter reaches nothing else; the test programs therefore
 * needed it for the blitter version of C2P. On the host NULL - there is
 * neither chip RAM nor a blitter there. */
void *plat_alloc_chip(uint32_t size);
void  plat_free_chip(void *p, uint32_t size);
#  define PLAT_PUTS(s) plat_puts(s)

#else
#  include <stdio.h>
#  define PLAT_PUTS(s) fputs((s), stdout)
   /* On the host there is no serial channel - the switch is a no-op, so that
    * the test programs build natively without a change. */
   /* On the host there is neither a serial channel nor a CACR. The stubs are
    * deliberately marked as unused - not every test program calls them. */
#  if defined(__GNUC__)
#    define CVX_MAYBE_UNUSED __attribute__((unused))
#  else
#    define CVX_MAYBE_UNUSED
#  endif
   CVX_MAYBE_UNUSED static void plat_serial(int on) { (void)on; }
   CVX_MAYBE_UNUSED static void *plat_alloc_chip(uint32_t size)
       { (void)size; return 0; }
   CVX_MAYBE_UNUSED static void plat_free_chip(void *p, uint32_t size)
       { (void)p; (void)size; }
   CVX_MAYBE_UNUSED static uint32_t plat_cache_state(void) { return 0; }
   CVX_MAYBE_UNUSED static uint32_t plat_cache_enable(void) { return 0; }
   CVX_MAYBE_UNUSED static void plat_cache_restore(uint32_t p) { (void)p; }
   CVX_MAYBE_UNUSED static int plat_has_caches(void) { return 0; }
#endif

#endif
