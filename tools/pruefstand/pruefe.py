#!/usr/bin/env python3
"""pruefe.py - tests of the 68000 player in the test rig.

  pruefe.py [--exe build.m68000/CyberPak.000] [muster ...]

Every test starts the program afresh, checks return code and output and, at the
end, that nothing stayed allocated or open. Needs unicorn (venv in the
scratchpad or `pip install unicorn`)."""
import argparse
import os
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
from amiga import Amiga, TimerDevice, AudioDevice, AhiDevice, Pruefabbruch  # noqa: E402
import ndk  # noqa: E402
import random  # noqa: E402
import struct  # noqa: E402
import tempfile  # noqa: E402
import hashlib  # noqa: E402
import subprocess  # noqa: E402
# The test clips are NOT in the repository (foreign source material). Directory
# through CYBERPAK_CLIPS, default clips/ in the project; symlinks are enough.
CLIPDIR = os.environ.get('CYBERPAK_CLIPS') or os.path.join(ROOT, 'clips')
CLIPS = {n: os.path.join(CLIPDIR, n) for n in ('goku12b.cpks', 'mib12.cpks', 'cpkstest.cpks')}

EXE = os.path.join(ROOT, 'build.m68000/CyberPak.dbg')
CPU = '68000'          # --cpu: the same tests under a different CPU model
TESTS = []


class Fehlschlag(Exception):
    pass


def test(fn):
    TESTS.append(fn)
    return fn


def pruefe(bedingung, text):
    if not bedingung:
        raise Fehlschlag(text)


def lauf(args, fast=True, setup=None, after_load=None, chip_kb=2048, files=None, read_max=None,
         strict=False, us_per_byte=0.35, gfx_version=40, chipset='ecs', tasten=(), read_us=None,
         cpu=None, fast_hi=False, setpatch=True, exe=None, ntsc=False, rtg=None, ahi=None):
    cpu = cpu or CPU
    am = Amiga(fast_kb=8192 if fast else 0, chip_kb=chip_kb, us_per_byte=us_per_byte,
               gfx_version=gfx_version, chipset=chipset, cpu=cpu, fast_hi=fast_hi, setpatch=setpatch,
               ntsc=ntsc, rtg=rtg)
    if strict and cpu == '68000':       # an address error exists only on the 68000
        am.strict_align()
    am.add_device(TimerDevice())
    am.add_device(AudioDevice())
    # ahi.device only when a test asks for it: without it OpenDevice fails,
    # which is exactly the machine without AHI (`ahi=()` = installed but no
    # unit opens).
    if ahi is not None:
        am.add_device(AhiDevice(units=ahi))
    for t, code in tasten:
        am.taste(t, code)
    am.files.update(CLIPS)
    am.files.update(files or {})
    am.read_max = read_max
    am.read_us = read_us
    if setup:
        setup(am)
    err = None
    rc = None
    try:
        rc = am.run(exe or EXE, args, after_load=after_load)
    except Pruefabbruch as e:
        err = str(e)
    return am, rc, am.stdout.decode('latin-1'), err


def sauber(am, erlaubt=()):
    rest = [x for x in am.leaks() if not any(x.startswith(e) for e in erlaubt)]
    pruefe(not rest, 'not released: ' + '; '.join(rest))


# --- Schritt 2: Geruest ------------------------------------------------------

@test
def ohne_argumente():
    am, rc, out, err = lauf('')
    pruefe(err is None, err)
    pruefe(rc == ndk.RETURN_ERROR if hasattr(ndk, 'RETURN_ERROR') else rc == 10, 'Rueckgabe %r' % rc)
    pruefe('required argument missing' in out, 'Ausgabe: %r' % out)
    sauber(am)


@test
def optionen_gueltig():
    am, rc, out, err = lauf('gibtsnicht.cpks HAM6 STATS ABUF=8 ANUM=4 NOAUDIO')
    pruefe(err is None, err)
    pruefe(rc == 20, 'Rueckgabe %r, Ausgabe %r' % (rc, out))
    for s in ('gibtsnicht.cpks', 'HAM6', 'ABUF 8', 'ANUM 4', 'NOAUDIO'):
        pruefe(s in out, '%r fehlt in %r' % (s, out))
    sauber(am)


@test
def optionen_vorgaben():
    am, rc, out, err = lauf('gibtsnicht.cpks STATS')
    pruefe(err is None, err)
    pruefe(rc == 20 and '5 planes 4-4-2' in out and 'ABUF 32' in out and 'ANUM 16' in out, out)
    sauber(am)


