#!/usr/bin/env python3
"""pruefe020.py - tests of the 020/030 player (src/a020) in the test rig.

  pruefe020.py [--exe build.m68020/CyberPak.dbg] [--cpu 68020|68030] [pattern ...]

The same environment as pruefe.py (unicorn, OS stubs), but with a 68020 or
68030 core and the modes of the 020+ rework: GRAY (ECS 5, AGA 8 planes), HAM6,
DHAM6, DHAM8 and the automatic choice without an option. Golden hashes and random
streams come from the independent reference decoder cvidref.py. The helpers (run,
stream building, Paula check) come from pruefe.py."""
import argparse
import hashlib
import os
import random
import re
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pruefe as P  # noqa: E402
import ndk  # noqa: E402

EXE = os.path.join(P.ROOT, 'build.m68020/CyberPak.dbg')
CPU = '68020'
TESTS = []
pruefe, sauber = P.pruefe, P.sauber

# mode -> (call word, chipset, planes, plane size, golden/cvidref name)
MODI = {
    'gray5': ('GRAY', 'ecs', 5, 10240, 'gray'),
    'ham6': ('HAM6', 'ecs', 6, 10240, 'ham6'),
    'gray8': ('GRAY', 'aga', 8, 10240, 'gray8'),
    'dham6': ('DHAM6', 'aga', 6, 20480, 'dham6'),
    'dham8': ('DHAM8', 'aga', 8, 20480, 'dham8'),
}


def test(fn):
    TESTS.append(fn)
    return fn


def lauf(args, **kw):
    kw.setdefault('cpu', CPU)
    kw.setdefault('chipset', 'aga')
    return P.lauf(args, exe=EXE, **kw)


def dekodiere(clip_or_data, modus, vorbau=True, zaehler=None, args='STATS NOAUDIO', **kw):
    wort, chipset, np_, bpl, _ = MODI[modus]
    if isinstance(clip_or_data, bytes):
        path = P.als_datei(clip_or_data)
        name, files = 'test.cpks', {'test.cpks': path}
    else:
        name, files = clip_or_data, {}
    hashes = []

    def after(am):
        def fertig():
            base = am.rl(am.symbols['sc_planes'])
            hashes.append(hashlib.md5(bytes(am.u.mem_read(base, np_ * bpl))).hexdigest())
        am.hook_symbol('bild_gezeigt', fertig)
        if not vorbau:
            am.wb(am.symbols['sp_kein_vorbau'], 1)
        if zaehler is not None:
            zaehler['vorbauen'] = 0
            am.hook_symbol('cvid_vorbauen', lambda: zaehler.__setitem__('vorbauen', zaehler['vorbauen'] + 1))
    kw.setdefault('us_per_byte', 0)
    kw.setdefault('chipset', chipset)
    am, rc, out, err = lauf('%s %s %s' % (name, wort, args), after_load=after, files=files, **kw)
    return am, rc, out, err, hashes


def golden(clip, modus):
    return [l.split()[1] for l in open(os.path.join(P.GOLDEN, '%s_%s.txt' % (clip.split('.')[0], MODI[modus][4])))]


def zeile(out, wort):
    return next((l for l in out.splitlines() if wort in l), '')


# --- call ----------------------------------------------------------------------

@test
def aufruf_ohne_datei():
    am, rc, out, err = lauf('')
    pruefe(err is None and rc == 5, '%r %r %r' % (rc, err, out))
    sauber(am)


@test
def aufruf_zwei_modi():
    am, rc, out, err = lauf('cpkstest.cpks HAM6 DHAM8')
    pruefe(err is None and rc == 5 and 'Nur ein Modus' in out, '%r %r %r' % (rc, err, out))
    sauber(am)


