; ============================================================================
; SNAKE for Project Trinity
;
; Runs in video mode 2 (mixed): the top 26 rows are graphics, where the game
; is played on a 40 x 26 grid of 8 x 8 blocks, and the bottom 4 rows are text,
; which show the title, the score and the controls.
;
; Controls: arrow keys (joystick 0, $9005) or W A S D (keyboard, $9003/$9004).
; Eat the red food to grow and score a point. Hitting the wall or yourself
; ends the game; press SPACE to play again.
;
; Load at $0100 (emulator/main.py jumps there).
; ----------------------------------------------------------------------------
; Memory used
;   $0010  head index into the body arrays (ring buffer)
;   $0011  tail index into the body arrays
;   $0012  current direction: 0 right, 1 down, 2 left, 3 up
;   $0014  head column        $0015  head row
;   $0016  next head column   $0017  next head row
;   $0018  blocks still to grow
;   $0020  random number (8-bit LFSR, never 0)
;   $0021  direction asked for by the player
;   $0022  row, $0023 column, $0024 color: parameters for draw_cell
;   $0025  string index, $0026/$0027 text address: parameters for print
;   $0028  frames per move (game speed)
;   $0029  1 when new food must be placed
;   $1000  body columns (256 bytes, indexed by head/tail index)
;   $1100  body rows    (256 bytes)
;
; Graphics colors (both nibbles the same, so a block is one solid color)
;   $00 black background   $55 gray wall   $BB green body
;   $AA yellow head        $88 red food
; Text color: $1F (white on navy)
;
; Fixed addresses (the assembler only resolves labels in jumps, so code that
; is patched at run time, and tables, live at known addresses):
;   $0900  plot / peek / pr_store routines whose operands get patched
;   $0A00  start address of each of the 26 graphics rows
;   $0B00  text strings
; ============================================================================

.org $0100

start:
  lds #$7FFF
  lda #$02              ; video mode 2: graphics on top, text below
  sta $9000
  lda $0020             ; the random generator must never be 0
  jne seed_ok
  lda #$5A
  sta $0020
seed_ok:
  jsr clear_screen
  jsr draw_border

  lda #$00              ; " SNAKE" at text row 26, column 0
  sta $0025
  lda #$21
  sta $0026
  lda #$88
  sta $0027
  jsr print
  lda #$07              ; "SCORE 000" at text row 26, column 31
  sta $0025
  lda #$5F
  sta $0026
  lda #$88
  sta $0027
  jsr print
  lda #$11              ; controls at text row 28, column 0
  sta $0025
  lda #$C1
  sta $0026
  lda #$88
  sta $0027
  jsr print

; ---- starting snake: 3 blocks long on row 12, heading right
  lda #$0A
  sta $1000
  lda #$0B
  sta $1001
  lda #$0C
  sta $1002
  sta $0014
  sta $1100
  sta $1101
  sta $1102
  sta $0015
  lda #$00
  sta $0011
  sta $0012
  sta $0021
  sta $0018
  sta $0029
  lda #$02
  sta $0010
  lda #$06              ; move once every 6 frames (10 moves a second)
  sta $0028

  lda #$0C
  sta $0022
  lda #$0A
  sta $0023
  lda #$BB
  sta $0024
  jsr draw_cell
  lda #$0B
  sta $0023
  lda #$BB
  sta $0024
  jsr draw_cell
  lda #$0C
  sta $0023
  lda #$AA
  sta $0024
  jsr draw_cell
  jsr place_food

; ============================================================================
; Main loop: one move per tick
; ============================================================================
main_loop:
  jsr wait_tick

  lda $0021             ; take the new direction unless it is a U-turn
  xor $0012             ; (opposite directions differ by exactly 2)
  cmp #$02
  jeq dir_kept
  lda $0021
  sta $0012
dir_kept:

  lda $0014             ; next head = head moved one block
  sta $0016
  lda $0015
  sta $0017
  lda $0012
  cmp #$00
  jeq go_right
  cmp #$01
  jeq go_down
  cmp #$02
  jeq go_left
  dec $0017             ; up
  jmp moved
go_right:
  inc $0016
  jmp moved
go_down:
  inc $0017
  jmp moved
go_left:
  dec $0016
