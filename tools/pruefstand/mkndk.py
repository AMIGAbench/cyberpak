#!/usr/bin/env python3
"""mkndk - fetch structure offsets, constants and LVOs from the NDK includes of
the build image and write them to tools/pruefstand/ndk.py.

None of it is copied by hand: vasm assembles a probe with `dc.l SYMBOL` against
exactly the includes the player is built with, and the values are read out of
the binary image. Symbols vasm does not know are reported and left out.

Call: python3 tools/pruefstand/mkndk.py"""
import os
import re
import subprocess
import sys
import tempfile

IMAGE = 'cyberavi-x-build:latest'
NDK = '/opt/ApolloCrossDev/Compilers/GCC-6.50-Patched/m68k-amigaos/ndk-include'
# The CyberGraphX and Picasso96 SDK do not live in the NDK but next to it
INC = '/opt/ApolloCrossDev/Compilers/GCC-6.50-Patched/m68k-amigaos/include'

INCLUDES = [
    'exec/types.i', 'exec/nodes.i', 'exec/lists.i', 'exec/libraries.i', 'exec/execbase.i',
    'exec/tasks.i', 'exec/ports.i', 'exec/io.i', 'exec/memory.i', 'exec/errors.i',
    'dos/dos.i', 'dos/dosextens.i', 'devices/timer.i', 'devices/audio.i',
    'devices/ahi.i',
    'graphics/gfx.i', 'graphics/view.i', 'graphics/modeid.i', 'graphics/gfxbase.i',
    'graphics/rastport.i', 'graphics/displayinfo.i', 'graphics/copper.i', 'graphics/layers.i',
    'intuition/intuition.i', 'intuition/screens.i', 'utility/tagitem.i',
    'lvo/exec_lib.i', 'lvo/dos_lib.i', 'lvo/graphics_lib.i', 'lvo/intuition_lib.i',
    'lvo/timer_lib.i',
    'lvo/cybergraphics.i',
]

