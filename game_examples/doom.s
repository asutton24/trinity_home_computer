; ============================================================================
; TRINITY DOOM  (made by game_examples/doom_build.py: edit the levels there)
;
; A DOOM-style raycaster for Project Trinity in video mode 2 (mixed). The top
; 26 rows show a first-person 3D view, 40 columns wide: one ray per column is
; traced through a 16 x 16 map and its wall drawn taller the closer it is.
; There are 4 levels, played in order.
; The bottom 4 rows show health, ammo, kills and messages.
;
; Controls: up/down (or W/S) walk, left/right (or A/D) turn,
;           Ctrl (or SPACE when no arrow is held) shoots.
; Shoot the imps (pink/red blocks): standing next to one hurts. You start with
; 20 bullets. Walk into the yellow exit to go to the next level (you keep
; your health and get 10 more bullets). Dying restarts the level.
;
; How a frame is drawn
;   1. cast_all: for each column, the ray angle is player angle + column - 20
;      (256 angles to a turn). A DDA walk steps the ray from cell edge to cell
;      edge until it meets a wall. Ray lengths per cell come from tables, and
;      the only multiply is a short 6-step one for the first, partial cell.
;   2. The distance picks a half wall height from a table for that column,
;      which also removes the fish-eye effect.
;   3. draw_all paints each column as ceiling, wall and floor using the
;      unrolled column painter at $0E00 (one store per subpixel row).
;   4. The gun is stamped on top and the status bar updated.
; Movement is scaled by the clock ticks since the last frame, so walking speed
; doesn't depend on how fast frames are drawn.
; ----------------------------------------------------------------------------
; Memory
;   $0010 player angle   $0011/$0012 player x (fraction, cell)
;   $0013/$0014 player y (fraction, cell)
;   $0015 column   $0016 ray angle   $0017 x step (+1/-1)  $0018 y step (+16/-16)
;   $0019/$001A ray length per x cell   $001B/$001C per y cell
;   $001D/$001E ray length to next x edge   $001F/$0020 to next y edge
;   $0021 map index of the ray's cell   $0022 side hit (0 x, 1 y)   $0023 cell type
;   $0024 column distance from the centre   $0025 half wall height
;   $0026 top row  $0027 bottom row  $0028 top*3  $0029 bottom*3
;   $002A wall color  $002B column*2
;   $0030 controls: bit 0 turn left, 1 turn right, 2 forward, 3 back, 4 fire
;   $0031 fire held last frame  $0032 muzzle flash timer  $0033 clock last frame
;   $0034 ticks this frame  $0035 imp attack timer  $0036 health  $0037 ammo
;   $0038 kills  $0039 0 playing, 1 dead, 2 level complete  $003A scratch
;   $003C hurt flash timer  $003D level (0 = first)
;   $0040-$0044 multiply  $0045-$004B movement
;   $0050 string index  $0051/$0052 text address
;   $0D00 patched helper routines   $0E00 column painter
;   $1000-$15FF ray and movement tables   $2000-$34FF wall height tables
;   $3800 level being played   $3A00 colors, offsets, text
;   $3C00 per column: half heights  $3C40 colors  $3C80 cell types  $3CC0 map indexes
;   $3E00 level starts and imp counts   $3F00 level names   $4000 the levels, 256 bytes each
; ============================================================================


.org $0100

start:
  lds #$7FFF
  lda #$02              ; video mode 2: graphics on top, text below
  sta $9000
  jsr clear_screen
  lda #$00              ; first level, full health and ammo
  sta $3D
  lda #$64
  sta $36
  lda #$14
  sta $37

  lda #$00
  sta $50
  lda #$21              ; text row 26
  sta $51
  lda #$88
  sta $52
  jsr print
  lda #$24
  sta $50
  lda #$71              ; text row 27
  sta $51
  lda #$88
  sta $52
  jsr print
  lda #$32
  sta $50
  lda #$C1              ; text row 28
  sta $51
  lda #$88
  sta $52
  jsr print
  jsr load_level

; ============================================================================
; Main loop: one frame
; ============================================================================
main_loop:
  jsr wait_tick
  jsr read_input
  jsr update
  lda $39
  jne end_state
  jsr fire
  jsr cast_all
  jsr draw_all
  jsr draw_gun
  jsr draw_hud
  jmp main_loop

; ---- died or reached an exit
end_state:
  jsr draw_hud
  jsr clear_message
  lda $39
  cmp #$01
  jne es_exit
  lda #$7F         ; died: this level again, with full health and ammo
  jsr show_message
  jsr wait_space
  lda #$64
  sta $36
  lda #$14
  sta $37
  jsr load_level
  jmp main_loop
es_exit:
  lda $3D
  cmp #$03
  jeq es_episode
  lda #$A3         ; on to the next level, keeping health, 10 more bullets
  jsr show_message
  jsr wait_space
  inc $3D
  lda $37
  clc
  adc #$0A
  jcc es_ammo
  lda #$FF
es_ammo:
  sta $37
  jsr load_level
  jmp main_loop
es_episode:
  lda #$CB      ; that was the last level: back to the first
  jsr show_message
  jsr wait_space
  jmp start

; show_message: print string a on text row 29
show_message:
  sta $50
  lda #$11
  sta $51
  lda #$89
  sta $52
  jsr print
  ret

; wait_space: wait for all keys up, then for SPACE
wait_space:
  lda $9005
  and #$1F
  jne wait_space
  lda $9004
  jne wait_space
ws_wait:
  lda $9004
  jeq ws_wait
  lda $9003
  cmp #$20
  jne ws_wait
  ret

; ============================================================================
; load_level: start level $003D: copy its map, place the player, reset the
; level's kills and timers, show its name and imp count, and the opening message
; ============================================================================
load_level:
  lda #$40              ; its map is at $4000 + 256 * level
  clc
  adc $3D
  sta $0D0E
  ldi #$00
ll_copy:
  jsr mapread
  sta $3800,i
  inc i
  jne ll_copy
  lda $3D               ; its start and imps: 4 bytes at $3E00 + 4 * level
  asl a
  asl a
  tai
  lda $3E00,i
  sta $12
  lda $3E01,i
  sta $14
  lda $3E02,i
  sta $10
  lda $3E03,i
  clc
  adc #$30
  sta $8865
  lda #$80              ; the middle of the start cell
  sta $11
  sta $13
  lda #$00
  sta $38
  sta $39
  sta $32
  sta $35
  sta $3C
  sta $3C93           ; forget what the last level was aiming at
  sta $3C94
  lda #$10              ; treat fire as held, so the SPACE that started
  sta $31               ; this level doesn't also shoot
  lda $3D               ; its name: 16 characters at $3F00 + 16 * level,
  asl a                 ; on the right of text row 27
  asl a
  asl a
  asl a
  sta $50
  lda #$9F
  sta $0D09
  lda #$88
  sta $0D0A
  ldb #$00
ll_name:
  ldi $50
  lda $3F00,i
  tac
  tba
  tai
  tca
  jsr prstore
  inc $50
  inc b
  inc b
  tba
  cmp #$20
  jne ll_name
  jsr clear_message
  lda #$58
  jsr show_message
  lda $9001
  sta $33
  ret

; ============================================================================
; wait_tick: wait for the clock, then $0034 = ticks since last frame (1-8)
; ============================================================================
wait_tick:
  lda $9001
  sec
  sbc $33
  jeq wait_tick
  cmp #$08
  jcc wt_ok
  lda #$08
wt_ok:
  sta $34
  lda $9001
  sta $33
  ret

