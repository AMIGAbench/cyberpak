"""amiga.py - test rig for the 68000 player.

Loads an Amiga hunk program and runs it in a 68000 instruction set core
(unicorn). There is no chipset and no kickstart: every call of a
library or a device lands in a Python stub. The stubs
keep books (memory, open libraries, devices, signals), so that a test
can check after the run whether the program released everything again.

Memory image (modelled on an A600 with fast RAM):
  0x000000-0x1FFFFF  chip RAM, 2 MB (0x000000-0x000FFF locked except SysBase)
  0x400000-0xBFFFFF  fast RAM, 8 MB
  0xF00000-0xF7FFFF  library bases and jump tables of the stubs
With cpu='68020'/'68030' and fast_hi=True the fast RAM lies instead
32-bit addressed at 0x08000000 (as Zorro III / CPU card).
A library function is called through its LVO; an RTS stands there, and
a code hook on that area runs the Python function beforehand.

Time is virtual (microseconds). It advances per executed block by
`us_per_byte` per code byte and jumps in Wait() to the next event.
More precise time models hook in through `on_block`."""
import hashlib
import heapq
import struct
import sys
import os

from unicorn import Uc, UC_ARCH_M68K, UC_MODE_BIG_ENDIAN, UC_HOOK_CODE, UC_HOOK_BLOCK, \
    UC_HOOK_MEM_INVALID, UcError
from unicorn.m68k_const import UC_M68K_REG_D0, UC_M68K_REG_A0, UC_M68K_REG_A7, UC_M68K_REG_PC, \
    UC_CPU_M68K_M68000, UC_CPU_M68K_M68020, UC_CPU_M68K_M68030

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ndk  # noqa: E402

CHIP_LO, CHIP_HI = 0x001000, 0x200000
FAST_LO, FAST_HI = 0x400000, 0xC00000
FAST_HI_LO = 0x08000000         # fast RAM above 16 MB (020/030 only)
CPU_MODELL = {'68000': UC_CPU_M68K_M68000, '68020': UC_CPU_M68K_M68020, '68030': UC_CPU_M68K_M68030}
LIB_LO, LIB_HI = 0xF00000, 0xF80000
EXIT_ADDR = LIB_HI - 8
ECLOCK_FREQ = 709379            # PAL

HUNK_HEADER, HUNK_CODE, HUNK_DATA, HUNK_BSS = 0x3F3, 0x3E9, 0x3EA, 0x3EB
HUNK_RELOC32, HUNK_SYMBOL, HUNK_DEBUG, HUNK_END = 0x3EC, 0x3F0, 0x3F1, 0x3F2
HUNK_RELOC32SHORT, HUNK_DREL32 = 0x3FC, 0x3F7


class Pruefabbruch(Exception):
    """The program did something that would be wrong on the Amiga."""


class Heap:
    """First fit with bookkeeping. Addresses and sizes rounded to 4 bytes
    (exec rounds to MEM_BLOCKSIZE = 8; 4 is enough for the check)."""

    def __init__(self, lo, hi, name):
        self.free = [(lo, hi - lo)]
        self.name = name
        self.lo, self.hi = lo, hi

    def alloc(self, size):
        size = (size + 7) & ~7
        for i, (a, n) in enumerate(self.free):
            if n >= size:
                if n == size:
                    del self.free[i]
                else:
                    self.free[i] = (a + size, n - size)
                return a
        return 0

    def release(self, addr, size):
        size = (size + 7) & ~7
        self.free.append((addr, size))
        self.free.sort()
        merged = []
        for a, n in self.free:
            if merged and merged[-1][0] + merged[-1][1] == a:
                merged[-1] = (merged[-1][0], merged[-1][1] + n)
            else:
                merged.append((a, n))
        self.free = merged

    def avail(self, largest=False):
        return max((n for _, n in self.free), default=0) if largest else sum(n for _, n in self.free)


class Library:
    def __init__(self, am, name, version, lvotab, handlers, pos=64):
        self.name = name
        neg = max((-o for o in lvotab), default=36) + 6
        size = neg + pos
        start = am.lib_alloc(size)
        self.base = start + neg
        self.lvotab = lvotab
        self.handlers = handlers
        self.opencnt = 0
        for off in lvotab:
            am.u.mem_write(self.base + off, b'\x4e\x75\x4e\x71\x4e\x71')
        am.u.mem_write(self.base + ndk.LIB_VERSION, struct.pack('>HH', version, 0))
        am.libs_by_base[self.base] = self


