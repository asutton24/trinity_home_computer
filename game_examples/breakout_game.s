; ============================================================================
; BREAKOUT for Project Trinity
;
; Runs in video mode 2 (mixed). The top 26 rows are graphics, used here as a
; grid of 80 x 52 subpixels (4 x 4 pixels each); the bottom 4 rows are text
; and show the title, lives, score, controls and messages.
;
;   wall    gray, around the top and sides
;   bricks  6 rows of 19, each 4 subpixels wide (the last one dark, so the
;           bricks stand apart), on subpixel rows 6-11
;   paddle  10 subpixels wide on subpixel row 48, moves 2 subpixels a frame
;   ball    1 white subpixel
;
; Controls: left/right arrows or A/D move the paddle. SPACE (or up/Ctrl)
; launches the ball. Bounce it off the paddle to break every brick: hitting
; the left half of the paddle sends it left, the right half sends it right.
; Each brick scores 1. The ball speeds up once it reaches the top two rows.
; Miss the ball 3 times and the game is over.
;
; Load at $0100 (python main.py breakout_game.bin).
; ----------------------------------------------------------------------------
; Memory used
;   $0010  paddle: column of its leftmost block (1-34)
;   $0011  ball x (subpixel column)    $0012  ball y (subpixel row)
;   $0013  ball x direction: 0 right, 1 left
;   $0014  ball y direction: 0 down,  1 up
;   $0015  1 once the ball is launched
;   $0017  bricks left
;   $0018  frames until the ball's next move
;   $0019  frames per ball move (2, then 1 once it reaches the top rows)
;   $001A  ball's next x               $001B  ball's next y
;   $0022  subpixel row, $0023 subpixel column, $0024 color (both nibbles):
;          parameters for get_sub, set_sub and break_brick
;   $0025  string index, $0026/$0027 text address: parameters for print
;   $0030  controls this frame: bit 0 left, bit 1 right, bit 2 launch
;   $0031  1 when the ball has been missed
;   $0050-$0054  scratch
;
; Colors: $5 gray wall, $6 light gray paddle, $F white ball, black background.
; Anything else the ball touches is a brick.
; Text color: $1F (white on navy). Lives digit at $884B, score digits at
; $886B $886D $886F (the digits on screen are the counters).
;
; Fixed addresses (the assembler only resolves labels in jumps, so code that
; is patched at run time, and tables, live at known addresses):
;   $0900  peek / poke / pr_store routines whose addresses get patched
;   $0A00  start address of each of the 26 graphics rows
;   $0A80  brick colors
;   $0B00  text strings
;
; Avoids clc, rol, ror and the (ind) addressing modes, which don't yet behave
; as the spec describes in cpu.py.
; ============================================================================

.org $0100

start:
  lds #$7FFF
  lda #$02              ; video mode 2: graphics on top, text below
  sta $9000
  jsr clear_screen
  jsr draw_walls
  jsr draw_bricks
  lda #$72              ; 6 rows x 19 bricks = 114
  sta $0017

  lda #$00              ; " BREAKOUT" at text row 26, column 0
  sta $0025
  lda #$21
  sta $0026
  lda #$88
  sta $0027
  jsr print
  lda #$0A              ; "LIVES 3" at column 15
  sta $0025
  lda #$3F
  sta $0026
  lda #$88
  sta $0027
  jsr print
  lda #$12              ; "SCORE 000" at column 31
  sta $0025
  lda #$5F
  sta $0026
  lda #$88
  sta $0027
  jsr print
  lda #$1C              ; controls at text row 28
  sta $0025
  lda #$C1
  sta $0026
  lda #$88
  sta $0027
  jsr print

  lda #$11              ; paddle in the middle
  sta $0010
  jsr draw_paddle
  lda #$27              ; somewhere harmless for the first "erase old ball"
  sta $0011
  lda #$2F
  sta $0012

