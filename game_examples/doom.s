; ============================================================================
; TRINITY DOOM  (made by game_examples/doom_build.py: edit the levels there)
;
; A DOOM-style raycaster for Project Trinity in video mode 2 (mixed). The top
; 26 rows show a first-person 3D view, 40 columns wide: one ray per column is
; traced through a 16 x 16 map and its wall drawn taller the closer it is.
; There are 5 levels, played in order.
; The bottom 4 rows show health, ammo, kills and messages.
;
; Controls: up/down (or W/S) walk, left/right (or A/D) turn,
;           Ctrl (or SPACE when no arrow is held) shoots.
; Shoot the imps: when one can see you it throws fireballs, which fly straight
; at where you were (step aside to dodge; a hit costs 10 health), and standing
; next to one hurts too. The arch-imp takes 10 shots, throws three fireballs
; at once, and keeps the exit shut until it dies. Health pickups give 25. You start with 20 bullets. Walk into the yellow exit to go to the next level (you keep
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
;   4. draw_sprites draws the imps and fireballs, farthest first, at full
;      (subpixel) detail, only where they're nearer than the wall.
;   5. The gun is stamped on top and the status bar updated.
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
;   $3C80 is the wall distance (/2) per column, used for sprites and shooting
;   $5000 nibble painter  $5300-$5DFF sprite and fireball tables
;   $3500/$3600/$3700 arch-imp, health pickup, arch-imp-hit pictures
;   $3A0C picture pages  $3B20 more text
;   $5E00 things (imps, arch-imp, pickups): cells ($FF gone)  $5E10 shot timers
;         $5E20 can see you  $5E30/$5E40 your angle to them
;         $5E70 kind (0 imp, 1 arch-imp, 2 health pickup)
;   $5E50 fireballs (4): in the air, $5E54/$5E58 x, $5E5C/$5E60 y, $5E64/$5E68 step
;   $5E80-$5EEF sprite records   $6000 sprite and fireball code
;   $005D-$009E sprite, fireball and shooting scratch
;   $00A0 fireball aim offset  $00A1 arch-imp seen (show its health)
;   $00A2 arch-imp alive (exit shut)  $00A4 scratch  $00A5 arch-imp health
;   $00A6 arch-imp hit flash  $00A7 pickup flash
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
  jsr draw_sprites
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
  lda #$7A         ; died: this level again, with full health and ammo
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
  cmp #$04
  jeq es_episode
  lda #$9E         ; on to the next level, keeping health, 10 more bullets
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
  lda #$C6      ; that was the last level: back to the first
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
  jsr imp_list
  jsr clear_message
  jsr start_message
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
  jsr orb_tick
  lda $39
  jne up_done
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
  cmp #$07
  jne mx_solid
  jsr pickup
  jmp mx_ok
mx_solid:
  cmp #$05
  jne mv_y
  lda $A2
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
  cmp #$07
  jne my_solid
  jsr pickup
  jmp my_ok
my_solid:
  cmp #$05
  jne mv_done
  lda $A2
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
  cmp #$06
  jne ia_imp
  inc b
  inc b
  jmp ia_next
ia_imp:
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
; fire: on a new press, if there is ammo, shoot straight ahead: the nearest
; imp drawn across the middle of the view, in front of the wall there, dies
; (the arch-imp takes $0A hits)
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
  lda #$FF
  sta $90
  sta $91
  lda #$00
  sta $67
fi_scan:
  lda $67
  cmp $97
  jeq fi_scanned
  ldi $67
  lda $5EC0,i           ; only imps and the arch-imp can be shot
  cmp #$01
  jeq fi_next
  cmp #$03
  jeq fi_next
  lda $5E80,i           ; how far its middle is from the middle of the view (40)
  sec
  sbc #$28
  sta $3B
  and #$80
  jeq fi_pos
  lda #$00
  sec
  sbc $3B
  sta $3B
fi_pos:
  lda $5E90,i           ; a hit if within half its half width
  lsr a
  ora #$01
  cmp $3B
  jcc fi_next
  lda $5EB0,i           ; and nearer than the wall in the middle column
  cmp $3C94
  jcs fi_next
  cmp $90               ; and the nearest so far
  jcs fi_next
  sta $90
  lda $67
  sta $91
fi_next:
  inc $67
  jmp fi_scan
fi_scanned:
  lda $91
  cmp #$FF
  jeq fi_save
  tai
  lda #$00              ; not on screen any more
  sta $5ED0,i
  sta $A4
  lda $5EC0,i
  cmp #$02
  jne fi_kill
  lda #$10              ; the arch-imp flashes when hit
  sta $A6
  dec $A5
  jne fi_save           ; still standing
  inc $A4               ; down: the exit opens
  lda #$00
  sta $A1
  sta $A2
fi_kill:
  lda $5EE0,i
  sta $3B
  ldi $3B
  lda $5E00,i
  tac
  lda #$FF              ; it's dead: off the list and out of the map
  sta $5E00,i
  tca
  tai
  lda #$00
  sta $3800,i
  inc $38
  lda $A4
  jeq fi_save
  jsr clear_message
  lda #$25
  jsr show_message2
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
  cmp #$04              ; imps, the arch-imp and pickups are sprites:
  jeq dda               ; rays go through them
  cmp #$06
  jeq dda
  cmp #$07
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
  lda $42               ; wall distance, for sprites and shooting
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
  lda $A7
  jeq dh_red
  ldb #$3F
dh_red:
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
  jmp boss_bar

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
  lda #$1F
  sta $8910,i
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
rmwtramp:               ; $0D10: call the nibble painter at the row whose address is in $0D11/$0D12
  jsr $5000
  ret
sclook:                 ; $0D14: a = sprite scale table byte (page in $0D16)
  lda $5500,i
  ret
picidx:                 ; $0D18: a = picture column start (picture page in $0D1A)
  lda $5900,i
  ret
picrun:                 ; $0D1C: a = picture run byte (picture page in $0D1E)
  lda $5910,i
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

; The arch-imp picture: where each column's runs start
.org $3500
.bytes $00, $07
.bytes $0E, $15
.bytes $22, $32
.bytes $48, $5E
.bytes $74, $8A
.bytes $A0, $B6
.bytes $C6, $D3
.bytes $DA, $E1

; ... its runs: count, then top, bottom, color for each
.org $3510
.bytes $02, $09
.bytes $0B, $0D
.bytes $0B, $0C
.bytes $09, $02
.bytes $02, $05
.bytes $06, $08
.bytes $0A, $0D
.bytes $02, $01
.bytes $03, $06
.bytes $07, $09
.bytes $0D, $04
.bytes $00, $02
.bytes $0A, $07
.bytes $0B, $0D
.bytes $0E, $0F
.bytes $0D, $0F
.bytes $10, $06
.bytes $05, $01
.bytes $02, $0A
.bytes $03, $06
.bytes $0D, $08
.bytes $0E, $02
.bytes $0E, $0F
.bytes $0D, $0F
.bytes $10, $06
.bytes $07, $00
.bytes $02, $0A
.bytes $02, $04
.bytes $0D, $04
.bytes $05, $0A
.bytes $05, $07
.bytes $0D, $08
.bytes $0E, $02
.bytes $0E, $0F
.bytes $0D, $0F
.bytes $10, $06
.bytes $07, $01
.bytes $02, $0A
.bytes $02, $04
.bytes $0D, $04
.bytes $05, $09
.bytes $05, $06
.bytes $0D, $06
.bytes $07, $0F
.bytes $07, $08
.bytes $0D, $08
.bytes $0E, $02
.bytes $07, $01
.bytes $02, $0A
.bytes $02, $06
.bytes $0D, $06
.bytes $07, $08
.bytes $07, $08
.bytes $0D, $08
.bytes $0A, $02
.bytes $0A, $0B
.bytes $08, $0B
.bytes $0D, $02
.bytes $07, $01
.bytes $02, $0A
.bytes $02, $06
.bytes $0D, $06
.bytes $07, $08
.bytes $07, $08
.bytes $0D, $08
.bytes $0A, $02
.bytes $0A, $0B
.bytes $08, $0B
.bytes $0D, $02
.bytes $07, $01
.bytes $02, $0A
.bytes $02, $04
.bytes $0D, $04
.bytes $05, $09
.bytes $05, $06
.bytes $0D, $06
.bytes $07, $0F
.bytes $07, $08
.bytes $0D, $08
.bytes $0E, $02
.bytes $07, $00
.bytes $02, $0A
.bytes $02, $04
.bytes $0D, $04
.bytes $05, $0A
.bytes $05, $07
.bytes $0D, $08
.bytes $0E, $02
.bytes $0E, $0F
.bytes $0D, $0F
.bytes $10, $06
.bytes $05, $01
.bytes $02, $0A
.bytes $03, $06
.bytes $0D, $08
.bytes $0E, $02
.bytes $0E, $0F
.bytes $0D, $0F
.bytes $10, $06
.bytes $04, $00
.bytes $02, $0A
.bytes $07, $0B
.bytes $0D, $0E
.bytes $0F, $0D
.bytes $0F, $10
.bytes $06, $02
.bytes $01, $03
.bytes $06, $07
.bytes $09, $0D
.bytes $02, $02
.bytes $05, $06
.bytes $08, $0A
.bytes $0D, $02
.bytes $09, $0B
.bytes $0D, $0B
.bytes $0C, $09

; The health pickup picture: where each column's runs start
.org $3600
.bytes $00, $01
.bytes $02, $0C
.bytes $16, $20
.bytes $30, $40
.bytes $4A, $54
.bytes $64, $74
.bytes $7E, $88
.bytes $92, $93

; ... its runs: count, then top, bottom, color for each
.org $3610
.bytes $00, $00
.bytes $03, $08
.bytes $09, $06
.bytes $09, $0F
.bytes $0F, $0F
.bytes $10, $06
.bytes $03, $08
.bytes $09, $06
.bytes $09, $0F
.bytes $0F, $0F
.bytes $10, $06
.bytes $03, $08
.bytes $09, $06
.bytes $09, $0F
.bytes $0F, $0F
.bytes $10, $06
.bytes $05, $08
.bytes $09, $06
.bytes $09, $0B
.bytes $0F, $0B
.bytes $0D, $08
.bytes $0D, $0F
.bytes $0F, $0F
.bytes $10, $06
.bytes $05, $08
.bytes $09, $06
.bytes $09, $0B
.bytes $0F, $0B
.bytes $0D, $08
.bytes $0D, $0F
.bytes $0F, $0F
.bytes $10, $06
.bytes $03, $08
.bytes $09, $06
.bytes $09, $0F
.bytes $08, $0F
.bytes $10, $06
.bytes $03, $08
.bytes $09, $06
.bytes $09, $0F
.bytes $08, $0F
.bytes $10, $06
.bytes $05, $08
.bytes $09, $06
.bytes $09, $0B
.bytes $0F, $0B
.bytes $0D, $08
.bytes $0D, $0F
.bytes $0F, $0F
.bytes $10, $06
.bytes $05, $08
.bytes $09, $06
.bytes $09, $0B
.bytes $0F, $0B
.bytes $0D, $08
.bytes $0D, $0F
.bytes $0F, $0F
.bytes $10, $06
.bytes $03, $08
.bytes $09, $06
.bytes $09, $0F
.bytes $0F, $0F
.bytes $10, $06
.bytes $03, $08
.bytes $09, $06
.bytes $09, $0F
.bytes $0F, $0F
.bytes $10, $06
.bytes $03, $08
.bytes $09, $06
.bytes $09, $0F
.bytes $0F, $0F
.bytes $10, $06
.bytes $00, $00

; The arch-imp when hit picture: where each column's runs start
.org $3700
.bytes $00, $07
.bytes $0E, $15
.bytes $22, $32
.bytes $48, $58
.bytes $6E, $84
.bytes $94, $AA
.bytes $BA, $C7
.bytes $CE, $D5

; ... its runs: count, then top, bottom, color for each
.org $3710
.bytes $02, $09
.bytes $0B, $0F
.bytes $0B, $0C
.bytes $09, $02
.bytes $02, $05
.bytes $06, $08
.bytes $0A, $0F
.bytes $02, $01
.bytes $03, $06
.bytes $07, $09
.bytes $0F, $04
.bytes $00, $02
.bytes $0A, $07
.bytes $0B, $0F
.bytes $0E, $0F
.bytes $0F, $0F
.bytes $10, $06
.bytes $05, $01
.bytes $02, $0A
.bytes $03, $06
.bytes $0F, $08
.bytes $0E, $0E
.bytes $0E, $0F
.bytes $0F, $0F
.bytes $10, $06
.bytes $07, $00
.bytes $02, $0A
.bytes $02, $04
.bytes $0F, $04
.bytes $05, $0A
.bytes $05, $07
.bytes $0F, $08
.bytes $0E, $0E
.bytes $0E, $0F
.bytes $0F, $0F
.bytes $10, $06
.bytes $05, $01
.bytes $02, $0A
.bytes $02, $04
.bytes $0F, $04
.bytes $05, $09
.bytes $05, $08
.bytes $0F, $08
.bytes $0E, $0E
.bytes $07, $01
.bytes $02, $0A
.bytes $02, $06
.bytes $0F, $06
.bytes $07, $08
.bytes $07, $08
.bytes $0F, $08
.bytes $0A, $0E
.bytes $0A, $0B
.bytes $08, $0B
.bytes $0D, $0E
.bytes $07, $01
.bytes $02, $0A
.bytes $02, $06
.bytes $0F, $06
.bytes $07, $08
.bytes $07, $08
.bytes $0F, $08
.bytes $0A, $0E
.bytes $0A, $0B
.bytes $08, $0B
.bytes $0D, $0E
.bytes $05, $01
.bytes $02, $0A
.bytes $02, $04
.bytes $0F, $04
.bytes $05, $09
.bytes $05, $08
.bytes $0F, $08
.bytes $0E, $0E
.bytes $07, $00
.bytes $02, $0A
.bytes $02, $04
.bytes $0F, $04
.bytes $05, $0A
.bytes $05, $07
.bytes $0F, $08
.bytes $0E, $0E
.bytes $0E, $0F
.bytes $0F, $0F
.bytes $10, $06
.bytes $05, $01
.bytes $02, $0A
.bytes $03, $06
.bytes $0F, $08
.bytes $0E, $0E
.bytes $0E, $0F
.bytes $0F, $0F
.bytes $10, $06
.bytes $04, $00
.bytes $02, $0A
.bytes $07, $0B
.bytes $0F, $0E
.bytes $0F, $0F
.bytes $0F, $10
.bytes $06, $02
.bytes $01, $03
.bytes $06, $07
.bytes $09, $0F
.bytes $02, $02
.bytes $05, $06
.bytes $08, $0A
.bytes $0F, $02
.bytes $09, $0B
.bytes $0F, $0B
.bytes $0C, $09

; Wall colors: cell type * 2 + side (0 lit, 1 shaded)
.org $3A00
.bytes $00, $00
.bytes $66, $55
.bytes $BB, $33
.bytes $DD, $22
.bytes $EE, $88
.bytes $AA, $99

; Picture pages: imp, fireball, arch-imp, health pickup
.org $3A0C
.bytes $59, $5A
.bytes $35, $36

; Map offsets of the 8 cells around the player
.org $3A10
.bytes $EF, $F0
.bytes $F1, $FF
.bytes $01, $0F
.bytes $10, $11

; Text, each string ending in 0: $00 HUD  $24 TITLE  $32 HELP  $58 START  $7A DEAD  $9E NEXT  $C6 EPISODE
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
.bytes $45, $58
.bytes $49, $54
.bytes $2E, $20
.bytes $44, $45
.bytes $53, $54
.bytes $52, $4F
.bytes $59, $20
.bytes $54, $48
.bytes $45, $4D
.bytes $20, $41
.bytes $4C, $4C
.bytes $21, $00
.bytes $20, $59
.bytes $4F, $55
.bytes $20, $44
.bytes $49, $45
.bytes $44, $21
.bytes $20, $50
.bytes $52, $45
.bytes $53, $53
.bytes $20, $53
.bytes $50, $41
.bytes $43, $45
.bytes $20, $54
.bytes $4F, $20
.bytes $54, $52
.bytes $59, $20
.bytes $41, $47
.bytes $41, $49
.bytes $4E, $00
.bytes $20, $4C
.bytes $45, $56
.bytes $45, $4C
.bytes $20, $43
.bytes $4F, $4D
.bytes $50, $4C
.bytes $45, $54
.bytes $45, $21
.bytes $20, $53
.bytes $50, $41
.bytes $43, $45
.bytes $20, $46
.bytes $4F, $52
.bytes $20, $54
.bytes $48, $45
.bytes $20, $4E
.bytes $45, $58
.bytes $54, $20
.bytes $4F, $4E
.bytes $45, $00
.bytes $20, $59
.bytes $4F, $55
.bytes $20, $42
.bytes $45, $41
.bytes $54, $20
.bytes $54, $48
.bytes $45, $4D
.bytes $20, $41
.bytes $4C, $4C
.bytes $21, $20
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

; More text: $00 BOSS  $25 OPEN  $4D BAR
.org $3B20
.bytes $20, $4B
.bytes $49, $4C
.bytes $4C, $20
.bytes $54, $48
.bytes $45, $20
.bytes $41, $52
.bytes $43, $48
.bytes $2D, $49
.bytes $4D, $50
.bytes $20, $54
.bytes $4F, $20
.bytes $4F, $50
.bytes $45, $4E
.bytes $20, $54
.bytes $48, $45
.bytes $20, $45
.bytes $58, $49
.bytes $54, $21
.bytes $00, $20
.bytes $54, $48
.bytes $45, $20
.bytes $41, $52
.bytes $43, $48
.bytes $2D, $49
.bytes $4D, $50
.bytes $20, $49
.bytes $53, $20
.bytes $44, $45
.bytes $41, $44
.bytes $21, $20
.bytes $54, $48
.bytes $45, $20
.bytes $45, $58
.bytes $49, $54
.bytes $20, $49
.bytes $53, $20
.bytes $4F, $50
.bytes $45, $4E
.bytes $00, $20
.bytes $41, $52
.bytes $43, $48
.bytes $2D, $49
.bytes $4D, $50
.bytes $20, $00

; Levels: start x, start y, start angle, number of imps (and arch-imp)
.org $3E00
.bytes $01, $01
.bytes $00, $03
.bytes $01, $01
.bytes $00, $06
.bytes $01, $01
.bytes $00, $07
.bytes $01, $01
.bytes $40, $07
.bytes $01, $01
.bytes $C0, $04

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
.bytes $20, $20
.bytes $45, $31
.bytes $4D, $35
.bytes $3A, $20
.bytes $54, $48
.bytes $45, $20
.bytes $4C, $41
.bytes $49, $52

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
.bytes $03, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $03, $00
.bytes $00, $04
.bytes $00, $00
.bytes $00, $01
.bytes $01, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $02
.bytes $02, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $07, $00
.bytes $02, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $07, $00
.bytes $02, $00
.bytes $00, $01
.bytes $01, $00
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $02, $00
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
.bytes $04, $00
.bytes $00, $00
.bytes $00, $00
.bytes $01, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $01, $00
.bytes $07, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $01, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $04, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
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

; Level 5: THE LAIR (copied to $3800 when it starts)
.org $4400
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $00
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $07, $00
.bytes $00, $00
.bytes $00, $00
.bytes $01, $01
.bytes $01, $00
.bytes $01, $00
.bytes $03, $03
.bytes $00, $00
.bytes $00, $00
.bytes $00, $03
.bytes $03, $00
.bytes $00, $01
.bytes $01, $00
.bytes $01, $00
.bytes $03, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $03, $00
.bytes $00, $01
.bytes $01, $00
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $06, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $01, $00
.bytes $03, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $03, $00
.bytes $00, $01
.bytes $01, $00
.bytes $01, $00
.bytes $03, $03
.bytes $00, $00
.bytes $04, $00
.bytes $00, $03
.bytes $03, $00
.bytes $00, $01
.bytes $01, $00
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $01, $01
.bytes $01, $01
.bytes $01, $00
.bytes $00, $01
.bytes $01, $01
.bytes $01, $01
.bytes $00, $01
.bytes $01, $07
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $02, $00
.bytes $00, $02
.bytes $00, $00
.bytes $00, $04
.bytes $00, $01
.bytes $01, $00
.bytes $00, $04
.bytes $00, $00
.bytes $02, $00
.bytes $00, $02
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $00
.bytes $00, $00
.bytes $00, $00
.bytes $02, $00
.bytes $00, $02
.bytes $00, $00
.bytes $00, $00
.bytes $07, $05
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01

; ============================================================================
; Nibble painter, for sprites: for rows y.., row byte = byte AND $005D OR $005E,
; at block column offset i. Entered at $5000 + 12 * row and stopped early like
; the column painter (its first instruction, lda = $35, is swapped for a ret).
; ============================================================================
.org $5000
  lda $8000,i    ; row 0
  and $5D
  ora $5E
  sta $8000,i
  lda $8001,i    ; row 1
  and $5D
  ora $5E
  sta $8001,i
  lda $8050,i    ; row 2
  and $5D
  ora $5E
  sta $8050,i
  lda $8051,i    ; row 3
  and $5D
  ora $5E
  sta $8051,i
  lda $80A0,i    ; row 4
  and $5D
  ora $5E
  sta $80A0,i
  lda $80A1,i    ; row 5
  and $5D
  ora $5E
  sta $80A1,i
  lda $80F0,i    ; row 6
  and $5D
  ora $5E
  sta $80F0,i
  lda $80F1,i    ; row 7
  and $5D
  ora $5E
  sta $80F1,i
  lda $8140,i    ; row 8
  and $5D
  ora $5E
  sta $8140,i
  lda $8141,i    ; row 9
  and $5D
  ora $5E
  sta $8141,i
  lda $8190,i    ; row 10
  and $5D
  ora $5E
  sta $8190,i
  lda $8191,i    ; row 11
  and $5D
  ora $5E
  sta $8191,i
  lda $81E0,i    ; row 12
  and $5D
  ora $5E
  sta $81E0,i
  lda $81E1,i    ; row 13
  and $5D
  ora $5E
  sta $81E1,i
  lda $8230,i    ; row 14
  and $5D
  ora $5E
  sta $8230,i
  lda $8231,i    ; row 15
  and $5D
  ora $5E
  sta $8231,i
  lda $8280,i    ; row 16
  and $5D
  ora $5E
  sta $8280,i
  lda $8281,i    ; row 17
  and $5D
  ora $5E
  sta $8281,i
  lda $82D0,i    ; row 18
  and $5D
  ora $5E
  sta $82D0,i
  lda $82D1,i    ; row 19
  and $5D
  ora $5E
  sta $82D1,i
  lda $8320,i    ; row 20
  and $5D
  ora $5E
  sta $8320,i
  lda $8321,i    ; row 21
  and $5D
  ora $5E
  sta $8321,i
  lda $8370,i    ; row 22
  and $5D
  ora $5E
  sta $8370,i
  lda $8371,i    ; row 23
  and $5D
  ora $5E
  sta $8371,i
  lda $83C0,i    ; row 24
  and $5D
  ora $5E
  sta $83C0,i
  lda $83C1,i    ; row 25
  and $5D
  ora $5E
  sta $83C1,i
  lda $8410,i    ; row 26
  and $5D
  ora $5E
  sta $8410,i
  lda $8411,i    ; row 27
  and $5D
  ora $5E
  sta $8411,i
  lda $8460,i    ; row 28
  and $5D
  ora $5E
  sta $8460,i
  lda $8461,i    ; row 29
  and $5D
  ora $5E
  sta $8461,i
  lda $84B0,i    ; row 30
  and $5D
  ora $5E
  sta $84B0,i
  lda $84B1,i    ; row 31
  and $5D
  ora $5E
  sta $84B1,i
  lda $8500,i    ; row 32
  and $5D
  ora $5E
  sta $8500,i
  lda $8501,i    ; row 33
  and $5D
  ora $5E
  sta $8501,i
  lda $8550,i    ; row 34
  and $5D
  ora $5E
  sta $8550,i
  lda $8551,i    ; row 35
  and $5D
  ora $5E
  sta $8551,i
  lda $85A0,i    ; row 36
  and $5D
  ora $5E
  sta $85A0,i
  lda $85A1,i    ; row 37
  and $5D
  ora $5E
  sta $85A1,i
  lda $85F0,i    ; row 38
  and $5D
  ora $5E
  sta $85F0,i
  lda $85F1,i    ; row 39
  and $5D
  ora $5E
  sta $85F1,i
  lda $8640,i    ; row 40
  and $5D
  ora $5E
  sta $8640,i
  lda $8641,i    ; row 41
  and $5D
  ora $5E
  sta $8641,i
  lda $8690,i    ; row 42
  and $5D
  ora $5E
  sta $8690,i
  lda $8691,i    ; row 43
  and $5D
  ora $5E
  sta $8691,i
  lda $86E0,i    ; row 44
  and $5D
  ora $5E
  sta $86E0,i
  lda $86E1,i    ; row 45
  and $5D
  ora $5E
  sta $86E1,i
  lda $8730,i    ; row 46
  and $5D
  ora $5E
  sta $8730,i
  lda $8731,i    ; row 47
  and $5D
  ora $5E
  sta $8731,i
  lda $8780,i    ; row 48
  and $5D
  ora $5E
  sta $8780,i
  lda $8781,i    ; row 49
  and $5D
  ora $5E
  sta $8781,i
  lda $87D0,i    ; row 50
  and $5D
  ora $5E
  sta $87D0,i
  lda $87D1,i    ; row 51
  and $5D
  ora $5E
  sta $87D1,i
  ret

; Angle (512 to a turn) of a slope small/big = index/256
.org $5300
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
.bytes $06, $07
.bytes $07, $07
.bytes $08, $08
.bytes $08, $09
.bytes $09, $09
.bytes $0A, $0A
.bytes $0A, $0A
.bytes $0B, $0B
.bytes $0B, $0C
.bytes $0C, $0C
.bytes $0D, $0D
.bytes $0D, $0E
.bytes $0E, $0E
.bytes $0E, $0F
.bytes $0F, $0F
.bytes $10, $10
.bytes $10, $11
.bytes $11, $11
.bytes $12, $12
.bytes $12, $12
.bytes $13, $13
.bytes $13, $14
.bytes $14, $14
.bytes $15, $15
.bytes $15, $15
.bytes $16, $16
.bytes $16, $17
.bytes $17, $17
.bytes $18, $18
.bytes $18, $18
.bytes $19, $19
.bytes $19, $1A
.bytes $1A, $1A
.bytes $1A, $1B
.bytes $1B, $1B
.bytes $1C, $1C
.bytes $1C, $1C
.bytes $1D, $1D
.bytes $1D, $1E
.bytes $1E, $1E
.bytes $1E, $1F
.bytes $1F, $1F
.bytes $1F, $20
.bytes $20, $20
.bytes $21, $21
.bytes $21, $21
.bytes $22, $22
.bytes $22, $22
.bytes $23, $23
.bytes $23, $23
.bytes $24, $24
.bytes $24, $24
.bytes $25, $25
.bytes $25, $26
.bytes $26, $26
.bytes $26, $27
.bytes $27, $27
.bytes $27, $28
.bytes $28, $28
.bytes $28, $29
.bytes $29, $29
.bytes $29, $2A
.bytes $2A, $2A
.bytes $2A, $2A
.bytes $2B, $2B
.bytes $2B, $2B
.bytes $2C, $2C
.bytes $2C, $2C
.bytes $2D, $2D
.bytes $2D, $2D
.bytes $2E, $2E
.bytes $2E, $2E
.bytes $2E, $2F
.bytes $2F, $2F
.bytes $2F, $30
.bytes $30, $30
.bytes $30, $30
.bytes $31, $31
.bytes $31, $31
.bytes $32, $32
.bytes $32, $32
.bytes $32, $33
.bytes $33, $33
.bytes $33, $33
.bytes $34, $34
.bytes $34, $34
.bytes $34, $35
.bytes $35, $35
.bytes $35, $35
.bytes $36, $36
.bytes $36, $36
.bytes $36, $37
.bytes $37, $37
.bytes $37, $37
.bytes $38, $38
.bytes $38, $38
.bytes $38, $39
.bytes $39, $39
.bytes $39, $39
.bytes $39, $3A
.bytes $3A, $3A
.bytes $3A, $3A
.bytes $3B, $3B
.bytes $3B, $3B
.bytes $3B, $3B
.bytes $3C, $3C
.bytes $3C, $3C
.bytes $3C, $3D
.bytes $3D, $3D
.bytes $3D, $3D
.bytes $3D, $3E
.bytes $3E, $3E
.bytes $3E, $3E
.bytes $3E, $3F
.bytes $3F, $3F
.bytes $3F, $3F
.bytes $3F, $40
.bytes $40, $40

; Distance / big side * 128, for slope index/256
.org $5400
.bytes $80, $80
.bytes $80, $80
.bytes $80, $80
.bytes $80, $80
.bytes $80, $80
.bytes $80, $80
.bytes $80, $80
.bytes $80, $80
.bytes $80, $80
.bytes $80, $80
.bytes $80, $80
.bytes $80, $81
.bytes $81, $81
.bytes $81, $81
.bytes $81, $81
.bytes $81, $81
.bytes $81, $81
.bytes $81, $81
.bytes $81, $81
.bytes $81, $81
.bytes $82, $82
.bytes $82, $82
.bytes $82, $82
.bytes $82, $82
.bytes $82, $82
.bytes $82, $83
.bytes $83, $83
.bytes $83, $83
.bytes $83, $83
.bytes $83, $83
.bytes $83, $84
.bytes $84, $84
.bytes $84, $84
.bytes $84, $84
.bytes $84, $85
.bytes $85, $85
.bytes $85, $85
.bytes $85, $85
.bytes $86, $86
.bytes $86, $86
.bytes $86, $86
.bytes $86, $87
.bytes $87, $87
.bytes $87, $87
.bytes $87, $88
.bytes $88, $88
.bytes $88, $88
.bytes $88, $89
.bytes $89, $89
.bytes $89, $89
.bytes $89, $8A
.bytes $8A, $8A
.bytes $8A, $8A
.bytes $8B, $8B
.bytes $8B, $8B
.bytes $8B, $8C
.bytes $8C, $8C
.bytes $8C, $8C
.bytes $8D, $8D
.bytes $8D, $8D
.bytes $8D, $8E
.bytes $8E, $8E
.bytes $8E, $8E
.bytes $8F, $8F
.bytes $8F, $8F
.bytes $90, $90
.bytes $90, $90
.bytes $90, $91
.bytes $91, $91
.bytes $91, $92
.bytes $92, $92
.bytes $92, $93
.bytes $93, $93
.bytes $93, $94
.bytes $94, $94
.bytes $94, $95
.bytes $95, $95
.bytes $95, $96
.bytes $96, $96
.bytes $96, $97
.bytes $97, $97
.bytes $97, $98
.bytes $98, $98
.bytes $99, $99
.bytes $99, $99
.bytes $9A, $9A
.bytes $9A, $9A
.bytes $9B, $9B
.bytes $9B, $9C
.bytes $9C, $9C
.bytes $9C, $9D
.bytes $9D, $9D
.bytes $9E, $9E
.bytes $9E, $9F
.bytes $9F, $9F
.bytes $9F, $A0
.bytes $A0, $A0
.bytes $A1, $A1
.bytes $A1, $A2
.bytes $A2, $A2
.bytes $A2, $A3
.bytes $A3, $A3
.bytes $A4, $A4
.bytes $A4, $A5
.bytes $A5, $A5
.bytes $A6, $A6
.bytes $A6, $A7
.bytes $A7, $A7
.bytes $A7, $A8
.bytes $A8, $A8
.bytes $A9, $A9
.bytes $A9, $AA
.bytes $AA, $AA
.bytes $AB, $AB
.bytes $AB, $AC
.bytes $AC, $AC
.bytes $AD, $AD
.bytes $AD, $AE
.bytes $AE, $AE
.bytes $AF, $AF
.bytes $AF, $B0
.bytes $B0, $B0
.bytes $B1, $B1
.bytes $B2, $B2
.bytes $B2, $B3
.bytes $B3, $B3
.bytes $B4, $B4
.bytes $B4, $B5

; Picture row v at half size hs: row offset v * 2hs / 16, at hs * 32 + v
.org $5500
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
.bytes $00, $01
.bytes $01, $01
.bytes $01, $01
.bytes $01, $01
.bytes $02, $02
.bytes $02, $02
.bytes $02, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $01
.bytes $02, $02
.bytes $02, $02
.bytes $02, $03
.bytes $03, $03
.bytes $04, $04
.bytes $04, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $01, $01
.bytes $02, $02
.bytes $02, $03
.bytes $03, $03
.bytes $04, $04
.bytes $04, $05
.bytes $05, $06
.bytes $06, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $01, $02
.bytes $02, $02
.bytes $03, $04
.bytes $04, $04
.bytes $05, $06
.bytes $06, $06
.bytes $07, $08
.bytes $08, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $02
.bytes $02, $03
.bytes $04, $04
.bytes $05, $06
.bytes $06, $07
.bytes $08, $08
.bytes $09, $09
.bytes $0A, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $02, $02
.bytes $03, $04
.bytes $04, $05
.bytes $06, $07
.bytes $08, $08
.bytes $09, $0A
.bytes $0A, $0B
.bytes $0C, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $02, $03
.bytes $04, $04
.bytes $05, $06
.bytes $07, $08
.bytes $09, $0A
.bytes $0A, $0B
.bytes $0C, $0D
.bytes $0E, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $02, $03
.bytes $04, $05
.bytes $06, $07
.bytes $08, $09
.bytes $0A, $0B
.bytes $0C, $0D
.bytes $0E, $0F
.bytes $10, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $02, $03
.bytes $04, $06
.bytes $07, $08
.bytes $09, $0A
.bytes $0B, $0C
.bytes $0E, $0F
.bytes $10, $11
.bytes $12, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $02, $04
.bytes $05, $06
.bytes $08, $09
.bytes $0A, $0B
.bytes $0C, $0E
.bytes $0F, $10
.bytes $12, $13
.bytes $14, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $03, $04
.bytes $06, $07
.bytes $08, $0A
.bytes $0B, $0C
.bytes $0E, $0F
.bytes $10, $12
.bytes $13, $15
.bytes $16, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $02
.bytes $03, $04
.bytes $06, $08
.bytes $09, $0A
.bytes $0C, $0E
.bytes $0F, $10
.bytes $12, $14
.bytes $15, $16
.bytes $18, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $02
.bytes $03, $05
.bytes $06, $08
.bytes $0A, $0B
.bytes $0D, $0F
.bytes $10, $12
.bytes $14, $15
.bytes $17, $18
.bytes $1A, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $02
.bytes $04, $05
.bytes $07, $09
.bytes $0A, $0C
.bytes $0E, $10
.bytes $12, $13
.bytes $15, $17
.bytes $18, $1A
.bytes $1C, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $02
.bytes $04, $06
.bytes $08, $09
.bytes $0B, $0D
.bytes $0F, $11
.bytes $13, $15
.bytes $16, $18
.bytes $1A, $1C
.bytes $1E, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $02
.bytes $04, $06
.bytes $08, $0A
.bytes $0C, $0E
.bytes $10, $12
.bytes $14, $16
.bytes $18, $1A
.bytes $1C, $1E
.bytes $20, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $02
.bytes $04, $06
.bytes $08, $0B
.bytes $0D, $0F
.bytes $11, $13
.bytes $15, $17
.bytes $1A, $1C
.bytes $1E, $20
.bytes $22, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $02
.bytes $04, $07
.bytes $09, $0B
.bytes $0E, $10
.bytes $12, $14
.bytes $16, $19
.bytes $1B, $1D
.bytes $20, $22
.bytes $24, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $02
.bytes $05, $07
.bytes $0A, $0C
.bytes $0E, $11
.bytes $13, $15
.bytes $18, $1A
.bytes $1C, $1F
.bytes $21, $24
.bytes $26, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $02
.bytes $05, $08
.bytes $0A, $0C
.bytes $0F, $12
.bytes $14, $16
.bytes $19, $1C
.bytes $1E, $20
.bytes $23, $26
.bytes $28, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $03
.bytes $05, $08
.bytes $0A, $0D
.bytes $10, $12
.bytes $15, $18
.bytes $1A, $1D
.bytes $20, $22
.bytes $25, $27
.bytes $2A, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $03
.bytes $06, $08
.bytes $0B, $0E
.bytes $10, $13
.bytes $16, $19
.bytes $1C, $1E
.bytes $21, $24
.bytes $26, $29
.bytes $2C, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $03
.bytes $06, $09
.bytes $0C, $0E
.bytes $11, $14
.bytes $17, $1A
.bytes $1D, $20
.bytes $22, $25
.bytes $28, $2B
.bytes $2E, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $03
.bytes $06, $09
.bytes $0C, $0F
.bytes $12, $15
.bytes $18, $1B
.bytes $1E, $21
.bytes $24, $27
.bytes $2A, $2D
.bytes $30, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $03
.bytes $06, $09
.bytes $0C, $10
.bytes $13, $16
.bytes $19, $1C
.bytes $1F, $22
.bytes $26, $29
.bytes $2C, $2F
.bytes $32, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $03
.bytes $06, $0A
.bytes $0D, $10
.bytes $14, $17
.bytes $1A, $1D
.bytes $20, $24
.bytes $27, $2A
.bytes $2E, $31
.bytes $34, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00
.bytes $00, $00

; The imp picture: where each column's runs start
.org $5900
.bytes $00, $01
.bytes $02, $06
.bytes $0D, $1A
.bytes $27, $37
.bytes $47, $57
.bytes $67, $74
.bytes $81, $88
.bytes $8C, $8D

; ... its runs: count, then top, bottom, color for each
.org $5910
.bytes $00, $00
.bytes $01, $08
.bytes $09, $08
.bytes $02, $02
.bytes $04, $05
.bytes $08, $0A
.bytes $08, $04
.bytes $03, $05
.bytes $05, $09
.bytes $0B, $08
.bytes $0E, $0F
.bytes $08, $0F
.bytes $10, $05
.bytes $04, $04
.bytes $07, $08
.bytes $09, $0C
.bytes $0E, $0C
.bytes $0F, $08
.bytes $0F, $10
.bytes $05, $05
.bytes $03, $05
.bytes $08, $05
.bytes $06, $0A
.bytes $06, $09
.bytes $08, $09
.bytes $0C, $0E
.bytes $0C, $0F
.bytes $08, $05
.bytes $03, $07
.bytes $08, $07
.bytes $08, $00
.bytes $08, $09
.bytes $08, $09
.bytes $0C, $0E
.bytes $0C, $0D
.bytes $08, $05
.bytes $03, $07
.bytes $08, $07
.bytes $08, $00
.bytes $08, $09
.bytes $08, $09
.bytes $0C, $0E
.bytes $0C, $0D
.bytes $08, $05
.bytes $03, $05
.bytes $08, $05
.bytes $06, $0A
.bytes $06, $09
.bytes $08, $09
.bytes $0C, $0E
.bytes $0C, $0F
.bytes $08, $04
.bytes $04, $07
.bytes $08, $09
.bytes $0C, $0E
.bytes $0C, $0F
.bytes $08, $0F
.bytes $10, $05
.bytes $04, $03
.bytes $05, $05
.bytes $09, $0B
.bytes $08, $0E
.bytes $0F, $08
.bytes $0F, $10
.bytes $05, $02
.bytes $02, $04
.bytes $05, $08
.bytes $0A, $08
.bytes $01, $08
.bytes $09, $08
.bytes $00, $00

; The fireball picture: where each column's runs start
.org $5A00
.bytes $00, $01
.bytes $02, $06
.bytes $10, $1A
.bytes $2A, $3A
.bytes $4A, $5A
.bytes $6A, $7A
.bytes $84, $8E
.bytes $92, $93

; ... its runs: count, then top, bottom, color for each
.org $5A10
.bytes $00, $00
.bytes $01, $07
.bytes $09, $09
.bytes $03, $05
.bytes $07, $09
.bytes $07, $09
.bytes $0A, $09
.bytes $0B, $09
.bytes $03, $04
.bytes $05, $09
.bytes $05, $0B
.bytes $0A, $0B
.bytes $0C, $09
.bytes $05, $04
.bytes $05, $09
.bytes $05, $07
.bytes $0A, $07
.bytes $09, $0F
.bytes $09, $0B
.bytes $0A, $0B
.bytes $0C, $09
.bytes $05, $03
.bytes $04, $09
.bytes $04, $06
.bytes $0A, $06
.bytes $0A, $0F
.bytes $0A, $0C
.bytes $0A, $0C
.bytes $0D, $09
.bytes $05, $03
.bytes $04, $09
.bytes $04, $05
.bytes $0A, $05
.bytes $0B, $0F
.bytes $0B, $0C
.bytes $0A, $0C
.bytes $0D, $09
.bytes $05, $03
.bytes $04, $09
.bytes $04, $05
.bytes $0A, $05
.bytes $0B, $0F
.bytes $0B, $0C
.bytes $0A, $0C
.bytes $0D, $09
.bytes $05, $03
.bytes $04, $09
.bytes $04, $06
.bytes $0A, $06
.bytes $0A, $0F
.bytes $0A, $0C
.bytes $0A, $0C
.bytes $0D, $09
.bytes $05, $04
.bytes $05, $09
.bytes $05, $07
.bytes $0A, $07
.bytes $09, $0F
.bytes $09, $0B
.bytes $0A, $0B
.bytes $0C, $09
.bytes $03, $04
.bytes $05, $09
.bytes $05, $0B
.bytes $0A, $0B
.bytes $0C, $09
.bytes $03, $05
.bytes $07, $09
.bytes $07, $09
.bytes $0A, $09
.bytes $0B, $09
.bytes $01, $07
.bytes $09, $09
.bytes $00, $00

; Picture columns per screen column (8.8) by half size, low bytes
.org $5B00
.bytes $00, $00
.bytes $00, $AB
.bytes $00, $9A
.bytes $55, $25
.bytes $00, $E4
.bytes $CD, $BA
.bytes $AB, $9E
.bytes $92, $89
.bytes $80, $78
.bytes $72, $6C
.bytes $66, $62
.bytes $5D, $59
.bytes $55, $52
.bytes $4F, $00

; ... high bytes
.org $5B20
.bytes $00, $08
.bytes $04, $02
.bytes $02, $01
.bytes $01, $01
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

; Nibble painter entry for each row, low bytes
.org $5B40
.bytes $00, $0C
.bytes $18, $24
.bytes $30, $3C
.bytes $48, $54
.bytes $60, $6C
.bytes $78, $84
.bytes $90, $9C
.bytes $A8, $B4
.bytes $C0, $CC
.bytes $D8, $E4
.bytes $F0, $FC
.bytes $08, $14
.bytes $20, $2C
.bytes $38, $44
.bytes $50, $5C
.bytes $68, $74
.bytes $80, $8C
.bytes $98, $A4
.bytes $B0, $BC
.bytes $C8, $D4
.bytes $E0, $EC
.bytes $F8, $04
.bytes $10, $1C
.bytes $28, $34
.bytes $40, $4C
.bytes $58, $64
.bytes $70, $00

; ... high bytes
.org $5B80
.bytes $50, $50
.bytes $50, $50
.bytes $50, $50
.bytes $50, $50
.bytes $50, $50
.bytes $50, $50
.bytes $50, $50
.bytes $50, $50
.bytes $50, $50
.bytes $50, $50
.bytes $50, $50
.bytes $51, $51
.bytes $51, $51
.bytes $51, $51
.bytes $51, $51
.bytes $51, $51
.bytes $51, $51
.bytes $51, $51
.bytes $51, $51
.bytes $51, $51
.bytes $51, $51
.bytes $51, $52
.bytes $52, $52
.bytes $52, $52
.bytes $52, $52
.bytes $52, $52
.bytes $52, $00

; Fireball step along x per tick, by direction (256 to a turn)
.org $5C00
.bytes $08, $08
.bytes $08, $08
.bytes $08, $08
.bytes $08, $08
.bytes $08, $08
.bytes $08, $08
.bytes $08, $08
.bytes $08, $07
.bytes $07, $07
.bytes $07, $07
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
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $02, $02
.bytes $02, $02
.bytes $02, $01
.bytes $01, $01
.bytes $01, $01
.bytes $00, $00
.bytes $00, $00
.bytes $00, $FF
.bytes $FF, $FF
.bytes $FF, $FF
.bytes $FE, $FE
.bytes $FE, $FE
.bytes $FE, $FD
.bytes $FD, $FD
.bytes $FD, $FD
.bytes $FD, $FC
.bytes $FC, $FC
.bytes $FC, $FC
.bytes $FC, $FB
.bytes $FB, $FB
.bytes $FB, $FB
.bytes $FB, $FA
.bytes $FA, $FA
.bytes $FA, $FA
.bytes $FA, $FA
.bytes $FA, $F9
.bytes $F9, $F9
.bytes $F9, $F9
.bytes $F9, $F9
.bytes $F9, $F9
.bytes $F9, $F9
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F9
.bytes $F9, $F9
.bytes $F9, $F9
.bytes $F9, $F9
.bytes $F9, $F9
.bytes $F9, $F9
.bytes $FA, $FA
.bytes $FA, $FA
.bytes $FA, $FA
.bytes $FA, $FA
.bytes $FB, $FB
.bytes $FB, $FB
.bytes $FB, $FB
.bytes $FC, $FC
.bytes $FC, $FC
.bytes $FC, $FC
.bytes $FD, $FD
.bytes $FD, $FD
.bytes $FD, $FD
.bytes $FE, $FE
.bytes $FE, $FE
.bytes $FE, $FF
.bytes $FF, $FF
.bytes $FF, $FF
.bytes $00, $00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $01
.bytes $01, $01
.bytes $02, $02
.bytes $02, $02
.bytes $02, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $07
.bytes $07, $07
.bytes $07, $07
.bytes $07, $07
.bytes $07, $07
.bytes $07, $07
.bytes $08, $08
.bytes $08, $08
.bytes $08, $08
.bytes $08, $08
.bytes $08, $08
.bytes $08, $08
.bytes $08, $08

; ... along y
.org $5D00
.bytes $00, $00
.bytes $00, $01
.bytes $01, $01
.bytes $01, $01
.bytes $02, $02
.bytes $02, $02
.bytes $02, $03
.bytes $03, $03
.bytes $03, $03
.bytes $03, $04
.bytes $04, $04
.bytes $04, $04
.bytes $04, $05
.bytes $05, $05
.bytes $05, $05
.bytes $05, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $06
.bytes $06, $07
.bytes $07, $07
.bytes $07, $07
.bytes $07, $07
.bytes $07, $07
.bytes $07, $07
.bytes $08, $08
.bytes $08, $08
.bytes $08, $08
.bytes $08, $08
.bytes $08, $08
.bytes $08, $08
.bytes $08, $08
.bytes $08, $08
.bytes $08, $08
.bytes $08, $08
.bytes $08, $08
.bytes $08, $08
.bytes $08, $08
.bytes $08, $08
.bytes $08, $07
.bytes $07, $07
.bytes $07, $07
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
.bytes $04, $04
.bytes $04, $04
.bytes $04, $04
.bytes $03, $03
.bytes $03, $03
.bytes $03, $03
.bytes $02, $02
.bytes $02, $02
.bytes $02, $01
.bytes $01, $01
.bytes $01, $01
.bytes $00, $00
.bytes $00, $00
.bytes $00, $FF
.bytes $FF, $FF
.bytes $FF, $FF
.bytes $FE, $FE
.bytes $FE, $FE
.bytes $FE, $FD
.bytes $FD, $FD
.bytes $FD, $FD
.bytes $FD, $FC
.bytes $FC, $FC
.bytes $FC, $FC
.bytes $FC, $FB
.bytes $FB, $FB
.bytes $FB, $FB
.bytes $FB, $FA
.bytes $FA, $FA
.bytes $FA, $FA
.bytes $FA, $FA
.bytes $FA, $F9
.bytes $F9, $F9
.bytes $F9, $F9
.bytes $F9, $F9
.bytes $F9, $F9
.bytes $F9, $F9
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F8
.bytes $F8, $F9
.bytes $F9, $F9
.bytes $F9, $F9
.bytes $F9, $F9
.bytes $F9, $F9
.bytes $F9, $F9
.bytes $FA, $FA
.bytes $FA, $FA
.bytes $FA, $FA
.bytes $FA, $FA
.bytes $FB, $FB
.bytes $FB, $FB
.bytes $FB, $FB
.bytes $FC, $FC
.bytes $FC, $FC
.bytes $FC, $FC
.bytes $FD, $FD
.bytes $FD, $FD
.bytes $FD, $FD
.bytes $FE, $FE
.bytes $FE, $FE
.bytes $FE, $FF
.bytes $FF, $FF
.bytes $FF, $FF
.bytes $00, $00

.org $6000
; ============================================================================
; Imps and their fireballs, drawn as sprites at full (subpixel) detail
; ============================================================================
; imp_list: note the level's things (imps, the arch-imp, health pickups; up
; to 12) at $5E00, give each a shooting timer, and clear the air of fireballs
imp_list:
  lda #$00
  sta $64
  sta $65
  sta $97
  sta $A0
  sta $A1
  sta $A2
  sta $A6
  sta $A7