; ============================================================================
; read_input: $0030 from the joystick ($9005, XXXUDLRC), or from the keyboard
; when no arrow/Ctrl is held ($9003 keeps the last key typed, so it would be
; stale while arrows are held)
; ============================================================================
read_input:
  lda #$00
  sta $30
  lda $9005
  and #$1F
  jeq ri_keys
  lda $9005
  bit 2                 ; left: turn left
  jcc ri_1
  lda $30
  ora #$01
  sta $30
ri_1:
  lda $9005
  bit 1                 ; right: turn right
  jcc ri_2
  lda $30
  ora #$02
  sta $30
ri_2:
  lda $9005
  bit 4                 ; up: forward
  jcc ri_3
  lda $30
  ora #$04
  sta $30
ri_3:
  lda $9005
  bit 3                 ; down: back
  jcc ri_4
  lda $30
  ora #$08
  sta $30
ri_4:
  lda $9005
  bit 0                 ; Ctrl: fire
  jcc ri_done
  lda $30
  ora #$10
  sta $30
  ret
ri_keys:
  lda $9004
  jeq ri_done
  lda $9003
  cmp #$41              ; A
  jne ri_k1
  lda #$01
  sta $30
  ret
ri_k1:
  cmp #$44              ; D
  jne ri_k2
  lda #$02
  sta $30
  ret
ri_k2:
  cmp #$57              ; W
  jne ri_k3
  lda #$04
  sta $30
  ret
ri_k3:
  cmp #$53              ; S
  jne ri_k4
  lda #$08
  sta $30
  ret
ri_k4:
  cmp #$20              ; SPACE
  jne ri_done
  lda #$10
  sta $30
ri_done:
  ret

; ============================================================================
; update: once per clock tick since the last frame: turn, walk, imp attacks,
; timers
; ============================================================================
update:
  lda $30
  and #$01
  jeq up_1
  dec $10               ; turn left 2 steps (about 3 degrees) per tick
  dec $10
up_1:
  lda $30
  and #$02
  jeq up_2
  inc $10
  inc $10
up_2:
  lda $30
  and #$04
  jeq up_3
  lda #$00
  jsr move
up_3:
  lda $30
  and #$08
  jeq up_4
  lda #$01
  jsr move
up_4:
  lda $39
  jne up_done
  inc $35               ; imps next to you attack twice a second
  lda $35
  cmp #$1E
  jcc up_5
  lda #$00
  sta $35
  jsr imp_attack
  lda $39
  jne up_done
up_5:
  lda $32
  jeq up_6
  dec $32
up_6:
  lda $3C
  jeq up_7
  dec $3C
up_7:
  dec $34
  jne update
up_done:
  ret

; ============================================================================
; move: walk one tick forward (a = 0) or back (a = 1). Each axis moves on its
; own so you slide along walls, and stops a quarter cell short of a wall.
; Walking into the exit finishes the level.
; ============================================================================
move:
  sta $3A
  ldi $10
  lda $1400,i
  sta $45
  lda $1500,i
  sta $46
  lda $3A
  jeq mv_x
  lda #$00              ; backwards: negate the step
  sec
  sbc $45
  sta $45
  lda #$00
  sec
  sbc $46
  sta $46
mv_x:
  lda $45
  jeq mv_y
  ldb #$00              ; b = high byte of the signed step
  and #$80
  jeq mx_add
  ldb #$FF
mx_add:
  clc                   ; new x in $47/$48
  lda $11
  adc $45
  sta $47
  lda $12
  adc b
  sta $48
  tba                   ; the cell a quarter cell further on
  cmp #$00
  jne mx_back
  clc
  lda $47
  adc #$40
  lda $48
  adc #$00
  jmp mx_cell
mx_back:
  sec
  lda $47
  sbc #$40
  lda $48
  sbc #$00
mx_cell:
  sta $4A
  lda $14
  asl a
  asl a
  asl a
  asl a
  ora $4A
  tai
  lda $3800,i
  jeq mx_ok
  cmp #$05
  jne mv_y
  lda #$02              ; the exit
  sta $39
  ret
mx_ok:
  lda $47
  sta $11
  lda $48
  sta $12
mv_y:
  lda $46
  jeq mv_done
  ldb #$00
  and #$80
  jeq my_add
  ldb #$FF
my_add:
  clc
  lda $13
  adc $46
  sta $47
  lda $14
  adc b
  sta $48
  tba
  cmp #$00
  jne my_back
  clc
  lda $47
  adc #$40
  lda $48
  adc #$00
  jmp my_cell
my_back:
  sec
  lda $47
  sbc #$40
  lda $48
  sbc #$00
my_cell:
  asl a
  asl a
  asl a
  asl a
  ora $12
  tai
  lda $3800,i
  jeq my_ok
  cmp #$05
  jne mv_done
  lda #$02
  sta $39
  ret
my_ok:
  lda $47
  sta $13
  lda $48
  sta $14
mv_done:
  ret

; ============================================================================
; imp_attack: each imp in the 8 cells around you takes 5 health
; ============================================================================
imp_attack:
  lda $14
  asl a
  asl a
  asl a
  asl a
  ora $12
  sta $4B
  ldb #$00              ; b = imps found
  ldc #$00              ; c = which neighbour
ia_loop:
  tca
  tai
  lda $3A10,i
  clc
  adc $4B
  tai
  lda $3800,i
  cmp #$04
  jne ia_next
  inc b
ia_next:
  inc c
  tca
  cmp #$08
  jne ia_loop
ia_hurt:
  tba
  cmp #$00
  jeq ia_done
  dec b
  lda #$0A              ; flash the status bar red
  sta $3C
  lda $36
  cmp #$06
  jcc ia_dead
  sec
  sbc #$05
  sta $36
  jmp ia_hurt
ia_dead:
  lda #$00
  sta $36
  lda #$01
  sta $39
ia_done:
  ret

; ============================================================================
; fire: on a new press, if there is ammo, shoot straight ahead. An imp in
; one of the two middle columns dies (its cell becomes empty).
; ============================================================================
fire:
  lda $30
  and #$10
  sta $3A
  lda $31
  jne fi_save           ; still held from before
  lda $3A
  jeq fi_save
  lda $37
  jeq fi_save           ; out of ammo
  dec $37
  lda #$06
  sta $32
  lda $3C94
  cmp #$04
  jne fi_19
  lda $3CD4
  jmp fi_kill
fi_19:
  lda $3C93
  cmp #$04
  jne fi_save
  lda $3CD3
fi_kill:
  tai
  lda #$00
  sta $3800,i
  inc $38
fi_save:
  lda $3A
  sta $31
  ret

; ============================================================================
; cast_all: trace the 40 rays, saving each column's half height, color,
; cell type and map index
; ============================================================================
cast_all:
  lda #$00
  sta $15
ca_loop:
  lda $15               ; ray angle = player angle + column - 20
  clc
  adc #$EC
  clc
  adc $10
  sta $16
  lda $15               ; distance from the centre column
  cmp #$14
  jcs ca_right
  lda #$14
  sec
  sbc $15
  jmp ca_off
ca_right:
  sec
  sbc #$14
ca_off:
  sta $24
  ldi $16
  lda $1000,i
  sta $19
  lda $1100,i
  sta $1A
  lda $1200,i
  sta $1B
  lda $1300,i
  sta $1C

  lda $16               ; x: cos >= 0 when angle + 64 has bit 7 clear
  clc
  adc #$40
  and #$80
  jne cx_neg
  lda #$01
  sta $17
  lda $11               ; part of a cell to the next x edge, in 1/32: 32 - fraction
  lsr a
  lsr a
  lsr a
  sta $3A
  lda #$20
  sec
  sbc $3A
  jmp cx_mul