; ---- a new ball waits on the paddle until it is launched
new_ball:
  lda #$00
  sta $0015
  sta $0031
  lda #$02
  sta $0019
  sta $0018
  lda #$01              ; it will go up
  sta $0014
  lda #$2F              ; row 47, just above the paddle
  sta $0012
  jsr ball_on_paddle
  lda #$42              ; "PRESS SPACE OR UP TO LAUNCH THE BALL" on row 29
  sta $0025
  lda #$11
  sta $0026
  lda #$89
  sta $0027
  jsr print

; ============================================================================
; Main loop: once per frame
; ============================================================================
main_loop:
  jsr wait_frame
  jsr read_input
  jsr move_paddle

  lda $0015
  jne in_play
  jsr ball_on_paddle    ; not launched: the ball rides on the paddle
  lda $0030
  and #$04
  jeq main_loop
  lda #$01              ; launch, left or right depending on the clock
  sta $0015
  lda $9001
  and #$01
  sta $0013
  jsr clear_message
  jmp main_loop

in_play:
  dec $0018
  jne main_loop
  lda $0019
  sta $0018
  jsr step_ball
  lda $0031
  jne missed
  lda $0017
  jeq you_win
  jmp main_loop

; ---- the ball went past the paddle
missed:
  dec $884B             ; one life fewer (the digit on screen)
  lda $884B
  cmp #$30
  jeq game_over
  jsr draw_paddle       ; tidy the paddle row
  jmp new_ball

game_over:
  lda #$68              ; "GAME OVER! PRESS SPACE TO PLAY AGAIN"
  jmp end_message
you_win:
  lda #$8E              ; "YOU WIN! PRESS SPACE TO PLAY AGAIN"
end_message:
  sta $0025
  jsr clear_message
  lda #$11
  sta $0026
  lda #$89
  sta $0027
  jsr print
end_release:            ; wait for all keys up, then for SPACE
  lda $9004
  jne end_release
end_wait:
  lda $9004
  jeq end_wait
  lda $9003
  cmp #$20
  jne end_wait
  jmp start

; ============================================================================
; step_ball: move the ball one subpixel across and one down or up, bouncing
; off walls, the paddle and bricks (which break). Sets $0031 if it is missed.
; ============================================================================
step_ball:
  ldb $0013             ; ---- across
  jne sx_left
  lda $0011
  inc a
  jmp sx_have
sx_left:
  lda $0011
  dec a
sx_have:
  sta $001A
  sta $0023
  lda $0012
  sta $0022
  jsr get_sub
  cmp #$00
  jeq x_done            ; free
  cmp #$05
  jeq x_bounce
  cmp #$06
  jeq x_bounce
  cmp #$0F
  jeq x_bounce
  jsr break_brick
x_bounce:
  lda $0013
  xor #$01
  sta $0013
  lda $0011             ; stay in this column
  sta $001A
x_done:

  ldb $0014             ; ---- down or up
  jne sy_up
  lda $0012
  inc a
  jmp sy_have
sy_up:
  lda $0012
  dec a
sy_have:
  sta $001B
  cmp #$34              ; past the bottom of the graphics: missed
  jeq ball_missed
  sta $0022
  lda $001A
  sta $0023
  jsr get_sub
  cmp #$00
  jeq y_done            ; free
  cmp #$06
  jeq y_paddle
  cmp #$05
  jeq y_bounce
  cmp #$0F
  jeq y_bounce
  jsr break_brick
y_bounce:
  lda $0014
  xor #$01
  sta $0014
  lda $0012             ; stay in this row
  sta $001B
  jmp y_done
y_paddle:
  lda #$01              ; up again
  sta $0014
  lda $0010             ; where on the paddle? (0-9 from its left end)
  asl a
  sta $0050
  lda $001A
  sec
  sbc $0050
  cmp #$05
  jcs pad_right
  lda #$01              ; left half: go left
  sta $0013
  jmp pad_done
pad_right:
  lda #$00              ; right half: go right
  sta $0013
pad_done:
  lda $0012
  sta $001B
y_done:

  jsr erase_ball        ; ---- move it
  lda $001A
  sta $0011
  lda $001B
  sta $0012
  jsr draw_ball
  ret

