; ============================================================================
; PONG for Project Trinity
;
; Player 1 moves with W/S; Player 2 moves with the up/down arrow keys.
; First player to score five points wins. Press SPACE to start a new game.
;
; Load at $0100 (emulator/main.py jumps there).
; ============================================================================

.org $0100

start:
  lds #$7FFF
  lda #$02
  sta $9000
  jsr clear_screen

  lda #$00
  sta $0018
  sta $0019
  lda #$0C
  sta $0014
  sta $0015
  lda #$14
  sta $0010
  sta $0011
  lda #$01
  sta $0012
  sta $0013

  lda #$50
  sta $8871
  lda #$4F
  sta $8873
  lda #$4E
  sta $8875
  lda #$47
  sta $8877
  lda #$50
  sta $8821
  lda #$31
  sta $8823
  lda #$3A
  sta $8825
  lda #$50
  sta $8867
  lda #$32
  sta $8869
  lda #$3A
  sta $886B
  jsr show_scores

  lda #$05
  sta $0025
  lda #$C1
  sta $0026
  lda #$88
  sta $0027
  jsr print

  jsr draw_net
  jsr draw_paddles
  jsr draw_ball

main_loop:
  jsr wait_tick
  jsr erase_ball
  jsr erase_paddles
  jsr move_paddles
  jsr move_ball
  jsr draw_paddles
  jsr draw_ball
  jmp main_loop

; Wait three video frames between ball moves.
wait_tick:
  ldb #$03
wt_frame:
  ldc $9001
wt_spin:
  lda $9001
  cmp c
  jeq wt_spin
  dec b
  jne wt_frame
  ret

move_paddles:
  lda $9004
  jeq mp_right
  lda $9003
  cmp #$57
  jeq mp_left_up
  cmp #$53
  jeq mp_left_down
  jmp mp_right
mp_left_up:
  lda $0014
  cmp #$03
  jeq mp_right
  dec $0014
  jmp mp_right
mp_left_down:
  lda $0014
  cmp #$16
  jeq mp_right
  inc $0014
mp_right:
  lda $9005
  bit 4
  jcs mp_right_up
  bit 3
  jcs mp_right_down
  ret
mp_right_up:
  lda $0015
  cmp #$03
  jeq mp_done
  dec $0015
mp_done:
  ret
mp_right_down:
  lda $0015
  cmp #$16
  jeq mp_done
  inc $0015
  ret

move_ball:
  lda $0013
  cmp #$00
  jeq mb_up
  lda $0011
  cmp #$18
  jeq mb_bounce_up
  inc $0011
  lda $0011
  cmp #$18
  jne mb_horizontal
mb_bounce_up:
  lda #$00
  sta $0013
  jmp mb_horizontal
mb_up:
  lda $0011
  cmp #$01
  jeq mb_bounce_down
  dec $0011
  lda $0011
  cmp #$01
  jne mb_horizontal
mb_bounce_down:
  lda #$01
  sta $0013

mb_horizontal:
  lda $0012
  cmp #$00
  jeq mb_left
  lda $0010
  cmp #$26
  jeq mb_score_left
  inc $0010
  lda $0010
  cmp #$25
  jeq mb_check_right
  ret

mb_check_right:
  lda $0015
  dec a
  dec a
  sta $0016
  lda $0011
  cmp $0016
  jcc mb_right_miss
  lda $0015
  inc a
  inc a
  sta $0016
  lda $0011
  cmp $0016
  jcc mb_right_hit
  jeq mb_right_hit
mb_right_miss:
  ret
mb_right_hit:
  lda #$00
  sta $0012
  ret

mb_left:
  lda $0010
  cmp #$01
  jeq mb_score_right
  dec $0010
  lda $0010
  cmp #$02
  jeq mb_check_left
  ret

mb_check_left:
  lda $0014
  dec a
  dec a
  sta $0016
  lda $0011
  cmp $0016
  jcc mb_left_miss
  lda $0014
  inc a
  inc a
  sta $0016
  lda $0011
  cmp $0016
  jcc mb_left_hit
  jeq mb_left_hit
mb_left_miss:
  ret
mb_left_hit:
  lda #$01
  sta $0012
  ret

mb_score_left:
  inc $0018
  jsr show_scores
  lda $0018
  cmp #$05
  jeq player_one_wins
  jmp mb_serve
mb_score_right:
  inc $0019
  jsr show_scores
  lda $0019
  cmp #$05
  jeq player_two_wins
mb_serve:
  lda #$14
  sta $0010
  lda #$0C
  sta $0011
  lda #$01
  sta $0012
  sta $0013
  ret

show_scores:
  lda $0018
  ora #$30
  sta $8827
  lda $0019
  ora #$30
  sta $886D
  ret