il_loop:
  ldi $64
  lda $3800,i
  cmp #$04
  jeq il_imp
  cmp #$06
  jeq il_boss
  cmp #$07
  jne il_next
  lda #$02              ; a health pickup
  jmp il_add
il_boss:
  lda #$01              ; the arch-imp: the exit stays shut until it dies
  sta $A2
  lda #$0A
  sta $A5
  lda #$01
  jmp il_add
il_imp:
  lda #$00
il_add:
  ldi $65
  sta $5E70,i           ; what it is
  lda $64
  sta $5E00,i           ; its cell
  lda $65               ; first shot 1 to 3 seconds after it sees you, staggered
  asl a
  asl a
  asl a
  asl a
  clc
  adc #$3C
  sta $5E10,i
  lda #$00
  sta $5E20,i           ; can't see you yet
  inc $65
il_next:
  inc $64
  jne il_loop
  lda #$00              ; no fireballs in the air
  sta $5E50
  sta $5E51
  sta $5E52
  sta $5E53
  ret

; start_message: the level's opening message
start_message:
  lda $A2
  jne sm_boss
  lda #$58
  jsr show_message
  ret
sm_boss:
  lda #$00
  jsr show_message2
  ret

; show_message2: print string a of the second text table on text row 29
show_message2:
  sta $50
  lda #$11
  sta $0D09
  lda #$89
  sta $0D0A