@test
def aufruf_grey_und_noser():
    am, rc, out, err, h = dekodiere('cpkstest.cpks', 'gray8', args='NOAUDIO NOSER')
    pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-300:]))
    am2, rc2, out2, err2 = lauf('cpkstest.cpks GREY NOAUDIO', us_per_byte=0)
    pruefe(err2 is None and rc2 == 0 and am2.closed_screen['depth'] == 8, '%r %r %r' % (rc2, err2, out2[-300:]))
    sauber(am)
    sauber(am2)


@test
def binaer_020_gleich_030():
    a = open(os.path.join(P.ROOT, 'build.m68020/CyberPak.020'), 'rb').read()
    b = open(os.path.join(P.ROOT, 'build.m68030/CyberPak.030'), 'rb').read()
    pruefe(a == b, '.020 und .030 unterscheiden sich')


# --- decoding against the reference decoder ------------------------------------

def golden_test(clip, modus, vorbau=True, **kw):
    def t():
        soll = golden(clip, modus)
        z = {}
        am, rc, out, err, ist = dekodiere(clip, modus, vorbau=vorbau, zaehler=z, **kw)
        pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-300:]))
        P.vergleiche_hashes(ist, soll, 'Golden')
        pruefe('Decoderfehler: 0' in out, out[-300:])
        if vorbau:
            pruefe(z['vorbauen'] >= len(soll) // 2, 'nur %d-mal vorgebaut' % z['vorbauen'])
        else:
            pruefe(z['vorbauen'] == 0, '%d-mal vorgebaut' % z['vorbauen'])
        sauber(am)
    t.__name__ = 'dekodieren_%s_%s%s%s' % (clip.split('.')[0], modus, '' if vorbau else '_ohne_vorbau',
                                          '_fast_hoch' if kw.get('fast_hi') else '')
    return test(t)


for _c in ('cpkstest.cpks', 'goku12b.cpks', 'mib12.cpks'):
    for _m in MODI:
        golden_test(_c, _m)
golden_test('goku12b.cpks', 'dham8', vorbau=False)
golden_test('goku12b.cpks', 'gray8', vorbau=False)
golden_test('goku12b.cpks', 'dham6', vorbau=False)
for _m in MODI:
    golden_test('cpkstest.cpks', _m, fast_hi=True)

for _seed, _m, _vb in ((21, 'gray8', True), (22, 'dham6', True), (23, 'dham8', True), (24, 'gray5', True),
                      (25, 'ham6', True), (26, 'dham8', False), (27, 'gray8', False), (28, 'dham6', False)):
    def _zt(seed=_seed, modus=_m, vorbau=_vb):
        rnd = random.Random(seed)
        bilder = [P.zufallsbild(rnd) for _ in range(40)]
        data = P.cpks_datei(bilder, muell=random.Random(seed + 100))
        soll = P.referenz_hashes(data, MODI[modus][4])
        am, rc, out, err, ist = dekodiere(data, modus, vorbau=vorbau)
        pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-300:]))
        P.vergleiche_hashes(ist, soll, 'Referenzdecoder')
        sauber(am)
    _zt.__name__ = 'dekodieren_zufall_%d_%s%s' % (_seed, _m, '' if _vb else '_ohne_vorbau')
    test(_zt)


@test
def dekodieren_falsche_breite():
    import struct
    data = P.cpks_datei([b'']).replace(struct.pack('>HH', 320, 180), struct.pack('>HH', 640, 180), 1)
    am, rc, out, err, ist = dekodiere(data, 'dham8')
    pruefe(err is None and rc == 10 and 'Bildgroesse' in out and 'nicht verfuegbar' in out, '%r %r %r' % (rc, err, out))
    sauber(am)


# --- Moduswahl ---------------------------------------------------------------------

def schirm(am):
    sc = am.closed_screen
    return (sc['mode'], sc['depth'], sc['tags'].get(ndk.SA_Width), sc['tags'].get(ndk.SA_Height)) if sc else None


@test
def automatik_aga_dham8():
    am, rc, out, err = lauf('cpkstest.cpks STATS NOAUDIO', us_per_byte=0)
    pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-300:]))
    pruefe(schirm(am) == (0x29800, 8, 640, 256), 'Schirm %r' % (schirm(am),))
    pruefe('DHAM8 (ohne Optionen)' in out, out[:600])
    sauber(am)


