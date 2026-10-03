/* plat.c - text output of the test programs on the Amiga.
 *
 * Geht bewusst auf BEIDE Kanaele:
 *
 *  - the shell (dos.library Write on Output()), so that the numbers can be
 *    echter Hardware ueberhaupt sieht;
 *  - the serial line (KPutStr), because the FS-UAE harness reads it through
 *    serial_port=tcp:// and evaluates the [OK]/[FAIL] marks from it.
 *
 * Without the first channel there was simply nothing to see on real hardware -
 * the programs were usable in the emulator only.
 *
 * Write() instead of printf on purpose: that keeps stdio out of the test
 * binaries. Started from the Workbench there is no Output(), then only serial.
 */
#ifdef __m68k__

#include <clib/debug_protos.h>
#include <exec/execbase.h>
#include <proto/dos.h>
#include <exec/memory.h>
#include <proto/exec.h>
#include "plat.h"

static int g_serial = 1;

void plat_serial(int on) { g_serial = on; }

void plat_puts(const char *s)
{
    const char *p = s;
    long n = 0;
    BPTR out;

    while (*p++) n++;

    out = Output();
    if (out) Write(out, (CONST APTR)s, n);

    if (g_serial) KPutStr((CONST_STRPTR)s);
}

/* --- Chip-RAM ----------------------------------------------------------
 *
 * The blitter can only read and write chip RAM. Whoever hands it a buffer has
 * to take it from there - MEMF_CHIP is not a recommendation but a condition.
 * On a machine with fast RAM an ordinary AllocMem() would land there instead,
 * and the blitter would read rubbish. */
void *plat_alloc_chip(uint32_t size)
{
    return AllocMem(size, MEMF_CHIP);
}

void plat_free_chip(void *p, uint32_t size)
{
    if (p) FreeMem(p, size);
}

/* --- Cachezustand ------------------------------------------------------
 *
 * On 68020/030 the instruction cache has its say in how expensive the block
 * loop of the decoder is: it is 256 bytes, and whatever goes beyond that is
 * fetched from the bus again on every iteration. The 68030 data cache and the
 * burst mode are switched off on some accelerator cards, because they caused
 * trouble there in the past.
 *
 * Normally SetPatch sets this at boot time - but that is not guaranteed.
 * Without this query one may be measuring against a target one does not know
 * at all, and credit or discredit an optimisation that in truth depends on
 * Cache lag.
 *
 * CacheControl(0,0) only reads, it changes nothing. */
uint32_t plat_cache_state(void)
{
    return (uint32_t)CacheControl(0, 0);
}

/* Switch the caches on and return the previous state, so that the caller can
 * restore it at the end. Deliberately NOT automatic: if a machine is set up
 * that way, there is usually a reason. */
uint32_t plat_cache_enable(void)
{
    const ULONG want = CACRF_EnableI | CACRF_EnableD | CACRF_IBE | CACRF_DBE;
    return (uint32_t)CacheControl(want, want);
}

void plat_cache_restore(uint32_t prev)
{
    CacheControl((ULONG)prev, 0xFFFFFFFFul);
}

/* The 68000 and 68010 have no cache; CacheControl() returns 0 there. A hint
 * "caches off - CACHE switches them on" would be wrong there - on an A600 with
 * a 68000 it cost a test run that could not change anything.
 * AFF_68020 is set by exec for every CPU from the 68020 on, including 030 to 080. */
int plat_has_caches(void)
{
    return (SysBase->AttnFlags & AFF_68020) != 0;
}

#endif