print2:                 ; (print, for the text at $3B20)
  ldb #$00
p2_loop:
  ldi $50
  lda $3B20,i
  jeq p2_done
  tac
  tba
  tai
  tca
  jsr prstore
  inc b
  inc b
  inc $50
  jmp p2_loop
p2_done:
  ret

; boss_bar: once you've seen the arch-imp, its health on text row 29 (end of draw_hud)
boss_bar:
  lda $A1
  jeq bb_done
  lda #$4D
  sta $50
  lda #$11
  sta $0D09
  lda #$89
  sta $0D0A
  jsr print2
  ldb #$00              ; then a block for each hit it can still take
  ldi #$00
bb_loop:
  lda #$2D              ; "-" for hits it has taken
  sta $3A
  tba
  cmp $A5
  jcs bb_put
  lda #$23              ; "#" for hits left
  sta $3A
bb_put:
  lda #$18              ; red on navy
  sta $8924,i
  lda $3A
  sta $8925,i
  inc i
  inc i
  inc b
  tba
  cmp #$0A
  jne bb_loop
bb_blank:               ; and nothing after it
  lda #$20
  sta $8925,i
  inc i
  inc i
  tia
  cmp #$3C
  jne bb_blank
bb_done:
  ret

; pickup: walking onto the health pickup in map cell i: +$19 health, up to 100
pickup:
  tia
  sta $A4
  lda $36
  cmp #$64
  jcs pk_done           ; full health already: leave it for later
  clc
  adc #$19
  cmp #$65
  jcc pk_ok
  lda #$64
