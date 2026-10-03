; -----------------------------------------------------------------------------
; c2p1x1_5_c5_030 - chunky to planar, 5 bitplanes, for 68020/68030.
;
; ORIGIN: Mikael Kalms (Scout/C-Lous), mikael@kalms.org, from
; github.com/Kalmalyzer/kalms-c2p, directory normal/. Released into the public
; domain by the author - the same source as the c2p1x1_8_c5_040 that is
; already in here.
;
; CHANGES AGAINST THE ORIGINAL: none. The file is unchanged.
;
; WHAT FOR: ECS can only do 5 bitplanes (32 colours) or 6 (64 colours, EHB or
; HAM). The 8-plane routine cannot be used for that - it would write three
; planes that do not exist on screen.
;
; THE DECISIVE DIFFERENCE TO THE 8-PLANE VERSION: there `bplsize` is a runtime
; parameter, here it is an ASSEMBLY-TIME constant - it sits as a displacement
; inside the addressing modes (`move.l d7,BPLSIZE(a1)`) and cannot be made
; variable without a rework.
;
; That settles the ECS path: the screen is ALWAYS 320x256 (BPLSIZE = 10240),
; and a smaller picture is centred inside it. The shifting is done by the
; `scroffsy` parameter of _init, which the routine brings along anyway. No
; self-modifying code, no cache question.
;
; CALLING CONVENTION:
;   c2p1x1_5_c5_030_init  d0.w chunkyx, d1.w chunkyy, d3.w scroffsy
;   c2p1x1_5_c5_030       a0 = chunky buffer, a1 = base of plane 0
;
; LAYOUT as with the 8-plane version: 5 contiguous, NON-interleaved bitplanes
; without row padding, plane b at a1 + b*BPLSIZE.
; -----------------------------------------------------------------------------


;				modulo	max res	fscreen	compu
; c2p1x1_5_c5_030		no	320x256?  no	030

	IFND	BPLX
BPLX	EQU	320
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

; For smcinit, which has to clear the instruction cache after modifying itself.
; From the NDK and not written by hand: in the 6-plane file the constant was
; once wrong (-640 instead of -636), and because the routine lay there unused,
; nobody noticed for years.
	include	"lvo/exec_lib.i"

	section	code,code

; d0.w	chunkyx [chunky-pixels]
; d1.w	chunkyy [chunky-pixels]
; d2.w	(scroffsx) [screen-pixels]
; d3.w	scroffsy [screen-pixels]
; d4.w	(rowlen) [bytes] -- offset between one row and the next in a bpl
; d5.l	(bplsize) [bytes] -- offset between one row in one bpl and the next bpl

; ---------------------------------------------------------------------------
; ADDED BY US. Kalms supplied this variant only for c2p1x1_6_c5_030 (there
; "2000-04-17: added bplsize modifying init"); the 5-plane file came without
; it. It is carried over line by line from the 6-plane version - same frame,
; same register use, same order - so that the comparison with the original
; stays possible. Differences:
;
;   * seven patch points instead of nine. The 5-plane loop has no
;     `move.l d7,-BPLSIZE(a1)` (smc8/smc9 of the 6-plane version).
;   * smc7 gets bplsize*3 instead of bplsize*4 - at the end the loop advances
;     by three planes, not by four.
;
; THE LIMIT APPLIES HERE JUST THE SAME: smc4 takes bplsize*2 into a WORD, above
; 16383 bytes that turns negative. The chipset path stays below it (screen.s).
; And unlike the 6-plane version this one has an intermediate buffer whose size
; is fixed at ASSEMBLY TIME (tempbuf, CHUNKYXMAX*CHUNKYYMAX/4) - so
; chunkyx*chunkyy has to be checked as well.
;
; d0.w	chunkyx [chunky-pixels]
; d1.w	chunkyy [chunky-pixels]
; d3.w	scroffsy [screen-pixels]
; d5.l	bplsize [bytes]

	XDEF	_c2p1x1_5_c5_030_smcinit
	XDEF	c2p1x1_5_c5_030_smcinit
_c2p1x1_5_c5_030_smcinit
c2p1x1_5_c5_030_smcinit
	movem.l	d2-d3/d5/a6,-(sp)
	andi.l	#$ffff,d0
	mulu.w	d0,d3
	lsr.l	#3,d3
	move.l	d3,c2p1x1_5_c5_030_scroffs
	mulu.w	d0,d1
	move.l	d1,c2p1x1_5_c5_030_pixels

	move.w	d5,c2p1x1_5_c5_030_smc1
	move.w	d5,c2p1x1_5_c5_030_smc2
	move.w	d5,c2p1x1_5_c5_030_smc5

	move.w	d5,d0
	neg.w	d0
	subq.w	#4,d0
	move.w	d0,c2p1x1_5_c5_030_smc3
	move.w	d0,c2p1x1_5_c5_030_smc6

	move.l	d5,d0
	add.l	d0,d0			; 2*bplsize
	move.w	d0,c2p1x1_5_c5_030_smc4
	add.l	d5,d0			; 3*bplsize
	move.w	d0,c2p1x1_5_c5_030_smc7	; word, not longword - see above

	move.l	$4.w,a6
	jsr	_LVOCacheClearU(a6)
	movem.l	(sp)+,d2-d3/d5/a6
	rts

	XDEF	_c2p1x1_5_c5_030_init
	XDEF	c2p1x1_5_c5_030_init