@test
def quiet_ohne_ausgabe():
    am, rc, out, err = lauf('cpkstest.cpks QUIET NOVIDEO NOAUDIO')
    pruefe(err is None and rc == 0, '%r %r' % (rc, err))
    pruefe(out == '', 'Ausgabe trotz QUIET: %r' % out)
    sauber(am)


@test
def ham6_und_gray():
    am, rc, out, err = lauf('goku12b.cpks HAM6 GRAY')
    pruefe(err is None, err)
    pruefe(rc == 20 and 'mutually exclusive' in out, '%r %r' % (rc, out))
    sauber(am)


@test
def abuf_null():
    am, rc, out, err = lauf('goku12b.cpks ABUF=0')
    pruefe(err is None and rc == 20 and 'ABUF' in out, '%r %r %r' % (rc, out, err))
    sauber(am)


@test
def abuf_keine_zahl():
    am, rc, out, err = lauf('goku12b.cpks ABUF=abc')
    pruefe(err is None and rc == 10 and 'bad number' in out, '%r %r %r' % (rc, out, err))
    sauber(am)


@test
def workbench_start():
    info = {}

    def setup(am):
        am.wl(am.proc + ndk.pr_CLI, 0)
        port = am.proc + ndk.pr_MsgPort
        am.wb(port + ndk.MP_SIGBIT, 8)
        am.ports[port] = []
        reply = am.lib_alloc(ndk.MP_SIZE)
        am.u.mem_write(reply, bytes(ndk.MP_SIZE))
        am.wb(reply + ndk.MP_SIGBIT, 9)
        am.ports[reply] = []
        msg = am.lib_alloc(64)
        am.u.mem_write(msg, bytes(64))
        am.wl(msg + ndk.MN_REPLYPORT, reply)
        am.ports[port].append(msg)
        info.update(port=port, reply=reply, msg=msg)

    am, rc, out, err = lauf('', setup=setup)
    pruefe(err is None, err)
    pruefe(am.ports[info['reply']] == [info['msg']], 'start message not answered')
    pruefe(am.ports[info['port']] == [], 'start message not collected')
    am.ports.pop(info['port'])
    am.ports.pop(info['reply'])
    sauber(am, erlaubt=('Forbid-Zaehler 1',))


# --- Schritt 3: CPKS-Leser --------------------------------------------------

MAXPKT = 128 * 1024


def pakete(data):
    """(type, flags, pts, payload, start, end) - reference of the format with
    resumption at the next sync word (as src/cpks.c)."""
    off, n = 0, len(data)
    while off + 16 <= n:
        if data[off:off + 4] != b'CPKS':
            nxt = data.find(b'CPKS', off + 1)
            if nxt < 0:
                return
            off = nxt
            continue
        typ, flags = data[off + 4], data[off + 5]
        pts, ln = struct.unpack('>II', data[off + 8:off + 16])
        if off + 16 + ln > n:
            return
        yield typ, flags, pts, data[off + 16:off + 16 + ln], off, off + 16 + ln + ((4 - (ln & 3)) & 3)
        off += 16 + ln + ((4 - (ln & 3)) & 3)


def erwartung(data):
    kopf, bilder, ton, zugross = None, [], bytearray(), 0
    for typ, flags, pts, pl, _, _ in pakete(data):
        if typ == 1:
            if kopf is None and len(pl) >= 36:
                kopf = struct.unpack('>HHHHIIIIBBHII', pl[:36])
            continue
        if kopf is None or typ not in (2, 3):
            continue
        if typ == 3 and kopf[7] == 0:
            continue
        if len(pl) > MAXPKT:
            zugross += 1
            continue
        if typ == 2:
            bilder.append((pts, flags & 1, bytes(pl)))
        else:
            ton += pl
    return kopf, bilder, bytes(ton), zugross


def lese(data_or_name, args='', read_max=None, **kw):
    if isinstance(data_or_name, bytes):
        tmp = tempfile.NamedTemporaryFile(suffix='.cpks', delete=False)
        tmp.write(data_or_name)
        tmp.close()
        name, files = 'test.cpks', {'test.cpks': tmp.name}
    else:
        name, files = data_or_name, {}
    rec = {'bilder': [], 'ton': bytearray()}
    args = (args + ' NOVIDEO NOAUDIO STATS').strip()   # here the reader is what counts

    def after(am):
        def bild():
            e = am.a(0)
            ptr, ln, pts, key = (am.rl(e + o) for o in (0, 4, 8, 12))
            rec['bilder'].append((pts, key, bytes(am.u.mem_read(ptr, ln)) if ln else b''))

        def ton():
            rec['ton'] += bytes(am.u.mem_read(am.a(0), am.d(0)))
        am.hook_symbol('bild_da', bild)
        am.hook_symbol('ton_sink', ton)
    kw.setdefault('strict', True)
    am, rc, out, err = lauf((name + ' ' + args).strip(), after_load=after, files=files,
                            read_max=read_max, **kw)
    return am, rc, out, err, rec