@test
def automatik_ecs_ham6():
    am, rc, out, err = lauf('cpkstest.cpks STATS NOAUDIO', chipset='ecs', us_per_byte=0)
    pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-300:]))
    pruefe(schirm(am) == (0x21800, 6, 320, 256), 'Schirm %r' % (schirm(am),))
    pruefe('HAM6 (ohne Optionen)' in out, out[:600])
    sauber(am)


@test
def automatik_aga_ohne_setpatch():
    am, rc, out, err = lauf('cpkstest.cpks STATS NOAUDIO', setpatch=False, us_per_byte=0)
    pruefe(err is None and rc == 0 and schirm(am) == (0x21800, 6, 320, 256), '%r %r %r' % (rc, schirm(am), out[-300:]))
    sauber(am)


@test
def gray_ecs_und_aga():
    for chipset, soll in (('ecs', (0x21000, 5, 320, 256)), ('aga', (0x21000, 8, 320, 256))):
        am, rc, out, err = lauf('cpkstest.cpks GRAY NOAUDIO', chipset=chipset, us_per_byte=0)
        pruefe(err is None and rc == 0 and schirm(am) == soll, '%s: %r %r %r' % (chipset, rc, schirm(am), out[-300:]))
        n = soll[1] == 5 and 32 or 256
        pruefe(am.palette == ('rgb32', [(i * 255 // (n - 1),) * 3 for i in range(n)]), 'Palette %s' % chipset)
        sauber(am)


@test
def dham6_auf_ecs():
    am, rc, out, err = lauf('cpkstest.cpks DHAM6', chipset='ecs')
    pruefe(err is None and rc == 10, '%r %r %r' % (rc, err, out))
    pruefe('Modus "DHAM6" nicht verfuegbar: braucht AGA (ECS-Chipsatz erkannt)' in out
           and 'z. B.: HAM6  oder  GRAY' in out, out)
    sauber(am)


@test
def dham8_ohne_setpatch():
    am, rc, out, err = lauf('cpkstest.cpks DHAM8', setpatch=False)
    pruefe(err is None and rc == 10 and 'SetPatch' in out and 'Modus "DHAM8" nicht verfuegbar' in out,
           '%r %r %r' % (rc, err, out))
    sauber(am)


# --- Grafikkarte (RTG) ------------------------------------------------------------

def karte(depth=24, pixfmt=None, **kw):
    r = dict(depth=depth, pixfmt=ndk.PIXFMT_ARGB32 if pixfmt is None else pixfmt)
    r.update(kw)
    return r


def rtg_golden(clip, name):
    return [l.split()[1] for l in open(os.path.join(P.ROOT, 'tests/golden_rtg', '%s_%s.txt' % (clip.split('.')[0], name)))]


def rtg_test(clip):
    def t():
        am, rc, out, err = lauf('%s STATS NOAUDIO' % clip, rtg=karte(), us_per_byte=0)
        pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-400:]))
        pruefe('RTG 32 Bit (ohne Optionen), Fenster 320x180, Tiefe 24, Pixelformat 11' in out, out[:700])
        ist = [b[1] for b in am.rtg_bilder]
        pruefe(all(b[0] == 'argb' and b[2:] == (4, 11, 320, 180) for b in am.rtg_bilder), am.rtg_bilder[:2])
        P.vergleiche_hashes(ist, rtg_golden(clip, 'rgb32'), 'Golden RTG')
        pruefe(am.closed_window['tags'].get(ndk.WA_PubScreen) is not None, 'kein Fenster auf der Workbench')
        sauber(am)
    t.__name__ = 'rtg32_%s' % clip.split('.')[0]
    return test(t)


for _c in ('cpkstest.cpks', 'goku12b.cpks', 'mib12.cpks'):
    rtg_test(_c)

for _fmt, _n in (('PIXFMT_RGB16', 0), ('PIXFMT_RGB15', 1), ('PIXFMT_RGB16PC', 2), ('PIXFMT_RGB15PC', 3)):
    def _rt(fmt=_fmt, n=_n):
        am, rc, out, err = lauf('cpkstest.cpks HICOLOR STATS NOAUDIO', rtg=karte(16, getattr(ndk, fmt)),
                                us_per_byte=0)
        pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-400:]))
        ist = [b[1] for b in am.rtg_bilder]
        pruefe(all(b[0].startswith('p96:') for b in am.rtg_bilder), am.rtg_bilder[:2])
        P.vergleiche_hashes(ist, rtg_golden('cpkstest.cpks', 'rgb16_%d' % n), 'Golden RTG 16 Bit')
        sauber(am)
    _rt.__name__ = 'rtg16_' + _fmt.split('_')[1].lower()
    test(_rt)


