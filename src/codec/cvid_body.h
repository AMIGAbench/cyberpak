/* cvid_body.h - the Cinepak bitstream parser as a template.
 *
 * Included once from cvid.c for each output mode. That way each mode has a
 * fully specialised loop of its own - instead of jumping eight times per
 * block through global function pointers as in the original
 * (DecodeCVID.c:232,237,256,282,295,311,316,329). The compiler can thereby
 * keep the row pointers and both codebook bases in address registers
 * throughout.
 *
 * Before the include the caller defines:
 *   CVID_FN        function name
 *   CVID_BPP       bytes per pixel
 *   CVID_MKCB1     build a codebook entry for V1
 *   CVID_MKCB4     build a codebook entry for V4
 *   CVID_PUT1      write a 4x4 block from one V1 entry
 *   CVID_PUT4      write a 4x4 block from four V4 entries
 *
 * The chunk semantics follow DecodeCVID.c:80-408 exactly.
 */

/* P1: form the codebook pointers BEFORE the first store.
 *
 * Without that gcc rematerialises the index arithmetic before every single
 * store - in the 68020 assembler `move.b (a0),d2` + `lsl.l #4,d2` stood
 * sixteen times instead of four. The reason is `cvx_u32a` with __may_alias__
 * (src/cpu.h): the compiler MUST assume that a store into the picture buffer
 * changes the bitstream `from[]`, and therefore reloads the index byte after
 * every store.
 *
 * The assumption is correct in substance and the annotation stays necessary -
 * only here does the programmer know more than the compiler: picture buffer
 * and bitstream never overlap. Four local pointers tell it that.
 *
 * Measured on the generated code: the PUT4 body shrinks from 200 to 108 bytes,
 * and the stores go from `(bd,An,Dn.l)` (7 cycles EA) to `(An)+` (2). */
#define CVID_V4(src_)                                          \
    do {                                                       \
        const CVID_CB *c0_ = &cb0[(src_)[0]];                  \
        const CVID_CB *c1_ = &cb0[(src_)[1]];                  \
        const CVID_CB *c2_ = &cb0[(src_)[2]];                  \
        const CVID_CB *c3_ = &cb0[(src_)[3]];                  \
        CVID_PUT4(p0, p1, p2, p3, c0_, c1_, c2_, c3_);         \
        CVID_MARK();                                           \
    } while (0)

#define CVID_V1(src_)                                          \
    do {                                                       \
        const CVID_CB *c_ = &cb1[*(src_)];                     \
        CVID_PUT1(p0, p1, p2, p3, c_);                         \
        CVID_MARK();                                           \
    } while (0)

/* --- dirty rows -------------------------------------------------------
 *
 * One byte per block row: set as soon as any block has been written in that
 * row at all. The pointer `drow` moves on exactly when the block advance
 * wraps into the next row - so it hangs on the same counting as p0 and
 * needs no arithmetic of its own.
 *
 * For modes without CVID_DIRTY both macros are empty; there not a single
 * instruction arises. */
#ifdef CVID_DIRTY
#  define CVID_MARK()          do { *drow = 1; } while (0)
#  define CVID_NEXTROW()       do { drow++;    } while (0)
#  define CVID_DROW            drow
#  define CVID_SET_DROW(v_)    do { drow = (v_); } while (0)
#else
#  define CVID_MARK()          do { } while (0)
#  define CVID_NEXTROW()       do { } while (0)
/* Without dirty rows the assembler version gets ctx->dirty as its target and
 * never writes there - its PUT macros do not mark at all. The pointer must
 * still be valid, because the loop frame moves it on. */
#  define CVID_DROW            ctx->dirty
#  define CVID_SET_DROW(v_)    do { (void)(v_); } while (0)
#endif