cx_neg:
  lda #$FF
  sta $17
  lda $11               ; going left: just the fraction
  lsr a
  lsr a
  lsr a
cx_mul:
  sta $3A               ; ray length to the first x edge = part * length per cell / 32
  lda $19
  sta $40
  lda $1A
  sta $41
  lda $3A
  jsr mul
  jsr shr5
  lda $42
  sta $1D
  lda $43
  sta $1E

  lda $16               ; y: sin >= 0 when angle < 128
  and #$80
  jne cy_neg
  lda #$10
  sta $18
  lda $13
  lsr a
  lsr a
  lsr a
  sta $3A
  lda #$20
  sec
  sbc $3A
  jmp cy_mul
cy_neg:
  lda #$F0
  sta $18
  lda $13
  lsr a
  lsr a
  lsr a
cy_mul:
  sta $3A
  lda $1B
  sta $40
  lda $1C
  sta $41
  lda $3A
  jsr mul
  jsr shr5
  lda $42
  sta $1F
  lda $43
  sta $20

  lda $14               ; map index = y * 16 + x
  asl a
  asl a
  asl a
  asl a
  ora $12
  sta $21

dda:                    ; step to whichever cell edge is nearer
  lda $1E
  cmp $20
  jcc dda_x
  jne dda_y
  lda $1D
  cmp $1F
  jcc dda_x
dda_y:
  clc
  lda $1F
  adc $1B
  sta $1F
  lda $20
  adc $1C
  sta $20
  clc
  lda $21
  adc $18
  sta $21
  lda #$01
  sta $22
  jmp dda_check
dda_x:
  clc
  lda $1D
  adc $19
  sta $1D
  lda $1E
  adc $1A
  sta $1E
  clc
  lda $21
  adc $17
  sta $21
  lda #$00
  sta $22
dda_check:
  ldi $21
  lda $3800,i
  jeq dda
  sta $23

  lda $22               ; distance = ray length to the edge it crossed
  jne dist_y
  sec
  lda $1D
  sbc $19
  sta $42
  lda $1E
  sbc $1A
  sta $43
  jmp dist_have
dist_y:
  sec
  lda $1F
  sbc $1B
  sta $42
  lda $20
  sbc $1C
  sta $43
dist_have:
  lsr $43               ; table index = distance / 2, at most 255
  ror $42
  lda $43
  jeq idx_ok
  lda #$FF
  sta $42
idx_ok:
  lda #$20              ; this column's height table is at $2000 + 256 * distance from centre
  clc
  adc $24
  sta $0D06
  ldi $42
  jsr hlook
  sta $25
  cmp #$04              ; far away: fog
  jcc fog
  lda $23
  asl a
  ora $22
  tai
  lda $3A00,i
  jmp col_have
fog:
  lda #$55
col_have:
  ldi $15
  sta $3C40,i
  lda $25
  sta $3C00,i
  lda $23
  sta $3C80,i
  lda $21
  sta $3CC0,i
  inc $15
  lda $15
  cmp #$28
  jne ca_loop
  ret

; mul: $42/$43 = a * $40/$41 (a up to 63; $40/$41 is used up)
mul:
  sta $44
  lda #$00
  sta $42
  sta $43
mul_loop:
  lda $44
  jeq mul_done
  lsr $44
  jcc mul_skip
  clc
  lda $42
  adc $40
  sta $42
  lda $43
  adc $41
  sta $43
mul_skip:
  asl $40
  rol $41
  jmp mul_loop
mul_done:
  ret

; shr5: $42/$43 shifted right 5 places
shr5:
  lsr $43
  ror $42
  lsr $43
  ror $42
  lsr $43
  ror $42
  lsr $43
  ror $42
  lsr $43
  ror $42
  ret

; ============================================================================
; draw_all: paint the 40 columns: ceiling, wall, floor
; ============================================================================
draw_all:
  lda #$00
  sta $15
da_loop:
  ldi $15
  lda $3C00,i
  sta $25
  lda $3C40,i
  sta $2A
  lda $15
  asl a
  sta $2B
  lda #$1A              ; top = 26 - half height, bottom = 26 + half height
  sec
  sbc $25
  sta $26
  lda #$1A
  clc
  adc $25
  sta $27
  lda $26               ; offsets into the painter: row * 3
  asl a
  clc
  adc $26
  sta $28
  lda $27
  asl a
  clc
  adc $27
  sta $29

  lda $26               ; ceiling: rows 0 to top-1
  jeq da_wall
  ldi $28
  lda #$A0
  sta $0E00,i
  ldi $2B
  lda #$11
  jsr col0
  ldi $28
  lda #$DD
  sta $0E00,i
da_wall:
  lda $25               ; wall: rows top to bottom-1
  jeq da_floor
  lda $27
  cmp #$34
  jeq da_wall_go
  ldi $29
  lda #$A0
  sta $0E00,i
da_wall_go:
  lda $28
  sta $0D01
  ldi $2B
  lda $2A
  jsr tramp
  lda $27
  cmp #$34
  jeq da_next
  ldi $29
  lda #$DD
  sta $0E00,i
da_floor:
  lda $27               ; floor: rows bottom to 51
  cmp #$34
  jeq da_next
  lda $29
  sta $0D01
  ldi $2B
  lda #$44
  jsr tramp
da_next:
  inc $15
  lda $15
  cmp #$28
  jne da_loop
  ret

; ============================================================================
; draw_gun: the pistol at the bottom of the view, with a flash after a shot
; ============================================================================
draw_gun:
  lda $32
  jeq dg_body
  lda #$AA
  sta $85C6
  sta $85C8
  sta $85C7
  sta $85C9
  sta $8616
  sta $8618
  sta $8617
  sta $8619
  lda #$99
  sta $85C5
  sta $85CB
  sta $8614
  sta $861A
dg_body:
  lda #$56
  sta $8666
  lda #$65
  sta $8668
  lda #$56
  sta $8667
  lda #$65
  sta $8669
  lda #$56
  sta $86B6
  lda #$65
  sta $86B8
  lda #$56
  sta $86B7
  lda #$65
  sta $86B9
  lda #$55
  sta $8704
  lda #$66
  sta $8706
  sta $8708
  lda #$55
  sta $870A
  sta $8705
  lda #$66
  sta $8707
  sta $8709
  lda #$55
  sta $870B
  sta $8754
  lda #$66
  sta $8756
  sta $8758
  lda #$55
  sta $875A
  sta $8755
  lda #$66
  sta $8757
  sta $8759
  lda #$55
  sta $875B
  lda #$77
  sta $87A4
  lda #$55
  sta $87A6
  sta $87A8
  lda #$77
  sta $87AA
  sta $87A5
  lda #$55
  sta $87A7
  sta $87A9
  lda #$77
  sta $87AB
  sta $87F4
  lda #$55
  sta $87F6
  sta $87F8
  lda #$77
  sta $87FA
  sta $87F5
  lda #$55
  sta $87F7
  sta $87F9
  lda #$77
  sta $87FB
  ret

; ============================================================================
; draw_hud: health, ammo and kills; the status bar flashes red when hurt
; ============================================================================
draw_hud:
  lda #$31
  sta $51
  lda #$88
  sta $52
  lda $36
  jsr print3
  lda #$49
  sta $51
  lda #$88
  sta $52
  lda $37
  jsr print3
  lda $38
  clc
  adc #$30
  sta $8861
  ldb #$1F
  lda $3C
  jeq dh_color
  ldb #$8F
dh_color:
  ldi #$00
dh_loop:
  tba
  sta $8820,i
  inc i
  inc i
  tia
  cmp #$50
  jne dh_loop
  ret