_c2p1x1_5_c5_030_init
c2p1x1_5_c5_030_init
	movem.l	d2-d3,-(sp)
	andi.l	#$ffff,d0
	mulu.w	d0,d3
	lsr.l	#3,d3
	move.l	d3,c2p1x1_5_c5_030_scroffs
	mulu.w	d0,d1
	move.l	d1,c2p1x1_5_c5_030_pixels
	movem.l	(sp)+,d2-d3
	rts

; a0	c2pscreen
; a1	bitplanes

	XDEF	_c2p1x1_5_c5_030
	XDEF	c2p1x1_5_c5_030
_c2p1x1_5_c5_030
c2p1x1_5_c5_030
	movem.l	d2-d7/a2-a6,-(sp)

	move.l	#$33333333,a6

	add.w	#BPLSIZE,a1
c2p1x1_5_c5_030_smc1 EQU *-2
	add.l	c2p1x1_5_c5_030_scroffs,a1
	lea	c2p1x1_5_c5_030_tempbuf,a3

	move.l	c2p1x1_5_c5_030_pixels,a2
	add.l	a0,a2
	cmp.l	a0,a2
	beq	.none

	move.l	a1,-(sp)

	move.l	(a0)+,d1
	move.l	(a0)+,d5
	move.l	(a0)+,d0
	move.l	(a0)+,d6

	move.l	#$0f0f0f0f,d4		; Swap 4x1, part 1
	move.l	d5,d7
	lsr.l	#4,d7
	eor.l	d1,d7
	and.l	d4,d7
	eor.l	d7,d1
	lsl.l	#4,d7
	eor.l	d7,d5

	move.l	d6,d7
	lsr.l	#4,d7
	eor.l	d0,d7
	and.l	d4,d7
	eor.l	d7,d0
	lsl.l	#4,d7
	eor.l	d7,d6

	move.l	(a0)+,d3
	move.l	(a0)+,d2

	move.l	d2,d7			; Swap 4x1, part 2
	lsr.l	#4,d7
	eor.l	d3,d7
	and.l	d4,d7
	eor.l	d7,d3
	lsl.l	#4,d7
	eor.l	d7,d2

	move.w	d3,d7			; Swap 16x4, part 1
	move.w	d1,d3
	swap	d3
	move.w	d3,d1
	move.w	d7,d3

	lsl.l	#2,d1			; Swap/Merge 2x4, part 1
	or.l	d1,d3
	move.l	d3,(a3)+

	move.l	(a0)+,d1
	move.l	(a0)+,d3

	move.l	d3,d7
	lsr.l	#4,d7
	eor.l	d1,d7
	and.l	d4,d7
	eor.l	d7,d1
	lsl.l	#4,d7
	eor.l	d7,d3

	move.w	d1,d7			; Swap 16x4, part 2
	move.w	d0,d1
	swap	d1
	move.w	d1,d0
	move.w	d7,d1

	lsl.l	#2,d0			; Swap/Merge 2x4, part 2
	or.l	d0,d1
	move.l	d1,(a3)+

	bra.s	.start1
.x1
	move.l	(a0)+,d1
	move.l	(a0)+,d5
	move.l	(a0)+,d0
	move.l	(a0)+,d6

	move.l	d7,BPLSIZE(a1)
c2p1x1_5_c5_030_smc2 EQU *-2

	move.l	#$0f0f0f0f,d4		; Swap 4x1, part 1
	move.l	d5,d7
	lsr.l	#4,d7
	eor.l	d1,d7
	and.l	d4,d7
	eor.l	d7,d1
	lsl.l	#4,d7
	eor.l	d7,d5

	move.l	d6,d7
	lsr.l	#4,d7
	eor.l	d0,d7
	and.l	d4,d7
	eor.l	d7,d0
	lsl.l	#4,d7
	eor.l	d7,d6

	move.l	(a0)+,d3
	move.l	(a0)+,d2

	move.l	a4,(a1)+

	move.l	d2,d7			; Swap 4x1, part 2
	lsr.l	#4,d7
	eor.l	d3,d7
	and.l	d4,d7
	eor.l	d7,d3
	lsl.l	#4,d7
	eor.l	d7,d2

	move.w	d3,d7			; Swap 16x4, part 1
	move.w	d1,d3
	swap	d3
	move.w	d3,d1
	move.w	d7,d3

	lsl.l 	#2,d1 			; Swap/Merge 2x4, part 1
	or.l 	d1,d3
	move.l 	d3,(a3)+

	move.l	(a0)+,d1
	move.l	(a0)+,d3

	move.l	a5,-BPLSIZE-4(a1)