pk_ok:
  sta $36
  lda #$0A              ; the status bar flashes green
  sta $A7
  ldi $A4
  lda #$00
  sta $3800,i           ; it's used up
  ldi #$00
pk_find:                ; and off the list of things
  lda $5E00,i
  cmp $A4
  jne pk_next
  lda $5E70,i
  cmp #$02
  jne pk_next
  lda #$FF
  sta $5E00,i
pk_next:
  inc i
  tia
  cmp $65
  jne pk_find
pk_done:
  ret

; ============================================================================
; orb_tick: once per clock tick: imps that can see you count down and throw
; a fireball; fireballs fly on, burst on walls, or hit you
; ============================================================================
orb_tick:
  lda $A6               ; flash timers
  jeq ot_f1
  dec $A6
ot_f1:
  lda $A7
  jeq ot_f2
  dec $A7
ot_f2:
  lda #$00
  sta $64
ot_imps:
  lda $64
  cmp $65
  jeq ot_orbs
  ldi $64
  lda $5E00,i
  cmp #$FF
  jeq ot_imp_next       ; dead
  lda $5E70,i
  cmp #$02
  jeq ot_imp_next       ; a pickup
  lda $5E20,i
  jeq ot_imp_next       ; can't see you
  lda $5E10,i
  jeq ot_throw
  sec
  sbc #$01
  sta $5E10,i
  jmp ot_imp_next