; print3: write a (0-255) as three digits at the text address in $51/$52
print3:
  sta $3A
  lda $51
  sta $0D09
  lda $52
  sta $0D0A
  ldb #$30
p3_h:
  lda $3A
  cmp #$64
  jcc p3_hd
  sec
  sbc #$64
  sta $3A
  inc b
  jmp p3_h
p3_hd:
  ldi #$00
  tba
  jsr prstore
  ldb #$30
p3_t:
  lda $3A
  cmp #$0A
  jcc p3_td
  sec
  sbc #$0A
  sta $3A
  inc b
  jmp p3_t
p3_td:
  ldi #$02
  tba
  jsr prstore
  lda $3A
  clc
  adc #$30
  ldi #$04
  jsr prstore
  ret

; ============================================================================
; Text
; ============================================================================
; print: copy the string at $3A20 + $0050 (ends with 0) into the text
; character bytes starting at $0051/$0052
print:
  lda $51
  sta $0D09
  lda $52
  sta $0D0A
  ldb #$00
print_loop:
  ldi $50
  lda $3A20,i
  jeq print_done
  tac
  tba
  tai
  tca
  jsr prstore
  inc b
  inc b
  inc $50
  jmp print_loop
print_done:
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

; clear_screen: graphics to black, text to blank white-on-navy
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

; ============================================================================
; Helpers whose addresses are patched at run time
; ============================================================================
.org $0D00
tramp:                  ; $0D00: call the column painter at row (low byte $0D01) / 3
  jsr $0E00
  ret
hlook:                  ; $0D04: a = height table byte (table page in $0D06)
  lda $2000,i
  ret
prstore:                ; $0D08: write a character (address in $0D09/$0D0A)
  sta $8000,i
  ret
mapread:                ; $0D0C: a = byte of a level map (page in $0D0E)
  lda $4000,i
  ret


; ============================================================================
; Column painter: one store per subpixel row, for column offset i (= column * 2).
; draw_all enters at row * 3 and stops it early by writing a ret ($A0) over
; the store for the first row it should not paint, then puts the store ($DD) back.
; ============================================================================
.org $0E00
col0:
  sta $8000,i    ; row 0
  sta $8001,i    ; row 1
  sta $8050,i    ; row 2
  sta $8051,i    ; row 3
  sta $80A0,i    ; row 4
  sta $80A1,i    ; row 5
  sta $80F0,i    ; row 6
  sta $80F1,i    ; row 7
  sta $8140,i    ; row 8
  sta $8141,i    ; row 9
  sta $8190,i    ; row 10
  sta $8191,i    ; row 11
  sta $81E0,i    ; row 12
  sta $81E1,i    ; row 13
  sta $8230,i    ; row 14
  sta $8231,i    ; row 15
  sta $8280,i    ; row 16
  sta $8281,i    ; row 17
  sta $82D0,i    ; row 18
  sta $82D1,i    ; row 19
  sta $8320,i    ; row 20
  sta $8321,i    ; row 21
  sta $8370,i    ; row 22
  sta $8371,i    ; row 23
  sta $83C0,i    ; row 24
  sta $83C1,i    ; row 25
  sta $8410,i    ; row 26
  sta $8411,i    ; row 27
  sta $8460,i    ; row 28
  sta $8461,i    ; row 29
  sta $84B0,i    ; row 30
  sta $84B1,i    ; row 31
  sta $8500,i    ; row 32
  sta $8501,i    ; row 33
  sta $8550,i    ; row 34
  sta $8551,i    ; row 35
  sta $85A0,i    ; row 36
  sta $85A1,i    ; row 37
  sta $85F0,i    ; row 38
  sta $85F1,i    ; row 39
  sta $8640,i    ; row 40
  sta $8641,i    ; row 41
  sta $8690,i    ; row 42
  sta $8691,i    ; row 43
  sta $86E0,i    ; row 44
  sta $86E1,i    ; row 45
  sta $8730,i    ; row 46
  sta $8731,i    ; row 47
  sta $8780,i    ; row 48
  sta $8781,i    ; row 49
  sta $87D0,i    ; row 50
  sta $87D1,i    ; row 51
  ret

; Ray length to cross one cell along x (1/16 cell), low bytes, by angle
.org $1000
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $11
.bytes $11, $11
.bytes $11, $11
.bytes $11, $12
.bytes $12, $12
.bytes $12, $12
.bytes $13, $13
.bytes $13, $14
.bytes $14, $14
.bytes $15, $15
.bytes $16, $16
.bytes $17, $17
.bytes $18, $18
.bytes $19, $1A
.bytes $1B, $1C
.bytes $1D, $1E
.bytes $1F, $20
.bytes $22, $24
.bytes $25, $27
.bytes $2A, $2C
.bytes $2F, $33
.bytes $37, $3C
.bytes $42, $49
.bytes $52, $5E
.bytes $6D, $83
.bytes $A3, $D9
.bytes $46, $8C
.bytes $FF, $8C
.bytes $46, $D9
.bytes $A3, $83
.bytes $6D, $5E
.bytes $52, $49
.bytes $42, $3C
.bytes $37, $33
.bytes $2F, $2C
.bytes $2A, $27
.bytes $25, $24
.bytes $22, $20
.bytes $1F, $1E
.bytes $1D, $1C
.bytes $1B, $1A
.bytes $19, $18
.bytes $18, $17
.bytes $17, $16
.bytes $16, $15
.bytes $15, $14
.bytes $14, $14
.bytes $13, $13
.bytes $13, $12
.bytes $12, $12
.bytes $12, $12
.bytes $11, $11
.bytes $11, $11
.bytes $11, $11
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $11
.bytes $11, $11
.bytes $11, $11
.bytes $11, $12
.bytes $12, $12
.bytes $12, $12
.bytes $13, $13
.bytes $13, $14
.bytes $14, $14
.bytes $15, $15
.bytes $16, $16
.bytes $17, $17
.bytes $18, $18
.bytes $19, $1A
.bytes $1B, $1C
.bytes $1D, $1E
.bytes $1F, $20
.bytes $22, $24
.bytes $25, $27
.bytes $2A, $2C
.bytes $2F, $33
.bytes $37, $3C
.bytes $42, $49
.bytes $52, $5E
.bytes $6D, $83
.bytes $A3, $D9
.bytes $46, $8C
.bytes $FF, $8C
.bytes $46, $D9
.bytes $A3, $83
.bytes $6D, $5E
.bytes $52, $49
.bytes $42, $3C
.bytes $37, $33
.bytes $2F, $2C
.bytes $2A, $27
.bytes $25, $24
.bytes $22, $20
.bytes $1F, $1E
.bytes $1D, $1C
.bytes $1B, $1A
.bytes $19, $18
.bytes $18, $17
.bytes $17, $16
.bytes $16, $15
.bytes $15, $14
.bytes $14, $14
.bytes $13, $13
.bytes $13, $12
.bytes $12, $12
.bytes $12, $12
.bytes $11, $11
.bytes $11, $11
.bytes $11, $11
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10

; ... high bytes
.org $1100
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $01, $02
.bytes $07, $02
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $01, $02
.bytes $07, $02
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00