moved:

  lda $0017             ; what is in the block we are moving into?
  sta $0022
  lda $0016
  sta $0023
  jsr cell_addr
  jsr peek
  cmp #$88
  jeq eat
  cmp #$00
  jne game_over         ; wall or snake
  jmp advance
eat:
  jsr add_score
  inc $0018             ; grow 2 blocks
  inc $0018
  lda #$01
  sta $0029

advance:
  lda $0015             ; old head becomes body
  sta $0022
  lda $0014
  sta $0023
  lda #$BB
  sta $0024
  jsr draw_cell

  inc $0010             ; add the new head to the body
  ldi $0010
  lda $0016
  sta $1000,i
  sta $0014
  lda $0017
  sta $1100,i
  sta $0015
  sta $0022
  lda $0014
  sta $0023
  lda #$AA
  sta $0024
  jsr draw_cell

  lda $0018             ; still growing? then keep the tail
  jeq erase_tail
  lda $0010             ; but never let the body outgrow its 256-entry arrays
  sec
  sbc $0011
  cmp #$F0
  jcs erase_tail
  dec $0018
  jmp tail_done
erase_tail:
  ldi $0011
  lda $1100,i
  sta $0022
  lda $1000,i
  sta $0023
  lda #$00
  sta $0024
  jsr draw_cell
  inc $0011
tail_done:

  lda $0029
  jeq main_loop
  lda #$00
  sta $0029
  jsr place_food
  jmp main_loop

; ============================================================================
; Game over: show the message, wait for all keys up, then for SPACE
; ============================================================================
game_over:
  lda #$2E
  sta $0025
  lda #$11
  sta $0026
  lda #$89
  sta $0027
  jsr print
go_release:
  jsr rng_step
  lda $9004
  jne go_release
go_wait:
  jsr rng_step
  lda $9004
  jeq go_wait
  lda $9003
  cmp #$20
  jne go_wait
  jmp start

; ============================================================================
; wait_tick: wait $0028 frames, reading input and stirring the random
; number while waiting. Uses a, b, c.
; ============================================================================
wait_tick:
  ldb $0028
wt_frame:
  ldc $9001
wt_spin:
  jsr rng_step
  jsr read_input
  lda $9001
  cmp c
  jeq wt_spin
  dec b
  jne wt_frame
  ret

; ============================================================================
; read_input: set $0021 from the arrow keys or W A S D. Uses a.
; ============================================================================
read_input:
  lda $9005             ; joystick: XXXUDLRC
  bit 4
  jcs in_up
  bit 3
  jcs in_down
  bit 2
  jcs in_left
  bit 1
  jcs in_right
  lda $9004             ; keyboard: only while a key is held
  jeq in_done
  lda $9003
  cmp #$57              ; W
  jeq in_up
  cmp #$53              ; S
  jeq in_down
  cmp #$41              ; A
  jeq in_left
  cmp #$44              ; D
  jeq in_right
in_done:
  ret
in_up:
  lda #$03
  sta $0021
  ret
in_down:
  lda #$01
  sta $0021
  ret
in_left:
  lda #$02
  sta $0021
  ret
in_right:
  lda #$00
  sta $0021
  ret

; ============================================================================
; rng_step: next value of the 8-bit LFSR in $0020, returned in a.
; ============================================================================
rng_step:
  lda $0020
  lsr a
  jcc rng_no_tap
  xor #$B8
rng_no_tap:
  sta $0020
  ret

; ============================================================================
; place_food: pick a random empty block inside the wall and draw food there.
; ============================================================================
place_food:
  jsr rng_step
pf_mod_x:               ; column = 1 + random mod 38
  cmp #$26
  jcc pf_x_ok
  sec
  sbc #$26
  jmp pf_mod_x
pf_x_ok:
  inc a
  sta $0023
  jsr rng_step
pf_mod_y:               ; row = 1 + random mod 24
  cmp #$18
  jcc pf_y_ok
  sec
  sbc #$18
  jmp pf_mod_y
pf_y_ok:
  inc a
  sta $0022
  jsr cell_addr
  jsr peek
  cmp #$00
  jne place_food        ; taken, try again
  lda #$88
  jsr plot
  ret

; ============================================================================
; add_score: add 1 to the three score digits shown on screen
; (the digits in VRAM are the score: $886B hundreds, $886D tens, $886F ones)
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
  lda $886B
  cmp #$39
  jeq as_wrap
  inc $886B
  ret
as_wrap:
  lda #$30
  sta $886B
  ret