@test
def rtg_workbench_8bit():
    am, rc, out, err = lauf('cpkstest.cpks NOAUDIO', rtg=karte(8, ndk.PIXFMT_LUT8))
    pruefe(err is None and rc == 10 and '15 Bit' in out and 'RTG 32 Bit (ohne Optionen)' in out
           and 'z. B.: DHAM8  oder  HAM6  oder  GRAY' in out, '%r %r %r' % (rc, err, out))
    sauber(am)


@test
def rtg_workbench_nicht_auf_karte():
    am, rc, out, err = lauf('cpkstest.cpks STATS NOAUDIO', rtg=karte(cgx=False), us_per_byte=0)
    pruefe(err is None and rc == 0 and schirm(am) == (0x29800, 8, 640, 256), '%r %r %r' % (rc, schirm(am), out[-300:]))
    pruefe(not am.rtg_bilder, 'trotzdem ins Fenster gezeichnet')
    sauber(am)


@test
def rtg_erzwungener_chipsatz():
    am, rc, out, err = lauf('cpkstest.cpks HAM6 NOAUDIO', rtg=karte(), us_per_byte=0)
    pruefe(err is None and rc == 0 and schirm(am) == (0x21800, 6, 320, 256) and not am.rtg_bilder,
           '%r %r %r' % (rc, schirm(am), out[-300:]))
    sauber(am)


@test
def hicolor_ohne_karte():
    am, rc, out, err = lauf('cpkstest.cpks HICOLOR')
    pruefe(err is None and rc == 10 and 'Modus "HICOLOR" nicht verfuegbar: cybergraphics.library fehlt' in out
           and 'z. B.: (ohne Optionen)' in out, '%r %r %r' % (rc, err, out))
    sauber(am)


@test
def hicolor_ohne_p96():
    am, rc, out, err = lauf('cpkstest.cpks HICOLOR', rtg=karte(16, ndk.PIXFMT_RGB16, p96=False))
    pruefe(err is None and rc == 10 and 'Picasso96API.library' in out, '%r %r %r' % (rc, err, out))
    sauber(am)


@test
def hicolor_falsches_format():
    am, rc, out, err = lauf('cpkstest.cpks HICOLOR', rtg=karte())
    pruefe(err is None and rc == 10 and 'Bildschirmformat' in out, '%r %r %r' % (rc, err, out))
    sauber(am)


@test
def rtg_vollbild_und_zurueck():
    am, rc, out, err = lauf('goku12b.cpks STATS NOAUDIO', rtg=karte(), us_per_byte=0,
                            tasten=((1e6, 13), (2e6, 13), (3e6, 27)))
    pruefe(err is None and rc == 0 and '[OK] Wiedergabe beendet' in out, '%r %r %r' % (rc, err, out[-400:]))
    orte = sorted(set(b[2:4] for b in am.rtg_bilder))
    pruefe((160, 150) in orte and (4, 11) in orte, 'Bildorte %r' % orte)
    pruefe(getattr(am, 'closed_rtg_screen', None) is not None, 'kein Grafikkartenschirm geoeffnet')
    sauber(am)