; Ray length to cross one cell along y, low bytes
.org $1200
.bytes $FF, $8C
.bytes $46, $D9
.bytes $A3, $83
.bytes $6D, $5E
.bytes $52, $49
.bytes $42, $3C
.bytes $37, $33
.bytes $2F, $2C
.bytes $2A, $27
.bytes $25, $24
.bytes $22, $20
.bytes $1F, $1E
.bytes $1D, $1C
.bytes $1B, $1A
.bytes $19, $18
.bytes $18, $17
.bytes $17, $16
.bytes $16, $15
.bytes $15, $14
.bytes $14, $14
.bytes $13, $13
.bytes $13, $12
.bytes $12, $12
.bytes $12, $12
.bytes $11, $11
.bytes $11, $11
.bytes $11, $11
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $11
.bytes $11, $11
.bytes $11, $11
.bytes $11, $12
.bytes $12, $12
.bytes $12, $12
.bytes $13, $13
.bytes $13, $14
.bytes $14, $14
.bytes $15, $15
.bytes $16, $16
.bytes $17, $17
.bytes $18, $18
.bytes $19, $1A
.bytes $1B, $1C
.bytes $1D, $1E
.bytes $1F, $20
.bytes $22, $24
.bytes $25, $27
.bytes $2A, $2C
.bytes $2F, $33
.bytes $37, $3C
.bytes $42, $49
.bytes $52, $5E
.bytes $6D, $83
.bytes $A3, $D9
.bytes $46, $8C
.bytes $FF, $8C
.bytes $46, $D9
.bytes $A3, $83
.bytes $6D, $5E
.bytes $52, $49
.bytes $42, $3C
.bytes $37, $33
.bytes $2F, $2C
.bytes $2A, $27
.bytes $25, $24
.bytes $22, $20
.bytes $1F, $1E
.bytes $1D, $1C
.bytes $1B, $1A
.bytes $19, $18
.bytes $18, $17
.bytes $17, $16
.bytes $16, $15
.bytes $15, $14
.bytes $14, $14
.bytes $13, $13
.bytes $13, $12
.bytes $12, $12
.bytes $12, $12
.bytes $11, $11
.bytes $11, $11
.bytes $11, $11
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $10
.bytes $10, $11
.bytes $11, $11
.bytes $11, $11
.bytes $11, $12
.bytes $12, $12
.bytes $12, $12
.bytes $13, $13
.bytes $13, $14
.bytes $14, $14
.bytes $15, $15
.bytes $16, $16
.bytes $17, $17
.bytes $18, $18
.bytes $19, $1A
.bytes $1B, $1C
.bytes $1D, $1E
.bytes $1F, $20
.bytes $22, $24
.bytes $25, $27
.bytes $2A, $2C
.bytes $2F, $33
.bytes $37, $3C
.bytes $42, $49
.bytes $52, $5E
.bytes $6D, $83
.bytes $A3, $D9
.bytes $46, $8C

; ... high bytes
.org $1300
.bytes $07, $02
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $01, $02
.bytes $07, $02
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $01, $02

; Step along x per clock tick when walking (signed, 1/256 cell)
.org $1400
.bytes $0D, $0D
.bytes $0D, $0D
.bytes $0D, $0D
.bytes $0D, $0D
.bytes $0D, $0D
.bytes $0D, $0D
.bytes $0C, $0C
.bytes $0C, $0C
.bytes $0C, $0C
.bytes $0C, $0C
.bytes $0B, $0B
.bytes $0B, $0B
.bytes $0B, $0B
.bytes $0A, $0A
.bytes $0A, $0A
.bytes $0A, $09
.bytes $09, $09
.bytes $09, $08
.bytes $08, $08
.bytes $08, $07
.bytes $07, $07
.bytes $07, $06
.bytes $06, $06
.bytes $06, $05
.bytes $05, $05
.bytes $04, $04
.bytes $04, $03
.bytes $03, $03
.bytes $03, $02
.bytes $02, $02
.bytes $01, $01
.bytes $01, $00
.bytes $00, $00
.bytes $FF, $FF
.bytes $FF, $FE
.bytes $FE, $FE
.bytes $FD, $FD
.bytes $FD, $FD
.bytes $FC, $FC
.bytes $FC, $FB
.bytes $FB, $FB
.bytes $FA, $FA
.bytes $FA, $FA
.bytes $F9, $F9
.bytes $F9, $F9
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F7, $F7
.bytes $F7, $F7
.bytes $F6, $F6
.bytes $F6, $F6
.bytes $F6, $F5
.bytes $F5, $F5
.bytes $F5, $F5
.bytes $F5, $F4
.bytes $F4, $F4
.bytes $F4, $F4
.bytes $F4, $F4
.bytes $F4, $F3
.bytes $F3, $F3
.bytes $F3, $F3
.bytes $F3, $F3
.bytes $F3, $F3
.bytes $F3, $F3
.bytes $F3, $F3
.bytes $F3, $F3
.bytes $F3, $F3
.bytes $F3, $F3
.bytes $F3, $F3
.bytes $F3, $F3
.bytes $F4, $F4
.bytes $F4, $F4
.bytes $F4, $F4
.bytes $F4, $F4
.bytes $F5, $F5
.bytes $F5, $F5
.bytes $F5, $F5
.bytes $F6, $F6
.bytes $F6, $F6
.bytes $F6, $F7
.bytes $F7, $F7
.bytes $F7, $F8
.bytes $F8, $F8
.bytes $F8, $F9
.bytes $F9, $F9
.bytes $F9, $FA
.bytes $FA, $FA
.bytes $FA, $FB
.bytes $FB, $FB
.bytes $FC, $FC
.bytes $FC, $FD
.bytes $FD, $FD
.bytes $FD, $FE
.bytes $FE, $FE
.bytes $FF, $FF
.bytes $FF, $00
.bytes $00, $00
.bytes $01, $01
.bytes $01, $02
.bytes $02, $02
.bytes $03, $03
.bytes $03, $03
.bytes $04, $04
.bytes $04, $05
.bytes $05, $05
.bytes $06, $06
.bytes $06, $06
.bytes $07, $07
.bytes $07, $07
.bytes $08, $08
.bytes $08, $08
.bytes $09, $09
.bytes $09, $09
.bytes $0A, $0A
.bytes $0A, $0A
.bytes $0A, $0B
.bytes $0B, $0B
.bytes $0B, $0B
.bytes $0B, $0C
.bytes $0C, $0C
.bytes $0C, $0C
.bytes $0C, $0C
.bytes $0C, $0D
.bytes $0D, $0D
.bytes $0D, $0D
.bytes $0D, $0D
.bytes $0D, $0D
.bytes $0D, $0D

