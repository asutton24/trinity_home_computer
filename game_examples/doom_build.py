"""
Builds Trinity DOOM for Project Trinity: writes doom.s and assembles it
into emulator/doom.bin, ready for  python main.py doom.bin

The game code is below as assembly text; this script adds the levels and the
lookup tables (the CPU has no multiply or divide, so all the trigonometry is
done here, ahead of time).

To make your own levels, edit LEVELS below and run:

    python doom_build.py

Levels are played in order: walking into an exit takes you to the next one
(keeping your health, plus 10 bullets); dying restarts the level you're on;
finishing the last level goes back to the first. The build checks every map
and tells you what's wrong if one can't be played.
"""
import math
import os
import sys

# ---------------------------------------------------------------- the levels
# Each map is 16 x 16 cells, x to the right, y down. The outside must be wall.
#   #  gray stone     G  green slime     T  purple tech
#   I  imp (shoot it; up to 9 per level)  E  exit (walk into it)
#   .  empty
#   Player start, one per map:  >  facing east   v  south   <  west   ^  north
#                               (P also means facing east)
# Names can be up to 10 characters; they show as "E1M1: NAME".
LEVELS = [
    ("MY LEVEL", [          # your map from MAP: rename it here
        "################",
        "#P.............#",
        "#..............#",
        "#..............#",
        "#..............#",
        "#..............#",
        "#..............#",
        "#..............#",
        "#..............#",
        "#..............#",
        "#..............#",
        "#..............#",
        "#..............#",
        "#..............#",
        "#..............E",
        "################",
    ]),
    ("HANGAR", [
        "################",
        "#P...#.........#",
        "#....#..TTTT...#",
        "#....G.....T.I.#",
        "#....G..I..T...#",
        "#..........T...#",
        "###.####.#######",
        "#..............#",
        "#.TTT....##..I.#",
        "#...T....##....#",
        "#.I.T..........#",
        "#...TTTT..GGGG.#",
        "#.........G..I.#",
        "#..I......G....#",
        "#.........G....E",
        "################",
    ]),
    ("TOXIN LAB", [
        "################",
        "#>.....G.......#",
        "#.GGG..G..GGGG.#",
        "#.G.I..G..G..I.#",
        "#.G....G..G....#",
        "#.GGGG.G..GG.GG#",
        "#..............#",
        "#GGGG.GGGGGG.GG#",
        "#..I.....I.....#",
        "#.TT.TTTT.TT.T.#",
        "#.T.........I..#",
        "#.T.TTTT.TTTT..#",
        "#.........T....#",
        "#.I.......T..I.#",
        "#.........T....E",
        "################",
    ]),
    ("COMMAND", [
        "################",
        "#v.....#.......#",
        "#......#..I....#",
        "#..TT..#.......#",
        "#..TT.....TTT..#",
        "#......#..T.T..#",
        "###.####..T.T..#",
        "#..I...#.......#",
        "#.......#.###.##",
        "#.GG.I..#.#I...#",
        "#.GG....#.#....#",
        "#.......#.###..#",
        "#..I.....I.....#",
        "#####.######.###",
        "#...........I..E",
        "################",
    ]),
]
CELL = {".": 0, "#": 1, "G": 2, "T": 3, "I": 4, "E": 5}
STARTS = {"P": 0, ">": 0, "v": 64, "<": 128, "^": 192}   # facing angle (256 to a turn)
AMMO = 20             # bullets at the start of a game, and after dying
MAX_LEVELS = 16

# Wall colors (both nibbles the same): lit side, shaded side, for each cell type
COLORS = [(0x00, 0x00),   # 0 empty
          (0x66, 0x55),   # 1 stone: light gray / dark gray
          (0xBB, 0x33),   # 2 slime: green / forest green
          (0xDD, 0x22),   # 3 tech: lavender / plum
          (0xEE, 0x88),   # 4 imp: pink / red
          (0xAA, 0x99)]   # 5 exit: yellow / orange
CEILING, FLOOR, FOG = 0x11, 0x44, 0x55