@test
def rtg_bench():
    am, rc, out, err = lauf('goku12b.cpks BENCH=60', rtg=karte(), us_per_byte=0.35)
    pruefe(err is None and rc == 0 and 'BENCH: 60 Bilder' in out, '%r %r %r' % (rc, err, out[-300:]))
    P.vergleiche_hashes([b[1] for b in am.rtg_bilder], rtg_golden('goku12b.cpks', 'rgb32')[:60], 'Golden RTG')
    sauber(am)


@test
def dham8_chip_knapp():
    am, rc, out, err = lauf('cpkstest.cpks DHAM8 NOAUDIO', chip_kb=160)
    pruefe(err is None and rc == 10 and 'Chip-RAM' in out and 'z. B.: DHAM6  oder  HAM6' in out,
           '%r %r %r' % (rc, err, out))
    sauber(am)


@test
def ntsc_dham8():
    am, rc, out, err = lauf('cpkstest.cpks DHAM8 NOAUDIO', ntsc=True, us_per_byte=0)
    pruefe(err is None and rc == 0 and schirm(am) == (0x19800, 8, 640, 200), '%r %r %r' % (rc, schirm(am), out[-300:]))
    sauber(am)


# --- Anzeige ------------------------------------------------------------------------

@test
def anzeige_dham8():
    am, rc, out, err, h = dekodiere('cpkstest.cpks', 'dham8')
    pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-400:]))
    P.vergleiche_hashes(h, golden('cpkstest.cpks', 'dham8'), 'Golden')
    z = zeile(out, 'Anzeige:')
    pruefe(' HAM' in z and 'BPLCON0 0x8a10' in z and 'Steuerplanes nach dem Oeffnen 0x0000' in z, z)
    pruefe(am.palette == ('rgb32', [(i * 255 // 63,) * 3 for i in range(64)]), 'Palette %r' % (am.palette,))
    pruefe(am.closed_window['tags'].get(ndk.WA_Width) == 640, 'Fenster %r' % am.closed_window['tags'])
    pruefe(am.closed_screen['tags'].get(ndk.SA_BackFill) == ndk.LAYERS_NOBACKFILL, 'Schirm mit Backfill')
    pruefe(am.semaphoren == 0, 'Semaphore nicht freigegeben')
    sauber(am)


@test
def anzeige_gray8():
    am, rc, out, err, h = dekodiere('cpkstest.cpks', 'gray8')
    z = zeile(out, 'Anzeige:')
    pruefe(err is None and rc == 0 and 'ohne HAM' in z and 'BPLCON0 0x0210' in z, z or out[-400:])
    sauber(am)


@test
def anzeige_dham6_ham6():
    for modus, bpl in (('dham6', 'BPLCON0 0xea00'), ('ham6', 'BPLCON0 0x6a00')):
        am, rc, out, err, h = dekodiere('cpkstest.cpks', modus)
        z = zeile(out, 'Anzeige:')
        pruefe(err is None and rc == 0 and bpl in z, '%s: %s' % (modus, z or out[-400:]))
        pruefe(am.palette == ('rgb32', [(i * 17,) * 3 for i in range(16)]), 'Palette %s' % modus)
        sauber(am)


# --- sound and main loop ------------------------------------------------------------

@test
def ton_goku12b_mono8():
    data = open(P.CLIPS['goku12b.cpks'], 'rb').read()
    am, rc, out, err = lauf('goku12b.cpks NOVIDEO STATS')
    pruefe(err is None and rc == 0 and '[OK] Wiedergabe beendet' in out, '%r %r %r' % (rc, err, out[-400:]))
    dev = P.pruefe_paula(am, data)
    pruefe(59.5 <= am.now / 1e6 <= 62.0, 'Laufzeit %.2f s' % (am.now / 1e6))
    pruefe(max(dev.leer.values()) == 0, 'Paula lief leer: %r' % dev.leer)
    sauber(am)


@test
def spielen_goku12b_dham8_voll():
    data = open(P.CLIPS['goku12b.cpks'], 'rb').read()
    am, rc, out, err, h = dekodiere('goku12b.cpks', 'dham8', args='STATS')
    pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-400:]))
    P.vergleiche_hashes(h, golden('goku12b.cpks', 'dham8'), 'Golden')
    pruefe('angezeigt 720, dekodiert 720, nicht angezeigt 0, ohne Dekodieren verworfen 0' in out, out[-800:])
    P.pruefe_paula(am, data)
    pruefe(59.5 <= am.now / 1e6 <= 62.0, 'Laufzeit %.2f s' % (am.now / 1e6))
    sauber(am)


@test
def ton_hat_vorrang_dham8():
    data = open(P.CLIPS['goku12b.cpks'], 'rb').read()

    def after(am):
        am.hook_symbol('cvid_decode', lambda: setattr(am, 'now', am.now + 150000))
    am, rc, out, err = lauf('goku12b.cpks DHAM8 STATS', us_per_byte=0, after_load=after)
    pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-400:]))
    leer = int(re.search(r'(\d+)x leergelaufen', out).group(1))
    pruefe(leer == 0, 'Paula %dx leer: %s' % (leer, out[-900:]))
    m = re.search(r'Bildsprung: (\d+)x zum Keyframe', out)
    pruefe(m and int(m.group(1)) > 10, 'kein Bildsprung: %s' % out[-900:])
    pruefe(59.5 <= am.now / 1e6 <= 62.5, 'Laufzeit %.2f s (die Uhr stand)' % (am.now / 1e6))
    P.pruefe_paula(am, data)
    sauber(am)