; Step along y per clock tick when walking
.org $1500
.bytes $00, $00
.bytes $01, $01
.bytes $01, $02
.bytes $02, $02
.bytes $03, $03
.bytes $03, $03
.bytes $04, $04
.bytes $04, $05
.bytes $05, $05
.bytes $06, $06
.bytes $06, $06
.bytes $07, $07
.bytes $07, $07
.bytes $08, $08
.bytes $08, $08
.bytes $09, $09
.bytes $09, $09
.bytes $0A, $0A
.bytes $0A, $0A
.bytes $0A, $0B
.bytes $0B, $0B
.bytes $0B, $0B
.bytes $0B, $0C
.bytes $0C, $0C
.bytes $0C, $0C
.bytes $0C, $0C
.bytes $0C, $0D
.bytes $0D, $0D
.bytes $0D, $0D
.bytes $0D, $0D
.bytes $0D, $0D
.bytes $0D, $0D
.bytes $0D, $0D
.bytes $0D, $0D
.bytes $0D, $0D
.bytes $0D, $0D
.bytes $0D, $0D
.bytes $0D, $0D
.bytes $0C, $0C
.bytes $0C, $0C
.bytes $0C, $0C
.bytes $0C, $0C
.bytes $0B, $0B
.bytes $0B, $0B
.bytes $0B, $0B
.bytes $0A, $0A
.bytes $0A, $0A
.bytes $0A, $09
.bytes $09, $09
.bytes $09, $08
.bytes $08, $08
.bytes $08, $07
.bytes $07, $07
.bytes $07, $06
.bytes $06, $06
.bytes $06, $05
.bytes $05, $05
.bytes $04, $04
.bytes $04, $03
.bytes $03, $03
.bytes $03, $02
.bytes $02, $02
.bytes $01, $01
.bytes $01, $00
.bytes $00, $00
.bytes $FF, $FF
.bytes $FF, $FE
.bytes $FE, $FE
.bytes $FD, $FD
.bytes $FD, $FD
.bytes $FC, $FC
.bytes $FC, $FB
.bytes $FB, $FB
.bytes $FA, $FA
.bytes $FA, $FA
.bytes $F9, $F9
.bytes $F9, $F9
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F7, $F7
.bytes $F7, $F7
.bytes $F6, $F6
.bytes $F6, $F6
.bytes $F6, $F5
.bytes $F5, $F5
.bytes $F5, $F5
.bytes $F5, $F4
.bytes $F4, $F4
.bytes $F4, $F4
.bytes $F4, $F4
.bytes $F4, $F3
.bytes $F3, $F3
.bytes $F3, $F3
.bytes $F3, $F3
.bytes $F3, $F3
.bytes $F3, $F3
.bytes $F3, $F3
.bytes $F3, $F3
.bytes $F3, $F3
.bytes $F3, $F3
.bytes $F3, $F3
.bytes $F3, $F3
.bytes $F4, $F4
.bytes $F4, $F4
.bytes $F4, $F4
.bytes $F4, $F4
.bytes $F5, $F5
.bytes $F5, $F5
.bytes $F5, $F5
.bytes $F6, $F6
.bytes $F6, $F6
.bytes $F6, $F7
.bytes $F7, $F7
.bytes $F7, $F8
.bytes $F8, $F8
.bytes $F8, $F9
.bytes $F9, $F9
.bytes $F9, $FA
.bytes $FA, $FA
.bytes $FA, $FB
.bytes $FB, $FB
.bytes $FC, $FC
.bytes $FC, $FD
.bytes $FD, $FD
.bytes $FD, $FE
.bytes $FE, $FE
.bytes $FF, $FF
.bytes $FF, $00