SYMBOLS = '''
LIB_VERSION LIB_REVISION LIB_OPENCNT LIB_SIZE ThisTask
TC_SIGALLOC TC_SIGWAIT TC_SIGRECVD
MP_FLAGS MP_SIGBIT MP_SIGTASK MP_MSGLIST MP_SIZE MN_REPLYPORT MN_LENGTH MN_SIZE LN_TYPE
NT_MESSAGE NT_REPLYMSG
IO_DEVICE IO_UNIT IO_COMMAND IO_FLAGS IO_ERROR IO_SIZE IO_ACTUAL IO_LENGTH IO_DATA IO_OFFSET IOSTD_SIZE
IOB_QUICK IOF_QUICK DEV_BEGINIO DEV_ABORTIO
CMD_INVALID CMD_RESET CMD_READ CMD_WRITE CMD_UPDATE CMD_CLEAR CMD_STOP CMD_START CMD_FLUSH
IOERR_OPENFAIL IOERR_ABORTED IOERR_NOCMD IOERR_BADLENGTH
MEMF_ANY MEMF_PUBLIC MEMF_CHIP MEMF_FAST MEMF_CLEAR MEMF_LARGEST
MODE_OLDFILE MODE_NEWFILE DOSTRUE DOSFALSE
ERROR_NO_FREE_STORE ERROR_BAD_TEMPLATE ERROR_BAD_NUMBER ERROR_REQUIRED_ARG_MISSING
ERROR_KEY_NEEDS_ARG ERROR_TOO_MANY_ARGS ERROR_LINE_TOO_LONG ERROR_OBJECT_NOT_FOUND
pr_MsgPort pr_Result2 pr_CIS pr_COS pr_CLI
TV_SECS TV_MICRO TV_SIZE EV_HI EV_LO EV_SIZE IOTV_TIME IOTV_SIZE
UNIT_MICROHZ UNIT_VBLANK UNIT_ECLOCK UNIT_WAITUNTIL UNIT_WAITECLOCK
TR_ADDREQUEST TR_GETSYSTIME TR_SETSYSTIME
ioa_AllocKey ioa_Data ioa_Length ioa_Period ioa_Volume ioa_Cycles ioa_WriteMsg ioa_SIZEOF
ADCMD_FREE ADCMD_SETPREC ADCMD_FINISH ADCMD_PERVOL ADCMD_LOCK ADCMD_WAITCYCLE ADCMD_ALLOCATE
ADIOF_PERVOL ADIOF_SYNCCYCLE ADIOF_NOWAIT ADIOF_WRITEMESSAGE
ADIOERR_NOALLOCATION ADIOERR_ALLOCFAILED ADIOERR_CHANNELSTOLEN
ahir_Version ahir_Type ahir_Frequency ahir_Volume ahir_Position ahir_Link AHIRequest_SIZEOF
AHIST_M8S AHIST_S8S AHIST_M16S AHIST_S16S AHI_DEFAULT_UNIT AHI_NO_UNIT
AHIE_OK AHIE_NOMEM AHIE_BADSOUNDTYPE AHIE_BADSAMPLETYPE AHIE_ABORTED AHIE_UNKNOWN
bm_BytesPerRow bm_Rows bm_Flags bm_Depth bm_Pad bm_Planes bm_SIZEOF
vp_SIZEOF
sc_Width sc_Height sc_ViewPort sc_RastPort sc_BitMap
wd_RPort wd_UserPort wd_WScreen
im_Class im_Code im_Qualifier
IDCMP_CLOSEWINDOW IDCMP_RAWKEY IDCMP_VANILLAKEY
SA_Left SA_Top SA_Width SA_Height SA_Depth SA_DisplayID SA_Type SA_Quiet SA_ShowTitle
SA_Draggable SA_Exclusive SA_BitMap SA_Behind SA_Interleaved SA_AutoScroll SA_Colors32
CUSTOMSCREEN CUSTOMBITMAP
WA_Left WA_Top WA_Width WA_Height WA_IDCMP WA_CustomScreen WA_Borderless WA_Activate
WA_RMBTrap WA_NoCareRefresh WA_Backdrop WA_SimpleRefresh
PAL_MONITOR_ID LORES_KEY HAM_KEY EXTRAHALFBRITE_KEY INVALID_ID
TAG_DONE TAG_IGNORE TAG_MORE TAG_USER
LN_PRI LN_NAME rp_BitMap gb_DisplayFlags PAL NTSC NTSC_MONITOR_ID
dim_Header dim_MaxDepth DTAG_DIMS qh_SIZEOF dim_SIZEOF
cli_Module RETURN_OK RETURN_WARN RETURN_ERROR RETURN_FAIL
gb_ActiView gb_ActiViewCprSemaphore v_LOFCprList crl_Next crl_start crl_MaxCount
vp_Modes vp_RasInfo ri_BitMap V_HAM V_EXTRA_HALFBRITE
WA_BackFill SA_BackFill LAYERS_NOBACKFILL
HIRES_KEY SUPER_KEY V_HIRES V_SUPERHIRES dim_Nominal ra_MinX ra_MinY ra_MaxX ra_MaxY
gb_ChipRevBits0 GFXB_AA_ALICE GFXF_AA_ALICE GFXB_AA_LISA GFXF_AA_LISA GFXB_HR_AGNUS GFXF_HR_AGNUS
GFXB_HR_DENISE GFXF_HR_DENISE
WA_PubScreen WA_InnerWidth WA_InnerHeight WA_Title WA_DragBar
WA_DepthGadget WA_CloseGadget wd_BorderLeft wd_BorderTop
'''.split()