; ============================================================================
; clear_screen: graphics rows to black, text rows to blank white-on-navy
; ============================================================================
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

; ============================================================================
; draw_border: gray wall around the 40 x 26 play field
; ============================================================================
draw_border:
  ldi #$00
db_rows:                ; rows 0 ($8000) and 25 ($87D0), all 80 bytes
  lda #$55
  sta $8000,i
  sta $87D0,i
  inc i
  tia
  cmp #$50
  jne db_rows
  lda #$01
  sta $0022
db_sides:               ; columns 0 and 39 of rows 1-24
  lda #$00
  sta $0023
  lda #$55
  sta $0024
  jsr draw_cell
  lda #$27
  sta $0023
  lda #$55
  sta $0024
  jsr draw_cell
  inc $0022
  lda $0022
  cmp #$19
  jne db_sides
  ret

; ============================================================================
; draw_cell: fill block (row $0022, column $0023) with color $0024
; ============================================================================
draw_cell:
  jsr cell_addr
  lda $0024
  jsr plot
  ret

; ============================================================================
; cell_addr: point plot and peek at block (row $0022, column $0023).
; Patches their addresses with the row's start and sets i = column * 2.
; ============================================================================
cell_addr:
  lda $0022
  asl a
  tai
  lda $0A00,i
  sta $0901
  sta $0905
  sta $0909
  lda $0A01,i
  sta $0902
  sta $0906
  sta $090A
  lda $0023
  asl a
  tai
  ret

; ============================================================================
; print: copy the string at $0B00 + $0025 (ends with 0) into the text
; character bytes starting at address $0026/$0027. Uses a, b, c, i.
; ============================================================================
print:
  lda $0026
  sta $090D
  lda $0027
  sta $090E
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
; Patched routines. Their $8000 addresses are rewritten by cell_addr and print.
; ============================================================================
.org $0900
plot:                   ; $0900: write a to both bytes of a block
  sta $8000,i           ; address at $0901-$0902
  inc i
  sta $8000,i           ; address at $0905-$0906
  ret
peek:                   ; $0908: read the block's first byte into a
  lda $8000,i           ; address at $0909-$090A
  ret
pr_store:               ; $090C: write one character
  sta $8000,i           ; address at $090D-$090E
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
; Text, each string ending in 0:
;   $00 " SNAKE"   $07 "SCORE 000"   $11 controls   $2E game over
; ============================================================================
.org $0B00
.bytes $20, $53    ; ' S'
.bytes $4E, $41    ; 'NA'
.bytes $4B, $45    ; 'KE'
.bytes $00, $53    ; '\\0S'
.bytes $43, $4F    ; 'CO'
.bytes $52, $45    ; 'RE'
.bytes $20, $30    ; ' 0'
.bytes $30, $30    ; '00'
.bytes $00, $20    ; '\\0 '
.bytes $41, $52    ; 'AR'
.bytes $52, $4F    ; 'RO'
.bytes $57, $20    ; 'W '
.bytes $4B, $45    ; 'KE'
.bytes $59, $53    ; 'YS'
.bytes $20, $4F    ; ' O'
.bytes $52, $20    ; 'R '
.bytes $57, $41    ; 'WA'
.bytes $53, $44    ; 'SD'
.bytes $20, $54    ; ' T'
.bytes $4F, $20    ; 'O '
.bytes $53, $54    ; 'ST'
.bytes $45, $45    ; 'EE'
.bytes $52, $00    ; 'R\\0'
.bytes $20, $47    ; ' G'
.bytes $41, $4D    ; 'AM'
.bytes $45, $20    ; 'E '
.bytes $4F, $56    ; 'OV'
.bytes $45, $52    ; 'ER'
.bytes $21, $20    ; '! '
.bytes $50, $52    ; 'PR'
.bytes $45, $53    ; 'ES'
.bytes $53, $20    ; 'S '
.bytes $53, $50    ; 'SP'
.bytes $41, $43    ; 'AC'
.bytes $45, $20    ; 'E '
.bytes $54, $4F    ; 'TO'
.bytes $20, $50    ; ' P'
.bytes $4C, $41    ; 'LA'
.bytes $59, $20    ; 'Y '
.bytes $41, $47    ; 'AG'
.bytes $41, $49    ; 'AI'
.bytes $4E, $00    ; 'N\\0'