; Half wall height (subpixel rows) for rays 0 steps from the centre, by distance/2
.org $2000
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $18, $16
.bytes $15, $13
.bytes $12, $11
.bytes $10, $0F
.bytes $0F, $0E
.bytes $0D, $0D
.bytes $0C, $0C
.bytes $0B, $0B
.bytes $0B, $0A
.bytes $0A, $0A
.bytes $09, $09
.bytes $09, $08
.bytes $08, $08
.bytes $08, $08
.bytes $07, $07
.bytes $07, $07
.bytes $07, $07
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Half wall height (subpixel rows) for rays 1 steps from the centre, by distance/2
.org $2100
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $18, $16
.bytes $15, $13
.bytes $12, $11
.bytes $10, $0F
.bytes $0F, $0E
.bytes $0D, $0D
.bytes $0C, $0C
.bytes $0B, $0B
.bytes $0B, $0A
.bytes $0A, $0A
.bytes $09, $09
.bytes $09, $08
.bytes $08, $08
.bytes $08, $08
.bytes $07, $07
.bytes $07, $07
.bytes $07, $07
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Half wall height (subpixel rows) for rays 2 steps from the centre, by distance/2
.org $2200
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $18, $16
.bytes $15, $13
.bytes $12, $11
.bytes $10, $0F
.bytes $0F, $0E
.bytes $0D, $0D
.bytes $0C, $0C
.bytes $0B, $0B
.bytes $0B, $0A
.bytes $0A, $0A
.bytes $09, $09
.bytes $09, $08
.bytes $08, $08
.bytes $08, $08
.bytes $07, $07
.bytes $07, $07
.bytes $07, $07
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Half wall height (subpixel rows) for rays 3 steps from the centre, by distance/2
.org $2300
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $18, $16
.bytes $15, $13
.bytes $12, $11
.bytes $10, $0F
.bytes $0F, $0E
.bytes $0D, $0D
.bytes $0C, $0C
.bytes $0B, $0B
.bytes $0B, $0A
.bytes $0A, $0A
.bytes $09, $09
.bytes $09, $08
.bytes $08, $08
.bytes $08, $08
.bytes $07, $07
.bytes $07, $07
.bytes $07, $07
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Half wall height (subpixel rows) for rays 4 steps from the centre, by distance/2
.org $2400
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $18, $16
.bytes $15, $13
.bytes $12, $11
.bytes $10, $0F
.bytes $0F, $0E
.bytes $0D, $0D
.bytes $0C, $0C
.bytes $0B, $0B
.bytes $0B, $0A
.bytes $0A, $0A
.bytes $09, $09
.bytes $09, $08
.bytes $08, $08
.bytes $08, $08
.bytes $07, $07
.bytes $07, $07
.bytes $07, $07
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Half wall height (subpixel rows) for rays 5 steps from the centre, by distance/2
.org $2500
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $18, $16
.bytes $15, $13
.bytes $12, $11
.bytes $10, $0F
.bytes $0F, $0E
.bytes $0D, $0D
.bytes $0C, $0C
.bytes $0B, $0B
.bytes $0B, $0A
.bytes $0A, $0A
.bytes $09, $09
.bytes $09, $08
.bytes $08, $08
.bytes $08, $08
.bytes $07, $07
.bytes $07, $07
.bytes $07, $07
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Half wall height (subpixel rows) for rays 6 steps from the centre, by distance/2
.org $2600
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $18, $16
.bytes $15, $14
.bytes $12, $11
.bytes $10, $10
.bytes $0F, $0E
.bytes $0D, $0D
.bytes $0C, $0C
.bytes $0B, $0B
.bytes $0B, $0A
.bytes $0A, $0A
.bytes $09, $09
.bytes $09, $09
.bytes $08, $08
.bytes $08, $08
.bytes $07, $07
.bytes $07, $07
.bytes $07, $07
.bytes $07, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Half wall height (subpixel rows) for rays 7 steps from the centre, by distance/2
.org $2700
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $18, $17
.bytes $15, $14
.bytes $12, $11
.bytes $10, $10
.bytes $0F, $0E
.bytes $0E, $0D
.bytes $0C, $0C
.bytes $0B, $0B
.bytes $0B, $0A
.bytes $0A, $0A
.bytes $09, $09
.bytes $09, $09
.bytes $08, $08
.bytes $08, $08
.bytes $08, $07
.bytes $07, $07
.bytes $07, $07
.bytes $07, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Half wall height (subpixel rows) for rays 8 steps from the centre, by distance/2
.org $2800
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $18, $17
.bytes $15, $14
.bytes $12, $11
.bytes $10, $10
.bytes $0F, $0E
.bytes $0E, $0D
.bytes $0C, $0C
.bytes $0C, $0B
.bytes $0B, $0A
.bytes $0A, $0A
.bytes $09, $09
.bytes $09, $09
.bytes $08, $08
.bytes $08, $08
.bytes $08, $07
.bytes $07, $07
.bytes $07, $07
.bytes $07, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Half wall height (subpixel rows) for rays 9 steps from the centre, by distance/2
.org $2900
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $19, $17
.bytes $15, $14
.bytes $13, $12
.bytes $11, $10
.bytes $0F, $0E
.bytes $0E, $0D
.bytes $0D, $0C
.bytes $0C, $0B
.bytes $0B, $0A
.bytes $0A, $0A
.bytes $09, $09
.bytes $09, $09
.bytes $08, $08
.bytes $08, $08
.bytes $08, $07
.bytes $07, $07
.bytes $07, $07
.bytes $07, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Half wall height (subpixel rows) for rays 10 steps from the centre, by distance/2
.org $2A00
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $19, $17
.bytes $15, $14
.bytes $13, $12
.bytes $11, $10
.bytes $0F, $0E
.bytes $0E, $0D
.bytes $0D, $0C
.bytes $0C, $0B
.bytes $0B, $0A
.bytes $0A, $0A
.bytes $09, $09
.bytes $09, $09
.bytes $08, $08
.bytes $08, $08
.bytes $08, $07
.bytes $07, $07
.bytes $07, $07
.bytes $07, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Half wall height (subpixel rows) for rays 11 steps from the centre, by distance/2
.org $2B00
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $19, $17
.bytes $15, $14
.bytes $13, $12
.bytes $11, $10
.bytes $0F, $0E
.bytes $0E, $0D
.bytes $0D, $0C
.bytes $0C, $0B
.bytes $0B, $0B
.bytes $0A, $0A
.bytes $0A, $09
.bytes $09, $09
.bytes $09, $08
.bytes $08, $08
.bytes $08, $07
.bytes $07, $07
.bytes $07, $07
.bytes $07, $07
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Half wall height (subpixel rows) for rays 12 steps from the centre, by distance/2
.org $2C00
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $19, $17
.bytes $16, $14
.bytes $13, $12
.bytes $11, $10
.bytes $0F, $0F
.bytes $0E, $0D
.bytes $0D, $0C
.bytes $0C, $0B
.bytes $0B, $0B
.bytes $0A, $0A
.bytes $0A, $09
.bytes $09, $09
.bytes $09, $08
.bytes $08, $08
.bytes $08, $08
.bytes $07, $07
.bytes $07, $07
.bytes $07, $07
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Half wall height (subpixel rows) for rays 13 steps from the centre, by distance/2
.org $2D00
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $19, $17
.bytes $16, $14
.bytes $13, $12
.bytes $11, $10
.bytes $0F, $0F
.bytes $0E, $0D
.bytes $0D, $0C
.bytes $0C, $0B
.bytes $0B, $0B
.bytes $0A, $0A
.bytes $0A, $09
.bytes $09, $09
.bytes $09, $08
.bytes $08, $08
.bytes $08, $08
.bytes $07, $07
.bytes $07, $07
.bytes $07, $07
.bytes $07, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Half wall height (subpixel rows) for rays 14 steps from the centre, by distance/2
.org $2E00
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $19, $18
.bytes $16, $15
.bytes $13, $12
.bytes $11, $10
.bytes $10, $0F
.bytes $0E, $0E
.bytes $0D, $0C
.bytes $0C, $0C
.bytes $0B, $0B
.bytes $0A, $0A
.bytes $0A, $09
.bytes $09, $09
.bytes $09, $08
.bytes $08, $08
.bytes $08, $08
.bytes $07, $07
.bytes $07, $07
.bytes $07, $07
.bytes $07, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Half wall height (subpixel rows) for rays 15 steps from the centre, by distance/2
.org $2F00
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $18
.bytes $16, $15
.bytes $13, $12
.bytes $11, $10
.bytes $10, $0F
.bytes $0E, $0E
.bytes $0D, $0D
.bytes $0C, $0C
.bytes $0B, $0B
.bytes $0B, $0A
.bytes $0A, $0A
.bytes $09, $09
.bytes $09, $09
.bytes $08, $08
.bytes $08, $08
.bytes $08, $07
.bytes $07, $07
.bytes $07, $07
.bytes $07, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Half wall height (subpixel rows) for rays 16 steps from the centre, by distance/2
.org $3000
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $18
.bytes $16, $15
.bytes $14, $13
.bytes $12, $11
.bytes $10, $0F
.bytes $0E, $0E
.bytes $0D, $0D
.bytes $0C, $0C
.bytes $0B, $0B
.bytes $0B, $0A
.bytes $0A, $0A
.bytes $09, $09
.bytes $09, $09
.bytes $08, $08
.bytes $08, $08
.bytes $08, $07
.bytes $07, $07
.bytes $07, $07
.bytes $07, $07
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Half wall height (subpixel rows) for rays 17 steps from the centre, by distance/2
.org $3100
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $18
.bytes $17, $15
.bytes $14, $13
.bytes $12, $11
.bytes $10, $0F
.bytes $0F, $0E
.bytes $0D, $0D
.bytes $0C, $0C
.bytes $0B, $0B
.bytes $0B, $0A
.bytes $0A, $0A
.bytes $09, $09
.bytes $09, $09
.bytes $09, $08
.bytes $08, $08
.bytes $08, $08
.bytes $07, $07
.bytes $07, $07
.bytes $07, $07
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Half wall height (subpixel rows) for rays 18 steps from the centre, by distance/2
.org $3200
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $19
.bytes $17, $15
.bytes $14, $13
.bytes $12, $11
.bytes $10, $0F
.bytes $0F, $0E
.bytes $0E, $0D
.bytes $0C, $0C
.bytes $0C, $0B
.bytes $0B, $0B
.bytes $0A, $0A
.bytes $0A, $09
.bytes $09, $09
.bytes $09, $08
.bytes $08, $08
.bytes $08, $08
.bytes $07, $07
.bytes $07, $07
.bytes $07, $07
.bytes $07, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Half wall height (subpixel rows) for rays 19 steps from the centre, by distance/2
.org $3300
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $19
.bytes $17, $16
.bytes $14, $13
.bytes $12, $11
.bytes $10, $10
.bytes $0F, $0E
.bytes $0E, $0D
.bytes $0D, $0C
.bytes $0C, $0B
.bytes $0B, $0B
.bytes $0A, $0A
.bytes $0A, $09
.bytes $09, $09
.bytes $09, $08
.bytes $08, $08
.bytes $08, $08
.bytes $08, $07
.bytes $07, $07
.bytes $07, $07
.bytes $07, $07
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Half wall height (subpixel rows) for rays 20 steps from the centre, by distance/2
.org $3400
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $1A
.bytes $1A, $19
.bytes $17, $16
.bytes $15, $13
.bytes $12, $11
.bytes $11, $10
.bytes $0F, $0E
.bytes $0E, $0D
.bytes $0D, $0C
.bytes $0C, $0C
.bytes $0B, $0B
.bytes $0A, $0A
.bytes $0A, $0A
.bytes $09, $09
.bytes $09, $09
.bytes $08, $08
.bytes $08, $08
.bytes $08, $07
.bytes $07, $07
.bytes $07, $07
.bytes $07, $07
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Wall colors: cell type * 2 + side (0 lit, 1 shaded)
.org $3A00
.bytes $00, $00
.bytes $66, $55
.bytes $BB, $33
.bytes $DD, $22
.bytes $EE, $88
.bytes $AA, $99

; Map offsets of the 8 cells around the player
.org $3A10
.bytes $EF, $F0
.bytes $F1, $FF
.bytes $01, $0F
.bytes $10, $11