def vergleiche_strom(data, rec, out):
    kopf, bilder, ton, zugross = erwartung(data)
    pruefe(len(rec['bilder']) == len(bilder), 'frames: %d instead of %d' % (len(rec['bilder']), len(bilder)))
    for i, (a, b) in enumerate(zip(rec['bilder'], bilder)):
        pruefe(a == b, 'frame %d differs (pts %d/%d, key %d/%d, length %d/%d)' % (
            i, a[0], b[0], a[1], b[1], len(a[2]), len(b[2])))
    pruefe(bytes(rec['ton']) == ton, 'sound: %d bytes instead of %d' % (len(rec['ton']), len(ton)))
    keys = sum(1 for b in bilder if b[1])
    blk = max(1, kopf[8] * (kopf[9] // 8)) if kopf else 1
    soll = 'Stream: %d frames, %d keyframes, %d audio samples' % (len(bilder), keys, len(ton) // blk)
    pruefe(soll in out, 'expected %r in %r' % (soll, out))
    pruefe((' %d too large' % zugross) in out, 'too large: %r' % out)


def strom_test(clip):
    def t():
        data = open(CLIPS[clip], 'rb').read()
        am, rc, out, err, rec = lese(clip)
        pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out))
        vergleiche_strom(data, rec, out)
        sauber(am)
    t.__name__ = 'strom_' + clip.split('.')[0]
    return test(t)


for _c in CLIPS:
    strom_test(_c)


def gestoert(seed):
    """Break a real stream: rubbish in front of it and in between, foreign
    packet types, packets before the header, a wrong sync word, an oversized packet,
    a truncated end."""
    rnd = random.Random(seed)
    data = open(CLIPS['cpkstest.cpks'], 'rb').read()
    ps = list(pakete(data))
    out = bytearray(rnd.randbytes(37) + b'CPK' + rnd.randbytes(5))
    # one video and one audio packet BEFORE the header
    for typ in (2, 3):
        p = next(x for x in ps if x[0] == typ)
        out += data[p[4]:p[5]]
    for i, p in enumerate(ps):
        out += data[p[4]:p[5]]
        r = rnd.random()
        if r < 0.03:
            out += rnd.randbytes(rnd.randrange(1, 9))
        elif r < 0.05:
            ln = rnd.randrange(0, 40)
            out += b'CPKS' + bytes([9, 0, 0, 0]) + struct.pack('>II', 0, ln) + rnd.randbytes(ln) + bytes((4 - ln & 3) & 3)
        elif r < 0.06:
            out += b'CPKS' + rnd.randbytes(3)
        elif i == 40:
            ln = MAXPKT + 1000
            out += b'CPKS' + bytes([2, 1, 0, 0]) + struct.pack('>II', p[2], ln) + bytes(ln) + bytes((4 - ln & 3) & 3)
    cut = len(out) - rnd.randrange(100, 3000)
    return bytes(out[:cut])


for _seed in (1, 2, 3):
    def _gt(seed=_seed):
        data = gestoert(seed)
        am, rc, out, err, rec = lese(data)
        pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out))
        vergleiche_strom(data, rec, out)
        sauber(am)
    _gt.__name__ = 'strom_gestoert_%d' % _seed
    test(_gt)


@test
def strom_kurze_reads():
    data = open(CLIPS['goku12b.cpks'], 'rb').read()
    rnd = random.Random(7)
    am, rc, out, err, rec = lese('goku12b.cpks', read_max=lambda: rnd.choice((1, 3, 700, 4096, 20000, 70000)))
    pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out))
    vergleiche_strom(data, rec, out)
    sauber(am)


@test
def strom_datei_fehlt():
    am, rc, out, err = lauf('gibtsnicht.cpks')
    pruefe(err is None and rc == 20 and 'Cannot open or read' in out, '%r %r %r' % (rc, err, out))
    sauber(am)


@test
def strom_kein_cpks():
    am, rc, out, err, rec = lese(random.Random(3).randbytes(5000))
    pruefe(err is None and rc == 20 and 'Not a CPKS stream' in out, '%r %r %r' % (rc, err, out))
    sauber(am)


@test
def strom_zu_wenig_speicher():
    am, rc, out, err = lauf('goku12b.cpks', fast=False, chip_kb=200)
    pruefe(err is None and rc == 20 and 'Not enough memory' in out, '%r %r %r' % (rc, err, out))
    sauber(am)