# CyberGraphX and Picasso96: the .i files of the SDK cannot be assembled with
# vasm (C notation 0x80, missing brackets). The values therefore come from the
# C HEADERS: gcc compiles an array with the constants and offsetof(), and the
# data section of the object is read. main() writes the same values to
# src/a020/rtg.i for the assembler player.
CSYMS = '''
CYBRMATTR_ISCYBERGFX CYBRMATTR_DEPTH CYBRMATTR_PIXFMT CYBRMATTR_BPPIX
PIXFMT_LUT8 PIXFMT_RGB15 PIXFMT_BGR15 PIXFMT_RGB15PC PIXFMT_BGR15PC PIXFMT_RGB16 PIXFMT_BGR16
PIXFMT_RGB16PC PIXFMT_BGR16PC PIXFMT_RGB24 PIXFMT_BGR24 PIXFMT_ARGB32 PIXFMT_BGRA32 PIXFMT_RGBA32
RECTFMT_RGB RECTFMT_ARGB CYBRBIDTG_Depth CYBRBIDTG_NominalWidth CYBRBIDTG_NominalHeight
RGBFB_R5G6B5 RGBFB_R5G5B5 RGBFB_R5G6B5PC RGBFB_R5G5B5PC
'''.split()
CSTRUCT = [('gri_Memory', 'offsetof(struct RenderInfo, Memory)'),
           ('gri_BytesPerRow', 'offsetof(struct RenderInfo, BytesPerRow)'),
           ('gri_pad', 'offsetof(struct RenderInfo, pad)'),
           ('gri_RGBFormat', 'offsetof(struct RenderInfo, RGBFormat)'),
           ('gri_SIZEOF', 'sizeof(struct RenderInfo)')]


def c_probe(tmp):
    namen = list(CSYMS) + [n for n, _ in CSTRUCT]
    ausdr = list(CSYMS) + [x for _, x in CSTRUCT]
    src = ['#include <stddef.h>', '#include <exec/types.h>', '#include <cybergraphx/cybergraphics.h>',
           '#include <libraries/Picasso96.h>', 'const long werte[] = {']
    src += ['    (long)(%s),' % x for x in ausdr] + ['    0x12345678', '};']
    open(os.path.join(tmp, 'cprobe.c'), 'w').write('\n'.join(src) + '\n')
    cmd = ['docker', 'run', '--rm', '-u', '%d:%d' % (os.getuid(), os.getgid()), '-v', '%s:/w' % tmp,
           '-w', '/w', IMAGE, 'sh', '-c',
           'm68k-amigaos-gcc -O0 -c cprobe.c -o cprobe.o && m68k-amigaos-objdump -s cprobe.o']
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit('C-Probe:\n' + r.stdout + r.stderr)
    worte = []
    for line in r.stdout.splitlines():
        m = re.match(r'^ ([0-9a-f]{4}) ((?:[0-9a-f]{8} ?)+)', line)
        if m:
            worte += [int(w, 16) for w in m.group(2).split()]
    if len(worte) < len(namen) + 1 or worte[len(namen)] != 0x12345678:
        sys.exit('C probe: data section not recognised:\n' + r.stdout)
    return dict(zip(namen, worte))


def lvo_names(text):
    return re.findall(r'^(_LVO\w+)\s+EQU', text, re.M)