ball_missed:
  jsr erase_ball
  lda #$01
  sta $0031
  ret

; ============================================================================
; break_brick: remove the brick containing subpixel (row $0022, column
; $0023) and score it. A brick is 2 bytes: one byte row of 2 blocks.
; ============================================================================
break_brick:
  lda $0022             ; point poke at the brick's graphics row
  and #$FE
  tai
  lda $0A00,i
  sta $0905
  lda $0A01,i
  sta $0906
  lda $0023             ; i = first byte of the brick
  sec                   ;   = ((column - 2) AND $FC) + 2, + 1 on odd rows
  sbc #$02
  and #$FC
  ora #$02
  sta $0050
  lda $0022
  and #$01
  ora $0050
  tai
  lda #$00
  jsr poke
  inc i
  inc i
  jsr poke
  dec $0017
  jsr add_score
  lda $0022             ; top two rows: the ball speeds up
  cmp #$08
  jcs bb_done
  lda #$01
  sta $0019
bb_done:
  ret

; ============================================================================
; add_score: add 1 to the three score digits shown on screen
; ============================================================================
add_score:
  lda $886F
  cmp #$39
  jeq as_tens
  inc $886F
  ret
as_tens:
  lda #$30
  sta $886F
  lda $886D
  cmp #$39
  jeq as_hundreds
  inc $886D
  ret
as_hundreds:
  lda #$30
  sta $886D
  inc $886B
  ret

; ============================================================================
; Ball drawing
; ============================================================================
draw_ball:
  lda #$FF
  jmp ball_color
erase_ball:
  lda #$00
ball_color:
  sta $0024
  lda $0011
  sta $0023
  lda $0012
  sta $0022
  jsr set_sub
  ret

; ball_on_paddle: put the waiting ball above the middle of the paddle
ball_on_paddle:
  jsr erase_ball
  lda $0010             ; x = paddle column * 2 + 5
  asl a
  sec
  adc #$04
  sta $0011
  jsr draw_ball
  ret

; ============================================================================
; Paddle: 5 blocks on graphics row 24, upper half ($8780 + column * 2)
; ============================================================================
move_paddle:
  lda $0030
  and #$01
  jeq mp_right
  lda $0010
  cmp #$01
  jeq mp_done           ; already at the left wall
  lda $0010             ; clear its right end, step left, draw its left end
  inc a
  inc a
  inc a
  inc a
  asl a
  tai
  lda #$00
  sta $8780,i
  dec $0010
  lda $0010
  asl a
  tai
  lda #$66
  sta $8780,i
  ret
mp_right:
  lda $0030
  and #$02
  jeq mp_done
  lda $0010
  cmp #$22
  jeq mp_done           ; already at the right wall
  lda $0010             ; clear its left end, step right, draw its right end
  asl a
  tai
  lda #$00
  sta $8780,i
  inc $0010
  lda $0010
  inc a
  inc a
  inc a
  inc a
  asl a
  tai
  lda #$66
  sta $8780,i
mp_done:
  ret

; draw_paddle: clear the paddle row and draw the whole paddle
draw_paddle:
  ldi #$02
dp_clear:
  lda #$00
  sta $8780,i
  sta $8781,i
  inc i
  inc i
  tia
  cmp #$4E
  jne dp_clear
  lda $0010
  asl a
  tai
  lda #$66
  sta $8780,i
  inc i
  inc i
  sta $8780,i
  inc i
  inc i
  sta $8780,i
  inc i
  inc i
  sta $8780,i
  inc i
  inc i
  sta $8780,i
  ret

; ============================================================================
; Subpixels. Subpixel (row, column) is in graphics row row/2, at byte
; (column AND $FE) + (row AND 1) of that row: upper nibble for even columns,
; lower nibble for odd ones.
; ============================================================================
; sub_addr: point peek and poke at subpixel (row $0022, column $0023)
sub_addr:
  lda $0022
  and #$FE
  tai
  lda $0A00,i
  sta $0901
  sta $0905
  lda $0A01,i
  sta $0902
  sta $0906
  lda $0022
  and #$01
  sta $0050
  lda $0023
  and #$FE
  ora $0050
  tai
  ret