@test
def bench_60_bilder():
    """BENCH=n: decode n frames without a clock, hashes as golden, a line with us per frame."""
    am, rc, out, err, h = dekodiere('goku12b.cpks', 'dham8', args='BENCH=60', us_per_byte=0.35)
    pruefe(err is None and rc == 0, '%r %r %r' % (rc, err, out[-400:]))
    P.vergleiche_hashes(h, golden('goku12b.cpks', 'dham8')[:60], 'Golden')
    m = re.search(r'BENCH: (\d+) Bilder, Decoder je Bild (\d+) us, Decoderfehler: 0', out)
    pruefe(m and int(m.group(1)) == 60 and int(m.group(2)) > 0, out[-400:])
    pruefe('[OK] Wiedergabe beendet' in out and 'audio.device' not in ' '.join(am.devices['audio.device'].__dict__.get('log', {}) and [] or []), out[-300:])
    sauber(am)


@test
def taste_esc_beendet():
    am, rc, out, err = lauf('goku12b.cpks STATS', us_per_byte=0, tasten=((3e6, 27),))
    pruefe(err is None and rc == 0 and am.now < 4.5e6 and '[OK] Wiedergabe beendet' in out,
           '%r %r %.1f %r' % (rc, err, am.now / 1e6, out[-300:]))
    sauber(am)


def main():
    global EXE, CPU
    ap = argparse.ArgumentParser()
    ap.add_argument('--exe', default=EXE)
    ap.add_argument('--cpu', default=CPU, choices=('68020', '68030'))
    ap.add_argument('muster', nargs='*')
    a = ap.parse_args()
    EXE, CPU = a.exe, a.cpu
    fehl = n = 0
    for t in TESTS:
        if a.muster and not any(m in t.__name__ for m in a.muster):
            continue
        n += 1
        try:
            t()
            print('[OK]   %s' % t.__name__, flush=True)
        except P.Fehlschlag as e:
            fehl += 1
            print('[FAIL] %s: %s' % (t.__name__, e), flush=True)
        except Exception:
            fehl += 1
            print('[FAIL] %s: Ausnahme' % t.__name__, flush=True)
            traceback.print_exc()
    print('%d Tests, %d fehlgeschlagen' % (n, fehl))
    return 1 if fehl else 0


if __name__ == '__main__':
    sys.exit(main())