# ---------------------------------------------------------------- geometry
ANGLES = 256          # a full turn
COLUMNS = 40          # one ray per 8-pixel-wide column, one angle step apart
ROWS = 52             # subpixel rows in the graphics part of mixed mode
HALF = ROWS // 2
FOV_HALF = (COLUMNS // 2) * 2 * math.pi / ANGLES
# half wall height (in subpixel rows) at 1 cell: focal length 160 px / tan(FOV/2), / 4 px rows / 2
WALL_HALF_AT_1 = (160 / math.tan(FOV_HALF)) / 4 / 2
STEP_PER_TICK = 13    # 1/256 cell per clock tick (about 3 cells a second)
MAX_DELTA = 2047      # keeps n(<=32) * delta inside 16 bits


def angle(a):
    return a * 2 * math.pi / ANGLES


def delta16(c):
    """Ray length (1/16 cell) to cross one cell along an axis, capped."""
    return MAX_DELTA if abs(c) < 1e-9 else min(MAX_DELTA, round(16 / abs(c)))


def half_height(off, idx):
    """Half wall height for a ray `off` angle steps from the centre whose
    distance along the ray is about idx*2 sixteenths of a cell."""
    dist16 = idx * 2 + 1
    perp = dist16 / 16 * math.cos(angle(off))
    return min(HALF, round(WALL_HALF_AT_1 / perp))


def tables():
    dxl, dxh, dyl, dyh, mvx, mvy = ([] for _ in range(6))
    for a in range(ANGLES):
        c, s = math.cos(angle(a)), math.sin(angle(a))
        dx, dy = delta16(c), delta16(s)
        dxl.append(dx & 0xFF); dxh.append(dx >> 8)
        dyl.append(dy & 0xFF); dyh.append(dy >> 8)
        mvx.append(round(STEP_PER_TICK * c) & 0xFF)
        mvy.append(round(STEP_PER_TICK * s) & 0xFF)
    heights = [[half_height(off, idx) for idx in range(256)] for off in range(COLUMNS // 2 + 1)]
    return dxl, dxh, dyl, dyh, mvx, mvy, heights


class LevelError(ValueError):
    pass


def level_bytes(n):
    """Check level n and return (cells, (x, y, angle), imps)."""
    name, rows = LEVELS[n]
    where = f"level {n + 1} ({name})"
    if len(name) > 10:
        raise LevelError(f"{where}: the name can be at most 10 characters")
    if len(rows) != 16 or any(len(r) != 16 for r in rows):
        bad = [i + 1 for i, r in enumerate(rows) if len(r) != 16]
        raise LevelError(f"{where}: the map must be 16 rows of 16 characters"
                         + (f" (rows {bad} aren't)" if bad else f" (it has {len(rows)} rows)"))
    cells, starts, exits = [], [], []
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch in STARTS:
                starts.append((x, y, STARTS[ch]))
                ch = "."
            if ch not in CELL:
                raise LevelError(f"{where}: unknown character {ch!r} at column {x + 1}, row {y + 1}")
            if (x in (0, 15) or y in (0, 15)) and ch in ".I":
                raise LevelError(f"{where}: the edge must be wall, but column {x + 1}, row {y + 1} is open")
            if ch == "E":
                exits.append((x, y))
            cells.append(CELL[ch])
    if len(starts) != 1:
        raise LevelError(f"{where}: needs exactly one player start (P > v < ^), found {len(starts)}")
    imps = cells.count(4)
    if imps > 9:
        raise LevelError(f"{where}: at most 9 imps, found {imps}")
    if not exits:
        raise LevelError(f"{where}: needs an exit (E)")
    # can the start reach a cell next to an exit? (imps count as open: you can shoot them)
    sx, sy, _ = starts[0]
    seen, todo = {(sx, sy)}, [(sx, sy)]
    while todo:
        x, y = todo.pop()
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if (nx, ny) not in seen and cells[ny * 16 + nx] in (0, 4):
                seen.add((nx, ny))
                todo.append((nx, ny))
    if not any((ex + dx, ey + dy) in seen for ex, ey in exits for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
        raise LevelError(f"{where}: no exit can be reached from the start")
    return cells, starts[0], imps


def vram(col, row):
    """Address of the byte for subpixel row `row` in block column `col`."""
    return 0x8000 + (row >> 1) * 80 + col * 2 + (row & 1)


def text_addr(row, col):
    """Address of the character byte of text cell (row 26-29, col)."""
    return 0x8821 + (row - 26) * 80 + col * 2


def data_lines(values):
    values = list(values)
    if len(values) % 2:
        values.append(0)
    return [f".bytes ${values[i]:02X}, ${values[i + 1]:02X}" for i in range(0, len(values), 2)]


def build():
    dxl, dxh, dyl, dyh, mvx, mvy, heights = tables()
    if not 1 <= len(LEVELS) <= MAX_LEVELS:
        raise LevelError(f"there must be 1 to {MAX_LEVELS} levels")
    levels = [level_bytes(n) for n in range(len(LEVELS))]

    hud = f" HEALTH 100%   AMMO {AMMO:03d}   KILLS 0/0"
    strings = [("HUD", hud),
               ("TITLE", " TRINITY DOOM"),
               ("HELP", " ARROWS/WASD: MOVE  CTRL/SPACE: SHOOT"),
               ("START", " FIND THE YELLOW EXIT. WATCH FOR IMPS!"),
               ("DEAD", " YOU DIED! PRESS SPACE TO TRY AGAIN"),
               ("NEXT", " LEVEL COMPLETE! SPACE FOR THE NEXT ONE"),
               ("EPISODE", " YOU BEAT THEM ALL! SPACE TO PLAY AGAIN")]
    text, offs = [], {}
    for name, s in strings:
        assert len(s) <= 40
        offs[name] = len(text)
        text += list(s.encode()) + [0]
    assert len(text) <= 256 and 0x3A20 + len(text) <= 0x3C00, "text would overlap the ray data at $3C00"

    sub = {
        "AMMO": AMMO, "CEIL": CEILING, "FLOOR": FLOOR, "FOG": FOG, "LAST_LEVEL": len(LEVELS) - 1,
        "KILLS_TOTAL_ADDR": text_addr(26, hud.index("/") + 1),
        "NAME_LO": text_addr(27, 23) & 0xFF, "NAME_HI": text_addr(27, 23) >> 8,
        "HEALTH_LO": text_addr(26, hud.index("100")) & 0xFF,
        "HEALTH_HI": text_addr(26, hud.index("100")) >> 8,
        "AMMO_LO": text_addr(26, hud.index(f"{AMMO:03d}")) & 0xFF,
        "AMMO_HI": text_addr(26, hud.index(f"{AMMO:03d}")) >> 8,
        "KILLS_ADDR": text_addr(26, hud.index("KILLS ") + 6),
        "TYP20": 0x3C80 + 20, "MI20": 0x3CC0 + 20, "TYP19": 0x3C80 + 19, "MI19": 0x3CC0 + 19,
    }
    for name, off in offs.items():
        sub["S_" + name] = off

    # gun: (row, column, color byte) drawn over the view every frame
    gun = []
    for r in range(40, 44):
        gun += [(r, 19, 0x56), (r, 20, 0x65)]
    for r in range(44, 48):
        gun += [(r, 18, 0x55), (r, 19, 0x66), (r, 20, 0x66), (r, 21, 0x55)]
    for r in range(48, 52):
        gun += [(r, 18, 0x77), (r, 19, 0x55), (r, 20, 0x55), (r, 21, 0x77)]
    flash = [(r, c, 0xAA) for r in range(36, 40) for c in (19, 20)] + \
            [(r, c, 0x99) for r in (37, 38) for c in (18, 21)]

    def stores(items):
        lines, last = [], None
        for r, c, v in items:
            if v != last:
                lines.append(f"  lda #${v:02X}")
                last = v
            lines.append(f"  sta ${vram(c, r):04X}")
        return "\n".join(lines)

    code = CODE
    for k, v in sub.items():
        code = code.replace(f"@{k}@", f"${v:02X}" if v < 256 else f"${v:04X}")
    code = code.replace("@GUN_FLASH@", stores(flash)).replace("@GUN_BODY@", stores(gun))
    assert "@" not in code, code[code.index("@") - 40:code.index("@") + 40]

    out = [HEADER.format(levels=len(LEVELS), ammo=AMMO), code]

    out.append("\n; ============================================================================")
    out.append("; Column painter: one store per subpixel row, for column offset i (= column * 2).")
    out.append("; draw_all enters at row * 3 and stops it early by writing a ret ($A0) over")
    out.append("; the store for the first row it should not paint, then puts the store ($DD) back.")
    out.append("; ============================================================================")
    out.append(".org $0E00")
    out.append("col0:")
    for r in range(ROWS):
        out.append(f"  sta ${vram(0, r):04X},i    ; row {r}")
    out.append("  ret")

    def table(addr, title, values):
        out.append(f"\n; {title}\n.org ${addr:04X}")
        out.extend(data_lines(values))

    table(0x1000, "Ray length to cross one cell along x (1/16 cell), low bytes, by angle", dxl)
    table(0x1100, "... high bytes", dxh)
    table(0x1200, "Ray length to cross one cell along y, low bytes", dyl)
    table(0x1300, "... high bytes", dyh)
    table(0x1400, "Step along x per clock tick when walking (signed, 1/256 cell)", mvx)
    table(0x1500, "Step along y per clock tick when walking", mvy)
    for off, h in enumerate(heights):
        table(0x2000 + off * 0x100,
              f"Half wall height (subpixel rows) for rays {off} steps from the centre, by distance/2", h)
    table(0x3A00, "Wall colors: cell type * 2 + side (0 lit, 1 shaded)", [v for pair in COLORS for v in pair])
    table(0x3A10, "Map offsets of the 8 cells around the player", [0xEF, 0xF0, 0xF1, 0xFF, 0x01, 0x0F, 0x10, 0x11])
    names = "  ".join(f"${o:02X} {n}" for n, o in offs.items())
    table(0x3A20, f"Text, each string ending in 0: {names}", text)
    table(0x3E00, "Levels: start x, start y, start angle, number of imps",
          [v for cells, (x, y, a), imps in levels for v in (x, y, a, imps)])
    table(0x3F00, "Level names as shown on the status bar, 16 characters each",
          [b for n, (name, _) in enumerate(LEVELS) for b in f"E1M{n + 1}: {name}".rjust(16).encode()])
    for n, (cells, _, _) in enumerate(levels):
        table(0x4000 + n * 0x100, f"Level {n + 1}: {LEVELS[n][0]} (copied to $3800 when it starts)", cells)
    return "\n".join(out) + "\n"


HEADER = """; ============================================================================
; TRINITY DOOM  (made by game_examples/doom_build.py: edit the levels there)
;
; A DOOM-style raycaster for Project Trinity in video mode 2 (mixed). The top
; 26 rows show a first-person 3D view, 40 columns wide: one ray per column is
; traced through a 16 x 16 map and its wall drawn taller the closer it is.
; There are {levels} levels, played in order.
; The bottom 4 rows show health, ammo, kills and messages.
;
; Controls: up/down (or W/S) walk, left/right (or A/D) turn,
;           Ctrl (or SPACE when no arrow is held) shoots.
; Shoot the imps (pink/red blocks): standing next to one hurts. You start with
; {ammo} bullets. Walk into the yellow exit to go to the next level (you keep
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
"""

CODE = r"""
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
  lda #@AMMO@
  sta $37

  lda #@S_HUD@
  sta $50
  lda #$21              ; text row 26
  sta $51
  lda #$88
  sta $52
  jsr print
  lda #@S_TITLE@
  sta $50
  lda #$71              ; text row 27
  sta $51
  lda #$88
  sta $52
  jsr print
  lda #@S_HELP@
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
  lda #@S_DEAD@         ; died: this level again, with full health and ammo
  jsr show_message
  jsr wait_space
  lda #$64
  sta $36
  lda #@AMMO@
  sta $37
  jsr load_level
  jmp main_loop
es_exit:
  lda $3D
  cmp #@LAST_LEVEL@
  jeq es_episode
  lda #@S_NEXT@         ; on to the next level, keeping health, 10 more bullets
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
  lda #@S_EPISODE@      ; that was the last level: back to the first
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
  sta @KILLS_TOTAL_ADDR@
  lda #$80              ; the middle of the start cell
  sta $11
  sta $13
  lda #$00
  sta $38
  sta $39
  sta $32
  sta $35
  sta $3C
  sta @TYP19@           ; forget what the last level was aiming at
  sta @TYP20@
  lda #$10              ; treat fire as held, so the SPACE that started
  sta $31               ; this level doesn't also shoot
  lda $3D               ; its name: 16 characters at $3F00 + 16 * level,
  asl a                 ; on the right of text row 27
  asl a
  asl a
  asl a
  sta $50
  lda #@NAME_LO@
  sta $0D09
  lda #@NAME_HI@
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
  lda #@S_START@
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
  lda @TYP20@
  cmp #$04
  jne fi_19
  lda @MI20@
  jmp fi_kill
fi_19:
  lda @TYP19@
  cmp #$04
  jne fi_save
  lda @MI19@
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
  lda #@FOG@
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
  lda #@CEIL@
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
  lda #@FLOOR@
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
@GUN_FLASH@
dg_body:
@GUN_BODY@
  ret

; ============================================================================
; draw_hud: health, ammo and kills; the status bar flashes red when hurt
; ============================================================================
draw_hud:
  lda #@HEALTH_LO@
  sta $51
  lda #@HEALTH_HI@
  sta $52
  lda $36
  jsr print3
  lda #@AMMO_LO@
  sta $51
  lda #@AMMO_HI@
  sta $52
  lda $37
  jsr print3
  lda $38
  clc
  adc #$30
  sta @KILLS_ADDR@
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
"""


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    try:
        source = build()
    except LevelError as exc:
        sys.exit(f"Can't build: {exc}")
    with open(os.path.join(here, "doom.s"), "w", newline="\r\n") as f:
        f.write(source)
    sys.path.insert(0, root)
    from assembler.main import parse_code
    binary = bytes.fromhex(parse_code(source))
    with open(os.path.join(root, "emulator", "doom.bin"), "wb") as f:
        f.write(binary)
    print(f"Built {len(LEVELS)} level(s): wrote game_examples/doom.s and emulator/doom.bin ({len(binary)} bytes)")
    print("Play it:  cd emulator  then  python main.py doom.bin")