class Amiga:
    def __init__(self, fast_kb=8192, chip_kb=2048, us_per_byte=0.35, trace=False,
                 gfx_version=40, chipset='ecs', ntsc=False, cpu='68000', fast_hi=False, setpatch=True,
                 rtg=None):
        if fast_hi and cpu == '68000':
            raise ValueError('fast RAM above 16 MB does not exist for the 68000')
        self.u = u = Uc(UC_ARCH_M68K, UC_MODE_BIG_ENDIAN)
        u.ctl_set_cpu_model(CPU_MODELL[cpu])
        self.cpu = cpu
        self.fast_lo = FAST_HI_LO if fast_hi else FAST_LO
        self.fast_hi = self.fast_lo + (((fast_kb * 1024 + 0xFFFF) & ~0xFFFF) if fast_hi else FAST_HI - FAST_LO)
        u.mem_map(0, 0x200000)
        u.mem_map(self.fast_lo, self.fast_hi - self.fast_lo)
        u.mem_map(LIB_LO, LIB_HI - LIB_LO)
        self.chip = Heap(CHIP_LO, min(CHIP_HI, chip_kb * 1024), 'chip')
        self.fast = Heap(self.fast_lo, self.fast_lo + fast_kb * 1024, 'fast') if fast_kb else None
        self.lib_next = LIB_LO
        self.libs_by_base = {}
        self.allocs = {}                 # addr -> (size, flags, was)
        self.trace = trace
        self.stdout = bytearray()
        self.now = 0.0                   # Mikrosekunden
        self.us_per_byte = us_per_byte
        self.events = []                 # (zeit, nr, funktion)
        self.evnr = 0
        self.sigrecvd = 0
        self.sigalloc = 0xFFFF           # bits 0-15 belong to the system
        self.ports = {}                  # addr -> list of messages
        self.files = {}                  # Amiga-Name -> Host-Pfad
        self.handles = {}                # handle -> open host file
        self.ioerr = 0
        self.args = ''
        self.devices = {}                # Name -> Device-Objekt
        self.dev_by_base = {}
        self.pending_io = {}             # Request -> Device
        self.calls = {}                  # 'lib.Funktion' -> Anzahl
        self.forbid = 0
        self.exitcode = None
        self.on_block = None
        self.hunks = []                  # (adresse, laenge, MEMF-Art)
        self.symbols = {}                # Name -> Adresse (aus HUNK_SYMBOL)
        self.error = None
        self.gfx_version = gfx_version
        self.chipset = chipset
        self.setpatch = setpatch         # False: AGA machine without SetPatch, database only ECS depths
        # Graphics card: None = none; otherwise dict(depth, pixfmt, cgx=True, p96=True,
        # vollbild=True, vollbild_pixfmt=pixfmt, breite=1024, hoehe=768)
        self.rtg = rtg
        self.rtg_bilder = []             # per WritePixelArray: (kind, md5, x, y, w, h)
        self.pub_locks = 0
        self.rtg_screen = None
        self.cgx_bitmaps = {}
        self.ntsc = ntsc
        self.max_depth = {}              # DisplayID -> MaxDepth (ueberschreibt ECS/AGA)
        self.screen = None
        self.window = None
        self.closed_screen = None
        self.screen_fail = False
        self.palette = None
        self.user_ports = set()
        self.sa_bitmap_ohne_ham = False  # reproduces the A600 symptom: HAM is lost with SA_BitMap
        self.semaphoren = 0
        self.read_max = None             # None or a function -> at most this many bytes per Read()
        self.read_us = None              # None or function(bytes) -> microseconds a read takes
        self._mk_system()
        u.hook_add(UC_HOOK_CODE, self._lvo_hook, begin=LIB_LO, end=LIB_HI - 1)
        u.hook_add(UC_HOOK_BLOCK, self._block_hook, begin=0, end=0xC00000)
        if fast_hi:
            u.hook_add(UC_HOOK_BLOCK, self._block_hook, begin=self.fast_lo, end=self.fast_hi - 1)

    # --- memory -----------------------------------------------------------

    def lib_alloc(self, size):
        a = self.lib_next
        self.lib_next += (size + 7) & ~7
        if self.lib_next > EXIT_ADDR:
            raise RuntimeError('Library-Bereich voll')
        return a

    def alloc_mem(self, size, flags, was='AllocMem'):
        if size <= 0:
            return 0
        a = 0
        if flags & ndk.MEMF_CHIP:
            a = self.chip.alloc(size)
        elif flags & ndk.MEMF_FAST:
            a = self.fast.alloc(size) if self.fast else 0
        else:
            a = (self.fast.alloc(size) if self.fast else 0) or self.chip.alloc(size)
        if a:
            self.allocs[a] = (size, flags, was)
            if flags & ndk.MEMF_CLEAR:
                self.u.mem_write(a, bytes((size + 7) & ~7))
        return a

    def free_mem(self, addr, size, was='FreeMem'):
        rec = self.allocs.pop(addr, None)
        if rec is None:
            raise Pruefabbruch('%s: 0x%06x is not allocated' % (was, addr))
        if rec[0] != size:
            raise Pruefabbruch('%s: 0x%06x freed with size %d, %d was allocated' % (
                was, addr, size, rec[0]))
        (self.chip if addr < CHIP_HI else self.fast).release(addr, size)

    def type_of_mem(self, addr):
        if CHIP_LO <= addr < CHIP_HI:
            return ndk.MEMF_CHIP | ndk.MEMF_PUBLIC
        if self.fast and self.fast_lo <= addr < self.fast_hi:
            return ndk.MEMF_FAST | ndk.MEMF_PUBLIC
        return 0

    def chip_zaehler(self):
        """Count the CPU's accesses to chip RAM, as bus cycles of the
        16-bit chip bus: byte and word 1 each, longword 2. Returns a dict
        that counts along during the run (lesen, schreiben); resetting it
        is up to the caller. Costs run time - for measurements only."""
        from unicorn import UC_HOOK_MEM_READ, UC_HOOK_MEM_WRITE
        z = {'lesen': 0, 'schreiben': 0}

        def rd(uc, acc, addr, size, val, ud):
            z['lesen'] += 2 if size == 4 else 1

        def wr(uc, acc, addr, size, val, ud):
            z['schreiben'] += 2 if size == 4 else 1
        self.u.hook_add(UC_HOOK_MEM_READ, rd, begin=CHIP_LO, end=CHIP_HI - 1)
        self.u.hook_add(UC_HOOK_MEM_WRITE, wr, begin=CHIP_LO, end=CHIP_HI - 1)
        return z

    # --- registers and memory access ---------------------------------------

    def d(self, n, v=None):
        if v is None:
            return self.u.reg_read(UC_M68K_REG_D0 + n)
        self.u.reg_write(UC_M68K_REG_D0 + n, v & 0xFFFFFFFF)

    def a(self, n, v=None):
        if v is None:
            return self.u.reg_read(UC_M68K_REG_A0 + n)
        self.u.reg_write(UC_M68K_REG_A0 + n, v & 0xFFFFFFFF)

    def rl(self, addr):
        return struct.unpack('>I', self.u.mem_read(addr, 4))[0]

    def rw(self, addr):
        return struct.unpack('>H', self.u.mem_read(addr, 2))[0]

    def rb(self, addr):
        return self.u.mem_read(addr, 1)[0]

    def wl(self, addr, v):
        self.u.mem_write(addr, struct.pack('>I', v & 0xFFFFFFFF))

    def ww(self, addr, v):
        self.u.mem_write(addr, struct.pack('>H', v & 0xFFFF))

    def wb(self, addr, v):
        self.u.mem_write(addr, bytes([v & 0xFF]))

    def cstr(self, addr, maxlen=4096):
        if not addr:
            return None
        b = bytes(self.u.mem_read(addr, maxlen))
        return b[:b.index(0)].decode('latin-1') if 0 in b else b.decode('latin-1')

    def new_cstr(self, s):
        b = s.encode('latin-1') + b'\0'
        a = self.alloc_mem(len(b), ndk.MEMF_ANY, 'intern')
        self.u.mem_write(a, b)
        return a

    # --- time and events ----------------------------------------------------

    def at(self, t, fn):
        self.evnr += 1
        heapq.heappush(self.events, (t, self.evnr, fn))

    def signal(self, bits):
        self.sigrecvd |= bits

    def run_events(self):
        while self.events and self.events[0][0] <= self.now:
            _, _, fn = heapq.heappop(self.events)
            fn()

    def _block_hook(self, uc, addr, size, ud):
        if self.on_block:
            self.on_block(addr, size)
        else:
            self.now += size * self.us_per_byte
        if self.events and self.events[0][0] <= self.now:
            self.run_events()

    # --- System -------------------------------------------------------------

    def _mk_system(self):
        L = ndk.LVO
        self.exec = Library(self, 'exec.library', 40, L['exec'], self._exec_handlers())
        self.u.mem_write(4, struct.pack('>I', self.exec.base))
        self.dos = Library(self, 'dos.library', 40, L['dos'], self._dos_handlers())
        self.graphics = Library(self, 'graphics.library', self.gfx_version, L['graphics'],
                                self._gfx_handlers(), pos=512)
        self.ww(self.graphics.base + ndk.gb_DisplayFlags, ndk.NTSC if self.ntsc else ndk.PAL)
        self.wb(self.graphics.base + ndk.gb_ChipRevBits0,
                (ndk.GFXF_AA_ALICE | ndk.GFXF_AA_LISA) if self.chipset == 'aga'
                else (ndk.GFXF_HR_AGNUS | ndk.GFXF_HR_DENISE))
        # Active view with a copper list that carries the screen's BPLCON0
        self.view = self.lib_alloc(64)
        self.u.mem_write(self.view, bytes(64))
        self.cpr = self.lib_alloc(16)
        self.u.mem_write(self.cpr, bytes(16))
        self.copper = self.lib_alloc(64)
        self.u.mem_write(self.copper, bytes(64))
        self.wl(self.cpr + ndk.crl_start, self.copper)
        self.wl(self.view + ndk.v_LOFCprList, self.cpr)
        self.wl(self.graphics.base + ndk.gb_ActiView, self.view)
        sem = self.lib_alloc(64)
        self.u.mem_write(sem, bytes(64))
        self.wl(self.graphics.base + ndk.gb_ActiViewCprSemaphore, sem)
        self.intuition = Library(self, 'intuition.library', 40, L['intuition'], self._int_handlers(), pos=512)
        self.libraries = {l.name: l for l in (self.dos, self.graphics, self.intuition)}
        # Process: CLI start with a segment list (cli_Module), own message port
        self.proc = self.lib_alloc(512)
        self.u.mem_write(self.proc, bytes(512))
        self.cli = self.lib_alloc(128)
        self.u.mem_write(self.cli, bytes(128))
        self.wl(self.proc + ndk.pr_CLI, self.cli >> 2)
        # Reply port for IntuiMessages
        self.int_port = self.lib_alloc(ndk.MP_SIZE)
        self.u.mem_write(self.int_port, bytes(ndk.MP_SIZE))
        self.ports[self.int_port] = []
        self.wl(self.exec.base + ndk.ThisTask, self.proc)
        self.u.mem_write(EXIT_ADDR, b'\x4e\x71\x4e\x71')
        self.wb_schirm = None
        if self.rtg is not None:
            self._mk_rtg()

    # --- Grafikkarte (cybergraphics.library, Picasso96API.library) ------------

    def _mk_rtg(self):
        r = self.rtg
        self.wb_schirm = self.lib_alloc(512)
        self.u.mem_write(self.wb_schirm, bytes(512))
        bm = self.lib_alloc(64)
        self.u.mem_write(bm, bytes(64))
        self.wl(self.wb_schirm + ndk.sc_RastPort + ndk.rp_BitMap, bm)
        self.ww(self.wb_schirm + ndk.sc_Width, r.get('breite', 1024))
        self.ww(self.wb_schirm + ndk.sc_Height, r.get('hoehe', 768))
        self.cgx_bitmaps[bm] = dict(cgx=r.get('cgx', True), depth=r['depth'], pixfmt=r['pixfmt'])
        self.add_library('cybergraphics.library', 41, ndk.LVO['cybergraphics'], self._cgx_handlers())
        if r.get('p96', True):
            self.add_library('Picasso96API.library', 2, ndk.LVO['picasso96'], self._p96_handlers())

    def _rtg_rastport(self, rp):
        w = self.window
        if not w or rp != self.rl(w['addr'] + ndk.wd_RPort):
            raise Pruefabbruch('drawing into a RastPort 0x%06x that belongs to no open window' % rp)
        return w

    def _cgx_handlers(self):
        d, a = self.d, self.a

        def get_cyber_map_attr():
            info = self.cgx_bitmaps.get(a(0))
            attr = d(0)
            if info is None or not info['cgx']:
                d(0, 0)
            elif attr == ndk.CYBRMATTR_ISCYBERGFX:
                d(0, 0xFFFFFFFF)
            elif attr == ndk.CYBRMATTR_DEPTH:
                d(0, info['depth'])
            elif attr == ndk.CYBRMATTR_PIXFMT:
                d(0, info['pixfmt'])
            elif attr == ndk.CYBRMATTR_BPPIX:
                d(0, (info['depth'] + 7) // 8)
            else:
                raise Pruefabbruch('GetCyberMapAttr: attribute 0x%x not reproduced' % attr)

        def write_pixel_array():
            src, sx, sy, mod, rp = a(0), d(0), d(1), d(2), a(1)
            dx, dy, w, h, fmt = d(3), d(4), d(5), d(6), d(7)
            self._rtg_rastport(rp)
            if fmt != ndk.RECTFMT_ARGB or sx or sy or mod != w * 4 or not w or not h:
                raise Pruefabbruch('WritePixelArray: format %d, source %d/%d, SrcMod %d, %dx%d' % (fmt, sx, sy, mod, w, h))
            data = bytes(self.u.mem_read(src, mod * h))
            self.rtg_bilder.append(('argb', hashlib.md5(data).hexdigest(), dx, dy, w, h))
            d(0, w * h)

        def best_cmode_id():
            if self.rtg.get('vollbild', True):
                d(0, 0x50011000)
            else:
                d(0, ndk.INVALID_ID)
        return {'GetCyberMapAttr': get_cyber_map_attr, 'WritePixelArray': write_pixel_array,
                'BestCModeIDTagList': best_cmode_id}

    def _p96_handlers(self):
        d, a = self.d, self.a

        def p96_write_pixel_array():
            ri, sx, sy, rp, dx, dy, w, h = a(0), d(0), d(1), a(1), d(2), d(3), d(4), d(5)
            self._rtg_rastport(rp)
            mem = self.rl(ri + ndk.gri_Memory)
            bpr = struct.unpack('>h', self.u.mem_read(ri + ndk.gri_BytesPerRow, 2))[0]
            fmt = self.rl(ri + ndk.gri_RGBFormat)
            if sx or sy or bpr != w * 2 or not w or not h:
                raise Pruefabbruch('p96WritePixelArray: source %d/%d, BytesPerRow %d, %dx%d' % (sx, sy, bpr, w, h))
            data = bytes(self.u.mem_read(mem, bpr * h))
            self.rtg_bilder.append(('p96:%d' % fmt, hashlib.md5(data).hexdigest(), dx, dy, w, h))
        return {'p96WritePixelArray': p96_write_pixel_array}

    def add_library(self, name, version, lvotab, handlers):
        lib = Library(self, name, version, lvotab, handlers)
        self.libraries[name] = lib
        return lib

    def add_device(self, dev):
        lvotab = {ndk.DEV_BEGINIO: 'BeginIO', ndk.DEV_ABORTIO: 'AbortIO'}
        lvotab.update(getattr(dev, 'lvotab', {}))
        handlers = {'BeginIO': lambda: dev.begin_io(self.a(1)),
                    'AbortIO': lambda: self.d(0, dev.abort_io(self.a(1)))}
        handlers.update(getattr(dev, 'handlers', {}))
        lib = Library(self, dev.name, 40, lvotab, handlers)
        dev.base = lib.base
        dev.am = self
        self.devices[dev.name] = dev
        self.dev_by_base[lib.base] = dev
        return dev

    def _lvo_hook(self, uc, addr, size, ud):
        if addr == EXIT_ADDR:
            self.exitcode = self.d(0)
            uc.emu_stop()
            return
        # LVOs are negative: the base responsible is the next one above.
        base = min((b for b in self.libs_by_base if b > addr), default=None)
        lib = self.libs_by_base.get(base)
        if lib is None or (addr - base) not in lib.lvotab:
            raise Pruefabbruch('jump into the library area 0x%06x without a function' % addr)
        name = lib.lvotab[addr - base]
        key = '%s.%s' % (lib.name.split('.')[0], name)
        self.calls[key] = self.calls.get(key, 0) + 1
        fn = lib.handlers.get(name)
        if fn is None:
            self.error = Pruefabbruch('not reproduced: %s' % key)
            uc.emu_stop()
            return
        if self.trace:
            print('  [%9.3f ms] %s' % (self.now / 1000, key))
        try:
            fn()
        except Pruefabbruch as e:
            self.error = e
            uc.emu_stop()

    # --- exec ---------------------------------------------------------------

    def _exec_handlers(self):
        d, a = self.d, self.a

        def open_library():
            name, ver = self.cstr(a(1)), d(0)
            lib = self.libraries.get(name)
            if lib is None or self.rw(lib.base + ndk.LIB_VERSION) < ver:
                d(0, 0)
                return
            lib.opencnt += 1
            d(0, lib.base)

        def close_library():
            lib = self.libs_by_base.get(a(1))
            if lib is None or lib.opencnt <= 0:
                raise Pruefabbruch('CloseLibrary on a library that is not open 0x%06x' % a(1))
            lib.opencnt -= 1

        def wait():
            mask = d(0)
            while not (self.sigrecvd & mask):
                if not self.events:
                    raise Pruefabbruch('Wait(0x%08x) without any coming event' % mask)
                t, _, _ = self.events[0]
                self.now = max(self.now, t)
                self.run_events()
            got = self.sigrecvd & mask
            self.sigrecvd &= ~mask
            d(0, got)

        def set_signal():
            old = self.sigrecvd
            new, mask = d(0), d(1)
            self.sigrecvd = (old & ~mask) | (new & mask)
            d(0, old)

        def alloc_signal():
            n = d(0) & 0xFFFFFFFF
            if n == 0xFFFFFFFF:
                n = next((i for i in range(31, -1, -1) if not (self.sigalloc >> i) & 1), None)
            if n is None or (self.sigalloc >> n) & 1:
                d(0, 0xFFFFFFFF)
                return
            self.sigalloc |= 1 << n
            d(0, n)

        def free_signal():
            self.sigalloc &= ~(1 << d(0))

        def create_msgport():
            p = self.alloc_mem(ndk.MP_SIZE, ndk.MEMF_CLEAR, 'CreateMsgPort')
            n = next((i for i in range(31, 15, -1) if not (self.sigalloc >> i) & 1), None)
            if not p or n is None:
                d(0, 0)
                return
            self.sigalloc |= 1 << n
            self.wb(p + ndk.MP_SIGBIT, n)
            self.wl(p + ndk.MP_SIGTASK, self.proc)
            self.ports[p] = []
            self.user_ports.add(p)
            d(0, p)

        def delete_msgport():
            p = a(0)
            if not p:
                return
            if self.ports.get(p):
                raise Pruefabbruch('DeleteMsgPort: port 0x%06x still has %d messages' % (p, len(self.ports[p])))
            self.ports.pop(p, None)
            self.user_ports.discard(p)
            self.sigalloc &= ~(1 << self.rb(p + ndk.MP_SIGBIT))
            self.free_mem(p, ndk.MP_SIZE, 'DeleteMsgPort')

        def get_msg():
            q = self.ports.get(a(0))
            if q is None:
                raise Pruefabbruch('GetMsg on an unknown port 0x%06x' % a(0))
            d(0, q.pop(0) if q else 0)

        def wait_port():
            p = a(0)
            while not self.ports.get(p):
                if not self.events:
                    raise Pruefabbruch('WaitPort without a coming event')
                self.now = max(self.now, self.events[0][0])
                self.run_events()
            d(0, self.ports[p][0])

        def reply_msg():
            m = a(1)
            port = self.rl(m + ndk.MN_REPLYPORT)
            self.wb(m + ndk.LN_TYPE, ndk.NT_REPLYMSG)
            self.put_msg(port, m)

        def create_ioreq():
            port, size = a(0), d(0)
            r = self.alloc_mem(size, ndk.MEMF_CLEAR, 'CreateIORequest') if port else 0
            if r:
                self.wl(r + ndk.MN_REPLYPORT, port)
                self.ww(r + ndk.MN_LENGTH, size)
            d(0, r)

        def delete_ioreq():
            r = a(0)
            if r:
                if r in self.pending_io:
                    raise Pruefabbruch('DeleteIORequest: request 0x%06x is still running' % r)
                self.free_mem(r, self.rw(r + ndk.MN_LENGTH), 'DeleteIORequest')

        def open_device():
            name, unit, req, flags = self.cstr(a(0)), d(0), a(1), d(1)
            dev = self.devices.get(name)
            if dev is None:
                self.wb(req + ndk.IO_ERROR, ndk.IOERR_OPENFAIL & 0xFF)
                d(0, ndk.IOERR_OPENFAIL & 0xFF)
                return
            err = dev.open(req, unit, flags)
            self.wb(req + ndk.IO_ERROR, err & 0xFF)
            if not err:
                self.wl(req + ndk.IO_DEVICE, dev.base)
                dev.opencnt = getattr(dev, 'opencnt', 0) + 1
            d(0, err & 0xFF)

        def close_device():
            req = a(1)
            dev = self.dev_by_base.get(self.rl(req + ndk.IO_DEVICE))
            if dev is None or dev.opencnt <= 0:
                raise Pruefabbruch('CloseDevice on a request that is not open 0x%06x' % req)
            if req in self.pending_io:
                raise Pruefabbruch('CloseDevice: request 0x%06x is still running' % req)
            dev.close(req)
            dev.opencnt -= 1

        def dev_of(req):
            dev = self.dev_by_base.get(self.rl(req + ndk.IO_DEVICE))
            if dev is None:
                raise Pruefabbruch('IO on request 0x%06x without an open device' % req)
            return dev

        def send_io():
            req = a(1)
            self.wb(req + ndk.IO_FLAGS, 0)
            self.wb(req + ndk.LN_TYPE, ndk.NT_MESSAGE)
            dev_of(req).begin_io(req)

        def do_io():
            req = a(1)
            self.wb(req + ndk.IO_FLAGS, ndk.IOF_QUICK)
            self.wb(req + ndk.LN_TYPE, ndk.NT_MESSAGE)
            dev_of(req).begin_io(req)
            self.wait_io(req)
            d(0, self.rb(req + ndk.IO_ERROR))

        def check_io():
            req = a(1)
            d(0, 0 if req in self.pending_io else req)

        def wait_io():
            req = a(1)
            self.wait_io(req)
            v = self.rb(req + ndk.IO_ERROR)
            d(0, v - 256 if v & 0x80 else v)

        def abort_io():
            req = a(1)
            d(0, dev_of(req).abort_io(req))

        def copy_mem():
            src, dst, n = a(0), a(1), d(0)
            if n:
                self.u.mem_write(dst, bytes(self.u.mem_read(src, n)))

        def alloc_vec():
            size, flags = d(0), d(1)
            p = self.alloc_mem(size + 4, flags, 'AllocVec')
            if p:
                self.wl(p, size + 4)
                d(0, p + 4)
            else:
                d(0, 0)

        def free_vec():
            p = a(1)
            if p:
                self.free_mem(p - 4, self.rl(p - 4), 'FreeVec')

        def avail_mem():
            f = d(1)
            largest = bool(f & ndk.MEMF_LARGEST)
            if f & ndk.MEMF_CHIP:
                v = self.chip.avail(largest)
            elif f & ndk.MEMF_FAST:
                v = self.fast.avail(largest) if self.fast else 0
            else:
                v = self.chip.avail(largest) + (self.fast.avail(largest) if self.fast else 0)
            d(0, v)

        def forbid():
            self.forbid += 1

        def permit():
            self.forbid -= 1

        return {
            'OpenLibrary': open_library, 'OldOpenLibrary': open_library, 'CloseLibrary': close_library,
            'AllocMem': lambda: d(0, self.alloc_mem(d(0), d(1))),
            'FreeMem': lambda: self.free_mem(a(1), d(0)),
            'AllocVec': alloc_vec, 'FreeVec': free_vec, 'AvailMem': avail_mem,
            'TypeOfMem': lambda: d(0, self.type_of_mem(a(1))),
            'FindTask': lambda: d(0, self.proc if a(1) == 0 else 0),
            'Forbid': forbid, 'Permit': permit,
            'Wait': wait, 'SetSignal': set_signal, 'AllocSignal': alloc_signal, 'FreeSignal': free_signal,
            'CreateMsgPort': create_msgport, 'DeleteMsgPort': delete_msgport,
            'GetMsg': get_msg, 'WaitPort': wait_port, 'ReplyMsg': reply_msg,
            'PutMsg': lambda: self.put_msg(a(0), a(1)),
            'CreateIORequest': create_ioreq, 'DeleteIORequest': delete_ioreq,
            'OpenDevice': open_device, 'CloseDevice': close_device,
            'SendIO': send_io, 'DoIO': do_io, 'CheckIO': check_io, 'WaitIO': wait_io, 'AbortIO': abort_io,
            'CopyMem': copy_mem, 'CopyMemQuick': copy_mem,
            'SetTaskPri': lambda: d(0, 0),
            # Kalms' 5-plane C2P changes its own code (smcinit) and then flushes
            # the instruction cache; unicorn discards translated blocks on
            # writes by itself.
            'CacheClearU': lambda: None,
            'ObtainSemaphore': lambda: setattr(self, 'semaphoren', self.semaphoren + 1),
            'ReleaseSemaphore': lambda: setattr(self, 'semaphoren', self.semaphoren - 1),
        }

    def _gfx_handlers(self):
        d, a = self.d, self.a

        def modi():
            # Without SetPatch even an AGA machine reports only the ECS depths
            # (NOTES, "Die Testmaschine bootete ohne SetPatch").
            aga = self.chipset == 'aga' and self.setpatch
            lores = 8 if aga else 5
            ham = 8 if aga else 6
            hires = 8 if aga else 4
            m = {}
            for mon in (ndk.PAL_MONITOR_ID, ndk.NTSC_MONITOR_ID):
                m[mon | ndk.LORES_KEY] = lores
                m[mon | ndk.HAM_KEY] = ham
                m[mon | ndk.HIRES_KEY] = hires
                if aga:
                    m[mon | ndk.HIRES_KEY | ndk.HAM_KEY] = 8
            m.update(self.max_depth)
            return m
        self.modi = modi

        def nominal(i):
            pal = (i & ~0xFFFF) == (ndk.PAL_MONITOR_ID & ~0xFFFF)
            return (640 if i & ndk.HIRES_KEY else 320), (256 if pal else 200)

        def find_display_info():
            i = d(0)
            d(0, (0x7F0000 | (i & 0xFFFF)) if i in modi() else 0)

        def get_display_info_data():
            buf, size, tag, i = a(1), d(0), d(1), d(2)
            if tag != ndk.DTAG_DIMS or i not in modi():
                d(0, 0)
                return
            n = min(size, ndk.dim_SIZEOF)
            self.u.mem_write(buf, bytes(n))
            self.ww(buf + ndk.dim_MaxDepth, modi()[i])
            if n >= ndk.dim_Nominal + 8:
                w, hh = nominal(i)
                for off, v in ((ndk.ra_MinX, 0), (ndk.ra_MinY, 0), (ndk.ra_MaxX, w - 1), (ndk.ra_MaxY, hh - 1)):
                    self.ww(buf + ndk.dim_Nominal + off, v)
            d(0, n)

        def load_rgb32():
            t, pal = a(1), []
            while True:
                w = self.rl(t)
                n = w >> 16
                if n == 0:
                    break
                t += 4
                for _ in range(n):
                    pal.append((self.rl(t) >> 24, self.rl(t + 4) >> 24, self.rl(t + 8) >> 24))
                    t += 12
            self.palette = ('rgb32', pal)

        def load_rgb4():
            t, n = a(1), d(0) & 0xFFFF
            pal = []
            for k in range(n):
                w = self.rw(t + 2 * k)
                pal.append((((w >> 8) & 15) * 17, ((w >> 4) & 15) * 17, (w & 15) * 17))
            self.palette = ('rgb4', pal)
        def get_vp_mode_id():
            sc = self.screen
            if not sc or a(0) != sc['addr'] + ndk.sc_ViewPort:
                d(0, ndk.INVALID_ID)
                return
            modes = self.rw(sc['addr'] + ndk.sc_ViewPort + ndk.vp_Modes)
            d(0, (sc['mode'] & ~ndk.HAM_KEY) | (ndk.HAM_KEY if modes & ndk.V_HAM else 0))
        h = {'FindDisplayInfo': find_display_info, 'GetDisplayInfoData': get_display_info_data,
             'LoadRGB4': load_rgb4, 'GetVPModeID': get_vp_mode_id}
        if self.gfx_version >= 39:
            h['LoadRGB32'] = load_rgb32
        return h

    def _int_handlers(self):
        d, a = self.d, self.a

        def tags(p):
            out = {}
            while True:
                t, v = self.rl(p), self.rl(p + 4)
                if t == ndk.TAG_DONE:
                    return out
                if t == ndk.TAG_MORE:
                    p = v
                    continue
                if t != ndk.TAG_IGNORE:
                    out[t] = v
                p += 8

        def lock_pub_screen():
            if a(0) or self.wb_schirm is None:
                d(0, 0)
                return
            self.pub_locks += 1
            d(0, self.wb_schirm)

        def unlock_pub_screen():
            if a(1) != self.wb_schirm or self.pub_locks <= 0:
                raise Pruefabbruch('UnlockPubScreen on a screen that is not locked 0x%06x' % a(1))
            if self.window and self.window.get('pub'):
                raise Pruefabbruch('UnlockPubScreen while a window is open on it')
            self.pub_locks -= 1

        def open_rtg_screen(tg):
            r = self.rtg
            scr = self.lib_alloc(512)
            self.u.mem_write(scr, bytes(512))
            bm = self.lib_alloc(64)
            self.u.mem_write(bm, bytes(64))
            self.wl(scr + ndk.sc_RastPort + ndk.rp_BitMap, bm)
            self.ww(scr + ndk.sc_Width, r.get('voll_breite', 640))
            self.ww(scr + ndk.sc_Height, r.get('voll_hoehe', 480))
            self.cgx_bitmaps[bm] = dict(cgx=True, depth=tg.get(ndk.SA_Depth, r['depth']),
                                        pixfmt=r.get('vollbild_pixfmt', r['pixfmt']))
            self.rtg_screen = dict(addr=scr, tags=tg)
            d(0, scr)

        def open_screen():
            if a(0):
                raise Pruefabbruch('OpenScreenTagList with NewScreen not reproduced')
            tg = tags(a(1))
            if self.rtg is not None and (tg.get(ndk.SA_DisplayID, 0) & 0xF0000000) == 0x50000000:
                if self.rtg_screen:
                    raise Pruefabbruch('second graphics card screen')
                open_rtg_screen(tg)
                return
            if self.screen or self.screen_fail:
                d(0, 0)
                return
            bm = tg.get(ndk.SA_BitMap)
            depth, mode = tg.get(ndk.SA_Depth), tg.get(ndk.SA_DisplayID)
            scr = self.lib_alloc(512)
            self.u.mem_write(scr, bytes(512))
            eigene = []
            if not bm:
                # Intuition creates the BitMap - planes individually, NOT in one piece
                bm = scr + ndk.sc_BitMap
                w, hgt = tg.get(ndk.SA_Width, 320), tg.get(ndk.SA_Height, 256)
                bpr = ((w + 15) // 16) * 2
                self.ww(bm + ndk.bm_BytesPerRow, bpr)
                self.ww(bm + ndk.bm_Rows, hgt)
                self.wb(bm + ndk.bm_Depth, depth)
                for k in range(depth):
                    pl = self.alloc_mem(bpr * hgt + 8, ndk.MEMF_CHIP | ndk.MEMF_CLEAR, 'Intuition')
                    self.alloc_mem(64, ndk.MEMF_CHIP, 'Intuition')     # Luecke dazwischen
                    eigene.append(pl)
                    self.wl(bm + ndk.bm_Planes + 4 * k, pl)
            bpr, rows, bdepth = self.rw(bm + ndk.bm_BytesPerRow), self.rw(bm + ndk.bm_Rows), self.rb(bm + ndk.bm_Depth)
            planes = [self.rl(bm + ndk.bm_Planes + 4 * k) for k in range(bdepth)]
            fehler = []
            if bdepth != depth:
                fehler.append('BitMap depth %d, SA_Depth %d' % (bdepth, depth))
            if bpr * 8 < tg.get(ndk.SA_Width, 0) or rows < tg.get(ndk.SA_Height, 0):
                fehler.append('BitMap smaller than the screen')
            for k, pl in enumerate(planes):
                if not (self.type_of_mem(pl) & ndk.MEMF_CHIP):
                    fehler.append('plane %d not in chip RAM' % k)
                if pl != planes[0] + k * bpr * rows:
                    fehler.append('plane %d not in one piece' % k)
            if depth == 6 and not (mode & ndk.HAM_KEY) and self.chipset == 'ecs':
                fehler.append('6 planes on ECS without HAM')
            if mode not in self.modi():
                fehler.append('mode 0x%08x not in the display database' % mode)
            elif depth > self.modi()[mode]:
                fehler.append('depth %d, the mode can do %d' % (depth, self.modi()[mode]))
            if tg.get(ndk.SA_Width, 0) > (640 if mode & ndk.HIRES_KEY else 320):
                fehler.append('SA_Width %d does not fit mode 0x%08x' % (tg.get(ndk.SA_Width, 0), mode))
            if fehler and not eigene:
                raise Pruefabbruch('OpenScreenTagList: ' + '; '.join(fehler))
            self.wl(scr + ndk.sc_RastPort + ndk.rp_BitMap, bm)
            ri = self.lib_alloc(16)
            self.u.mem_write(ri, bytes(16))
            self.wl(ri + ndk.ri_BitMap, bm)
            self.wl(scr + ndk.sc_ViewPort + ndk.vp_RasInfo, ri)
            modes = mode & 0xFFFF
            if tg.get(ndk.SA_BitMap) and self.sa_bitmap_ohne_ham:
                modes &= ~ndk.V_HAM
            self.ww(scr + ndk.sc_ViewPort + ndk.vp_Modes, modes)
            self.ww(scr + ndk.sc_Width, tg.get(ndk.SA_Width, 0))
            self.ww(scr + ndk.sc_Height, tg.get(ndk.SA_Height, 0))
            self.screen = dict(addr=scr, mode=mode, depth=depth, planes=planes[0], tags=tg,
                               bm=bm, eigene=eigene, bpr=bpr, rows=rows)
            # Intuition fills the background: the BitMap is cleared. Whether that
            # was the screen or the window on the A600 is open - the
            # test rig assumes the worse case and always clears at the screen.
            self.planes_loeschen(bm)
            self.copper_neu()
            d(0, scr)

        def close_screen():
            if self.rtg_screen and a(0) == self.rtg_screen['addr']:
                if self.window and self.window.get('screen') == a(0):
                    raise Pruefabbruch('CloseScreen before CloseWindow')
                self.closed_rtg_screen, self.rtg_screen = self.rtg_screen, None
                return
            if not self.screen or a(0) != self.screen['addr']:
                raise Pruefabbruch('CloseScreen on an unknown screen 0x%06x' % a(0))
            if self.window:
                raise Pruefabbruch('CloseScreen before CloseWindow')
            sc = self.screen
            for k, pl in enumerate(sc['eigene']):
                if self.rl(sc['bm'] + ndk.bm_Planes + 4 * k) != pl:
                    raise Pruefabbruch('CloseScreen: plane %d of the Intuition BitMap not restored' % k)
            size = sc['bpr'] * sc['rows'] + 8
            for pl in sc['eigene']:
                self.free_mem(pl, size, 'Intuition')
            for a_, (n_, f_, w_) in list(self.allocs.items()):
                if w_ == 'Intuition' and n_ == 64:
                    self.free_mem(a_, 64, 'Intuition')
            self.closed_screen, self.screen = self.screen, None

        def open_window():
            tg = tags(a(1))
            if self.window:
                raise Pruefabbruch('second window')
            pub = tg.get(ndk.WA_PubScreen)
            rtgsc = self.rtg_screen and tg.get(ndk.WA_CustomScreen) == self.rtg_screen['addr']
            if pub is not None:
                if pub != self.wb_schirm or self.pub_locks <= 0:
                    raise Pruefabbruch('OpenWindowTagList on a public screen that is not locked')
            elif not rtgsc and (not self.screen or tg.get(ndk.WA_CustomScreen) != self.screen['addr']):
                raise Pruefabbruch('OpenWindowTagList without a matching screen')
            win = self.lib_alloc(256)
            self.u.mem_write(win, bytes(256))
            port = self.lib_alloc(ndk.MP_SIZE)
            self.u.mem_write(port, bytes(ndk.MP_SIZE))
            n = next(i for i in range(31, 15, -1) if not (self.sigalloc >> i) & 1)
            self.sigalloc |= 1 << n
            self.wb(port + ndk.MP_SIGBIT, n)
            self.ports[port] = []
            self.wl(win + ndk.wd_UserPort, port)
            rp = self.lib_alloc(128)
            self.u.mem_write(rp, bytes(128))
            self.wl(win + ndk.wd_RPort, rp)
            if pub is not None:
                self.wb(win + ndk.wd_BorderLeft, 4)
                self.wb(win + ndk.wd_BorderTop, 11)
            self.window = dict(addr=win, port=port, idcmp=tg.get(ndk.WA_IDCMP, 0), sigbit=n, tags=tg,
                               pub=pub is not None, screen=pub if pub is not None else tg.get(ndk.WA_CustomScreen))
            if pub is not None or rtgsc:
                d(0, win)
                return
            if tg.get(ndk.WA_BackFill) != ndk.LAYERS_NOBACKFILL:
                self.planes_loeschen(self.rl(self.screen['addr'] + ndk.sc_RastPort + ndk.rp_BitMap))
            d(0, win)

        def close_window():
            w = self.window
            if not w or a(0) != w['addr']:
                raise Pruefabbruch('CloseWindow on an unknown window')
            self.ports.pop(w['port'], None)
            self.sigalloc &= ~(1 << w['sigbit'])
            self.closed_window, self.window = w, None
        return {'OpenScreenTagList': open_screen, 'CloseScreen': close_screen,
                'LockPubScreen': lock_pub_screen, 'UnlockPubScreen': unlock_pub_screen,
                'OpenWindowTagList': open_window, 'CloseWindow': close_window,
                'ScreenToFront': lambda: None,
                'MakeScreen': self.copper_neu, 'RethinkDisplay': self.copper_neu}

    def planes_loeschen(self, bm):
        bpr, rows, depth = self.rw(bm + ndk.bm_BytesPerRow), self.rw(bm + ndk.bm_Rows), self.rb(bm + ndk.bm_Depth)
        for k in range(depth):
            self.u.mem_write(self.rl(bm + ndk.bm_Planes + 4 * k), bytes(bpr * rows))

    def copper_neu(self):
        """Copper list from the state of the screen: BPLCON0 and the planes
        that are really displayed."""
        sc = self.screen
        if not sc:
            return
        modes = self.rw(sc['addr'] + ndk.sc_ViewPort + ndk.vp_Modes)
        bm = self.rl(self.rl(sc['addr'] + ndk.sc_ViewPort + ndk.vp_RasInfo) + ndk.ri_BitMap)
        depth = self.rb(bm + ndk.bm_Depth)
        # AGA-Guide: Bit 15 HIRES, 14-12 BPU2-0, 11 HAM, 9 COLOR, 4 BPU3
        bplcon0 = ((depth & 7) << 12) | (0x10 if depth & 8 else 0) | 0x200 \
            | (0x800 if modes & ndk.V_HAM else 0) | (0x8000 if modes & ndk.V_HIRES else 0)
        self.ww(self.copper, 0x0100)
        self.ww(self.copper + 2, bplcon0)
        self.ww(self.cpr + ndk.crl_MaxCount, 1)
        sc['bplcon0'] = bplcon0
        sc['angezeigt'] = [self.rl(bm + ndk.bm_Planes + 4 * k) for k in range(depth)]

    def taste(self, t_us, code):
        """At time t_us a VANILLAKEY message to the window."""
        def senden():
            if not self.window:
                return
            m = self.lib_alloc(64)
            self.u.mem_write(m, bytes(64))
            self.wl(m + ndk.im_Class, ndk.IDCMP_VANILLAKEY)
            self.ww(m + ndk.im_Code, code)
            self.wl(m + ndk.MN_REPLYPORT, self.int_port)
            self.put_msg(self.window['port'], m)
        self.at(t_us, senden)

    def put_msg(self, port, msg):
        q = self.ports.get(port)
        if q is None:
            raise Pruefabbruch('message to an unknown port 0x%06x' % port)
        q.append(msg)
        self.signal(1 << self.rb(port + ndk.MP_SIGBIT))

    def reply_io(self, req):
        """To be called by the device when a request is finished."""
        self.pending_io.pop(req, None)
        if self.rb(req + ndk.IO_FLAGS) & ndk.IOF_QUICK:
            return
        self.wb(req + ndk.LN_TYPE, ndk.NT_REPLYMSG)
        self.put_msg(self.rl(req + ndk.MN_REPLYPORT), req)

    def wait_io(self, req):
        while req in self.pending_io:
            if not self.events:
                raise Pruefabbruch('WaitIO: request 0x%06x never finishes' % req)
            self.now = max(self.now, self.events[0][0])
            self.run_events()
        port = self.rl(req + ndk.MN_REPLYPORT)
        q = self.ports.get(port)
        if q and req in q:
            q.remove(req)
            if not q:
                self.sigrecvd &= ~(1 << self.rb(port + ndk.MP_SIGBIT))

    # --- dos ----------------------------------------------------------------

    def _dos_handlers(self):
        d = self.d
        OUT = 0x4F55

        def write():
            fh, buf, n = d(1), d(2), d(3)
            if fh != OUT:
                raise Pruefabbruch('Write on handle 0x%x (only Output() is reproduced)' % fh)
            self.stdout += bytes(self.u.mem_read(buf, n))
            d(0, n)

        def put_str():
            self.stdout += self.cstr(d(1), 65536).encode('latin-1')
            d(0, 0)

        def open_():
            name, mode = self.cstr(d(1)), d(2)
            path = self.files.get(name)
            if mode != ndk.MODE_OLDFILE or path is None or not os.path.exists(path):
                self.ioerr = ndk.ERROR_OBJECT_NOT_FOUND
                d(0, 0)
                return
            h = 0x1000 + 4 * len(self.handles) + 4
            self.handles[h] = open(path, 'rb')
            d(0, h)

        def close():
            f = self.handles.pop(d(1), None)
            if f is None:
                raise Pruefabbruch('Close on an unknown handle 0x%x' % d(1))
            f.close()
            d(0, ndk.DOSTRUE & 0xFFFFFFFF)

        def read():
            f = self.handles.get(d(1))
            if f is None:
                raise Pruefabbruch('Read on an unknown handle 0x%x' % d(1))
            n = d(3)
            if self.read_max is not None:
                n = max(1, min(n, self.read_max()))
            b = f.read(n)
            self.u.mem_write(d(2), b)
            if self.read_us is not None:
                self.now += self.read_us(len(b))
            d(0, len(b))

        def print_fault():
            code, head = d(1), self.cstr(d(2))
            text = {ndk.ERROR_OBJECT_NOT_FOUND: 'object not found',
                    ndk.ERROR_REQUIRED_ARG_MISSING: 'required argument missing',
                    ndk.ERROR_BAD_NUMBER: 'bad number',
                    ndk.ERROR_TOO_MANY_ARGS: 'wrong number of arguments',
                    ndk.ERROR_KEY_NEEDS_ARG: 'keyword needs argument',
                    ndk.ERROR_NO_FREE_STORE: 'not enough memory'}.get(code, 'Error %d' % code)
            self.stdout += ('%s: %s\n' % (head, text) if head else text + '\n').encode('latin-1')
            d(0, ndk.DOSTRUE & 0xFFFFFFFF)

        return {
            'Output': lambda: d(0, OUT), 'Input': lambda: d(0, 0x4F49),
            'Write': write, 'PutStr': put_str, 'Open': open_, 'Close': close, 'Read': read,
            'IoErr': lambda: d(0, self.ioerr), 'SetIoErr': lambda: (d(0, self.ioerr), setattr(self, 'ioerr', d(1))),
            'PrintFault': print_fault, 'ReadArgs': self._read_args, 'FreeArgs': self._free_args,
        }

    def _read_args(self):
        """ReadArgs with /A /S /K /N. Only the cases the player needs."""
        d = self.d
        template, array = self.cstr(d(1)), d(2)
        items = []
        for part in template.split(','):
            f = part.split('/')
            alias = f[0].upper().split('=')          # GRAY=GREY: both names
            items.append((alias[0], set(x.upper() for x in f[1:]), alias))
        words = self.args.split()
        vals = {}
        rest = []
        i = 0
        err = 0
        while i < len(words):
            w = words[i]
            key, _, inl = w.partition('=')
            hit = next((it for it in items if key.upper() in it[2]), None)
            if hit is None:
                rest.append(w)
            elif 'S' in hit[1]:
                vals[hit[0]] = True
            else:
                if inl:
                    vals[hit[0]] = inl
                elif i + 1 < len(words):
                    i += 1
                    vals[hit[0]] = words[i]
                else:
                    err = ndk.ERROR_KEY_NEEDS_ARG
            i += 1
        for w in rest:
            slot = next((it for it in items if it[0] not in vals and not (it[1] & {'S', 'K'})), None)
            if slot is None:
                err = err or ndk.ERROR_TOO_MANY_ARGS
            else:
                vals[slot[0]] = w
        for name, fl, _ in items:
            if 'A' in fl and name not in vals:
                err = err or ndk.ERROR_REQUIRED_ARG_MISSING
        allocs = []
        if not err:
            for n, (name, fl, _) in enumerate(items):
                v = vals.get(name)
                if v is None:
                    continue
                if 'S' in fl:
                    self.wl(array + 4 * n, 0xFFFFFFFF)
                elif 'N' in fl:
                    try:
                        num = int(v, 10)
                    except ValueError:
                        err = ndk.ERROR_BAD_NUMBER
                        break
                    p = self.alloc_mem(4, 0, 'ReadArgs')
                    self.wl(p, num)
                    allocs.append((p, 4))
                    self.wl(array + 4 * n, p)
                else:
                    p = self.new_cstr(v)
                    allocs.append((p, len(v) + 1))
                    self.wl(array + 4 * n, p)
        if err:
            for p, s in allocs:
                self.free_mem(p, s, 'intern')
            self.ioerr = err
            d(0, 0)
            return
        rda = self.alloc_mem(32, ndk.MEMF_CLEAR, 'ReadArgs')
        self._rdargs = getattr(self, '_rdargs', {})
        self._rdargs[rda] = allocs
        d(0, rda)

    def _free_args(self):
        rda = self.d(1)
        if not rda:
            return
        recs = getattr(self, '_rdargs', {}).pop(rda, None)
        if recs is None:
            raise Pruefabbruch('FreeArgs on an unknown RDArgs 0x%06x' % rda)
        for p, s in recs:
            self.free_mem(p, s, 'intern')
        self.free_mem(rda, 32, 'ReadArgs')

    # --- loading and running -------------------------------------------------

    def load_hunks(self, path):
        data = open(path, 'rb').read()
        pos = 0

        def rdl():
            nonlocal pos
            v = struct.unpack('>I', data[pos:pos + 4])[0]
            pos += 4
            return v
        if rdl() != HUNK_HEADER:
            raise ValueError('not a hunk program')
        while rdl():
            raise ValueError('resident names are not supported')
        count, first, last = rdl(), rdl(), rdl()
        addrs, sizes, blocks = [], [], []
        for i in range(count):
            s = rdl()
            kind = s >> 30
            flags = 0
            if kind == 3:
                flags = rdl()
            elif kind == 1:
                flags = ndk.MEMF_CHIP
            elif kind == 2:
                flags = ndk.MEMF_FAST
            n = (s & 0x3FFFFFFF) * 4
            a = self.alloc_mem(n + 8, flags | ndk.MEMF_CLEAR, 'LoadSeg')
            if not a:
                raise Pruefabbruch('LoadSeg: no memory for hunk %d (%d bytes, flags 0x%x)' % (i, n, flags))
            addrs.append(a + 8)
            sizes.append(n)
            blocks.append((a, n + 8))
        for i, (a, n) in enumerate(blocks):
            self.wl(a, n)
            self.wl(a + 4, (blocks[i + 1][0] + 4) >> 2 if i + 1 < len(blocks) else 0)
        if blocks:
            self.wl(self.cli + ndk.cli_Module, (blocks[0][0] + 4) >> 2)
            self.hunks.append((a + 8, n, 'chip' if a < CHIP_HI else 'fast'))
        h = 0
        while pos < len(data):
            t = rdl() & 0x3FFFFFFF
            if t in (HUNK_CODE, HUNK_DATA):
                n = rdl() * 4
                self.u.mem_write(addrs[h], data[pos:pos + n])
                pos += n
            elif t == HUNK_BSS:
                rdl()
            elif t in (HUNK_RELOC32, HUNK_DREL32):
                while True:
                    n = rdl()
                    if n == 0:
                        break
                    tgt = rdl()
                    for _ in range(n):
                        off = rdl()
                        self.wl(addrs[h] + off, self.rl(addrs[h] + off) + addrs[tgt])
            elif t == HUNK_RELOC32SHORT:
                cnt = 0
                while True:
                    n = struct.unpack('>H', data[pos:pos + 2])[0]
                    pos += 2
                    cnt += 2
                    if n == 0:
                        break
                    tgt = struct.unpack('>H', data[pos:pos + 2])[0]
                    pos += 2
                    cnt += 2
                    for _ in range(n):
                        off = struct.unpack('>H', data[pos:pos + 2])[0]
                        pos += 2
                        cnt += 2
                        self.wl(addrs[h] + off, self.rl(addrs[h] + off) + addrs[tgt])
                if cnt & 2:
                    pos += 2
            elif t == HUNK_SYMBOL:
                while True:
                    n = rdl()
                    if n == 0:
                        break
                    name = data[pos:pos + n * 4].rstrip(b'\0').decode('latin-1')
                    pos += n * 4
                    self.symbols[name] = addrs[h] + rdl()
            elif t == HUNK_DEBUG:
                pos += rdl() * 4
            elif t == HUNK_END:
                h += 1
            else:
                raise ValueError('hunk type 0x%x is not supported' % t)
        return addrs

    def strict_align(self):
        """Abort word and longword accesses to odd addresses - on
        the 68000 that is an address error (Guru 8000 0003)."""
        from unicorn import UC_HOOK_MEM_READ, UC_HOOK_MEM_WRITE

        def chk(uc, acc, addr, size, val, ud):
            if size > 1 and addr & 1 and self.error is None:
                self.error = Pruefabbruch('address error: %d byte access at 0x%06x, PC 0x%06x' % (
                    size, addr, uc.reg_read(UC_M68K_REG_PC)))
                uc.emu_stop()
        self.u.hook_add(UC_HOOK_MEM_READ | UC_HOOK_MEM_WRITE, chk, begin=0, end=0xBFFFFF)

    def hook_symbol(self, name, fn):
        """Run fn() before the instruction at the symbol `name` runs."""
        if name not in self.symbols:
            raise Pruefabbruch('symbol %s is missing (program built without symbols?)' % name)
        a = self.symbols[name]
        self.u.hook_add(UC_HOOK_CODE, lambda uc, addr, size, ud: fn(), begin=a, end=a)

    def run(self, path, args='', stack=16384, after_load=None):
        """Load the program and run it until the RTS out of the start code."""
        addrs = self.load_hunks(path)
        if after_load:
            after_load(self)
        self.args = args
        line = (args + '\n').encode('latin-1')
        cl = self.alloc_mem(len(line) + 1, ndk.MEMF_CLEAR, 'intern')
        self.u.mem_write(cl, line)
        sp = self.alloc_mem(stack, ndk.MEMF_ANY, 'Stack') + stack
        sp -= 4
        self.wl(sp, EXIT_ADDR)
        self.u.reg_write(UC_M68K_REG_A7, sp)
        self.a(0, cl)
        self.d(0, len(line))
        self.error = None
        self.u.emu_start(addrs[0], EXIT_ADDR + 2)
        if self.error:
            raise self.error
        return self.exitcode

    def leaks(self):
        """What is still allocated after the run, apart from loader and test rig."""
        out = []
        for a, (size, flags, was) in sorted(self.allocs.items()):
            if was not in ('LoadSeg', 'Stack', 'intern'):
                out.append('%s 0x%06x %d Byte' % (was, a, size))
        for lib in self.libs_by_base.values():
            if lib.opencnt:
                out.append('%s still open %dx' % (lib.name, lib.opencnt))
        for dev in self.devices.values():
            if getattr(dev, 'opencnt', 0):
                out.append('%s still open %dx' % (dev.name, dev.opencnt))
        if self.user_ports:
            out.append('%d ports not deleted' % len(self.user_ports))
        if self.screen:
            out.append('screen not closed')
        if self.rtg_screen:
            out.append('graphics card screen not closed')
        if self.pub_locks:
            out.append('public screen still locked %dx' % self.pub_locks)
        if self.window:
            out.append('window not closed')
        if self.handles:
            out.append('%d files not closed' % len(self.handles))
        if self.forbid:
            out.append('Forbid-Zaehler %d' % self.forbid)
        return out


class TimerDevice:
    """timer.device: TR_ADDREQUEST for MICROHZ/VBLANK/ECLOCK/WAITECLOCK,
    ReadEClock. The E clock runs with the virtual time."""
    name = 'timer.device'

    def __init__(self):
        self.lvotab = {o: n for o, n in ndk.LVO['timer'].items()}
        self.handlers = {'ReadEClock': self._read_eclock, 'GetSysTime': self._get_systime}
        self.units = {}

    def ticks(self):
        return int(self.am.now * ECLOCK_FREQ / 1e6)

    def _read_eclock(self):
        t = self.ticks()
        ev = self.am.a(0)
        self.am.wl(ev + ndk.EV_HI, t >> 32)
        self.am.wl(ev + ndk.EV_LO, t)
        self.am.d(0, ECLOCK_FREQ)

    def _get_systime(self):
        tv = self.am.a(0)
        us = int(self.am.now)
        self.am.wl(tv + ndk.TV_SECS, us // 1000000)
        self.am.wl(tv + ndk.TV_MICRO, us % 1000000)

    def open(self, req, unit, flags):
        self.units[req] = unit
        return 0

    def close(self, req):
        self.units.pop(req, None)

    def begin_io(self, req):
        am = self.am
        cmd = am.rw(req + ndk.IO_COMMAND)
        if cmd != ndk.TR_ADDREQUEST:
            am.wb(req + ndk.IO_ERROR, ndk.IOERR_NOCMD)
            am.reply_io(req)
            return
        unit = self.units.get(req)
        s = am.rl(req + ndk.IOTV_TIME + ndk.TV_SECS)
        us = am.rl(req + ndk.IOTV_TIME + ndk.TV_MICRO)
        if unit in (ndk.UNIT_MICROHZ, ndk.UNIT_VBLANK):
            t = am.now + s * 1e6 + us
        elif unit == ndk.UNIT_ECLOCK:
            t = am.now + ((s << 32) | us) * 1e6 / ECLOCK_FREQ
        elif unit == ndk.UNIT_WAITECLOCK:
            t = ((s << 32) | us) * 1e6 / ECLOCK_FREQ
        else:
            raise Pruefabbruch('timer.device: unit %s not reproduced' % unit)
        am.wb(req + ndk.IO_ERROR, 0)
        am.pending_io[req] = self
        am.at(max(t, am.now), lambda: am.reply_io(req) if req in am.pending_io else None)

    def abort_io(self, req):
        am = self.am
        if req in am.pending_io:
            am.wb(req + ndk.IO_ERROR, ndk.IOERR_ABORTED & 0xFF)
            am.reply_io(req)
        return 0


class AhiDevice:
    """ahi.device in device mode: CMD_WRITE with ahir_Link.

    The autodoc (ahi.device/CMD_WRITE) says the link points BACKWARDS at a
    request already sent, and this request is delayed until that one has
    finished. The stub models exactly that, because the player's clock depends
    on it: it counts the completions, and it may only count them in the order
    in which the sound really runs.

    Checked here, because getting it wrong is silent on a desktop and audible
    on the Amiga: length a multiple of the frame size, io_Offset 0, volume and
    position inside their range, and a link that points at a request that is
    really still outstanding. `log` collects everything played, so a test can
    compare it with the stream (interleaved, signed, big endian).
    """
    name = 'ahi.device'
    TYPES = {ndk.AHIST_M8S: (1, 1), ndk.AHIST_S8S: (2, 1),
             ndk.AHIST_M16S: (1, 2), ndk.AHIST_S16S: (2, 2)}

    def __init__(self, units=(0,)):
        self.units = set(units)      # which units open; empty = none at all
        self.unit = None             # open right now
        self.unit_offen = None       # which unit it was (survives close)
        self.version = 0
        self.log = bytearray()
        self.busy = 0.0              # when the chain is finished
        self.leer = 0                # how often it ran dry in between
        self.puffer = 0
        self.ende = {}               # request -> end of its piece
        self.typ = None
        self.freq = None
        self.lvotab = {}
        self.handlers = {}

    def open(self, req, unit, flags):
        am = self.am
        if unit not in self.units:
            return ndk.IOERR_OPENFAIL & 0xFF
        self.version = am.rw(req + ndk.ahir_Version)
        if self.version < 4:
            raise Pruefabbruch('ahi.device: ahir_Version %d (CMD_WRITE needs 4)'
                               % self.version)
        self.unit = unit
        self.unit_offen = unit
        return 0

    def close(self, req):
        self.unit = None

    def begin_io(self, req):
        am = self.am
        cmd = am.rw(req + ndk.IO_COMMAND)
        am.wb(req + ndk.IO_ERROR, 0)
        if cmd != ndk.CMD_WRITE:
            am.wb(req + ndk.IO_ERROR, ndk.IOERR_NOCMD & 0xFF)
            am.reply_io(req)
            return
        data = am.rl(req + ndk.IO_DATA)
        ln   = am.rl(req + ndk.IO_LENGTH)
        off  = am.rl(req + ndk.IO_OFFSET)
        typ  = am.rl(req + ndk.ahir_Type)
        freq = am.rl(req + ndk.ahir_Frequency)
        vol  = am.rl(req + ndk.ahir_Volume)
        pos  = am.rl(req + ndk.ahir_Position)
        link = am.rl(req + ndk.ahir_Link)
        if typ not in self.TYPES:
            raise Pruefabbruch('ahi.device: ahir_Type %d not reproduced' % typ)
        chans, breite = self.TYPES[typ]
        fs = chans * breite
        if off:
            raise Pruefabbruch('ahi.device: io_Offset %d (has to be 0)' % off)
        if ln == 0 or ln % fs:
            raise Pruefabbruch('ahi.device: io_Length %d is not a multiple of the '
                               'frame size %d' % (ln, fs))
        if not 0 <= vol <= 0x10000:
            raise Pruefabbruch('ahi.device: ahir_Volume 0x%x out of range' % vol)
        if not 0 <= pos <= 0x10000:
            raise Pruefabbruch('ahi.device: ahir_Position 0x%x out of range' % pos)
        if self.typ is not None and (typ, freq) != (self.typ, self.freq):
            raise Pruefabbruch('ahi.device: format changed in mid-stream '
                               '(%d/%d -> %d/%d)' % (self.typ, self.freq, typ, freq))
        self.typ, self.freq = typ, freq
        if link:
            if link not in am.pending_io:
                raise Pruefabbruch('ahi.device: ahir_Link 0x%06x is not outstanding'
                                   % link)
            start = self.ende.get(link, am.now)
        else:
            # Nothing linked: a gap if the chain had already run out.
            if self.puffer and am.now > self.busy + 1:
                self.leer += 1
            start = max(am.now, self.busy)
        self.log += bytes(am.u.mem_read(data, ln))
        self.puffer += 1
        dauer = (ln / fs) * 1e6 / float(freq if freq else 1)
        self.busy = start + dauer
        self.ende[req] = self.busy
        am.pending_io[req] = self
        am.at(self.busy, lambda r=req: am.reply_io(r) if r in am.pending_io else None)

    def abort_io(self, req):
        am = self.am
        if req in am.pending_io:
            am.wb(req + ndk.IO_ERROR, ndk.IOERR_ABORTED & 0xFF)
            am.reply_io(req)
            self.ende.pop(req, None)
        return 0


class AudioDevice:
    """audio.device: channel allocation through the combination list, ADCMD_PERVOL,
    CMD_WRITE with timing behaviour. Per channel it records what Paula
    received, and counts how often it ran dry before the next
    buffer came."""
    name = 'audio.device'

    def __init__(self, clock=3546895):
        self.clock = clock
        self.log = {1: bytearray(), 2: bytearray(), 4: bytearray(), 8: bytearray()}
        self.busy = {1: 0.0, 2: 0.0, 4: 0.0, 8: 0.0}
        self.leer = {1: 0, 2: 0, 4: 0, 8: 0}
        self.puffer = {1: 0, 2: 0, 4: 0, 8: 0}
        self.pervol = {}
        self.allocated = 0
        self.lvotab = {}
        self.handlers = {}

    def open(self, req, unit, flags):
        am = self.am
        data, n = am.rl(req + ndk.ioa_Data), am.rl(req + ndk.ioa_Length)
        for m in bytes(am.u.mem_read(data, n)):
            if m and not (m & self.allocated):
                self.allocated |= m
                am.wl(req + ndk.IO_UNIT, m)
                am.ww(req + ndk.ioa_AllocKey, 1)
                return 0
        return ndk.ADIOERR_ALLOCFAILED & 0xFF

    def close(self, req):
        self.allocated = 0

    def begin_io(self, req):
        am = self.am
        cmd, unit = am.rw(req + ndk.IO_COMMAND), am.rl(req + ndk.IO_UNIT)
        if unit not in self.log or not (unit & self.allocated):
            raise Pruefabbruch('audio.device: channel 0x%x not allocated' % unit)
        am.wb(req + ndk.IO_ERROR, 0)
        if cmd == ndk.ADCMD_PERVOL:
            self.pervol[unit] = (am.rw(req + ndk.ioa_Period), am.rw(req + ndk.ioa_Volume))
            am.reply_io(req)
            return
        if cmd != ndk.CMD_WRITE:
            am.wb(req + ndk.IO_ERROR, ndk.IOERR_NOCMD & 0xFF)
            am.reply_io(req)
            return
        data, ln = am.rl(req + ndk.ioa_Data), am.rl(req + ndk.ioa_Length)
        per, cyc = am.rw(req + ndk.ioa_Period), am.rw(req + ndk.ioa_Cycles)
        if ln == 0 or ln & 1:
            raise Pruefabbruch('audio.device: length %d (Paula counts in words)' % ln)
        if not (am.type_of_mem(data) & ndk.MEMF_CHIP):
            raise Pruefabbruch('audio.device: sound data 0x%06x not in chip RAM' % data)
        if per < 124 or cyc != 1:
            raise Pruefabbruch('audio.device: period %d, cycles %d' % (per, cyc))
        if unit not in self.pervol:
            raise Pruefabbruch('audio.device: CMD_WRITE before ADCMD_PERVOL (the volume would stay 0)')
        self.log[unit] += bytes(am.u.mem_read(data, ln))
        start = max(am.now, self.busy[unit])
        if self.puffer[unit] and am.now > self.busy[unit] + 1:
            self.leer[unit] += 1
        self.puffer[unit] += 1
        self.busy[unit] = start + ln * per * 1e6 / self.clock
        am.pending_io[req] = self
        am.at(self.busy[unit], lambda r=req: am.reply_io(r) if r in am.pending_io else None)

    def abort_io(self, req):
        am = self.am
        if req in am.pending_io:
            am.wb(req + ndk.IO_ERROR, ndk.IOERR_ABORTED & 0xFF)
            am.reply_io(req)
        return 0