# --- step 4: decoder --------------------------------------------------------

GOLDEN = os.path.join(ROOT, 'tests/golden_planar')
MODI = {'clut': '', 'gray': 'GRAY', 'ham6': 'HAM6'}
CVIDREF = os.path.join(HERE, 'cvidref.py')


def als_datei(data):
    tmp = tempfile.NamedTemporaryFile(suffix='.cpks', delete=False)
    tmp.write(data)
    tmp.close()
    return tmp.name


def dekodiere(clip_or_data, modus, strict=False, vorbau=True, zaehler=None):
    """vorbau=False: set sp_kein_vorbau, the path without pre-built codebooks.
    zaehler: dict, receives the number of calls of cvid_vorbauen."""
    if isinstance(clip_or_data, bytes):
        path = als_datei(clip_or_data)
        name, files = 'test.cpks', {'test.cpks': path}
    else:
        name, files = clip_or_data, {}
    hashes = []
    np_ = 6 if modus == 'ham6' else 5

    def after(am):
        def fertig():
            base = am.rl(am.symbols['sc_planes'])
            hashes.append(hashlib.md5(bytes(am.u.mem_read(base, np_ * 10240))).hexdigest())
        am.hook_symbol('bild_fertig', fertig)
        if not vorbau:
            am.wb(am.symbols['sp_kein_vorbau'], 1)
        if zaehler is not None:
            zaehler['vorbauen'] = 0
            am.hook_symbol('cvid_vorbauen', lambda: zaehler.__setitem__('vorbauen', zaehler['vorbauen'] + 1))
    am, rc, out, err = lauf(('%s %s STATS NOAUDIO' % (name, MODI[modus])).strip(), after_load=after,
                            files=files, strict=strict, us_per_byte=0)
    return am, rc, out, err, hashes


def vergleiche_hashes(ist, soll, was):
    pruefe(len(ist) == len(soll), '%s: %d frames instead of %d' % (was, len(ist), len(soll)))
    for i, (a, b) in enumerate(zip(ist, soll)):
        pruefe(a == b, '%s: frame %d differs' % (was, i))


