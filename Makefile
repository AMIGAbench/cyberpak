# CyberPak - build matrix for 68000/68020/68030/68040/68060/68080
#
# Always invoked through tools/mk.sh (docker wrapper), e.g.
#   tools/mk.sh all6          all six Amiga targets
#   tools/mk.sh CPU=68060     a single target
# The host build runs natively:
#   make host

CPU     ?= 68020
CC      := m68k-amigaos-gcc
AS      := vasmm68k_mot

# The CPU level as a macro of its own. Do NOT use __mc680x0__ - -m68030/40/60/80
# define NO __mc68020__, and __mc68000__ is set on all six.
CPU_LEVEL_68000 := 0
CPU_LEVEL_68020 := 20
CPU_LEVEL_68030 := 30
CPU_LEVEL_68040 := 40
CPU_LEVEL_68060 := 60
CPU_LEVEL_68080 := 80
LEVEL   := $(CPU_LEVEL_$(CPU))

SUFFIX_68000 := 000
SUFFIX_68020 := 020
SUFFIX_68030 := 030
SUFFIX_68040 := 040
SUFFIX_68060 := 060
SUFFIX_68080 := 080

# VARIANT selects the build form of the decoder. All variants produce
# bit-identical output (checked on the host) and serve only to measure what
# the individual optimisations gain:
#   opt     target form: row pointers, 16-byte codebook
#   legaddr like the original: a multiplication per block
#   legcb   like the original: 80-byte codebook (isolates the cache effect)
#   legacy  both
VARIANT ?= opt
VARFLAGS_opt     :=
VARFLAGS_legaddr := -DCVID_LEGACY_ADDR=1
VARFLAGS_legcb   := -DCVID_LEGACY_CB=1
VARFLAGS_legacy  := -DCVID_LEGACY_ADDR=1 -DCVID_LEGACY_CB=1

# The optimisation level of the DECODER is adjustable separately.
#
# On the 68020/030 the code size in the hot path matters: the
# instruction cache is 256 bytes, and every fetch beside it is a
# bus cycle. `-Os` produces about 13 % less code for cvid.c than `-O2`,
# but pays for it with `movea.l dN,aX` before some stores. Which side
# wins is a QUESTION OF MEASUREMENT, not of judgement:
#
#   tools/mk.sh CPU=68030                 -> cvidbench.030 with -O2
#   tools/mk.sh CPU=68030 CVIDOPT=-Os     -> for comparison
#
# The default stays -O2 until the measurement says otherwise.
CVIDOPT ?= -O2

# NOASM=1 compiles the decoder without its assembler versions and puts the
# result into a directory of its own. That allows an A/B comparison:
# the same clip, the same machine, once with and once without assembler.
#
#   tools/mk.sh CPU=68020            -> build.m68020
#   tools/mk.sh CPU=68020 NOASM=1    -> build.m68020.noasm
#
# The hash MUST be the same in both - only the time may
# differ. That is the sharpest check there is for an
# assembler version, and it needs no stored expected values.
ifeq ($(NOASM),1)
  CVIDEXTRA := -DCVID_NO_ASM=1
endif

# NOMKCB=1 leaves out ONLY the codebook assembler, the block loops
# stay. That makes the share of the codebook build measurable on its own
# instead of deducing it from two totals.
ifeq ($(NOMKCB),1)
  CVIDEXTRA := -DCVID_NO_MKCB=1
endif

CFLAGS  := -O2 -std=gnu99 -Wall -Wextra -fomit-frame-pointer -noixemul \
           -m$(CPU) -DCPU_LEVEL=$(LEVEL) $(VARFLAGS_$(VARIANT)) -Isrc -MMD -MP
LDFLAGS := -m$(CPU) -noixemul
LDLIBS  := -ldebug


# src/avi.c and src/avistream.c are OUT: the player reads nothing but CPKS.
# The AVI header reader is still needed by the test programs, however - there
# the golden hashes are calibrated on AVI clips - and therefore hangs on
# cvidbench instead of on all targets (see AVIOBJ further down).
# 020+ rework: aga.c, vout.c, c2p.c and cvidplanar.c are gone - the
# chipset path is the assembler display of the 020/030 player (KERN_OBJS).
SRCS    := src/yuv.c src/cpks.c src/timing.c src/plat.c src/sync.c \
           src/video.c src/audio.c src/codec/cvid.c
# Kalms' C2P (public domain). Assembled for all six targets - the
# routine uses 68000-compatible instructions exclusively, but is
# scheduled for 040/060.
ASMS    := src/asm/c2p_kalms_040.s
# The block loops by hand, once for 16 bits per pixel (RTG) and once
# for 8 bits (AGA/ECS, palette and grey levels). Both share the
# loop frame in src/asm/cvid_blk_loops.i and differ only in
# the two PUT macros. From the 68020 on only: they use (bd,An,Xn.l) and
# (An,Xn.l*2), which do not exist on the 68000.
# cvid_blk8_020.s: one byte per pixel (GRAY8, chunky GRAY of the assembler display).
ASMS    += src/asm/cvid_blk_020.s src/asm/cvid_blk8_020.s src/asm/cvid_blk32_020.s

