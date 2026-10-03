; -----------------------------------------------------------------------------
; c2p1x1_6_c5_030_2w - chunky to planar, 6 bitplanes, for 68020/68030.
;
; ORIGIN: Mikael Kalms (Scout/C-Lous), mikael@kalms.org, from
; github.com/Kalmalyzer/kalms-c2p, directory normal/. Released into the public
; domain by the author - the same source as c2p1x1_5_c5_030 and
; c2p1x1_8_c5_040.
;
; CHANGES AGAINST THE ORIGINAL - only the addressing, the algorithm is
; untouched. A copy of c2p1x1_6_c5_030_2 for the double-width HAM modes
; (640 pixels, plane 20480 bytes):
;   * every name carries a trailing "w", so that both versions can live in the
;     same binary (the narrow one keeps its short displacements);
;   * BPLX 640 instead of 320 (size of the intermediate buffer);
;   * smc4 carries 2*bplsize. At 20480 that no longer fits into a word
;     displacement (Kalms: "bplsize must be less than or equal to 16kB").
;     There it is a 32-bit displacement now: vasm picks it by itself, because
;     the assembly-time value is 40960; the mark sits at *-4 and smcinit writes
;     a longword instead of a word.

; WHAT FOR: the HAM modes of the 68080 build, and the measurement direct
; against C2P on a (throttled) 030. Of Kalms' two 030 versions the faster one
; (1.06 instead of 1.12 vbl on a Blizzard 1230-IV at 50 MHz).
;
; CALLING CONVENTION:
;   c2p1x1_6_c5_030_2w_smcinit  d0.w chunkyx, d1.w chunkyy, d3.w scroffsy, d5.l bplsize
;   c2p1x1_6_c5_030_2w          a0 = chunky buffer, a1 = base of plane 0
; Planes in one piece, not interleaved, plane b at a1 + b*bplsize.
; -----------------------------------------------------------------------------


;
; 2000-04-17
;
; 1999-02-13
;
; c2p1x1_6_c5_030_2w
;
; 1.06 frames [all dma off] on Blizzard 1230-IV@50MHz
;
; 2000-04-17: added bplsize modifying init (smcinit)
; 1999-02-13: corrected bpl4/bpl5 order (output was swapped!)
;
; bplsize must be less than or equal to 16kB!
;

	IFND	BPLX
BPLX	EQU	640
	ENDC
	IFND	BPLY
BPLY	EQU	256
	ENDC
	IFND	BPLSIZE
BPLSIZE	EQU	BPLX*BPLY/8
	ENDC
	IFND	CHUNKYXMAX
CHUNKYXMAX EQU	BPLX
	ENDC
	IFND	CHUNKYYMAX
CHUNKYYMAX EQU	BPLY
	ENDC

;	incdir	include:
	include	lvo/exec_lib.i


	section	code,code

; d0.w	chunkyx [chunky-pixels]
; d1.w	chunkyy [chunky-pixels]
; d2.w	(scroffsx) [screen-pixels]
; d3.w	scroffsy [screen-pixels]
; d4.l	(rowlen) [bytes] -- offset between one row and the next in a bpl
; d5.l	bplsize [bytes] -- offset between one row in one bpl and the next bpl
; d6.l	(chunkylen) [bytes] -- offset between one row and the next in chunkybuf

	XDEF	_c2p1x1_6_c5_030_2w_smcinit
	XDEF	c2p1x1_6_c5_030_2w_smcinit
_c2p1x1_6_c5_030_2w_smcinit
c2p1x1_6_c5_030_2w_smcinit
	movem.l	d2-d3/d5/a6,-(sp)
	andi.l	#$ffff,d0
	mulu.w	d0,d3
	lsr.l	#3,d3
	move.l	d3,c2p1x1_6_c5_030_2w_scroffs
	mulu.w	d0,d1
	move.l	d1,c2p1x1_6_c5_030_2w_pixels

	move.w	d5,c2p1x1_6_c5_030_2w_smc1
	move.w	d5,c2p1x1_6_c5_030_2w_smc2
	move.w	d5,c2p1x1_6_c5_030_2w_smc5
	move.w	d5,c2p1x1_6_c5_030_2w_smc9

	move.w	d5,d0
	subq.w	#4,d0
	move.w	d0,c2p1x1_6_c5_030_2w_smc8

	move.w	d5,d0
	neg.w	d0
	subq.w	#4,d0
	move.w	d0,c2p1x1_6_c5_030_2w_smc3
	move.w	d0,c2p1x1_6_c5_030_2w_smc6

	move.l	d5,d0
	add.l	d5,d5
	move.l	d5,c2p1x1_6_c5_030_2w_smc4
	add.l	d0,d5
	move.l	d5,c2p1x1_6_c5_030_2w_smc7

	move.l	$4.w,a6
	jsr	_LVOCacheClearU(a6)
	movem.l	(sp)+,d2-d3/d5/a6
	rts