#if defined(CVID_ASM_3100) && CVID_ASM_3100
/* Fill the state block, call the assembler version, take over the result. */
#define CVID_RUN_ASM(fn)                                          \
    do {                                                          \
        cvid_loop lst;                                            \
        lst.from   = from;   lst.cend  = cend;                    \
        lst.p0     = p0;                                          \
        lst.cb0    = (const uint8_t *)cb0;                        \
        lst.cb1    = (const uint8_t *)cb1;                        \
        lst.ylimit = ylimit; lst.stride = (int32_t)stride;        \
        lst.binc   = binc;   lst.wrap  = wrap;                    \
        lst.bx     = bx;     lst.bcols = bcols;                   \
        lst.dirty  = CVID_DROW;                                   \
        fn(&lst);                                                 \
        from = lst.from; p0 = lst.p0; bx = lst.bx;                \
        CVID_SET_DROW(lst.dirty);                                 \
        p1 = p0 + stride; p2 = p1 + stride; p3 = p2 + stride;     \
    } while (0)
#endif

static int CVID_FN(cvid_ctx *ctx, const uint8_t *from, const uint8_t *end,
                   uint8_t *dst, uint32_t stride)
{
    const yuv_table *yt   = ctx->yt;
    const uint8_t   *rng  = ctx->rng;
#ifdef CVID_NEED_GRAY
    const int        gsh = ctx->gsh;
#endif
#ifdef CVID_NEED_RNG16
    const uint32_t  *t16R = ctx->rng16->r;
    const uint32_t  *t16G = ctx->rng16->g;
    const uint32_t  *t16B = ctx->rng16->b;
#endif
#ifdef CVID_NEED_RNGARGB
    /* Only the RGB32 path needs them; in the gray8 path three unused
     * pointers would only create register pressure. */
    const uint32_t  *rngR = ctx->rngargb->r;
    const uint32_t  *rngG = ctx->rngargb->g;
    const uint32_t  *rngB = ctx->rngargb->b;
#endif
    const uint32_t   width = ctx->width;

    /* Block step and row break are loop-invariant -> in the hot path
     * pure pointer addition remains, no multiplication (RPZA pattern). */
    const int32_t binc = 4 * CVID_BPP;
    /* Row break: from the last block of a block row (column width-4) to
     * the start of the next one (column 0, four rows lower). The
     * block advance itself is included - exactly that was wrong here at
     * first and shifted every block row by four pixels. */
    const int32_t wrap = (int32_t)(4 * stride)
                       - (int32_t)((width - 4) * CVID_BPP);

    uint8_t *p0, *p1, *p2, *p3;
#if defined(CVID_LEGACY_ADDR) && CVID_LEGACY_ADDR
    uint32_t x = 0;
    uint32_t yy = 0;
#else
    /* P4: count the blocks down to the end of the row instead of comparing
     * the width from memory for every block. */
    const uint32_t bcols = width >> 2;
    uint32_t bx = bcols;
#endif
    uint32_t strips, kk, cvidMapNum;
    uint32_t len;
    uint8_t *ylimit;          /* lower bound of the current strip */
#ifdef CVID_DIRTY
    uint8_t *drow = ctx->dirty;   /* current block row, see CVID_MARK */
#endif

    p0 = dst;
    p1 = p0 + stride;
    p2 = p1 + stride;
    p3 = p2 + stride;

    if (end - from < 10)
        return CVID_ERR_TRUNCATED;

    from++;                       /* flags */
    len = rd_be24(from); from += 3;
    if (len != ctx->last_size) {
        if (len & 1) len++;
        if (len != ctx->last_size)
            return CVID_ERR_SIZE;
    }
    from += 4;                    /* xsz, ysz */
    strips = rd_be16(from); from += 2;

    /* Unchecked in the original (DecodeCVID.c:103-106): a stream with more
     * than 16 strips runs past cvidMaps0[16..] there. */
    if (strips > CVID_MAX_STRIPS)
        strips = CVID_MAX_STRIPS;
    CVID_ST(ctx->st.strips = strips);
    cvidMapNum = strips;

    ctx->yTop = 0;

    for (kk = 0; kk < strips; kk++) {
        CVID_CB *cb0 = ctx->maps0[kk];    /* V4 - read by PUT4 only */
        CVID_CB *cb1 = ctx->maps1[kk];    /* V1 - read by PUT1 only */
        int32_t  topSize;
        uint32_t y1;

        /* Codebook inheritance from the preceding strip. Measured, this
         * practically never applies to real material (6 copies in 242
         * frames), because every strip supplies full codebooks anyway - the
         * branch stays nevertheless, because the bitstream allows it. */
        if (!ctx->vmap0[kk]) {
            uint32_t idx = (kk == 0) ? (strips - 1) : (kk - 1);
            memcpy(cb0, ctx->maps0[idx], sizeof(CVID_CB) * 256);
            ctx->vmap0[kk] = 1;
        }
        if (!ctx->vmap1[kk]) {
            uint32_t idx = (kk == 0) ? (strips - 1) : (kk - 1);
            memcpy(cb1, ctx->maps1[idx], sizeof(CVID_CB) * 256);
            ctx->vmap1[kk] = 1;
        }

        if (end - from < 12)
            return CVID_ERR_TRUNCATED;
        from += 2;                            /* topCid */
        topSize = (int32_t)rd_be16(from); from += 2;
        from += 4;                            /* y0, x0 */
        y1 = rd_be16(from); from += 2;
        from += 2;                            /* x1 */

        ctx->yTop += y1;
        topSize -= 12;
#if defined(CVID_LEGACY_ADDR) && CVID_LEGACY_ADDR
        x = 0;
#else
        bx = bcols;
#endif

        /* One multiply per strip (1-3 per frame), not per block. */
        ylimit = dst + (size_t)ctx->yTop * stride;

        while (topSize > 0) {
            uint32_t cid;
            int32_t  cSize;
            const uint8_t *cend;

            if (end - from < 4)
                return CVID_ERR_TRUNCATED;
            cid   = rd_be16(from); from += 2;
            cSize = (int32_t)rd_be16(from); from += 2;
            topSize -= cSize;
            cSize  -= 4;
            if (cSize < 0 || (end - from) < cSize)
                return CVID_ERR_TRUNCATED;
            cend = from + cSize;

            switch (cid) {

            /* --- full codebook --------------------------------------- */
            case 0x2000:            /* V4 */
            case 0x2200: {          /* V1 */
                CVID_CB *cm;
                uint32_t i, n = (uint32_t)cSize / 6;
                int is_v1 = (cid == 0x2200);

                /* THE CODEBOOK HAS 256 ENTRIES. `cSize` comes from the
                 * bitstream and can become up to 65531, so `n` up to 10921.
                 * Without this clamp a broken or malicious stream writes
                 * far past the block into the shared pool of all
                 * strips.
                 *
                 * The partial form has always checked it (`ci < 256`
                 * further down), the full one so far has not. It does not
                 * occur in real material - it is still not right. */
                if (n > 256) n = 256;

                if (is_v1) {
                    cm = cb1;
                    for (i = 0; i < cvidMapNum; i++) ctx->vmap1[i] = 0;
                    ctx->vmap1[kk] = 1;
                    CVID_ST(ctx->st.cb_v1 += n);
                } else {
                    cm = cb0;
                    for (i = 0; i < cvidMapNum; i++) ctx->vmap0[i] = 0;
                    ctx->vmap0[kk] = 1;
                    CVID_ST(ctx->st.cb_v4 += n);
                }

#if defined(CVID_ASM_MKCBFULL) && CVID_ASM_MKCBFULL
                {
                    cvid_mkcb mst;
                    mst.from  = from;
                    mst.cend  = from + (size_t)n * 6;   /* already clamped */
                    mst.cm    = (uint8_t *)cm;
                    mst.cmend = (const uint8_t *)(cm + 256);
                    mst.ytab  = yt->yTab;
                    /* Which three clamp tables apply depends on the
                     * output mode - the arithmetic behind it is the same. */
#if defined(CVID_NEED_GRAY)
                    /* Grey levels use neither yTab nor tables, only
                     * the quantisation. */
                    mst.tabr  = mst.tabg = mst.tabb = (const uint32_t *)0;
                    mst.gsh   = gsh;
#elif defined(CVID_NEED_RNG16)
                    mst.tabr  = t16R; mst.tabg = t16G; mst.tabb = t16B;
                    mst.gsh   = 0;
#else   /* CVID_NEED_RNGARGB - RGB32 */
                    mst.tabr  = rngR; mst.tabg = rngG; mst.tabb = rngB;
                    mst.gsh   = 0;
#endif
                    if (is_v1) CVID_ASM_MKCBFULL1(&mst);
                    else       CVID_ASM_MKCBFULL4(&mst);
                    from = mst.from;
                }
#else
                for (i = 0; i < n; i++) {
                    if (is_v1)
                        CVID_MKCB1(&cm[i], from[0], from[1], from[2], from[3],
                                   from[4] ^ 0x80, from[5] ^ 0x80);
                    else
                        CVID_MKCB4(&cm[i], from[0], from[1], from[2], from[3],
                                   from[4] ^ 0x80, from[5] ^ 0x80);
                    from += 6;
                }
#endif
                break;
            }

            /* --- partial codebook ------------------------------------ */
            case 0x2100:            /* V4 */
            case 0x2300: {          /* V1 */
                int is_v1 = (cid == 0x2300);
                CVID_CB *cm = is_v1 ? cb1 : cb0;
                uint32_t ci = 0;
#if defined(CVID_ASM_MKCB) && CVID_ASM_MKCB
                /* 98.6 % of all codebook entries run through here (measured
                 * on goku600a.avi). The full form 0x2000/0x2200 stays with
                 * the C code - it accounts for 1.4 %. */
                {
                    cvid_mkcb mst;
                    mst.from  = from;
                    mst.cend  = cend;
                    mst.cm    = (uint8_t *)cm;
                    mst.cmend = (const uint8_t *)(cm + 256);
                    mst.ytab  = yt->yTab;
                    /* Which clamp tables apply depends on the output mode -
                     * the routine itself is the same arithmetic. */
                    mst.tabr  = t16R;
                    mst.tabg  = t16G;
                    mst.tabb  = t16B;
                    if (is_v1) CVID_ASM_MKCB1P(&mst);
                    else       CVID_ASM_MKCB4P(&mst);
                    from = mst.from;
                    (void)ci;
                    break;
                }
#endif
                while (from + 4 <= cend) {
                    uint32_t flag = rd_be32(from); from += 4;
                    uint32_t mask = 0x80000000u;
                    while (mask) {
                        if ((mask & flag) && ci < 256) {
                            if (from + 6 > cend) break;
                            if (is_v1) {
                                CVID_MKCB1(&cm[ci], from[0], from[1], from[2],
                                           from[3], from[4] ^ 0x80, from[5] ^ 0x80);
                                CVID_ST(ctx->st.cb_v1++);
                            } else {
                                CVID_MKCB4(&cm[ci], from[0], from[1], from[2],
                                           from[3], from[4] ^ 0x80, from[5] ^ 0x80);
                                CVID_ST(ctx->st.cb_v4++);
                            }
                            from += 6;
                        }
                        ci++;
                        mask >>= 1;
                    }
                }
                break;
            }

            /* --- blocks, V1/V4 mixed --------------------------------- */
            case 0x3000:
#if defined(CVID_ASM_3100) && CVID_ASM_3100
                CVID_RUN_ASM(CVID_ASM_BLK3000);
                break;
#else
                while (from + 4 <= cend && p0 < ylimit) {
                    uint32_t flag = rd_be32(from); from += 4;
                    uint32_t mask = 0x80000000u;
                    while (mask) {
                        if (p0 >= ylimit) break;
                        if (mask & flag) {
                            if (from + 4 > cend) goto chunk_done;
                            CVID_V4(from);
                            from += 4;
                            CVID_ST(ctx->st.blk_v4++);
                        } else {
                            if (from + 1 > cend) goto chunk_done;
                            CVID_V1(from);
                            from++;
                            CVID_ST(ctx->st.blk_v1++);
                        }
                        CVID_BLOCKINC();
                        mask >>= 1;
                    }
                }
                break;
#endif

            /* --- blocks, V1 only ------------------------------------- */
            /* Deliberately stays with the C code: an assembler version was
             * 10-25 % SLOWER throughout in four attempts (measured on an
             * emulated 68020, 42825 against 38800 us/frame). With pure V1
             * the loop is so simple that gcc resolves it better -
             * the gain of the assembler version comes from the V4 path, and
             * that does not exist here. */
            case 0x3200:
                while (from < cend && p0 < ylimit) {
                    CVID_V1(from);
                    from++;
                    CVID_ST(ctx->st.blk_v1++);
                    CVID_BLOCKINC();
                }
                break;

            /* --- blocks with skip (the most frequent chunk) ----------- *
             * Continuous bitstream, MSB first, in 32-bit words:
             *   0      -> leave the block unchanged
             *   1 0    -> V1 block, one codebook index follows
             *   1 1    -> V4 block, four codebook indices follow
             * The bits continue across the word boundary; the
             * type bit may therefore lie in a new word.
             *
             * CAUTION: decoder/txt/DecodeCVID.c:263-338 does something
             * different here - it reads fixed 2-bit codes and runs a
             * flag0/flag1/flag2 state machine. That only coincides
             * when every block is coded, and otherwise gives a picture
             * offset. Checked against an independent reference decoder and
             * ffmpeg: the bitstream reading is the right one. */

            case 0x3100: {
#if defined(CVID_ASM_3100) && CVID_ASM_3100
                /* Hand-written version, see src/asm/cvid_blk_020.s.
                 * The C branch below it is kept as a yardstick -
                 * both have to return the same hash. */
                CVID_RUN_ASM(CVID_ASM_BLK3100);
                break;
            }
            case 0x7fff: {   /* never reached - keeps the C branch compilable */
#endif
                uint32_t flag = 0, mask = 0;
                for (;;) {
                    int coded;
                    if (p0 >= ylimit) break;
                    if (!mask) {
                        if (from + 4 > cend) break;
                        flag = rd_be32(from); from += 4;
                        mask = 0x80000000u;
                    }
                    coded = (flag & mask) != 0;
                    mask >>= 1;
                    if (coded) {
                        int isv4;
                        if (!mask) {
                            if (from + 4 > cend) break;
                            flag = rd_be32(from); from += 4;
                            mask = 0x80000000u;
                        }
                        isv4 = (flag & mask) != 0;
                        mask >>= 1;
                        if (isv4) {
                            if (from + 4 > cend) break;
                            CVID_V4(from);
                            from += 4;
                            CVID_ST(ctx->st.blk_v4++);
                        } else {
                            if (from >= cend) break;
                            CVID_V1(from);
                            from++;
                            CVID_ST(ctx->st.blk_v1++);
                        }
                    } else {
                        CVID_ST(ctx->st.blk_skip++);
                    }
                    CVID_BLOCKINC();
                }
                break;
            }

            default:
                return CVID_ERR_CHUNKID;
            }
#if !defined(CVID_ASM_3100) || !CVID_ASM_3100
        chunk_done:
#endif
            from = cend;     /* consume the chunk exactly */
        }
    }

    (void)yt; (void)rng; (void)binc; (void)wrap;
#if defined(CVID_LEGACY_ADDR) && CVID_LEGACY_ADDR
    (void)yy; (void)x;
#else
    (void)bcols; (void)bx;
#endif
    return 0;
}

#undef CVID_V4
#undef CVID_V1
/* This file is included once per output mode; the dirty macros
 * hang on CVID_DIRTY and must therefore be created anew each time. */
#undef CVID_MARK
#undef CVID_NEXTROW
#undef CVID_DROW
#undef CVID_SET_DROW