ot_throw:
  lda $5E70,i
  jne ot_boss
  jsr spawn_orb
  ldi $64
  lda $9001             ; the next one in 1.5 to 2.5 seconds
  and #$3F
  clc
  adc #$5A
  sta $5E10,i
  jmp ot_imp_next
ot_boss:
  lda #$F8              ; the arch-imp throws three at once, fanned out
  sta $A0
  jsr spawn_orb
  lda #$00
  sta $A0
  jsr spawn_orb
  lda #$08
  sta $A0
  jsr spawn_orb
  lda #$00
  sta $A0
  ldi $64
  lda $9001             ; and again in 1 to 1.5 seconds
  and #$1F
  clc
  adc #$3C
  sta $5E10,i
ot_imp_next:
  inc $64
  jmp ot_imps
ot_orbs:
  lda #$00
  sta $96
ot_orb:
  ldi $96
  lda $5E50,i
  jeq ot_orb_next
  jsr move_orb
  lda $39
  jne ot_done           ; it killed you
ot_orb_next:
  inc $96
  lda $96
  cmp #$04
  jne ot_orb
ot_done:
  ret

; spawn_orb: imp $0064 throws a fireball at where you are now (up to 4 at once)
spawn_orb:
  ldi #$00
so_find:
  lda $5E50,i
  jeq so_free
  inc i
  tia
  cmp #$04
  jne so_find
  ret                   ; four already in the air