def golden_test(clip, modus, vorbau=True):
    def t():
        soll = [l.split()[1] for l in open(os.path.join(GOLDEN, '%s_%s.txt' % (clip.split('.')[0], modus)))]
        z = {}
        am, rc, out, err, ist = dekodiere(clip, modus, strict=(clip == 'cpkstest.cpks'), vorbau=vorbau,
                                          zaehler=z)
        pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-300:]))
        vergleiche_hashes(ist, soll, 'Golden')
        pruefe('decoder errors: 0' in out, out[-300:])
        if vorbau:
            pruefe(z['vorbauen'] >= len(soll) // 2, 'only pre-built %d times' % z['vorbauen'])
        else:
            pruefe(z['vorbauen'] == 0, '%d-mal vorgebaut' % z['vorbauen'])
        sauber(am)
    t.__name__ = 'dekodieren_%s_%s%s' % (clip.split('.')[0], modus, '' if vorbau else '_ohne_vorbau')
    return test(t)


for _c in ('cpkstest.cpks', 'goku12b.cpks', 'mib12.cpks'):
    for _m in MODI:
        golden_test(_c, _m)
golden_test('goku12b.cpks', 'ham6', vorbau=False)
golden_test('mib12.cpks', 'clut', vorbau=False)


def cpks_datei(bilder, hoehe=180, muell=None):
    """CPKS stream without sound out of raw Cinepak frames."""
    out = bytearray()

    def paket(typ, flags, pts, pl):
        nonlocal out
        out += b'CPKS' + bytes([typ, flags]) + struct.pack('>HII', len(out) & 0xFFFF, pts, len(pl)) + pl
        out += bytes((4 - (len(pl) & 3)) & 3)
    paket(1, 0, 0, struct.pack('>HHHHIIIIBBHII', 1, 0, 320, hoehe, 12, 1, 1000, 0, 0, 0, 0, 0x63766964, 0))
    for i, b in enumerate(bilder):
        if muell and muell.random() < 0.2:
            out += muell.randbytes(muell.randrange(1, 4))
        paket(2, 1 if i % 12 == 0 else 0, i * 83, b)
    return bytes(out)


def zufallsbild(rnd):
    """A random, often broken Cinepak frame. Below 100 KB: the reader skips
    larger packets (MAXPKT), and then the frame numbers no longer match."""
    while True:
        b = _zufallsbild(rnd)
        if len(b) < 100000:
            return b


def _zufallsbild(rnd):
    strips = rnd.choice((1, 1, 2, 3, 17))
    body = bytearray()
    for _ in range(strips):
        chunks = bytearray()
        for _ in range(rnd.randrange(0, 5)):
            cid = rnd.choice((0x2000, 0x2200, 0x2100, 0x2300, 0x3000, 0x3000, 0x3100, 0x3100, 0x3200, 0x2400))
            if cid in (0x2000, 0x2200):
                data = rnd.randbytes(6 * rnd.randrange(0, 270) + rnd.randrange(0, 6))
            elif cid in (0x2100, 0x2300):
                data = bytearray()
                for _ in range(rnd.randrange(1, 9)):
                    fl = rnd.getrandbits(32) & rnd.getrandbits(32)
                    data += struct.pack('>I', fl) + rnd.randbytes(max(0, 6 * bin(fl).count('1') - rnd.choice((0, 0, 0, 5))))
            else:
                data = rnd.randbytes(rnd.randrange(0, 2500))
            chunks += struct.pack('>HH', cid, (len(data) + 4) & 0xFFFF) + data
        size = len(chunks) + 12
        if rnd.random() < 0.08:
            size = rnd.randrange(0, 65536)
        body += struct.pack('>HHHHHH', 0x1000, size & 0xFFFF, 0, 0, rnd.choice((4, 60, 90, 180, 250)), 320) + chunks
    frame = bytes([0]) + (len(body) + 10).to_bytes(3, 'big') + struct.pack('>HHH', 320, 180, strips) + body
    if rnd.random() < 0.05:
        frame = frame[:rnd.randrange(0, len(frame))]
    return frame


def referenz_hashes(data, modus):
    path = als_datei(data)
    out = path + '.%s.txt' % modus
    subprocess.run(['/usr/bin/python3', CVIDREF, path, modus, '--hashes', out], check=True,
                   capture_output=True)
    return [l.split()[1] for l in open(out)]


for _seed, _m, _vb in ((11, 'clut', True), (12, 'ham6', True), (13, 'gray', True), (14, 'clut', True),
                      (11, 'clut', False), (15, 'ham6', False)):
    def _zt(seed=_seed, modus=_m, vorbau=_vb):
        rnd = random.Random(seed)
        # real frames in between, so that the codebooks are not just rubbish
        bilder = [zufallsbild(rnd) for _ in range(40)]
        data = cpks_datei(bilder, muell=random.Random(seed + 100))
        soll = referenz_hashes(data, modus)
        am, rc, out, err, ist = dekodiere(data, modus, strict=True, vorbau=vorbau)
        pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-300:]))
        vergleiche_hashes(ist, soll, 'reference decoder')
        sauber(am)
    _zt.__name__ = 'dekodieren_zufall_%d_%s%s' % (_seed, _m, '' if _vb else '_ohne_vorbau')
    test(_zt)


@test
def dekodieren_falsche_breite():
    data = cpks_datei([b'']).replace(struct.pack('>HH', 320, 180), struct.pack('>HH', 640, 180), 1)
    am, rc, out, err, ist = dekodiere(data, 'clut')
    pruefe(err is None and rc == 10 and 'Picture size' in out and 'not available' in out, '%r %r %r' % (rc, err, out))
    sauber(am)


# --- steps 5-7: sound, screen, main loop -------------------------------------

def tonpakete(data):
    kopf, _, ton, _ = erwartung(data)
    return kopf, ton


def paula_soll(kopf, ton):
    """What Paula has to receive per channel: left, right (signed 8 bit)."""
    ch, bits = kopf[8], kopf[9]
    if bits == 8 and ch == 1:
        m = bytes(b ^ 0x80 for b in ton)
        return m, m
    if bits == 8:
        return bytes(b ^ 0x80 for b in ton[0::2]), bytes(b ^ 0x80 for b in ton[1::2])
    if ch == 1:
        m = bytes(ton[1::2])
        return m, m
    return bytes(ton[1::4]), bytes(ton[3::4])


def ahi_soll(kopf, ton):
    """What ahi.device has to receive: interleaved, signed, m68k word order.

    8 bit only flips the sign, 16 bit swaps the bytes of every sample - and
    keeps both of them, which is the point of the AHI path. Mono stays mono:
    AHIST_M*S plays one channel on both sides, so nothing is duplicated.
    """
    ch, bits = kopf[8], kopf[9]
    if bits == 8:
        return bytes(b ^ 0x80 for b in ton)
    out = bytearray(len(ton))
    out[0::2] = ton[1::2]
    out[1::2] = ton[0::2]
    return bytes(out)