; get_sub: color (0-15) of subpixel (row $0022, column $0023) in a
get_sub:
  jsr sub_addr
  jsr peek
  tab
  lda $0023
  and #$01
  jne gs_odd
  tba
  lsr a
  lsr a
  lsr a
  lsr a
  ret
gs_odd:
  tba
  and #$0F
  ret

; set_sub: set subpixel (row $0022, column $0023) to color $0024
set_sub:
  jsr sub_addr
  jsr peek
  tab
  lda $0023
  and #$01
  jne ss_odd
  tba
  and #$0F
  sta $0050
  lda $0024
  and #$F0
  ora $0050
  jsr poke
  ret
ss_odd:
  tba
  and #$F0
  sta $0050
  lda $0024
  and #$0F
  ora $0050
  jsr poke
  ret

; ============================================================================
; Input: set $0030 from the joystick ($9005, XXXUDLRC) and the keyboard
; ============================================================================
read_input:
  lda #$00
  sta $0030
  lda $9005
  bit 2                 ; left
  jcc ri_right
  lda $0030
  ora #$01
  sta $0030
ri_right:
  lda $9005
  bit 1                 ; right
  jcc ri_launch
  lda $0030
  ora #$02
  sta $0030
ri_launch:
  lda $9005
  and #$11              ; up or Ctrl
  jeq ri_keys
  lda $0030
  ora #$04
  sta $0030
ri_keys:                ; keyboard, only when the joystick is idle: $9003 keeps
  lda $9005             ; the last key typed, so it can be stale while arrows
  and #$1F              ; are held
  jne ri_done
  lda $9004
  jeq ri_done
  lda $9003
  cmp #$41              ; A
  jeq ri_a
  cmp #$44              ; D
  jeq ri_d
  cmp #$20              ; SPACE
  jeq ri_space
ri_done:
  ret
ri_a:
  lda $0030
  ora #$01
  sta $0030
  ret
ri_d:
  lda $0030
  ora #$02
  sta $0030
  ret
ri_space:
  lda $0030
  ora #$04
  sta $0030
  ret

; wait_frame: wait for the clock byte to tick
wait_frame:
  ldc $9001
wf_spin:
  lda $9001
  cmp c
  jeq wf_spin
  ret

; ============================================================================
; Screen set-up
; ============================================================================
; clear_screen: graphics to black, text to blank white-on-navy
clear_screen:
  ldi #$00
cs_gfx:                 ; $8000-$87FF
  lda #$00
  sta $8000,i
  sta $8100,i
  sta $8200,i
  sta $8300,i
  sta $8400,i
  sta $8500,i
  sta $8600,i
  sta $8700,i
  inc i
  jne cs_gfx
cs_gfx_end:             ; $8800-$881F
  lda #$00
  sta $8800,i
  inc i
  tia
  cmp #$20
  jne cs_gfx_end
  ldi #$00
cs_txt:                 ; text cells $8820-$891F
  lda #$1F
  sta $8820,i
  inc i
  lda #$20
  sta $8820,i
  inc i
  jne cs_txt
cs_txt_end:             ; text cells $8920-$895F
  lda #$1F
  sta $8920,i
  inc i
  lda #$20
  sta $8920,i
  inc i
  tia
  cmp #$40
  jne cs_txt_end
  ret

; clear_message: blank text row 29
clear_message:
  ldi #$00
cm_loop:
  lda #$20
  sta $8911,i
  inc i
  inc i
  tia
  cmp #$50
  jne cm_loop
  ret

; draw_walls: gray graphics row 0, and blocks 0 and 39 of rows 1-25
draw_walls:
  ldi #$00
dw_top:
  lda #$55
  sta $8000,i
  inc i
  tia
  cmp #$50
  jne dw_top
  lda #$01
  sta $0054