so_free:
  tia
  sta $96
  lda #$01
  sta $5E50,i
  ldi $64               ; it starts in the middle of the imp's cell
  lda $5E00,i
  sta $6A
  ldi $96
  and #$0F
  sta $5E58,i           ; x: cell column, half a cell in
  lda #$80
  sta $5E54,i
  sta $5E5C,i
  lda $6A
  lsr a
  lsr a
  lsr a
  lsr a
  sta $5E60,i           ; y: cell row, half a cell in
  ldi $64               ; aimed back along the line you see it on:
  lda $5E30,i           ; (your angle to it + 256) / 2, 256 to a turn
  sta $3A
  lda $5E40,i
  xor #$01
  lsr a
  lda $3A
  ror a
  clc                   ; turned by $00A0 (the arch-imp's fan)
  adc $A0
  sta $3B
  ldi $3B
  lda $5C00,i           ; its step per tick
  sta $3A
  lda $5D00,i
  ldi $96
  sta $5E68,i
  lda $3A
  sta $5E64,i
  ret

; move_orb: fireball $0096 moves one tick
move_orb:
  ldi $96
  lda $5E64,i           ; x += step (signed)
  sta $3A
  ldb #$00
  and #$80
  jeq mo_x
  ldb #$FF
mo_x:
  clc
  lda $5E54,i
  adc $3A
  sta $5E54,i
  lda $5E58,i
  adc b
  sta $5E58,i
  lda $5E68,i           ; y += step
  sta $3A
  ldb #$00
  and #$80
  jeq mo_y
  ldb #$FF
mo_y:
  clc
  lda $5E5C,i
  adc $3A
  sta $5E5C,i
  lda $5E60,i
  adc b
  sta $5E60,i
  lda $5E60,i           ; into a wall? (imps don't stop it)
  asl a
  asl a
  asl a
  asl a
  ora $5E58,i
  sta $3B
  ldi $3B
  lda $3800,i
  ldi $96
  cmp #$00
  jeq mo_near
  cmp #$04
  jeq mo_near
  cmp #$06
  jeq mo_near
  cmp #$07
  jeq mo_near
  lda #$00              ; it bursts on the wall
  sta $5E50,i
  ret
mo_near:                ; within a quarter cell of you, across and down?
  sec
  lda $5E54,i
  sbc $11
  sta $3A
  lda $5E58,i
  sbc $12
  cmp #$00
  jeq mo_xr
  cmp #$FF
  jne mo_miss
  lda $3A
  cmp #$C1
  jcc mo_miss
  jmp mo_yc
mo_xr:
  lda $3A
  cmp #$40
  jcs mo_miss
mo_yc:
  sec
  lda $5E5C,i
  sbc $13
  sta $3A
  lda $5E60,i
  sbc $14
  cmp #$00
  jeq mo_yr
  cmp #$FF
  jne mo_miss
  lda $3A
  cmp #$C1
  jcc mo_miss
  jmp mo_hit
mo_yr:
  lda $3A
  cmp #$40
  jcs mo_miss
mo_hit:
  lda #$00              ; it hits you: gone, and 10 health
  sta $5E50,i
  lda #$0A              ; the status bar flashes red
  sta $3C
  lda $36
  cmp #$0B
  jcc mo_dead
  sec
  sbc #$0A
  sta $36
  ret
mo_dead:
  lda #$00
  sta $36
  lda #$01
  sta $39
mo_miss:
  ret

; ============================================================================
; draw_sprites: place every imp and fireball, then draw them farthest first.
; An imp drawn in at least one column can see you (and will shoot).
; Sprite records (up to 16): $5E80 centre column, $5E90 half size, $5EA0 top
; row, $5EB0 distance/2, $5EC0 picture (0 imp, 1 fireball, 2 arch-imp,
; 3 health pickup), $5ED0 1 to draw, 2 drawn, $5EE0 which thing ($FF for a fireball)
; ============================================================================
draw_sprites:
  lda #$00
  sta $97
  sta $64
dsp_imps:
  lda $64
  cmp $65
  jeq dsp_orbs
  ldi $64
  lda #$00
  sta $5E20,i           ; can't see you unless it gets drawn
  lda $5E00,i
  cmp #$FF
  jeq dsp_imp_next
  sta $6A               ; it stands in the middle of its cell
  and #$0F
  sta $93
  lda $6A
  lsr a
  lsr a
  lsr a
  lsr a
  sta $95
  lda #$80
  sta $92
  sta $94
  jsr project_obj
  lda $9A
  jeq dsp_imp_next
  ldi $64               ; the angle you see it at, for aiming its fireballs
  lda $9B
  sta $5E30,i
  lda $9C
  sta $5E40,i
  lda $5E70,i
  sta $A4
  ldi $97
  lda $61
  sta $5E80,i
  lda $A4
  cmp #$01
  jeq dsp_boss
  cmp #$02
  jeq dsp_kit
  lda $5F               ; an imp: as tall as a wall
  sta $5E90,i
  lda #$1A              ; from the ceiling line down to the floor
  sec
  sbc $5F
  sta $5EA0,i
  lda #$00
  jmp dsp_rec
dsp_boss:
  lda $5F               ; the arch-imp: half again as big, but no taller than the view
  lsr a
  clc
  adc $5F
  sta $3A
  lda $5F
  clc
  adc #$1A
  lsr a
  cmp $3A
  jcc dsp_bset
  lda $3A
dsp_bset:
  sta $5E90,i
  jsr floor_top
  lda #$02
  jmp dsp_rec
dsp_kit:
  lda $5F               ; a pickup: half the size, on the floor
  lsr a
  jne dsp_kset
  lda #$01
dsp_kset:
  sta $5E90,i
  jsr floor_top
  lda #$03
dsp_rec:
  sta $5EC0,i
  lda $7D
  lsr a
  sta $5EB0,i
  lda #$01
  sta $5ED0,i
  lda $64
  sta $5EE0,i
  inc $97
dsp_imp_next:
  inc $64
  jmp dsp_imps
dsp_orbs:
  lda #$00
  sta $96
dsp_orb:
  ldi $96
  lda $5E50,i
  jeq dsp_orb_next
  lda $5E54,i
  sta $92
  lda $5E58,i
  sta $93
  lda $5E5C,i
  sta $94
  lda $5E60,i
  sta $95
  jsr project_obj
  lda $9A
  jeq dsp_orb_next
  ldi $97
  lda $61
  sta $5E80,i
  lda $5F               ; half the size of a wall there, at least 1
  lsr a
  jne dsp_size
  lda #$01
dsp_size:
  sta $5E90,i
  sta $3A
  lda $5F               ; centred at an imp's chest height
  lsr a
  lsr a
  lsr a
  clc
  adc #$1A
  sec
  sbc $3A
  sta $5EA0,i
  lda $7D
  lsr a
  sta $5EB0,i
  lda #$01
  sta $5EC0,i
  sta $5ED0,i
  lda #$FF
  sta $5EE0,i
  inc $97
dsp_orb_next:
  inc $96
  lda $96
  cmp #$04
  jne dsp_orb
dsp_pick:
  lda #$00              ; the farthest one not yet drawn
  sta $68
  lda #$FF
  sta $69
  lda #$00
  sta $67
dsp_scan:
  lda $67
  cmp $97
  jeq dsp_scanned
  ldi $67
  lda $5ED0,i
  cmp #$01
  jne dsp_scan_next
  lda $5EB0,i
  cmp $68
  jcc dsp_scan_next
  sta $68
  lda $67
  sta $69
dsp_scan_next:
  inc $67
  jmp dsp_scan
dsp_scanned:
  lda $69
  cmp #$FF
  jeq dsp_done
  tai
  lda #$02
  sta $5ED0,i
  lda $69
  sta $67
  jsr draw_sprite
  jmp dsp_pick
dsp_done:
  ret

; floor_top: top row for sprite record i of half size a standing on the floor:
; 26 + wall half height - 2a
floor_top:
  asl a
  sta $3A
  lda $5F
  clc
  adc #$1A
  sec
  sbc $3A
  sta $5EA0,i
  ret

; project_obj: where the point $0092-$0095 (x low, x high, y low, y high) is on
; screen: $009A = 1 if it can be shown, $0061 centre column (0-79, can be
; off screen), $005F wall half height there, $007D distance (1/16 cell),
; $009B/$009C your angle to it (512 to a turn)
project_obj:
  lda #$00
  sta $9A
  sec                   ; dx, dy from you (1/256 cell)
  lda $92
  sbc $11
  sta $6B
  lda $93
  sbc $12
  sta $6C
  sec
  lda $94
  sbc $13
  sta $6D
  lda $95
  sbc $14
  sta $6E
  lda #$00              ; |dx|, sign in $72
  sta $72
  lda $6C
  and #$80
  jeq pr_xp
  lda #$01
  sta $72
  sec
  lda #$00
  sbc $6B
  sta $6B
  lda #$00
  sbc $6C
  sta $6C
pr_xp:
  lda #$00              ; |dy|, sign in $73
  sta $73
  lda $6E
  and #$80
  jeq pr_yp
  lda #$01
  sta $73
  sec
  lda #$00
  sbc $6D
  sta $6D
  lda #$00
  sbc $6E
  sta $6E
pr_yp:
  lda $6C               ; 8 or more cells away: not drawn
  cmp #$08
  jcs pr_out
  lda $6E
  cmp #$08
  jcs pr_out
  lda $6B               ; both in 1/16 cell
  lsr a
  lsr a
  lsr a
  lsr a
  sta $74
  lda $6C
  asl a
  asl a
  asl a
  asl a
  ora $74
  sta $74
  lda $6D
  lsr a
  lsr a
  lsr a
  lsr a
  sta $75
  lda $6E
  asl a
  asl a
  asl a
  asl a
  ora $75
  sta $75
  lda $74               ; the bigger and smaller of the two
  cmp $75
  jcc pr_steep
  sta $76
  lda $75
  sta $77
  lda #$00
  sta $78
  jmp pr_ratio
pr_steep:
  lda $75
  sta $76
  lda $74
  sta $77
  lda #$01
  sta $78
pr_ratio:
  lda $76
  cmp #$04
  jcc pr_out            ; closer than a quarter cell
  jsr div8              ; slope = small * 256 / big
  ldi $79
  lda $5300,i           ; its angle (512 to a turn, up to an eighth of a turn)
  sta $7B
  lda $5400,i           ; distance = big * secant / 128
  sta $7C
  lda $76
  sta $40
  lda #$00
  sta $41
  lda $7C
  jsr mul
  asl $42
  rol $43
  lda $43
  sta $7D
  lda $78               ; the angle all the way round
  jeq pr_a1
  lda #$80
  sec
  sbc $7B
  sta $7B
pr_a1:
  lda $7B
  sta $7E
  lda #$00
  sta $7F
  lda $72
  jeq pr_a2
  sec                   ; x negative: 256 - angle
  lda #$00
  sbc $7E
  sta $7E
  lda #$01
  sbc $7F
  sta $7F
pr_a2:
  lda $73
  jeq pr_a3
  sec                   ; y negative: 512 - angle
  lda #$00
  sbc $7E
  sta $7E
  lda #$02
  sbc $7F
  and #$01
  sta $7F
pr_a3:
  lda $7E               ; keep it for aiming fireballs
  sta $9B
  lda $7F
  sta $9C
  lda $10               ; relative to the view: angle - player angle * 2
  asl a
  sta $3A
  lda #$00
  rol a
  sta $3B
  sec
  lda $7E
  sbc $3A
  sta $7E
  lda $7F
  sbc $3B
  and #$01
  jne pr_left
  lda $7E               ; right of the middle (or on it)
  cmp #$3D
  jcs pr_out            ; too far round to be seen
  sta $60
  clc
  adc #$28
  sta $61
  jmp pr_size
pr_left:
  lda $7E               ; left of the middle
  cmp #$C4
  jcc pr_out
  lda #$00
  sec
  sbc $7E
  sta $60
  lda #$28
  sec
  sbc $60
  sta $61
pr_size:
  lda $60               ; its size, from the wall height table for that column
  lsr a                 ; (tables go by whole angle steps)
  cmp #$15
  jcc pr_off
  lda #$14
pr_off:
  clc
  adc #$20
  sta $0D06
  lda $7D
  lsr a
  tai
  jsr hlook
  sta $5F
  cmp #$03
  jcc pr_out            ; too small to bother
  lda #$01
  sta $9A
pr_out:
  ret

; div8: $0079 = $0077 * 256 / $0076, for $0077 <= $0076 (255 if equal)
div8:
  lda $77
  cmp $76
  jcc dv_go
  lda #$FF
  sta $79
  ret
dv_go:
  sta $7A
  lda #$00
  sta $79
  ldb #$08
dv_loop:
  asl $79
  asl $7A
  jcs dv_sub
  lda $7A
  cmp $76
  jcc dv_next
dv_sub:
  lda $7A
  sec
  sbc $76
  sta $7A
  inc $79
dv_next:
  dec b
  jne dv_loop
  ret

; draw_sprite: draw sprite record $0067: 2 * half size subpixels wide and
; tall, its picture scaled to fit, in columns where it's nearer than the wall
draw_sprite:
  ldi $67
  lda $5E90,i
  sta $80
  lda $5EB0,i
  sta $81
  lda $5EA0,i
  sta $83
  lda $5E80,i           ; leftmost column
  sec
  sbc $80
  sta $82
  lda $5EC0,i           ; its picture's page, from the table at $3A0C
  tai
  lda $3A0C,i
  cmp #$35
  jne ds_page
  lda $A6               ; the arch-imp, just hit: the flashing picture
  jeq ds_boss
  lda #$37
  jmp ds_page
ds_boss:
  lda #$35
ds_page:
  sta $0D1A
  sta $0D1E
  lda #$00
  sta $9E
  lda $80               ; this size's row of the scale table
  lsr a
  lsr a
  lsr a
  clc
  adc #$55
  sta $0D16
  lda $80
  and #$07
  asl a
  asl a
  asl a
  asl a
  asl a
  sta $84
  ldi $80               ; picture columns per screen column
  lda $5B00,i
  sta $85
  lda $5B20,i
  sta $86
  lda $86               ; start half a step in
  lsr a
  sta $88
  lda $85
  ror a
  sta $87
  lda $80
  asl a
  sta $89
  lda $82
  sta $8A
ds_col:
  lda $8A               ; on screen?
  cmp #$50
  jcs ds_next
  lsr a                 ; in front of the wall in this block column?
  tai
  lda $3C80,i
  cmp $81
  jcc ds_next
  jeq ds_next
  lda #$00              ; an even column whose neighbour shows the same picture
  sta $9D               ; column: paint both halves of the byte at once
  lda $8A
  and #$01
  jne ds_one
  lda $89
  cmp #$02
  jcc ds_one
  clc
  lda $87
  adc $85
  lda $88
  adc $86
  cmp $88
  jne ds_one
  inc $9D
ds_one:
  jsr sprite_column
  lda #$01
  sta $9E
  lda $9D
  jeq ds_next
  clc                   ; (and step past the neighbour)
  lda $87
  adc $85
  sta $87
  lda $88
  adc $86
  sta $88
  inc $8A
  dec $89
ds_next:
  clc
  lda $87
  adc $85
  sta $87
  lda $88
  adc $86
  sta $88
  inc $8A
  dec $89
  jne ds_col
  lda $9E               ; an imp that got drawn can see you
  jeq ds_done
  ldi $67
  lda $5EC0,i
  cmp #$02
  jne ds_imp
  sta $A1               ; the arch-imp: show its health from now on
  jmp ds_seen
ds_imp:
  cmp #$00
  jne ds_done
ds_seen:
  lda $5EE0,i
  tai
  lda #$01
  sta $5E20,i
ds_done:
  ret

; sprite_column: paint picture column $0088 in screen column $008A
sprite_column:
  lda $8A
  and #$FE
  sta $8B
  lda $8A
  and #$01
  sta $8C
  ldi $88
  jsr picidx
  sta $8D
  ldi $8D
  jsr picrun
  sta $8E
  inc $8D
sc_run:
  lda $8E
  jeq sc_done
  ldi $8D
  jsr picrun            ; top of the run, scaled to the screen
  clc
  adc $84
  tai
  jsr sclook
  clc
  adc $83
  sta $26
  inc $8D
  ldi $8D
  jsr picrun            ; bottom
  clc
  adc $84
  tai
  jsr sclook
  clc
  adc $83
  sta $27
  inc $8D
  ldi $8D
  jsr picrun            ; color
  sta $8F
  inc $8D
  lda $9D
  jne sc_both
  lda $8C
  jne sc_odd
  lda #$0F              ; even column: the upper nibble
  sta $5D
  lda $8F
  asl a
  asl a
  asl a
  asl a
  sta $5E
  jmp sc_paint
sc_odd:
  lda #$F0              ; odd column: the lower nibble
  sta $5D
  lda $8F
  sta $5E
  jmp sc_paint
sc_both:
  lda #$00              ; both columns: the whole byte
  sta $5D
  lda $8F
  asl a
  asl a
  asl a
  asl a
  ora $8F
  sta $5E
sc_paint:
  jsr rmw_seg
  dec $8E
  jmp sc_run
sc_done:
  ret

; rmw_seg: change rows $0026 to $0027-1 of block column offset $008B with the
; nibble painter (mask $005D, color $005E)
rmw_seg:
  lda $26
  cmp $27
  jcs rs_done
  ldi $26
  lda $5B40,i
  sta $0D11
  lda $5B80,i
  sta $0D12
  lda $27
  cmp #$34
  jeq rs_go
  ldi $27               ; stop early: ret over the first row not to paint
  lda $5B40,i
  sta $62
  lda $5B80,i
  sta $63
  lda #$A0
  sta ($62)
rs_go:
  ldi $8B
  jsr rmwtramp
  lda $27
  cmp #$34
  jeq rs_done
  lda #$35              ; put the lda back
  sta ($62)
rs_done:
  ret