def pruefe_ahi(am, data):
    kopf, ton = tonpakete(data)
    soll = ahi_soll(kopf, ton)
    dev = am.devices['ahi.device']
    pruefe(dev.unit is None, 'ahi.device not closed')
    ist = bytes(dev.log)
    fs = kopf[8] * (kopf[9] // 8)
    n = (len(soll) // fs) * fs
    pruefe(ist == soll[:n], 'AHI: %d bytes instead of %d%s' % (
        len(ist), n, '' if len(ist) != n else ', content differs'))
    return dev


def pruefe_paula(am, data):
    kopf, ton = tonpakete(data)
    links, rechts = paula_soll(kopf, ton)
    dev = am.devices['audio.device']
    pruefe(dev.allocated == 0, 'channels not released')
    l, r = bytes(dev.log[1]), bytes(dev.log[2])
    for name, ist, soll in (('left', l, links), ('right', r, rechts)):
        n = len(soll) & ~1
        pruefe(ist == soll[:n], 'Paula %s: %d bytes instead of %d%s' % (
            name, len(ist), n, '' if len(ist) != n else ', content differs'))
    return dev


def ton_test(name, clip, args, dauer=None):
    def t():
        data = open(CLIPS[clip], 'rb').read()
        am, rc, out, err = lauf('%s %s' % (clip, args))
        pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-400:]))
        pruefe('[OK] playback finished' in out, out[-400:])
        dev = pruefe_paula(am, data)
        if dauer:
            pruefe(dauer[0] <= am.now / 1e6 <= dauer[1], 'Laufzeit %.2f s' % (am.now / 1e6))
        pruefe(max(dev.leer.values()) <= 2, 'Paula lief leer: %r' % dev.leer)
        sauber(am)
    t.__name__ = name
    return test(t)


ton_test('ton_goku12b_mono8', 'goku12b.cpks', 'NOVIDEO STATS', dauer=(59.5, 62.0))
ton_test('ton_goku12b_abuf8', 'goku12b.cpks', 'NOVIDEO STATS ABUF=8', dauer=(59.5, 62.0))


def cpks_mit_ton(rate, chans, bits, sekunden, seed):
    rnd = random.Random(seed)
    out = bytearray()
    blk = chans * (bits // 8)

    def paket(typ, flags, pts, pl):
        nonlocal out
        out += b'CPKS' + bytes([typ, flags]) + struct.pack('>HII', 0, pts, len(pl)) + pl
        out += bytes((4 - (len(pl) & 3)) & 3)
    paket(1, 0, 0, struct.pack('>HHHHIIIIBBHII', 1, 0, 320, 180, 12, 1, rate, rate, chans, bits, 0,
                               0x63766964, rate // 2))
    je_bild = rate // 12
    pos = 0
    for i in range(12 * sekunden):
        paket(2, 1 if i % 12 == 0 else 0, pos, b'\0' * 10)
        n = je_bild + rnd.randrange(0, 3)
        paket(3, 0, pos, rnd.randbytes(n * blk))
        pos += n
    return bytes(out)


for _n, (_r, _c, _b) in (('stereo8', (22050, 2, 8)), ('stereo16', (11025, 2, 16)), ('mono16', (11025, 1, 16))):
    def _tt(r=_r, c=_c, b=_b):
        data = cpks_mit_ton(r, c, b, 6, r + c + b)
        path = als_datei(data)
        am, rc, out, err = lauf('test.cpks NOVIDEO STATS', files={'test.cpks': path})
        pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-400:]))
        pruefe_paula(am, data)
        sauber(am)
    _tt.__name__ = 'ton_' + _n
    test(_tt)


def schirm_lauf(clip, modus, **kw):
    hashes = []
    np_ = 6 if modus == 'ham6' else 5

    def after(am):
        def fertig():
            base = am.rl(am.symbols['sc_planes'])
            am.letzte_planes = base
            hashes.append(hashlib.md5(bytes(am.u.mem_read(base, np_ * 10240))).hexdigest())
        am.hook_symbol('bild_fertig', fertig)
    kw.setdefault('us_per_byte', 0)
    am, rc, out, err = lauf('%s %s %s' % (clip, MODI[modus], kw.pop('args', 'STATS NOAUDIO')),
                            after_load=after, **kw)
    return am, rc, out, err, hashes


def golden(clip, modus):
    return [l.split()[1] for l in open(os.path.join(GOLDEN, '%s_%s.txt' % (clip.split('.')[0], modus)))]


