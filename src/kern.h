/* kern.h - the chipset path of the C builds from the 68040 on.
 *
 * HAM6, DHAM6, DHAM8 and GRAY run through the assembler modules of the
 * 020/030 player (src/a020/cvid.s, screen.s), the very ones the test bench and
 * the emulator check. The C names come from src/asm/kern_glue.s. Which modes
 * go through a chunky buffer (kern_chunky) and CPU C2P (kern_planes_wandeln)
 * is fixed by the build (measurement direct against C2P on real hardware):
 * 68040/68060 GRAY, 68080 also HAM6/DHAM6/DHAM8; everything else straight into
 * the planes. Single buffered, own BitMap. */
#ifndef CYBERPAK_KERN_H
#define CYBERPAK_KERN_H

#include <stdint.h>

/* Modes as in src/a020/player.i */
#define KERN_GRAY5   1u   /* ECS: 5 Planes, 32 Graustufen      */
#define KERN_HAM6    2u   /* HAM6 single width (ECS and AGA)   */
#define KERN_GRAY8   3u   /* AGA: 8 Planes, 256 Graustufen     */
#define KERN_DHAM6   4u   /* AGA, doppelt breit                */
#define KERN_DHAM8   5u   /* AGA, doppelt breit                */

/* Errors from kern_screen_open (SC_E_* in player.i) */
#define KERN_SC_LIB      1u
#define KERN_SC_MODUS    2u
#define KERN_SC_TIEFE    3u
#define KERN_SC_SCHIRM   4u
#define KERN_SC_BITMAP   5u
#define KERN_SC_FENSTER  6u
#define KERN_SC_ECS      7u
#define KERN_SC_SETPATCH 8u

#ifdef __m68k__
/* 0 = good; sets the AGA detection and the nominal height, opens graphics/intuition. */
uint32_t kern_anzeige_erkennen(void);
uint32_t kern_aga(void);       /* AGA chip AND AGA depths in the database   */
uint32_t kern_aachip(void);    /* AGA chip (even without SetPatch)         */
uint32_t kern_nominal(void);   /* Schirmhoehe: 256 PAL, 200 NTSC           */
uint32_t kern_chunky(void);    /* C2P modes: chunky buffer, otherwise 0    */
uint32_t kern_modeid(void);

/* Planes (and for C2P modes the chunky buffer) -> address of plane 0, 0 = no chip RAM */
uint32_t kern_planes_open(uint32_t modus asm("d0"), uint32_t hoehe asm("d1"));
void     kern_planes_close(void);
void     kern_planes_wandeln(void);

/* 0 good, 1 geometry (320 wide, at most the screen height), 2 memory */
uint32_t kern_cvid_open(uint32_t modus asm("d0"), uint8_t *ziel asm("a0"),
                        uint32_t breite asm("d1"), uint32_t hoehe asm("d2"),
                        uint32_t schirmhoehe asm("d3"));
uint32_t kern_cvid_decode(const uint8_t *bild asm("a0"), uint32_t laenge asm("d0"),
                          uint32_t pts asm("d1"));
void     kern_cvid_close(void);

/* 0 gut, sonst KERN_SC_* */
uint32_t kern_screen_open(uint32_t modus asm("d0"));
void     kern_screen_close(void);
uint32_t kern_screen_input(void);    /* 0 nichts, 1 beenden, 2 Pause */
uint32_t kern_screen_sigmask(void);
#endif

#endif
