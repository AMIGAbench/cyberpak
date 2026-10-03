/* bytes.h - big endian reader for the bit stream.
 *
 * Replaces the macros from decoder/txt/Decode.h:150-172. Those cannot be taken
 * over for two reasons:
 *
 *  1. UB: "#define get16(p) (*p++)<<8 | (*p++)" modifies p twice without a
 *     sequence point. SAS/C evaluates left to right, gcc may not.
 *  2. Address Error: "flag = *(ulong *)from" (DecodeCVID.c:190,219,270,382)
 *     reads unaligned from the bit stream that is walked byte by byte. On
 *     68020+ merely slow, on the 68000 an immediate guru.
 *
 * Reading byte by byte also solves the endianness problem of the x86 host build.
 */
#ifndef CYBERPAK_BYTES_H
#define CYBERPAK_BYTES_H

#include <stdint.h>
#include "cpu.h"

static inline uint32_t rd_be16(const uint8_t *p)
{
    return ((uint32_t)p[0] << 8) | p[1];
}

static inline uint32_t rd_be24(const uint8_t *p)
{
    return ((uint32_t)p[0] << 16) | ((uint32_t)p[1] << 8) | p[2];
}

static inline uint32_t rd_be32(const uint8_t *p)
{
#if CVX_FAST_UNALIGNED
    /* 68020-68060: a single move.l is far cheaper than four move.b with
     * shift operations, and unaligned is allowed there. */
    return *(const uint32_t *)p;

#elif defined(__m68k__) && CPU_LEVEL >= 20
    /* 68080 (siehe cpu.h): unausgerichteten Zugriff vermeiden.
     *
     * `volatile` is MANDATORY here. Without it gcc recognises the byte-wise
     * assembly and builds exactly the one unaligned move.l from it that we
     * want to avoid - verified: the generated code was identical to the
     * default except for two unrelated lines. With volatile 1640 lines
     * change. */
    {
        const volatile uint8_t *q = p;
        uint32_t b0 = q[0], b1 = q[1], b2 = q[2], b3 = q[3];
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
    }

#else
    /* 68000 and host. On the 68000 gcc does not merge the four loads, because
     * an unaligned access would be an address error there; on x86 it may merge
     * them and does so. */
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
         | ((uint32_t)p[2] <<  8) |  (uint32_t)p[3];
#endif
}

static inline uint32_t rd_le16(const uint8_t *p)
{
    return ((uint32_t)p[1] << 8) | p[0];
}

static inline uint32_t rd_le32(const uint8_t *p)
{
    return ((uint32_t)p[3] << 24) | ((uint32_t)p[2] << 16)
         | ((uint32_t)p[1] <<  8) |  (uint32_t)p[0];
}

#define FOURCC(a,b,c,d) \
    (((uint32_t)(a)<<24) | ((uint32_t)(b)<<16) | ((uint32_t)(c)<<8) | (uint32_t)(d))

#endif