dw_sides:
  lda $0054
  asl a
  tai
  lda $0A00,i
  sta $0905
  lda $0A01,i
  sta $0906
  lda #$55
  ldi #$00
  jsr poke
  inc i
  jsr poke
  ldi #$4E
  jsr poke
  inc i
  jsr poke
  inc $0054
  lda $0054
  cmp #$1A
  jne dw_sides
  ret

; draw_bricks: 19 bricks on each subpixel row 6-11, colors from $0A80
draw_bricks:
  lda #$06
  sta $0022
db_row:
  lda $0022             ; point poke at this graphics row
  and #$FE
  tai
  lda $0A00,i
  sta $0905
  lda $0A01,i
  sta $0906
  lda $0022             ; this row's two color bytes
  sec
  sbc #$06
  asl a
  tai
  lda $0A80,i
  sta $0051
  lda $0A81,i
  sta $0052
  lda $0022             ; first brick at byte 2 (+1 on odd rows)
  and #$01
  ora #$02
  sta $0053
db_brick:
  ldi $0053
  lda $0051
  jsr poke
  inc i
  inc i
  lda $0052
  jsr poke
  inc $0053
  inc $0053
  inc $0053
  inc $0053
  lda $0053
  cmp #$4E
  jcc db_brick
  inc $0022
  lda $0022
  cmp #$0C
  jne db_row
  ret

; ============================================================================
; print: copy the string at $0B00 + $0025 (ends with 0) into the text
; character bytes starting at address $0026/$0027. Uses a, b, c, i.
; ============================================================================
print:
  lda $0026
  sta $0909
  lda $0027
  sta $090A
  ldb #$00
print_loop:
  ldi $0025
  lda $0B00,i
  jeq print_done
  tac
  tba
  tai
  tca
  jsr pr_store
  inc b
  inc b
  inc $0025
  jmp print_loop
print_done:
  ret

; ============================================================================
; Patched routines. Their $8000 addresses are rewritten at run time.
; ============================================================================
.org $0900
peek:                   ; $0900: a = byte (address at $0901-$0902)
  lda $8000,i
  ret
poke:                   ; $0904: byte = a (address at $0905-$0906)
  sta $8000,i
  ret
pr_store:               ; $0908: character = a (address at $0909-$090A)
  sta $8000,i
  ret

; ============================================================================
; Start address of each graphics row: $8000 + row * 80 (low byte, high byte)
; ============================================================================
.org $0A00
.bytes $00, $80    ; row  0 = $8000
.bytes $50, $80    ; row  1 = $8050
.bytes $A0, $80    ; row  2 = $80A0
.bytes $F0, $80    ; row  3 = $80F0
.bytes $40, $81    ; row  4 = $8140
.bytes $90, $81    ; row  5 = $8190
.bytes $E0, $81    ; row  6 = $81E0
.bytes $30, $82    ; row  7 = $8230
.bytes $80, $82    ; row  8 = $8280
.bytes $D0, $82    ; row  9 = $82D0
.bytes $20, $83    ; row 10 = $8320
.bytes $70, $83    ; row 11 = $8370
.bytes $C0, $83    ; row 12 = $83C0
.bytes $10, $84    ; row 13 = $8410
.bytes $60, $84    ; row 14 = $8460
.bytes $B0, $84    ; row 15 = $84B0
.bytes $00, $85    ; row 16 = $8500
.bytes $50, $85    ; row 17 = $8550
.bytes $A0, $85    ; row 18 = $85A0
.bytes $F0, $85    ; row 19 = $85F0
.bytes $40, $86    ; row 20 = $8640
.bytes $90, $86    ; row 21 = $8690
.bytes $E0, $86    ; row 22 = $86E0
.bytes $30, $87    ; row 23 = $8730
.bytes $80, $87    ; row 24 = $8780
.bytes $D0, $87    ; row 25 = $87D0