@test
def schirm_ham6_cpkstest():
    am, rc, out, err, h = schirm_lauf('cpkstest.cpks', 'ham6')
    pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-400:]))
    vergleiche_hashes(h, golden('cpkstest.cpks', 'ham6'), 'Golden')
    sc = am.closed_screen
    pruefe(sc and sc['mode'] == 0x21800 and sc['depth'] == 6, 'Schirm %r' % sc)
    pruefe(am.palette == ('rgb32', [(i * 17,) * 3 for i in range(16)]), 'palette %r' % (am.palette,))
    pruefe(am.closed_window['idcmp'] == 0x00200400, 'IDCMP %x' % am.closed_window['idcmp'])
    pruefe('mode 0x00021800' in out and 'Memory: hunks' in out, out[-600:])
    sauber(am)


@test
def schirm_clut_loadrgb4():
    am, rc, out, err, h = schirm_lauf('cpkstest.cpks', 'clut', gfx_version=37)
    pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-400:]))
    vergleiche_hashes(h, golden('cpkstest.cpks', 'clut'), 'Golden')
    soll = [((((i >> 3) * 85) >> 4) * 17, ((((i >> 1) & 3) * 85) >> 4) * 17, (((i & 1) * 255) >> 4) * 17)
            for i in range(32)]
    pruefe(am.palette == ('rgb4', soll), 'palette %r' % (am.palette,))
    pruefe(am.closed_screen['mode'] == 0x21000 and am.closed_screen['depth'] == 5, am.closed_screen)
    sauber(am)


@test
def schirm_gray_palette():
    am, rc, out, err, h = schirm_lauf('cpkstest.cpks', 'gray')
    pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-400:]))
    vergleiche_hashes(h, golden('cpkstest.cpks', 'gray'), 'Golden')
    pruefe(am.palette == ('rgb32', [(i * 255 // 31,) * 3 for i in range(32)]), 'palette %r' % (am.palette,))
    sauber(am)


@test
def schirm_tiefe_fehlt():
    def setup(am):
        am.max_depth[0x21800] = 5
    am, rc, out, err, h = schirm_lauf('cpkstest.cpks', 'ham6', setup=setup)
    pruefe(err is None and rc == 10, '%r %r %r' % (rc, err, out))
    pruefe('Mode "HAM6" not available' in out and 'e.g.: NOVIDEO' in out, out)
    sauber(am)


@test
def taste_esc_beendet():
    am, rc, out, err = lauf('goku12b.cpks STATS', us_per_byte=0, tasten=((3e6, 27),))
    pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-400:]))
    pruefe(am.now < 4.5e6, 'ran until %.1f s' % (am.now / 1e6))
    pruefe('[OK] playback finished' in out, out[-300:])
    sauber(am)


@test
def spielen_goku12b_voll():
    data = open(CLIPS['goku12b.cpks'], 'rb').read()
    am, rc, out, err, h = schirm_lauf('goku12b.cpks', 'clut', args='STATS')
    pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-400:]))
    vergleiche_hashes(h, golden('goku12b.cpks', 'clut'), 'Golden')
    pruefe('shown 720, decoded 720, not shown 0, dropped without decoding 0' in out, out[-800:])
    pruefe('661500 samples' in out, out[-800:])
    pruefe_paula(am, data)
    pruefe(59.5 <= am.now / 1e6 <= 62.0, 'Laufzeit %.2f s' % (am.now / 1e6))
    sauber(am)


@test
def ton_hat_vorrang():
    """A600 over the network, picture running: the picture takes longer than one
    frame spacing. The sound has to run on and the picture to skip - previously
    the reader stopped at a full queue, the audio packet behind the picture never
    arrived, Paula ran dry and the clock stood still. Here every frame costs 150 ms."""
    data = open(CLIPS['goku12b.cpks'], 'rb').read()

    def after(am):
        am.hook_symbol('cvid_decode', lambda: setattr(am, 'now', am.now + 150000))
    am, rc, out, err = lauf('goku12b.cpks HAM6 STATS', us_per_byte=0, after_load=after)
    pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-400:]))
    re_ = __import__('re')
    leer = int(re_.search(r'(\d+)x ran dry', out).group(1))
    pruefe(leer <= 1, 'Paula ran dry %dx: %s' % (leer, out[-900:]))
    m = re_.search(r'Frame jump: (\d+)x to the keyframe, dropped in the reader (\d+)', out)
    pruefe(m and int(m.group(1)) > 10, 'no frame jump: %s' % out[-900:])
    pruefe(59.5 <= am.now / 1e6 <= 62.5, 'run time %.2f s (the clock stood still)' % (am.now / 1e6))
    pruefe('661500 samples' in out, out[-900:])
    pruefe_paula(am, data)
    sauber(am)