player_one_wins:
  lda #$19
  sta $0025
  lda #$C1
  sta $0026
  lda #$88
  sta $0027
  jsr print
  lda #$29
  sta $0025
  lda #$11
  sta $0026
  lda #$89
  sta $0027
  jsr print
  jmp wait_restart

player_two_wins:
  lda #$21
  sta $0025
  lda #$C1
  sta $0026
  lda #$88
  sta $0027
  jsr print
  lda #$29
  sta $0025
  lda #$11
  sta $0026
  lda #$89
  sta $0027
  jsr print

wait_restart:
  lda $9004
  jne wait_restart
wait_space:
  lda $9004
  jeq wait_space
  lda $9003
  cmp #$20
  jne wait_space
  jmp start

draw_net:
  lda #$02
  sta $0022
dn_loop:
  lda #$13
  sta $0023
  lda #$55
  sta $0024
  jsr draw_cell
  lda $0022
  inc a
  inc a
  sta $0022
  cmp #$18
  jne dn_loop
  ret

draw_paddles:
  lda #$02
  sta $0017
  lda #$BB
  sta $0016
  lda $0014
  dec a
  dec a
  sta $001C
  jsr draw_paddle
  lda #$25
  sta $0017
  lda #$33
  sta $0016
  lda $0015
  dec a
  dec a
  sta $001C
  jsr draw_paddle
  ret

erase_paddles:
  lda #$02
  sta $0017
  lda #$00
  sta $0016
  lda $0014
  dec a
  dec a
  sta $001C
  jsr draw_paddle
  lda #$25
  sta $0017
  lda $0015
  dec a
  dec a
  sta $001C
  jsr draw_paddle
  ret

draw_paddle:
  lda #$05
  sta $001D
dp_loop:
  lda $001C
  sta $0022
  lda $0017
  sta $0023
  lda $0016
  sta $0024
  jsr draw_cell
  inc $001C
  dec $001D
  jne dp_loop
  ret

draw_ball:
  lda $0011
  sta $0022
  lda $0010
  sta $0023
  lda #$AA
  sta $0024
  jsr draw_cell
  ret

erase_ball:
  lda $0011
  sta $0022
  lda $0010
  sta $0023
  lda #$00
  sta $0024
  jsr draw_cell
  ret

clear_screen:
  ldi #$00
cs_gfx:
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
cs_gfx_end:
  lda #$00
  sta $8800,i
  inc i
  tia
  cmp #$20
  jne cs_gfx_end
  ldi #$00
cs_txt:
  lda #$1F
  sta $8820,i
  inc i
  lda #$20
  sta $8820,i
  inc i
  jne cs_txt
cs_txt_end:
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

draw_cell:
  jsr cell_addr
  lda $0024
  jsr plot
  ret

cell_addr:
  lda $0022
  asl a
  tai
  lda $0A00,i
  sta $0901
  sta $0905
  lda $0A01,i
  sta $0902
  sta $0906
  lda $0023
  asl a
  tai
  ret

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

.org $0900
plot:
  sta $8000,i
  inc i
  sta $8000,i
  ret
peek:
  lda $8000,i
  ret
pr_store:
  sta $8000,i
  ret

.org $0A00
.bytes $00, $80
.bytes $50, $80
.bytes $A0, $80
.bytes $F0, $80
.bytes $40, $81
.bytes $90, $81
.bytes $E0, $81
.bytes $30, $82
.bytes $80, $82
.bytes $D0, $82
.bytes $20, $83
.bytes $70, $83
.bytes $C0, $83
.bytes $10, $84
.bytes $60, $84
.bytes $B0, $84
.bytes $00, $85
.bytes $50, $85
.bytes $A0, $85
.bytes $F0, $85
.bytes $40, $86
.bytes $90, $86
.bytes $E0, $86
.bytes $30, $87
.bytes $80, $87
.bytes $D0, $87

.org $0B00
.bytes $50, $4F
.bytes $4E, $47
.bytes $00, $50
.bytes $31, $20
.bytes $57, $2F
.bytes $53, $20
.bytes $2D, $20
.bytes $50, $32
.bytes $20, $55
.bytes $50, $2F
.bytes $44, $4F
.bytes $57, $4E
.bytes $00, $50
.bytes $31, $20
.bytes $57, $49
.bytes $4E, $53
.bytes $00, $50
.bytes $32, $20
.bytes $57, $49
.bytes $4E, $53
.bytes $00, $20
.bytes $53, $50
.bytes $41, $43
.bytes $45, $20
.bytes $54, $4F
.bytes $20, $50
.bytes $4C, $41
.bytes $59, $20
.bytes $41, $47
.bytes $41, $49
.bytes $4E, $00