; ============================================================================
; Brick colors for subpixel rows 6-11: first byte, second byte (its right
; subpixel is navy so the bricks stand apart)
; ============================================================================
.org $0A80
.bytes $88, $81    ; row 6  red
.bytes $99, $91    ; row 7  orange
.bytes $AA, $A1    ; row 8  yellow
.bytes $BB, $B1    ; row 9  green
.bytes $CC, $C1    ; row 10 sky blue
.bytes $DD, $D1    ; row 11 lavender

; ============================================================================
; Text, each string ending in 0:
;   $00 " BREAKOUT"  $0A "LIVES 3"  $12 "SCORE 000"  $1C controls
;   $42 launch       $68 game over  $8E you win
; ============================================================================
.org $0B00
.bytes $20, $42    ;  B
.bytes $52, $45    ; RE
.bytes $41, $4B    ; AK
.bytes $4F, $55    ; OU
.bytes $54, $00    ; T.
.bytes $4C, $49    ; LI
.bytes $56, $45    ; VE
.bytes $53, $20    ; S 
.bytes $33, $00    ; 3.
.bytes $53, $43    ; SC
.bytes $4F, $52    ; OR
.bytes $45, $20    ; E 
.bytes $30, $30    ; 00
.bytes $30, $00    ; 0.
.bytes $20, $4C    ;  L
.bytes $45, $46    ; EF
.bytes $54, $2F    ; T/
.bytes $52, $49    ; RI
.bytes $47, $48    ; GH
.bytes $54, $20    ; T 
.bytes $4F, $52    ; OR
.bytes $20, $41    ;  A
.bytes $2F, $44    ; /D
.bytes $20, $54    ;  T
.bytes $4F, $20    ; O 
.bytes $4D, $4F    ; MO
.bytes $56, $45    ; VE
.bytes $20, $54    ;  T
.bytes $48, $45    ; HE
.bytes $20, $50    ;  P
.bytes $41, $44    ; AD
.bytes $44, $4C    ; DL
.bytes $45, $00    ; E.
.bytes $20, $50    ;  P
.bytes $52, $45    ; RE
.bytes $53, $53    ; SS
.bytes $20, $53    ;  S
.bytes $50, $41    ; PA
.bytes $43, $45    ; CE
.bytes $20, $4F    ;  O
.bytes $52, $20    ; R 
.bytes $55, $50    ; UP
.bytes $20, $54    ;  T
.bytes $4F, $20    ; O 
.bytes $4C, $41    ; LA
.bytes $55, $4E    ; UN
.bytes $43, $48    ; CH
.bytes $20, $54    ;  T
.bytes $48, $45    ; HE
.bytes $20, $42    ;  B
.bytes $41, $4C    ; AL
.bytes $4C, $00    ; L.
.bytes $20, $47    ;  G
.bytes $41, $4D    ; AM
.bytes $45, $20    ; E 
.bytes $4F, $56    ; OV
.bytes $45, $52    ; ER
.bytes $21, $20    ; ! 
.bytes $50, $52    ; PR
.bytes $45, $53    ; ES
.bytes $53, $20    ; S 
.bytes $53, $50    ; SP
.bytes $41, $43    ; AC
.bytes $45, $20    ; E 
.bytes $54, $4F    ; TO
.bytes $20, $50    ;  P
.bytes $4C, $41    ; LA
.bytes $59, $20    ; Y 
.bytes $41, $47    ; AG
.bytes $41, $49    ; AI
.bytes $4E, $00    ; N.
.bytes $20, $59    ;  Y
.bytes $4F, $55    ; OU
.bytes $20, $57    ;  W
.bytes $49, $4E    ; IN
.bytes $21, $20    ; ! 
.bytes $50, $52    ; PR
.bytes $45, $53    ; ES
.bytes $53, $20    ; S 
.bytes $53, $50    ; SP
.bytes $41, $43    ; AC
.bytes $45, $20    ; E 
.bytes $54, $4F    ; TO
.bytes $20, $50    ;  P
.bytes $4C, $41    ; LA
.bytes $59, $20    ; Y 
.bytes $41, $47    ; AG
.bytes $41, $49    ; AI
.bytes $4E, $00    ; N.