def run_probe(tmp, syms):
    lines = ['\tinclude "%s"' % i for i in INCLUDES]
    lines += ['\tdc.l\t%s' % s for s in syms]
    open(os.path.join(tmp, 'probe.s'), 'w').write('\n'.join(lines) + '\n')
    cmd = ['docker', 'run', '--rm', '-u', '%d:%d' % (os.getuid(), os.getgid()),
           '-v', '%s:/w' % tmp, '-w', '/w', IMAGE,
           'vasmm68k_mot', '-Fbin', '-m68000', '-quiet', '-nowarn=62', '-I' + NDK, '-I' + INC,
           '-o', 'probe.bin', 'probe.s']
    return subprocess.run(cmd, capture_output=True, text=True)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    tmp = tempfile.mkdtemp(prefix='mkndk')
    lvos = []
    for lib in ('exec', 'dos', 'graphics', 'intuition', 'timer'):
        r = subprocess.run(['docker', 'run', '--rm', IMAGE, 'cat', '%s/lvo/%s_lib.i' % (NDK, lib)],
                           capture_output=True, text=True, check=True)
        lvos.append((lib, lvo_names(r.stdout)))
    r = subprocess.run(['docker', 'run', '--rm', IMAGE, 'cat', '%s/lvo/cybergraphics.i' % INC],
                       capture_output=True, text=True, check=True)
    lvos.append(('cybergraphics', lvo_names(r.stdout)))
    # Picasso96API has no lvo file: compute it from the fd file (bias, 6 per function)
    r = subprocess.run(['docker', 'run', '--rm', IMAGE, 'cat', '%s/fd/Picasso96API_lib.fd' % INC],
                       capture_output=True, text=True, check=True)
    p96, bias = {}, 30
    for line in r.stdout.splitlines():
        if line.startswith('##bias'):
            bias = int(line.split()[1])
        elif line and not line.startswith('*') and not line.startswith('##'):
            p96[-bias] = line.split('(')[0]
            bias += 6
    syms = list(SYMBOLS) + [n for _, names in lvos for n in names]
    dropped = []
    for _ in range(10):
        r = run_probe(tmp, syms)
        bad = set(re.findall(r'undefined symbol <(\w+)>', r.stdout + r.stderr))
        if r.returncode == 0 and not bad:
            break
        if not bad:
            sys.exit('vasm error:\n' + r.stdout + r.stderr)
        dropped += sorted(bad)
        syms = [s for s in syms if s not in bad]
    cwerte = c_probe(tmp)
    raw = open(os.path.join(tmp, 'probe.bin'), 'rb').read()
    vals = {}
    for i, s in enumerate(syms):
        v = int.from_bytes(raw[4 * i:4 * i + 4], 'big')
        if v & 0x80000000 and (s.startswith('_LVO') or s.startswith('DEV_')):
            v -= 1 << 32
        vals[s] = v
    out = ['"""Generated from the NDK includes by mkndk.py - do not edit by hand."""', '']
    for s in syms:
        if not s.startswith('_LVO'):
            out.append('%s = %d' % (s, vals[s]))
    for s_ in CSYMS + [n for n, _ in CSTRUCT]:
        out.append('%s = %d' % (s_, cwerte[s_]))
    out.append('')
    out.append('LVO = {')
    for lib, names in lvos:
        out.append("    '%s': {" % lib)
        for n in names:
            if n in vals:
                out.append("        %d: '%s'," % (vals[n], n[4:]))
        out.append('    },')
    out.append("    'picasso96': {")
    for off, n in sorted(p96.items(), reverse=True):
        out.append("        %d: '%s'," % (off, n))
    out.append('    },')
    out.append('}')
    open(os.path.join(here, 'ndk.py'), 'w').write('\n'.join(out) + '\n')
    inc = ['; rtg.i - GENERATED by tools/pruefstand/mkndk.py from the C headers of the',
           '; CyberGraphX and Picasso96 SDK (their .i files are broken for vasm). Do not edit by hand.', '']
    for s_ in CSYMS + [n for n, _ in CSTRUCT]:
        inc.append('%-24s equ     $%08x' % (s_, cwerte[s_]))
    for off, n in sorted(p96.items(), reverse=True):
        if n in ('p96WritePixelArray',):
            inc.append('%-24s equ     %d' % ('_LVO' + n, off))
    open(os.path.join(os.path.dirname(os.path.dirname(here)), 'src', 'a020', 'rtg.i'), 'w').write('\n'.join(inc) + '\n')
    print('ndk.py: %d symbols, %d LVO tables, rtg.i written' % (len(syms), len(lvos)))
    if dropped:
        print('not in the NDK (left out): ' + ' '.join(dropped))


if __name__ == '__main__':
    main()
