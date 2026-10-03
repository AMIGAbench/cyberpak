* cvid_blk16_puts.i - the two PUT macros of the 16-bit block loops.
*
* They live here because TWO versions are built from them, differing in exactly
* one instruction:
*
*   cvid_blk3100_rgb16 / _rgb3000   without the dirty row mark (RTG path,
*                                   there is no C2P there)
*   cvid_blk3100_ham8  / _ham8      WITH the mark - HAM8 goes through C2P,
*                                   and C2P is the biggest item there,
*                                   because the screen is twice as wide.
*
* The difference is the macro MARKROW, which the including file defines BEFORE
* the include: empty or `st (a6)`. The frame carries a6 along anyway
* (cvid_blk_loops.i), and it is free in both PUT macros.
*
* Why not simply always mark: one `st` per block written is about 1,800
* instructions per frame. On the RTG path they would be pure cost - nobody
* reads the mark there.
* V4: four codebook indices, four 2x2 quarters. \1 = branch target on abort.
PUTV4   macro
        lea     4(a1),a0
        cmpa.l  a2,a0
        bhi     \1
        moveq   #0,d7
        move.b  (a1)+,d7
        add.l   d7,d7                        ; c0: idx*2, the *8 is done by the EA
        moveq   #0,d6
        move.b  (a1)+,d6
        add.l   d6,d6                        ; c1
        move.l  (a4,d7.l*8),(a3)             ; row 0: c0->q0 | c1->q0
        move.l  (a4,d6.l*8),4(a3)
        move.l  (4,a4,d7.l*8),(a3,d5.l)      ; row 1: c0->q1 | c1->q1
        move.l  (4,a4,d6.l*8),(4,a3,d5.l)
        moveq   #0,d7
        move.b  (a1)+,d7
        add.l   d7,d7                        ; c2
        moveq   #0,d6
        move.b  (a1)+,d6
        add.l   d6,d6                        ; c3
        lea     (a3,d5.l*2),a0               ; a0 = row 2
        move.l  (a4,d7.l*8),(a0)
        move.l  (a4,d6.l*8),4(a0)
        move.l  (4,a4,d7.l*8),(a0,d5.l)      ; row 3
        move.l  (4,a4,d6.l*8),(4,a0,d5.l)
        MARKROW
        endm

* V1: one index, 2x2 stretched to 4x4. \1 = branch target on abort.
*
* Two lessons from measuring, both against intuition:
*
*  - Rows 0 and 1 are equal, and so are 2 and 3. The values are therefore kept
*    in registers instead of being read twice.
*  - The codebook pointer is formed ONCE with lea and then read with (a0)+.
*    Four indexed accesses (a5,d7.l*8) compute the effective address every
*    time; post-increment is the cheapest mode on the 68020. The first version
*    had fewer instructions and was 22 % slower than the C code all the same.
*
*
* With V4 the indexed form stays: there every value is read only once, and
* there would be no register for two codebook pointers at the same time.
PUTV1   macro
        cmpa.l  a2,a1
        bcc     \1                           ; from >= cend
        moveq   #0,d7
        move.b  (a1)+,d7
        add.l   d7,d7
        ifd     AMMX
* --- 68080: a block row is 8 bytes, so ONE 64-bit access ---------------
* Row 0 is q[0]|q[1] - the first eight bytes of the entry, contiguous. Row 1
* is identical to it, and so are 2 and 3 from q[2]|q[3]. Two loads and four
* stores instead of four and eight.
*
* Alignment is guaranteed: the entries lie 16 bytes apart in one AllocVec
* block, and `width` is clamped to a multiple of 4, so stride = width*2 is a
* multiple of 8.
*
* For V4 AMMX does NOT pay off: there a row comes from two different entries
* (c0->q0 and c1->q0), and merging them costs one vperm per row, so more
* instructions than today's four move.l.
        load    (a5,d7.l*8),e0               ; q0|q1 = rows 0 and 1
        store   e0,(a3)
        store   e0,(a3,d5.l)
        lea     (a3,d5.l*2),a0
        load    (8,a5,d7.l*8),e1             ; q2|q3 = rows 2 and 3
        store   e1,(a0)
        store   e1,(a0,d5.l)
        else
        lea     (a5,d7.l*8),a0               ; a0 = &cb1[idx]
        move.l  (a0)+,d6                     ; q0
        move.l  (a0)+,d7                     ; q1
        move.l  d6,(a3)                      ; row 0
        move.l  d7,4(a3)
        move.l  d6,(a3,d5.l)                 ; row 1: the same
        move.l  d7,(4,a3,d5.l)
        move.l  (a0)+,d6                     ; q2
        move.l  (a0),d7                      ; q3
        lea     (a3,d5.l*2),a0
        move.l  d6,(a0)                      ; row 2
        move.l  d7,4(a0)
        move.l  d6,(a0,d5.l)                 ; row 3: the same
        move.l  d7,(4,a0,d5.l)
        endc
        MARKROW
        endm