; Text, each string ending in 0: $00 HUD  $24 TITLE  $32 HELP  $58 START  $7F DEAD  $A3 NEXT  $CB EPISODE
.org $3A20
.bytes $20, $48
.bytes $45, $41
.bytes $4C, $54
.bytes $48, $20
.bytes $31, $30
.bytes $30, $25
.bytes $20, $20
.bytes $20, $41
.bytes $4D, $4D
.bytes $4F, $20
.bytes $30, $32
.bytes $30, $20
.bytes $20, $20
.bytes $4B, $49
.bytes $4C, $4C
.bytes $53, $20
.bytes $30, $2F
.bytes $30, $00
.bytes $20, $54
.bytes $52, $49
.bytes $4E, $49
.bytes $54, $59
.bytes $20, $44
.bytes $4F, $4F
.bytes $4D, $00
.bytes $20, $41
.bytes $52, $52
.bytes $4F, $57
.bytes $53, $2F
.bytes $57, $41
.bytes $53, $44
.bytes $3A, $20
.bytes $4D, $4F
.bytes $56, $45
.bytes $20, $20
.bytes $43, $54
.bytes $52, $4C
.bytes $2F, $53
.bytes $50, $41
.bytes $43, $45
.bytes $3A, $20
.bytes $53, $48
.bytes $4F, $4F
.bytes $54, $00
.bytes $20, $46
.bytes $49, $4E
.bytes $44, $20
.bytes $54, $48
.bytes $45, $20
.bytes $59, $45
.bytes $4C, $4C
.bytes $4F, $57
.bytes $20, $45
.bytes $58, $49
.bytes $54, $2E
.bytes $20, $57
.bytes $41, $54
.bytes $43, $48
.bytes $20, $46
.bytes $4F, $52
.bytes $20, $49
.bytes $4D, $50
.bytes $53, $21
.bytes $00, $20
.bytes $59, $4F
.bytes $55, $20
.bytes $44, $49
.bytes $45, $44
.bytes $21, $20
.bytes $50, $52
.bytes $45, $53
.bytes $53, $20
.bytes $53, $50
.bytes $41, $43
.bytes $45, $20
.bytes $54, $4F
.bytes $20, $54
.bytes $52, $59
.bytes $20, $41
.bytes $47, $41
.bytes $49, $4E
.bytes $00, $20
.bytes $4C, $45
.bytes $56, $45
.bytes $4C, $20
.bytes $43, $4F
.bytes $4D, $50
.bytes $4C, $45
.bytes $54, $45
.bytes $21, $20
.bytes $53, $50
.bytes $41, $43
.bytes $45, $20
.bytes $46, $4F
.bytes $52, $20
.bytes $54, $48
.bytes $45, $20
.bytes $4E, $45
.bytes $58, $54
.bytes $20, $4F
.bytes $4E, $45
.bytes $00, $20
.bytes $59, $4F
.bytes $55, $20
.bytes $42, $45
.bytes $41, $54
.bytes $20, $54
.bytes $48, $45
.bytes $4D, $20
.bytes $41, $4C
.bytes $4C, $21
.bytes $20, $53
.bytes $50, $41
.bytes $43, $45
.bytes $20, $54
.bytes $4F, $20
.bytes $50, $4C
.bytes $41, $59
.bytes $20, $41
.bytes $47, $41
.bytes $49, $4E
.bytes $00, $00

; Levels: start x, start y, start angle, number of imps
.org $3E00
.bytes $01, $01
.bytes $00, $00
.bytes $01, $01
.bytes $00, $06
.bytes $01, $01
.bytes $00, $07
.bytes $01, $01
.bytes $40, $07

; Level names as shown on the status bar, 16 characters each
.org $3F00
.bytes $20, $20
.bytes $45, $31
.bytes $4D, $31
.bytes $3A, $20
.bytes $4D, $59
.bytes $20, $4C
.bytes $45, $56
.bytes $45, $4C
.bytes $20, $20
.bytes $20, $20
.bytes $45, $31
.bytes $4D, $32
.bytes $3A, $20
.bytes $48, $41
.bytes $4E, $47
.bytes $41, $52
.bytes $20, $45
.bytes $31, $4D
.bytes $33, $3A
.bytes $20, $54
.bytes $4F, $58
.bytes $49, $4E
.bytes $20, $4C
.bytes $41, $42
.bytes $20, $20
.bytes $20, $45
.bytes $31, $4D
.bytes $34, $3A
.bytes $20, $43
.bytes $4F, $4D
.bytes $4D, $41
.bytes $4E, $44

; Level 1: MY LEVEL (copied to $3800 when it starts)
.org $4000
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $05
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Level 2: HANGAR (copied to $3800 when it starts)
.org $4100
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $01
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $01
.bytes $00, $00
.bytes $03, $03
.bytes $03, $03
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $02
.bytes $00, $00
.bytes $00, $00
.bytes $00, $03
.bytes $00, $04
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $02
.bytes $00, $00
.bytes $04, $00
.bytes $00, $03
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $03
.bytes $00, $00
.bytes $00, $01
.bytes $01, $01
.bytes $01, $00
.bytes $01, $01
.bytes $01, $01
.bytes $00, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $03, $03
.bytes $03, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $04
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $03, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $04, $00
.bytes $03, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $03, $03
.bytes $03, $03
.bytes $00, $00
.bytes $02, $02
.bytes $02, $02
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $02, $00
.bytes $00, $04
.bytes $00, $01
.bytes $01, $00
.bytes $00, $04
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $02, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $02, $00
.bytes $00, $00
.bytes $00, $05
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Level 3: TOXIN LAB (copied to $3800 when it starts)
.org $4200
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $02
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $02, $02
.bytes $02, $00
.bytes $00, $02
.bytes $00, $00
.bytes $02, $02
.bytes $02, $02
.bytes $00, $01
.bytes $01, $00
.bytes $02, $00
.bytes $04, $00
.bytes $00, $02
.bytes $00, $00
.bytes $02, $00
.bytes $00, $04
.bytes $00, $01
.bytes $01, $00
.bytes $02, $00
.bytes $00, $00
.bytes $00, $02
.bytes $00, $00
.bytes $02, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $02, $02
.bytes $02, $02
.bytes $00, $02
.bytes $00, $00
.bytes $02, $02
.bytes $00, $02
.bytes $02, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $02
.bytes $02, $02
.bytes $02, $00
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $00, $02
.bytes $02, $01
.bytes $01, $00
.bytes $00, $04
.bytes $00, $00
.bytes $00, $00
.bytes $00, $04
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $03, $03
.bytes $00, $03
.bytes $03, $03
.bytes $03, $00
.bytes $03, $03
.bytes $00, $03
.bytes $00, $01
.bytes $01, $00
.bytes $03, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $04, $00
.bytes $00, $01
.bytes $01, $00
.bytes $03, $00
.bytes $03, $03
.bytes $03, $03
.bytes $00, $03
.bytes $03, $03
.bytes $03, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $03, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $04, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $03, $00
.bytes $00, $04
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $03, $00
.bytes $00, $00
.bytes $00, $05
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; Level 4: COMMAND (copied to $3800 when it starts)
.org $4300
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $00, $00
.bytes $04, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $03
.bytes $03, $00
.bytes $00, $01
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $03
.bytes $03, $00
.bytes $00, $00
.bytes $00, $00
.bytes $03, $03
.bytes $03, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $00, $00
.bytes $03, $00
.bytes $03, $00
.bytes $00, $01
.bytes $01, $01
.bytes $01, $00
.bytes $01, $01
.bytes $01, $01
.bytes $00, $00
.bytes $03, $00
.bytes $03, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $04
.bytes $00, $00
.bytes $00, $01
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $01, $00
.bytes $01, $01
.bytes $01, $00
.bytes $01, $01
.bytes $01, $00
.bytes $02, $02
.bytes $00, $04
.bytes $00, $00
.bytes $01, $00
.bytes $01, $04
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $02, $02
.bytes $00, $00
.bytes $00, $00
.bytes $01, $00
.bytes $01, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $01, $00
.bytes $01, $01
.bytes $01, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $04
.bytes $00, $00
.bytes $00, $00
.bytes $00, $04
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $00
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $00, $01
.bytes $01, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $04, $00
.bytes $00, $05
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