c2p1x1_5_c5_030_smc3 EQU *-2

	move.l	d3,d7
	lsr.l	#4,d7
	eor.l	d1,d7
	and.l	d4,d7
	eor.l	d7,d1
	lsl.l	#4,d7
	eor.l	d7,d3

	move.w	d1,d7			; Swap 16x4, part 2
	move.w	d0,d1
	swap	d1
	move.w	d1,d0
	move.w	d7,d1

	lsl.l	#2,d0			; Swap/Merge 2x4, part 2
	or.l	d0,d1
	move.l	d1,(a3)+

.start1
	move.w	d2,d7			; Swap 16x4, part 3 & 4
	move.w	d5,d2
	swap	d2
	move.w	d2,d5
	move.w	d7,d2

	move.w	d3,d7
	move.w	d6,d3
	swap	d3
	move.w	d3,d6
	move.w	d7,d3

	move.l	a6,d0

	move.l	d2,d7			; Swap/Merge 2x4, part 3 & 4
	lsr.l	#2,d7
	eor.l	d5,d7
	and.l	d0,d7
	eor.l	d7,d5
	lsl.l	#2,d7
	eor.l	d7,d2

	move.l	d3,d7
	lsr.l	#2,d7
	eor.l	d6,d7
	and.l	d0,d7
	eor.l	d7,d6
	lsl.l	#2,d7
	eor.l	d7,d3

	move.l	#$00ff00ff,d4

	move.l	d6,d7			; Swap 8x2, part 1
	lsr.l	#8,d7
	eor.l	d5,d7
	and.l	d4,d7
	eor.l	d7,d5
	lsl.l	#8,d7
	eor.l	d7,d6

	move.l	#$55555555,d1

	move.l	d6,d7			; Swap 1x2, part 1
	lsr.l	d7
	eor.l	d5,d7
	and.l	d1,d7
	eor.l	d7,d5
	move.l	d5,BPLSIZE*2(a1)
c2p1x1_5_c5_030_smc4 EQU *-2
	add.l	d7,d7
	eor.l	d6,d7

	move.l	d3,d5			; Swap 8x2, part 2
	lsr.l	#8,d5
	eor.l	d2,d5
	and.l	d4,d5
	eor.l	d5,d2
	lsl.l	#8,d5
	eor.l	d5,d3

	move.l	d3,d5			; Swap 1x2, part 2
	lsr.l	d5
	eor.l	d2,d5
	and.l	d1,d5
	eor.l	d5,d2
	add.l	d5,d5
	eor.l	d5,d3

	move.l	d2,a4
	move.l	d3,a5

	cmpa.l	a0,a2
	bne	.x1
.x1end
	move.l	d7,BPLSIZE(a1)
c2p1x1_5_c5_030_smc5 EQU *-2
	move.l	a4,(a1)+
	move.l	a5,-BPLSIZE-4(a1)
c2p1x1_5_c5_030_smc6 EQU *-2

	move.l	(sp)+,a1
; CHANGE: this read `add.l #BPLSIZE*3,a1`. vasm turns that into a 4-byte LEA,
; because 3*10240 = 30720 fits into the 16-bit displacement - a longword patch
; at `*-4` would then hit the opcode. Instead of trusting the optimiser, the
; form is spelled out now: same effect, same length, and the operand provably
; sits in the last two bytes.
;
; The price: 3*bplsize has to fit into a word, so bplsize <= 10922. That is
; tighter than the 16383 of the 6-plane version and still enough for everything
; ECS can display (320x256 = 10240).
.a7	lea	BPLSIZE*3(a1),a1
c2p1x1_5_c5_030_smc7 EQU *-2
	IFNE	*-.a7-4
	FAIL	"lea does not have the expected length - smc7 points wrong"
	ENDC
	IFGT	BPLSIZE*3-32767
	FAIL	"BPLSIZE*3 does not fit into the word displacement"
	ENDC

	move.l	#$00ff00ff,d3

	lea	c2p1x1_5_c5_030_tempbuf,a0
	move.l	c2p1x1_5_c5_030_pixels,d0
	lsr.l	#2,d0
	lea	(a0,d0.l),a2

	move.l	(a0)+,d0
	move.l	(a0)+,d1

	bra.s	.start2
.x2
	move.l	(a0)+,d0
	move.l	(a0)+,d1

	move.l	d2,(a1)+
.start2

	move.l	d1,d2			; Swap 8x2
	lsr.l	#8,d2
	eor.l	d0,d2
	and.l	d3,d2
	eor.l	d2,d0
	lsl.l	#8,d2
	eor.l	d1,d2

	add.l	d0,d0			; Merge 1x2
	add.l	d0,d2

	cmpa.l	a0,a2
	bne.s	.x2
.x2end
	move.l	d2,(a1)+

.none
	movem.l	(sp)+,d2-d7/a2-a6
	rts

	section	bss,bss

c2p1x1_5_c5_030_scroffs ds.l 1
c2p1x1_5_c5_030_pixels ds.l 1

c2p1x1_5_c5_030_tempbuf ds.b CHUNKYXMAX*CHUNKYYMAX/4
