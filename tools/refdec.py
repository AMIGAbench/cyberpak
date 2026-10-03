#!/usr/bin/env python3
"""Independent Cinepak reference decoder (Y plane) for stage A/B of the verification.

Deliberately NOT derived from the C code, but written from the publicly
documented Cinepak bitstream structure, so that it can serve as an
arbiter between our decoder and ffmpeg.
"""
import struct, sys

def movi_frames(d):
    p = 12
    s = e = None
    while p < len(d) - 8:
        cid = d[p:p+4]; sz = struct.unpack('<I', d[p+4:p+8])[0]
        if cid == b'LIST':
            if d[p+8:p+12] == b'movi':
                s, e = p+12, p+8+sz; break
            p += 12; continue
        p += 8 + sz + (sz & 1)
    out = []; p = s
    while p < e - 8:
        cid = d[p:p+4]; sz = struct.unpack('<I', d[p+4:p+8])[0]
        if cid[2:4] in (b'dc', b'db'):
            out.append(d[p+8:p+8+sz])
        p += 8 + sz + (sz & 1)
    return out

MAXSTRIPS = 16

class Dec:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.Y = bytearray(w*h)
        # Cinepak keeps the codebooks PER STRIP, not globally - with
        # inheritance from the preceding strip when a strip supplies none of
        # its own. With single-strip material the difference never shows
        # up; with two-strip material at once.
        self.v1 = [[[0,0,0,0] for _ in range(256)] for _ in range(MAXSTRIPS)]
        self.v4 = [[[0,0,0,0] for _ in range(256)] for _ in range(MAXSTRIPS)]
        self.vmap1 = [0]*MAXSTRIPS
        self.vmap4 = [0]*MAXSTRIPS

    def put_v1(self, x, y, e):
        w, Y = self.w, self.Y
        y0,y1,y2,y3 = e
        for dy,(a,b) in enumerate(((y0,y1),(y0,y1),(y2,y3),(y2,y3))):
            o = (y+dy)*w + x
            if y+dy >= self.h: break
            Y[o]=a; Y[o+1]=a; Y[o+2]=b; Y[o+3]=b

    def put_v4(self, x, y, e0,e1,e2,e3):
        w, Y = self.w, self.Y
        rows = ((e0[0],e0[1],e1[0],e1[1]),
                (e0[2],e0[3],e1[2],e1[3]),
                (e2[0],e2[1],e3[0],e3[1]),
                (e2[2],e2[3],e3[2],e3[3]))
        for dy,r in enumerate(rows):
            if y+dy >= self.h: break
            o = (y+dy)*w + x
            Y[o]=r[0]; Y[o+1]=r[1]; Y[o+2]=r[2]; Y[o+3]=r[3]
    def frame(self, f):
        if len(f) < 10: return self.Y          # drop frame
        q = 1
        q += 3                                  # len24
        q += 4                                  # xsz, ysz
        strips = int.from_bytes(f[q:q+2],'big'); q += 2
        if strips > MAXSTRIPS: strips = MAXSTRIPS
        ytop = 0
        x = y = 0
        for kk in range(strips):
            # Inheritance: a strip without codebooks of its own takes over those
            # of its predecessor (or of the last one when kk == 0).
            if not self.vmap4[kk]:
                src = strips-1 if kk == 0 else kk-1
                self.v4[kk] = [e[:] for e in self.v4[src]]
                self.vmap4[kk] = 1
            if not self.vmap1[kk]:
                src = strips-1 if kk == 0 else kk-1
                self.v1[kk] = [e[:] for e in self.v1[src]]
                self.vmap1[kk] = 1
            cb4 = self.v4[kk]
            cb1 = self.v1[kk]
            q += 2
            topSize = int.from_bytes(f[q:q+2],'big'); q += 2
            q += 4
            y1 = int.from_bytes(f[q:q+2],'big'); q += 2
            q += 2
            ytop += y1
            topSize -= 12
            x = 0
            while topSize > 0 and q+4 <= len(f):
                cid   = int.from_bytes(f[q:q+2],'big'); q += 2
                cSize = int.from_bytes(f[q:q+2],'big'); q += 2
                topSize -= cSize
                body = cSize - 4
                end = q + body
                if cid in (0x2000, 0x2200):
                    if cid == 0x2000:
                        book = cb4
                        for i in range(strips): self.vmap4[i] = 0
                        self.vmap4[kk] = 1
                    else:
                        book = cb1
                        for i in range(strips): self.vmap1[i] = 0
                        self.vmap1[kk] = 1
                    n = body // 6
                    for i in range(n):
                        book[i] = [f[q], f[q+1], f[q+2], f[q+3]]
                        q += 6
                elif cid in (0x2100, 0x2300):
                    book = cb4 if cid == 0x2100 else cb1
                    ci = 0
                    while q + 4 <= end:
                        flag = int.from_bytes(f[q:q+4],'big'); q += 4
                        for b in range(32):
                            if flag >> (31-b) & 1:
                                if q+6 > end: break
                                book[ci] = [f[q], f[q+1], f[q+2], f[q+3]]
                                q += 6
                            ci += 1
                elif cid == 0x3000:
                    while q + 4 <= end and y < ytop:
                        flag = int.from_bytes(f[q:q+4],'big'); q += 4
                        for b in range(32):
                            if y >= ytop: break
                            if flag >> (31-b) & 1:
                                if q+4 > end: break
                                self.put_v4(x, y, cb4[f[q]], cb4[f[q+1]],
                                                  cb4[f[q+2]], cb4[f[q+3]])
                                q += 4
                            else:
                                if q >= end: break
                                self.put_v1(x, y, cb1[f[q]]); q += 1
                            x += 4
                            if x >= self.w: x = 0; y += 4
                elif cid == 0x3200:
                    while q < end and y < ytop:
                        self.put_v1(x, y, cb1[f[q]]); q += 1
                        x += 4
                        if x >= self.w: x = 0; y += 4
                elif cid == 0x3100:
                    # Continuous bitstream: 0=skip, 10=V1, 11=V4.
                    flag = 0; mask = 0
                    while True:
                        if y >= ytop: break
                        if mask == 0:
                            if q+4 > end: break
                            flag = int.from_bytes(f[q:q+4],'big'); q += 4
                            mask = 0x80000000
                        coded = (flag & mask) != 0
                        mask >>= 1
                        if coded:
                            if mask == 0:
                                if q+4 > end: break
                                flag = int.from_bytes(f[q:q+4],'big'); q += 4
                                mask = 0x80000000
                            isv4 = (flag & mask) != 0
                            mask >>= 1
                            if isv4:
                                if q+4 > end: break
                                self.put_v4(x, y, cb4[f[q]], cb4[f[q+1]],
                                                  cb4[f[q+2]], cb4[f[q+3]])
                                q += 4
                            else:
                                if q >= end: break
                                self.put_v1(x, y, cb1[f[q]]); q += 1
                        x += 4
                        if x >= self.w: x = 0; y += 4
                q = end
        return self.Y

if __name__ == '__main__':
    d = open(sys.argv[1],'rb').read()
    frames = movi_frames(d)
    w, h = int(sys.argv[3]), int(sys.argv[4])
    nmax = int(sys.argv[5]) if len(sys.argv) > 5 else 12
    dec = Dec(w, h)
    with open(sys.argv[2],'wb') as out:
        for i, f in enumerate(frames[:nmax]):
            out.write(bytes(dec.frame(f)))
    print("%d Frames" % min(nmax, len(frames)), file=sys.stderr)