# --- HAM6 display (A600: black and white with stripes) ------------------------

@test
def ham6_anzeige():
    """A600: HAM on, picture grey with stripes nonetheless - Intuition had cleared
    the control planes when opening. The test rig clears on opening
    the screen (and the window without WA_BackFill); the planes have to match
    the golden hashes afterwards all the same, so carry the control planes anew."""
    am, rc, out, err, h = schirm_lauf('cpkstest.cpks', 'ham6')
    pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-400:]))
    vergleiche_hashes(h, golden('cpkstest.cpks', 'ham6'), 'Golden')
    zeile = next((l for l in out.splitlines() if 'Display:' in l), '')
    pruefe(' HAM' in zeile and 'BPLCON0 0x6a00' in zeile and 'control planes after opening 0x0000' in zeile, zeile)
    pruefe(am.closed_window['tags'].get(ndk.WA_BackFill) == ndk.LAYERS_NOBACKFILL, 'window with backfill')
    pruefe(am.closed_screen['tags'].get(ndk.SA_BackFill) == ndk.LAYERS_NOBACKFILL, 'screen with backfill')
    pruefe(am.semaphoren == 0, 'semaphores not released')
    sauber(am)


@test
def anzeige_5planes():
    am, rc, out, err, h = schirm_lauf('cpkstest.cpks', 'clut')
    zeile = next((l for l in out.splitlines() if 'Display:' in l), '')
    pruefe(err is None and rc == 0 and 'without HAM' in zeile and 'BPLCON0 0x5200' in zeile
           and 'VP 0x00021000' in zeile, zeile or out[-400:])
    sauber(am)


# --- read size (READ=n) and read diagnostics -----------------------------------

for _rd in (1, 4, 16):
    def _lk(rd=_rd):
        data = gestoert(5)
        am, rc, out, err, rec = lese(data, args='READ=%d' % rd)
        pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-300:]))
        vergleiche_strom(data, rec, out)
        pruefe('of up to %d KB' % rd in out, out[-500:])
        sauber(am)
    _lk.__name__ = 'strom_read_%d' % _rd
    test(_lk)


@test
def read_ungueltig():
    for w in ('3', '0', '128'):
        am, rc, out, err = lauf('gibtsnicht.cpks READ=%s' % w)
        pruefe(err is None and rc == 20 and 'READ has to be' in out, 'READ=%s: %r %r %r' % (w, rc, err, out))
        sauber(am)


def netz_lauf(read_kb):
    """A network handler that delivers every read only when everything is there: 55 KB/s."""
    am, rc, out, err = lauf('goku12b.cpks NOVIDEO STATS READ=%d' % read_kb, us_per_byte=0,
                            read_us=lambda n: n * 1e6 / 55000)
    pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-400:]))
    zeile = next((l for l in out.splitlines() if 'Read:' in l), '')
    werte = [int(x) for x in __import__('re').findall(r'(\d+)', zeile)]
    sauber(am)
    return zeile, werte


@test
def netz_lesen_diagnose():
    z64, w64 = netz_lauf(64)
    z4, w4 = netz_lauf(4)
    # Read: N Read() of up to K KB each, total G ms, longest L ms, above one frame spacing: U
    pruefe(len(w64) == 5 and w64[1] == 64 and 1100 <= w64[3] <= 1250 and w64[4] > 30, z64)
    pruefe(len(w4) == 5 and w4[1] == 4 and 60 <= w4[3] <= 80 and w4[4] == 0, z4)
    pruefe(w4[0] > 10 * w64[0], 'Reads %d gegen %d' % (w4[0], w64[0]))


def main():
    global EXE, CPU
    ap = argparse.ArgumentParser()
    ap.add_argument('--exe', default=EXE)
    ap.add_argument('--cpu', default=CPU, choices=('68000', '68020', '68030'))
    ap.add_argument('muster', nargs='*')
    a = ap.parse_args()
    EXE = a.exe
    CPU = a.cpu
    fehl = 0
    n = 0
    for t in TESTS:
        if a.muster and not any(m in t.__name__ for m in a.muster):
            continue
        n += 1
        try:
            t()
            print('[OK]   %s' % t.__name__)
        except Fehlschlag as e:
            fehl += 1
            print('[FAIL] %s: %s' % (t.__name__, e))
        except Exception:
            fehl += 1
            print('[FAIL] %s: exception' % t.__name__)
            traceback.print_exc()
    print('%d tests, %d failed' % (n, fehl))
    return 1 if fehl else 0


if __name__ == '__main__':
    sys.exit(main())
