# CyberPak

A Cinepak player for 68k Amigas — from the 68000 up to the 68080. It plays CPKS
streams (Cinepak in a lean streaming container) with sound through Paula and
puts the picture either on a graphics card or straight into the bitplanes of a
chipset screen.

CyberPak is a reimplementation of **CyberAVI** (1996–1997, Thore Böckelmann);
its origin and the terms that follow from it are in [LICENSE](LICENSE).


## What it does

| Build | Output |
|---|---|
| `CyberPak.000` | 68000, ECS: HAM6 (320 pixels, 4096 colours) and GRAY with 5 planes — pure assembler |
| `CyberPak.020`, `.030` | one byte-identical assembler binary: graphics card (32 bit, 15/16 bit through Picasso96), otherwise AGA with DHAM8 or DHAM6, ECS with HAM6, plus GRAY |
| `CyberPak.040`, `.060`, `.080` | the same modes as a C build; the chipset path uses the very same assembler modules as the 020 player |

Principles that explain how it is built:

* **Audio is the master clock.** The audio output must never drop out. If there
  is not enough time to compute, the picture skips — never the sound. The
  playback position follows the samples Paula has actually played, not a timer.
* **Straight into the bitplanes where it pays off.** Which way is faster —
  decoding directly, or into a chunky buffer first and then converting with a
  CPU chunky-to-planar routine — was measured on real hardware and decided per
  build: `.000`, `.020` and `.030` write directly, `.040` and `.060` likewise
  (only GRAY goes through C2P), `.080` converts everything through C2P, because
  there the chip bus is the bottleneck.
* **HAM levels are rounded**, not truncated.


## Usage

```
CyberPak.020 <file.cpks> [HAM6|DHAM6|DHAM8|GRAY|HICOLOR] [STATS] [NOAUDIO] [NOVIDEO] ...
```

Without a mode the player picks one itself: graphics card, otherwise AGA,
otherwise ECS.

| Mode | Meaning |
|---|---|
| *none given* | graphics card (32 bit), otherwise AGA with DHAM8, otherwise ECS with HAM6 |
| `HICOLOR` | graphics card with 15/16 bit through Picasso96 |
| `DHAM8`, `DHAM6` | AGA, 640 pixels, HAM with 8 respectively 6 bitplanes |
| `HAM6` | 320 pixels, runs on ECS as well |
| `GRAY` | greyscale, 8 bitplanes on AGA, 5 on ECS |

Further options: `STATS` (breakdown of the time spent, printed at the end),
`QUIET`, `NOAUDIO`, `NOVIDEO`, `ABUF=`/`ANUM=` (audio buffers), `READ=` (KB per
read) and `BENCH=n` (measuring run over n frames, without clock and sound; 68020
and up only).


## Thanks

* **Thore Böckelmann** for CyberAVI, the model this player follows.
* **Mikael Kalms** for the chunky-to-planar routines (public domain).
* **Mark Podlipec** for XAnim, whose licence notice is preserved in
  [LICENSE](LICENSE).