; d0.w	chunkyx [chunky-pixels]
; d1.w	chunkyy [chunky-pixels]
; d2.w	(scroffsx) [screen-pixels]
; d3.w	scroffsy [screen-pixels]
; d4.l	(rowlen) [bytes] -- offset between one row and the next in a bpl
; d5.l	(bplsize) [bytes] -- offset between one row in one bpl and the next bpl
; d6.l	(chunkylen) [bytes] -- offset between one row and the next in chunkybuf

	XDEF	_c2p1x1_6_c5_030_2w_init
	XDEF	c2p1x1_6_c5_030_2w_init
_c2p1x1_6_c5_030_2w_init
c2p1x1_6_c5_030_2w_init
	movem.l	d2-d3,-(sp)
	andi.l	#$ffff,d0
	mulu.w	d0,d3
	lsr.l	#3,d3
	move.l	d3,c2p1x1_6_c5_030_2w_scroffs
	mulu.w	d0,d1
	move.l	d1,c2p1x1_6_c5_030_2w_pixels
	movem.l	(sp)+,d2-d3
	rts

; a0	c2pscreen
; a1	bitplanes

	XDEF	_c2p1x1_6_c5_030_2w
	XDEF	c2p1x1_6_c5_030_2w
_c2p1x1_6_c5_030_2w
c2p1x1_6_c5_030_2w
	movem.l	d2-d7/a2-a6,-(sp)

	move.l	#$00ff00ff,a6

	add.w	#BPLSIZE,a1
c2p1x1_6_c5_030_2w_smc1 EQU *-2
	add.l	c2p1x1_6_c5_030_2w_scroffs,a1

	lea	c2p1x1_6_c5_030_2w_fastbuf,a3

	move.l	c2p1x1_6_c5_030_2w_pixels,a2
	add.l	a0,a2
	cmp.l	a0,a2
	beq	.none
	addq.l	#4,a2
	move.l	a1,-(sp)

	move.l	#$f0f0f0f0,d6

	move.l	(a0)+,d2
	move.l	(a0)+,d0
	move.l	(a0)+,d3
	move.l	(a0)+,d1

	move.l	d2,d7
	lsl.l	#4,d7
	eor.l	d0,d7
	and.l	d6,d7
	eor.l	d7,d0
	lsr.l	#4,d7
	eor.l	d7,d2
	move.l	d3,d7
	lsl.l	#4,d7
	eor.l	d1,d7
	and.l	d6,d7
	eor.l	d7,d1
	move.l	d2,(a3)+
	lsr.l	#4,d7
	eor.l	d7,d3
	move.l	d3,(a3)+

	move.l	(a0)+,d4
	move.l	(a0)+,d2
	move.l	(a0)+,d5
	move.l	(a0)+,d3

	move.l	d4,d7
	lsl.l	#4,d7
	eor.l	d2,d7
	and.l	d6,d7
	eor.l	d7,d2
	lsr.l	#4,d7
	eor.l	d7,d4
	move.l	d5,d7
	lsl.l	#4,d7
	eor.l	d3,d7
	and.l	d6,d7
	eor.l	d7,d3
	lsr.l	#4,d7
	eor.l	d7,d5

	move.w	d2,d7			; Swap 16x2
	move.w	d0,d2
	swap	d2
	move.w	d2,d0
	move.l	d4,(a3)+
	move.w	d7,d2

	move.w	d3,d7
	move.w	d1,d3
	move.l	d5,(a3)+
	swap	d3
	move.w	d3,d1
	move.w	d7,d3

	bra.s	.start1
.x1
	move.l	(a0)+,d0
	move.l	(a0)+,d3
	move.l	(a0)+,d1
	move.l	d7,BPLSIZE(a1)
c2p1x1_6_c5_030_2w_smc2 EQU *-2
	move.l	d2,d7
	lsl.l	#4,d7
	eor.l	d0,d7
	and.l	d6,d7
	eor.l	d7,d0
	lsr.l	#4,d7
	eor.l	d7,d2
	move.l	d3,d7
	lsl.l	#4,d7
	eor.l	d1,d7
	and.l	d6,d7
	eor.l	d7,d1
	move.l	d2,(a3)+
	lsr.l	#4,d7
	eor.l	d7,d3
	move.l	d3,(a3)+

	move.l	(a0)+,d4
	move.l	d4,d7
	lsl.l	#4,d7
	move.l	(a0)+,d2
	move.l	(a0)+,d5
	move.l	(a0)+,d3
	move.l	a4,(a1)+
	eor.l	d2,d7
	and.l	d6,d7
	eor.l	d7,d2
	lsr.l	#4,d7
	eor.l	d7,d4
	move.l	d5,d7
	lsl.l	#4,d7
	eor.l	d3,d7
	and.l	d6,d7
	eor.l	d7,d3
	lsr.l	#4,d7
	eor.l	d7,d5

	move.w	d2,d7			; Swap 16x2
	move.w	d0,d2
	swap	d2
	move.w	d2,d0
	move.l	d4,(a3)+
	move.w	d7,d2

	move.w	d3,d7
	move.w	d1,d3
	move.l	d5,(a3)+
	swap	d3
	move.w	d3,d1
	move.w	d7,d3

	move.l	a5,-BPLSIZE-4(a1)