# Kalms' C2P for 5 bitplanes (GRAY on ECS). smcinit writes the plane size
# into the code at run time; the assembler display calls both routines directly.
# Codebook build for grey levels, full form. For EVERY target: the
# version does without 020 addressing modes, and it is most valuable
# precisely on the 68000 - there grey levels are the recommended choice.
ASMS    += src/asm/cvid_mkcbgray.s

ASMS    += src/asm/c2p1x1_5_c5_030.s

# The NDK includes for the assembler files (lvo/exec_lib.i in smcinit,
# the system includes of the assembler display).
ASINC   := -I/opt/ApolloCrossDev/Compilers/GCC-6.50-Patched/m68k-amigaos/ndk-include

# AMMX only in the 68080 target, and through the file list - not with #ifdef
# in the assembler, otherwise vasm tries the AMMX mnemonics against -m68020.
ifeq ($(CPU),68080)
  ASMS   += $(wildcard src/asm/*_ammx.s)
  CFLAGS += -DHAVE_AMMX=1
endif

OBJDIR  := build.m$(CPU)$(if $(KERNWEG),.kern$(KERNWEG))$(if $(filter-out opt,$(VARIANT)),.$(VARIANT))$(if $(filter-out -O2,$(CVIDOPT)),.$(subst -,,$(CVIDOPT)))$(if $(filter 1,$(NOASM)),.noasm)$(if $(filter 1,$(NOMKCB)),.nomkcb)
OBJS    := $(patsubst src/%.c,$(OBJDIR)/%.o,$(SRCS)) \
           $(patsubst src/%.s,$(OBJDIR)/%.o,$(ASMS))
# Chipset path of the C builds (src/kern.h): the assembler modules of the
# 020/030 player and their block loops, plus the C entry points.
KERN_OBJS := $(OBJDIR)/a020/cvid.o $(OBJDIR)/a020/screen.o $(OBJDIR)/a020/tabellen.o \
             $(patsubst %,$(OBJDIR)/asm/%.o,cvidp_blk000 cvidh_blk cvidp_mkcb000 cvidh_mkcb \
               cvxg8_blk cvxd6_blk cvxd8_blk cvxg8_mkcb cvxd6_mkcb cvxd8_mkcb kern_glue \
               cvxc_mkcb c2p1x1_8_c5_030_2w c2p1x1_6_c5_030_2 c2p1x1_6_c5_030_2w)
ifeq (,$(filter $(CPU),68000 68020 68030))
  OBJS  += $(KERN_OBJS)
endif
SFX     := $(SUFFIX_$(CPU))
TARGETS := $(OBJDIR)/selftest.$(SFX) $(OBJDIR)/cvidbench.$(SFX) \
           $(OBJDIR)/readbench.$(SFX) \
           $(OBJDIR)/CyberPak.$(SFX) $(OBJDIR)/beep.$(SFX) $(OBJDIR)/beep2.$(SFX) \
           $(OBJDIR)/modelist.$(SFX)

# 68000: the player is pure assembler (src/a68k) - no C, no C2P, no
# chunky paths. The C targets are dropped for this CPU; checking happens on the
# host in the test rig (tools/pruefstand/pruefe.py). main.o comes first, because
# the first code hunk is the entry point.
ifeq ($(CPU),68000)
  A68K_SRCS := src/a68k/main.s $(filter-out src/a68k/main.s,$(wildcard src/a68k/*.s))
  A68K_OBJS := $(patsubst src/a68k/%.s,$(OBJDIR)/a68k/%.o,$(A68K_SRCS)) \
               $(OBJDIR)/asm/cvidp_blk000.o $(OBJDIR)/asm/cvidh_blk.o \
               $(OBJDIR)/asm/cvidp_mkcb000.o $(OBJDIR)/asm/cvidh_mkcb.o
  TARGETS   := $(OBJDIR)/CyberPak.000 $(OBJDIR)/CyberPak.dbg
endif

# 68020 and 68030: ONE player in pure assembler (src/a020, 020+ rework), for
# both CPUs with the same flags (-m68020) - .020 and .030 are byte-identical.
# Plus the block loops of the 68000 (GRAY5, HAM6) and the new chipset modes
# (GRAY8, DHAM6, DHAM8). The C targets are dropped; checking happens in the test
# rig (tools/pruefstand/pruefe020.py) and in FS-UAE.
# According to the measurement hurdle GRAY goes through chunky + CPU C2P, RTG
# through the chunky loops of the C builds (both in assembler).
#
# WHICH CHIPSET MODE GOES THROUGH C2P was decided by the Vampire measurement
# directly against C2P (NOTES): on an 030 at 50 MHz the direct path wins
# everywhere (GRAY narrowly), on the unthrottled 68080 C2P wins on busy clips. So:
# the 020/030 player all direct, without C2P code; 040/060 GRAY through C2P
# (KERN_C2P); the 68080 additionally HAM6/DHAM6/DHAM8 (KERN_C2P_HAM: cvxc_mkcb and
# Kalms' 030_2 versions, for 640 points with the suffix w).
# KERNWEG=080 builds the 020/030 player with the 68080's choice - only for the
# test rig (pruefe020.py --exe build.m68020.kern080/CyberPak.dbg), which cannot
# run the 68080 build itself.
A020_ASM := cvidp_blk000 cvidh_blk cvidp_mkcb000 cvidh_mkcb cvxg8_blk cvxd6_blk cvxd8_blk \
            cvxg8_mkcb cvxd6_mkcb cvxd8_mkcb cvid_blk32_020 cvid_blk_020
ifneq (,$(filter $(CPU),68040 68060))
  A020FLAGS := -DKERN_C2P=1
endif
ifneq (,$(filter 68080,$(CPU))$(filter 080,$(KERNWEG)))
  A020FLAGS := -DKERN_C2P=1 -DKERN_C2P_HAM=1
endif
ifeq ($(KERNWEG),080)
  A020_ASM  += cvid_blk8_020 cvid_mkcbgray c2p_kalms_040 c2p1x1_5_c5_030 \
               cvxc_mkcb c2p1x1_8_c5_030_2w c2p1x1_6_c5_030_2 c2p1x1_6_c5_030_2w
endif
# CyberGraphX/Picasso96: lvo/cybergraphics.i lies beside the NDK (rtg.s).
A020INC  := -I/opt/ApolloCrossDev/Compilers/GCC-6.50-Patched/m68k-amigaos/include
ifneq (,$(filter $(CPU),68020 68030))
  A020_SRCS := src/a020/main.s $(filter-out src/a020/main.s,$(wildcard src/a020/*.s))
  A020_OBJS := $(patsubst src/a020/%.s,$(OBJDIR)/a020/%.o,$(A020_SRCS)) \
               $(patsubst %,$(OBJDIR)/asm/%.o,$(A020_ASM))
  TARGETS   := $(OBJDIR)/CyberPak.$(SFX) $(OBJDIR)/CyberPak.dbg
endif

# If a rule fails, its target MUST disappear. Otherwise an assembler error
# leaves the old object lying around, the link succeeds, and one
# measures a version for hours that was changed long ago. Exactly that
# has happened.
.DELETE_ON_ERROR:

.PHONY: all all6 variants host clean
all: $(TARGETS)

$(OBJDIR)/%.o: src/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

# The decoder gets its own level (see CVIDOPT above).
$(OBJDIR)/codec/cvid.o: src/codec/cvid.c
	@mkdir -p $(dir $@)
	$(CC) $(filter-out -O2,$(CFLAGS)) $(CVIDOPT) $(CVIDEXTRA) -c $< -o $@

# On the 68080 -DAMMX selects the 64-bit version of the V1 block writers.
ifeq ($(CPU),68080)
  ASFLAGS := -DAMMX=1
else
  ASFLAGS :=
endif

# The 68030 assembles like the 68020 (one binary for both, see A020).
ASCPU := $(if $(filter 68030,$(CPU)),68020,$(CPU))
# The .i files as prerequisites: a change to the shared frame
# (cvid_blk_loops.i) otherwise left old objects lying around - the link did not
# find the new 0x3200 routine.
$(OBJDIR)/%.o: src/%.s $(wildcard src/asm/*.i)
	@mkdir -p $(dir $@)
	$(AS) -Fhunk -m$(ASCPU) $(ASFLAGS) $(ASINC) -quiet -o $@ $<

# Linking is done with the gcc driver, NOT with vlink: vlink fails on
# bebbo's libc.a ("Misplaced HUNK_END in lib_a-__cmpxf2.o").
$(OBJDIR)/selftest.$(SFX): $(OBJS) tests/selftest.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) tests/selftest.c $(OBJS) $(LDFLAGS) $(LDLIBS) -o $@
	@printf '  %-28s %8s Bytes\n' "$@" "$$(stat -c%s $@)"

# cvidbench reads AVI and CPKS and is therefore the only Amiga target that
# still needs the AVI header reader.
AVIOBJ := $(OBJDIR)/avi.o

$(OBJDIR)/cvidbench.$(SFX): $(OBJS) $(AVIOBJ) tests/cvidbench.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) tests/cvidbench.c $(OBJS) $(AVIOBJ) $(LDFLAGS) $(LDLIBS) -o $@
	@printf '  %-28s %8s Bytes\n' "$@" "$$(stat -c%s $@)"

# readbench measures the read path alone - see the header comment of the source.
$(OBJDIR)/readbench.$(SFX): $(OBJS) tests/readbench.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) tests/readbench.c $(OBJS) $(LDFLAGS) $(LDLIBS) -o $@
	@printf '  %-28s %8s Bytes\n' "$@" "$$(stat -c%s $@)"

# A pure diagnostic tool: lists the display modes of the machine. From the
# project it needs only plat.o.
$(OBJDIR)/modelist.$(SFX): $(OBJDIR)/plat.o tests/modelist.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) tests/modelist.c $(OBJDIR)/plat.o $(LDFLAGS) $(LDLIBS) -o $@
	@ls -l $@ | awk '{printf "  %-30s %s Bytes\n", "$@", $$5}'

# A minimal audio.device test, without a dependency on src/audio.c.
$(OBJDIR)/beep.$(SFX): tests/beep.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) tests/beep.c $(LDFLAGS) $(LDLIBS) -o $@
	@printf '  %-28s %8s Bytes\n' "$@" "$$(stat -c%s $@)"

$(OBJDIR)/beep2.$(SFX): tests/beep2.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) tests/beep2.c $(LDFLAGS) $(LDLIBS) -o $@
	@printf '  %-28s %8s Bytes\n' "$@" "$$(stat -c%s $@)"

# The player itself.
ifeq (,$(filter $(CPU),68000 68020 68030))
$(OBJDIR)/CyberPak.$(SFX): $(OBJS) src/player.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) src/player.c $(OBJS) $(LDFLAGS) $(LDLIBS) -o $@
	@printf '  %-28s %8s Bytes\n' "$@" "$$(stat -c%s $@)"
else ifeq ($(CPU),68000)
# vlink instead of gcc: no libc. -s: without symbols.
$(OBJDIR)/a68k/%.o: src/a68k/%.s $(wildcard src/a68k/*.i) src/a68k/tabellen.bin
	@mkdir -p $(dir $@)
	$(AS) -Fhunk -m68000 -Isrc/a68k $(ASINC) $(A68KFLAGS) -quiet -o $@ $<

$(OBJDIR)/CyberPak.000: $(A68K_OBJS)
	@mkdir -p $(dir $@)
	vlink -bamigahunk -s -o $@ $(A68K_OBJS)
	@printf '  %-28s %8s Bytes\n' "$@" "$$(stat -c%s $@)"

# The same objects WITH symbols - for the test rig (hook points).
$(OBJDIR)/CyberPak.dbg: $(A68K_OBJS)
	@mkdir -p $(dir $@)
	vlink -bamigahunk -o $@ $(A68K_OBJS)
endif

$(OBJDIR)/a020/%.o: src/a020/%.s $(wildcard src/a020/*.i) src/a020/tabellen.bin
	@mkdir -p $(dir $@)
	$(AS) -Fhunk -m68020 -Isrc/a020 $(ASINC) $(A020INC) $(A020FLAGS) -quiet -o $@ $<

ifneq (,$(filter $(CPU),68020 68030))

$(OBJDIR)/CyberPak.$(SFX): $(A020_OBJS)
	@mkdir -p $(dir $@)
	vlink -bamigahunk -s -o $@ $(A020_OBJS)
	@printf '  %-28s %8s Bytes\n' "$@" "$$(stat -c%s $@)"

$(OBJDIR)/CyberPak.dbg: $(A020_OBJS)
	@mkdir -p $(dir $@)
	vlink -bamigahunk -o $@ $(A020_OBJS)
endif

all6:
	@for c in 68000 68020 68030 68040 68060 68080; do \
	   $(MAKE) --no-print-directory CPU=$$c || exit 1; \
	 done

# All four build forms of a target, for the A/B comparison.
variants:
	@for v in opt legaddr legcb legacy; do \
	   $(MAKE) --no-print-directory CPU=$(CPU) VARIANT=$$v || exit 1; \
	 done

host:
	@mkdir -p build.x86_64
	gcc -O2 -std=gnu99 -Wall -Wextra -Isrc -fsanitize=address,undefined \
	    tests/selftest.c src/yuv.c -lm -o build.x86_64/selftest
	gcc -O2 -std=gnu99 -Wall -Wextra -Isrc \
	    host/hostmain.c src/avi.c src/yuv.c src/codec/cvid.c -lm -o build.x86_64/cvidtest
	@./build.x86_64/selftest

clean:
	rm -rf build.m* build.x86_64

-include $(OBJS:.o=.d)