c2p1x1_6_c5_030_2w_smc3 EQU *-2
.start1
	move.l	#$33333333,d5

	move.l	d2,d7			; Swap 2x2
	lsr.l	#2,d7
	eor.l	d0,d7
	and.l	d5,d7
	eor.l	d7,d0
	lsl.l	#2,d7
	eor.l	d7,d2

	move.l	d3,d7
	lsr.l	#2,d7
	eor.l	d1,d7
	and.l	d5,d7
	eor.l	d7,d1
	lsl.l	#2,d7
	eor.l	d7,d3

	move.l	a6,d4
	move.l	#$55555555,d5

	move.l	d1,d7
	lsr.l	#8,d7
	eor.l	d0,d7
	and.l	d4,d7
	eor.l	d7,d0
	lsl.l	#8,d7
	eor.l	d7,d1

	move.l	d1,d7
	lsr.l	#1,d7
	eor.l	d0,d7
	and.l	d5,d7
	eor.l	d7,d0
	move.l	d0,BPLSIZE*2(a1)
c2p1x1_6_c5_030_2w_smc4 EQU *-4
	add.l	d7,d7
	eor.l	d1,d7

	move.l	d3,d1
	lsr.l	#8,d1
	eor.l	d2,d1
	and.l	d4,d1
	eor.l	d1,d2
	lsl.l	#8,d1
	eor.l	d1,d3

	move.l	d3,d1
	lsr.l	#1,d1
	eor.l	d2,d1
	and.l	d5,d1
	eor.l	d1,d2
	move.l	d2,a4
	move.l	(a0)+,d2
	add.l	d1,d1
	eor.l	d1,d3
	move.l	d3,a5

	cmpa.l	a0,a2
	bne	.x1
.x1end
	move.l	d7,BPLSIZE(a1)
c2p1x1_6_c5_030_2w_smc5 EQU *-2
	move.l	a4,(a1)+
	move.l	a5,-BPLSIZE-4(a1)
c2p1x1_6_c5_030_2w_smc6 EQU *-2

	move.l	(sp)+,a1
	add.l	#BPLSIZE*3,a1
c2p1x1_6_c5_030_2w_smc7 EQU *-4

	move.l	c2p1x1_6_c5_030_2w_pixels,d0
	lsr.l	#1,d0
	lea	c2p1x1_6_c5_030_2w_fastbuf,a0
	lea	(a0,d0.l),a2

	move.l	(a0)+,d0
	move.l	#$55555555,d4
	move.l	#$33333333,d5
	move.l	#$00ff00ff,d6
	move.l	(a0)+,d1
	move.l	(a0)+,d2
	move.l	(a0)+,d3

	move.w	d2,d7			; Swap 16x2
	move.w	d0,d2
	swap	d2
	move.w	d2,d0
	move.w	d7,d2

	move.w	d3,d7
	move.w	d1,d3
	swap	d3
	move.w	d3,d1
	move.w	d7,d3

	lsl.l	#2,d0			; Merge 2x2
	lsl.l	#2,d1
	or.l	d2,d0
	or.l	d3,d1

	move.l	d1,d7
	lsr.l	#8,d7
	bra.s	.start2
.x2
	move.l	(a0)+,d0
	move.l	(a0)+,d1
	move.l	(a0)+,d2
	move.l	(a0)+,d3

	move.l	d7,(a1)+
	move.w	d2,d7			; Swap 16x2
	move.w	d0,d2
	swap	d2
	move.w	d2,d0
	move.w	d7,d2

	move.w	d3,d7
	move.w	d1,d3
	swap	d3
	move.w	d3,d1
	move.w	d7,d3

	lsl.l	#2,d0			; Merge 2x2
	lsl.l	#2,d1
	or.l	d2,d0
	or.l	d3,d1

	move.l	a6,BPLSIZE-4(a1)
c2p1x1_6_c5_030_2w_smc8 EQU *-2
	move.l	d1,d7
	lsr.l	#8,d7
.start2
	eor.l	d0,d7
	and.l	d6,d7
	eor.l	d7,d0
	lsl.l	#8,d7
	eor.l	d7,d1

	move.l	d1,d7
	lsr.l	#1,d7
	eor.l	d0,d7
	and.l	d4,d7
	eor.l	d7,d0
	add.l	d7,d7
	eor.l	d1,d7

	move.l	d0,a6

	cmpa.l	a0,a2
	bne.s	.x2

	move.l	d7,(a1)
	move.l	a6,BPLSIZE(a1)
c2p1x1_6_c5_030_2w_smc9 EQU *-2

.none
	movem.l	(sp)+,d2-d7/a2-a6
	rts

	section	bss,bss

c2p1x1_6_c5_030_2w_scroffs	ds.l	1
c2p1x1_6_c5_030_2w_pixels	ds.l	1

c2p1x1_6_c5_030_2w_fastbuf	ds.b	CHUNKYXMAX*CHUNKYYMAX/2
