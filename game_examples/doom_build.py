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

Imps are drawn as sprites (the IMP picture below) and throw fireballs (ORB)
at you when they can see you: step out of the way to dodge them.

Put an A in a map for the arch-imp, a boss that takes 10 shots and throws
three fireballs at once; the exit stays shut until it's dead. Put an H for a
health pickup (+25 health, up to 100).
"""
import math
import os
import sys

# ---------------------------------------------------------------- the levels
# Each map is 16 x 16 cells, x to the right, y down. The outside must be wall.
#   #  gray stone     G  green slime     T  purple tech
#   I  imp (shoot it)                     E  exit (walk into it)
#   A  arch-imp boss (one per level: takes 10 shots, and the exit stays shut
#      until it's dead)                  H  health pickup (+25, up to 3 per level)
#   .  empty
#   Imps and arch-imp together: up to 9 per level.
#   Player start, one per map:  >  facing east   v  south   <  west   ^  north
#                               (P also means facing east)
# Names can be up to 10 characters; they show as "E1M1: NAME".
LEVELS = [
    ("MY LEVEL", [          # your map from MAP: rename it here
        "################",
        "#P.............#",
        "#.......T......#",
        "#.......T..I...#",
        "#GGGGGGGGGGGG..#",
        "#.........H.G..#",
        "#.........H.G..#",
        "#.##########G..#",
        "#..............#",
        "#...I.....#....#",
        "#.........#.H..#",
        "#.........#....#",
        "#...I..........#",
        "#......#########",
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
    ("THE LAIR", [
        "################",
        "#^#.....H.....##",
        "#.#.TT.....TT..#",
        "#.#.T.......T..#",
        "#.#............#",
        "#.#.....A......#",
        "#.#............#",
        "#.#.T.......T..#",
        "#.#.TT..I..TT..#",
        "#.#............#",
        "#.#####..#####.#",
        "#H.......#.....#",
        "#.....G..G...I.#",
        "#..I..G..G.....#",
        "#.....G..G....HE",
        "################",
    ]),
]
CELL = {".": 0, "#": 1, "G": 2, "T": 3, "I": 4, "E": 5, "A": 6, "H": 7}
BOSS_HP = 10          # shots to kill the arch-imp
HEAL = 25             # health from a pickup
STARTS = {"P": 0, ">": 0, "v": 64, "<": 128, "^": 192}   # facing angle (256 to a turn)
AMMO = 20             # bullets at the start of a game, and after dying
MAX_LEVELS = 16

# ---------------------------------------------------------------- pictures
# 16 x 16, one character per subpixel: a palette color 0-F, or "." to see through.
# Each is scaled to its size on screen.
IMP = [
    "................",
    "................",
    "...5........5...",
    "...55.8888.55...",
    "....58888885....",
    ".....8A88A8.....",
    ".....888888.....",
    "......8008......",
    "..88..8888..88..",
    "...88EEEEEE88...",
    "....8EEEEEE8....",
    ".....EEEEEE.....",
    ".....888888.....",
    ".....88..88.....",
    "....888..888....",
    "....55....55....",
]
ARCH = [     # the arch-imp: drawn half again as big as an imp, standing on the floor
    "...A.A....A.A...",
    "..6AAAAAAAAAA6..",
    ".66..DDDDDD..66.",
    ".6..DDDDDDDD..6.",
    ".6..DA9DD9AD..6.",
    "....DDDDDDDD....",
    ".....DF88FD.....",
    "..DD..DDDD..DD..",
    ".DDD22222222DDD.",
    "DD.D22222222D.DD",
    "D..D22288222D..D",
    "9...22222222...9",
    "....22222222....",
    "....222..222....",
    "...DDD....DDD...",
    "...666....666...",
]
ARCH_HURT = [r.translate(str.maketrans("D2", "FE")) for r in ARCH]   # flashes when shot
MEDKIT = [   # a health pickup, lying on the floor
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "..666666666666..",
    "..FFFFF88FFFFF..",
    "..FFFFF88FFFFF..",
    "..FFF888888FFF..",
    "..FFF888888FFF..",
    "..FFFFF88FFFFF..",
    "..FFFFF88FFFFF..",
    "..666666666666..",
]
ORB = [      # an imp's fireball
    "................",
    "................",
    "................",
    "......9999......",
    "....99AAAA99....",
    "...9AAAFFAAA9...",
    "...9AAFFFFAA9...",
    "..9AAFFFFFFAA9..",
    "..9AAFFFFFFAA9..",
    "...9AAFFFFAA9...",
    "...9AAAFFAAA9...",
    "....99AAAA99....",
    "......9999......",
    "................",
    "................",
    "................",
]
ORB_SPEED = 8         # 1/256 cell per clock tick (about 1.5 cells a second)

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
    """Check level n and return (cells, (x, y, angle), imps + arch-imp)."""
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
            if (x in (0, 15) or y in (0, 15)) and ch in ".IAH":
                raise LevelError(f"{where}: the edge must be wall, but column {x + 1}, row {y + 1} is open")
            if ch == "E":
                exits.append((x, y))
            cells.append(CELL[ch])
    if len(starts) != 1:
        raise LevelError(f"{where}: needs exactly one player start (P > v < ^), found {len(starts)}")
    if cells.count(6) > 1:
        raise LevelError(f"{where}: only one arch-imp (A) per level, found {cells.count(6)}")
    imps = cells.count(4) + cells.count(6)
    if imps > 9:
        raise LevelError(f"{where}: at most 9 imps (counting the arch-imp), found {imps}")
    if cells.count(7) > 3:
        raise LevelError(f"{where}: at most 3 health pickups (H), found {cells.count(7)}")
    if not exits:
        raise LevelError(f"{where}: needs an exit (E)")
    # can the start reach a cell next to an exit? (imps count as open: you can shoot them)
    open_cells = (0, 4, 6, 7)
    sx, sy, _ = starts[0]
    seen, todo = {(sx, sy)}, [(sx, sy)]
    while todo:
        x, y = todo.pop()
        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if (nx, ny) not in seen and cells[ny * 16 + nx] in open_cells:
                seen.add((nx, ny))
                todo.append((nx, ny))
    if not any((ex + dx, ey + dy) in seen for ex, ey in exits for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
        raise LevelError(f"{where}: no exit can be reached from the start")
    return cells, starts[0], imps


def picture_runs(picture):
    """A picture as vertical runs of one color per column: an index of where
    each column's runs start, then for each column a count and (top, bottom, color)."""
    assert len(picture) == 16 and all(len(r) == 16 for r in picture)
    index, data = [], []
    for u in range(16):
        runs, v = [], 0
        while v < 16:
            ch = picture[v][u]
            if ch == ".":
                v += 1
                continue
            v0 = v
            while v < 16 and picture[v][u] == ch:
                v += 1
            runs.append((v0, v, int(ch, 16)))
        index.append(len(data))
        data.append(len(runs))
        for v0, v1, c in runs:
            data += [v0, v1, c]
    assert len(data) <= 240, "a picture has too many color runs"
    return index, data


def regular_code():
    """CODE with imps as sprites and their fireballs added."""
    code = CODE
    a = code.index("; ============================================================================\n; fire:")
    b = code.index("; ============================================================================\n; cast_all:", a)
    code = code[:a] + FIRE_SPRITES + code[b:]
    for old, new in (
            ("  jsr draw_all\n  jsr draw_gun\n", "  jsr draw_all\n  jsr draw_sprites\n  jsr draw_gun\n"),
            ("  jsr clear_message\n  lda #@S_START@\n  jsr show_message\n",
             "  jsr imp_list\n  jsr clear_message\n  jsr start_message\n"),
            ("up_5:\n", "up_5:\n  jsr orb_tick\n  lda $39\n  jne up_done\n"),
            ("  lda $3800,i\n  jeq dda\n  sta $23\n",
             "  lda $3800,i\n  jeq dda\n  cmp #$04              ; imps, the arch-imp and pickups are sprites:\n  jeq dda               ; rays go through them\n"
             "  cmp #$06\n  jeq dda\n  cmp #$07\n  jeq dda\n  sta $23\n"),
            # walking into a pickup takes it; the exit is shut while the arch-imp lives
            ("  lda $3800,i\n  jeq mx_ok\n  cmp #$05\n  jne mv_y\n",
             "  lda $3800,i\n  jeq mx_ok\n  cmp #$07\n  jne mx_solid\n  jsr pickup\n  jmp mx_ok\n"
             "mx_solid:\n  cmp #$05\n  jne mv_y\n  lda $A2\n  jne mv_y\n"),
            ("  lda $3800,i\n  jeq my_ok\n  cmp #$05\n  jne mv_done\n",
             "  lda $3800,i\n  jeq my_ok\n  cmp #$07\n  jne my_solid\n  jsr pickup\n  jmp my_ok\n"
             "my_solid:\n  cmp #$05\n  jne mv_done\n  lda $A2\n  jne mv_done\n"),
            # standing next to the arch-imp hurts twice as much
            ("  cmp #$04\n  jne ia_next\n  inc b\nia_next:\n",
             "  cmp #$06\n  jne ia_imp\n  inc b\n  inc b\n  jmp ia_next\nia_imp:\n  cmp #$04\n  jne ia_next\n  inc b\nia_next:\n"),
            # the status bar flashes green on a pickup; the arch-imp's health bar
            ("  ldb #$1F\n  lda $3C\n  jeq dh_color\n",
             "  ldb #$1F\n  lda $A7\n  jeq dh_red\n  ldb #$3F\ndh_red:\n  lda $3C\n  jeq dh_color\n"),
            ("  cmp #$50\n  jne dh_loop\n  ret\n", "  cmp #$50\n  jne dh_loop\n  jmp boss_bar\n"),
            ("cm_loop:\n  lda #$20\n  sta $8911,i\n", "cm_loop:\n  lda #$1F\n  sta $8910,i\n  lda #$20\n  sta $8911,i\n"),
            ("  lda $23\n  sta $3C80,i\n", "  lda $42               ; wall distance, for sprites and shooting\n  sta $3C80,i\n")):
        assert code.count(old) == 1, old
        code = code.replace(old, new)
    return code + """rmwtramp:               ; $0D10: call the nibble painter at the row whose address is in $0D11/$0D12
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
"""


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
               ("START", " FIND THE EXIT. DESTROY THEM ALL!"),
               ("DEAD", " YOU DIED! PRESS SPACE TO TRY AGAIN"),
               ("NEXT", " LEVEL COMPLETE! SPACE FOR THE NEXT ONE"),
               ("EPISODE", " YOU BEAT THEM ALL! SPACE TO PLAY AGAIN")]
    text, offs = [], {}
    for name, s in strings:
        assert len(s) <= 40
        offs[name] = len(text)
        text += list(s.encode()) + [0]
    assert len(text) <= 256, "too much text"
    # more text, for the arch-imp, printed by print2 from $3B20
    strings2 = [("BOSS", " KILL THE ARCH-IMP TO OPEN THE EXIT!"),
                ("OPEN", " THE ARCH-IMP IS DEAD! THE EXIT IS OPEN"),
                ("BAR", " ARCH-IMP ")]
    text2, offs2 = [], {}
    for name, s in strings2:
        assert len(s) <= 40
        offs2[name] = len(text2)
        text2 += list(s.encode()) + [0]
    assert 0x3B20 + len(text2) <= 0x3C00, "text would overlap the ray data at $3C00"

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
    for name, off in offs2.items():
        sub["S2_" + name] = off
    sub["BOSS_HP"] = BOSS_HP
    sub["HEAL"] = HEAL

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

    code = regular_code()
    sprites = SPRITES
    for k, v in sub.items():
        code = code.replace(f"@{k}@", f"${v:02X}" if v < 256 else f"${v:04X}")
        sprites = sprites.replace(f"@{k}@", f"${v:02X}" if v < 256 else f"${v:04X}")
    assert "@" not in sprites, sprites[sprites.index("@") - 40:sprites.index("@") + 40]
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
    pictures = ((0x3500, "arch-imp", ARCH), (0x3600, "health pickup", MEDKIT), (0x3700, "arch-imp when hit", ARCH_HURT))
    for page, name, picture in pictures:
        index, data = picture_runs(picture)
        table(page, f"The {name} picture: where each column's runs start", index)
        table(page + 0x10, f"... its runs: count, then top, bottom, color for each", data)
    table(0x3A00, "Wall colors: cell type * 2 + side (0 lit, 1 shaded)", [v for pair in COLORS for v in pair])
    table(0x3A0C, "Picture pages: imp, fireball, arch-imp, health pickup", [0x59, 0x5A, 0x35, 0x36])
    table(0x3A10, "Map offsets of the 8 cells around the player", [0xEF, 0xF0, 0xF1, 0xFF, 0x01, 0x0F, 0x10, 0x11])
    names = "  ".join(f"${o:02X} {n}" for n, o in offs.items())
    table(0x3A20, f"Text, each string ending in 0: {names}", text)
    names2 = "  ".join(f"${o:02X} {n}" for n, o in offs2.items())
    table(0x3B20, f"More text: {names2}", text2)
    table(0x3E00, "Levels: start x, start y, start angle, number of imps (and arch-imp)",
          [v for cells, (x, y, a), imps in levels for v in (x, y, a, imps)])
    table(0x3F00, "Level names as shown on the status bar, 16 characters each",
          [b for n, (name, _) in enumerate(LEVELS) for b in f"E1M{n + 1}: {name}".rjust(16).encode()])
    for n, (cells, _, _) in enumerate(levels):
        table(0x4000 + n * 0x100, f"Level {n + 1}: {LEVELS[n][0]} (copied to $3800 when it starts)", cells)

    out.append("\n; ============================================================================")
    out.append("; Nibble painter, for sprites: for rows y.., row byte = byte AND $005D OR $005E,")
    out.append("; at block column offset i. Entered at $5000 + 12 * row and stopped early like")
    out.append("; the column painter (its first instruction, lda = $35, is swapped for a ret).")
    out.append("; ============================================================================")
    out.append(".org $5000")
    for r in range(ROWS):
        a = vram(0, r)
        out += [f"  lda ${a:04X},i    ; row {r}", "  and $5D", "  ora $5E", f"  sta ${a:04X},i"]
    out.append("  ret")
    table(0x5300, "Angle (512 to a turn) of a slope small/big = index/256",
          [round(math.atan(r / 256) * 512 / (2 * math.pi)) for r in range(256)])
    table(0x5400, "Distance / big side * 128, for slope index/256",
          [round(128 * math.sqrt(1 + (r / 256) ** 2)) for r in range(256)])
    scale = [0] * (27 * 32)
    for hs in range(27):
        for v in range(17):
            scale[hs * 32 + v] = round(v * 2 * hs / 16)
    table(0x5500, "Picture row v at half size hs: row offset v * 2hs / 16, at hs * 32 + v", scale)
    for page, name, picture in ((0x5900, "imp", IMP), (0x5A00, "fireball", ORB)):
        index, data = picture_runs(picture)
        table(page, f"The {name} picture: where each column's runs start", index)
        table(page + 0x10, f"... its runs: count, then top, bottom, color for each", data)
    step = [0] + [round(2048 / hs) for hs in range(1, 27)]
    table(0x5B00, "Picture columns per screen column (8.8) by half size, low bytes", [v & 0xFF for v in step])
    table(0x5B20, "... high bytes", [v >> 8 for v in step])
    entries = [0x5000 + 12 * r for r in range(ROWS + 1)]
    table(0x5B40, "Nibble painter entry for each row, low bytes", [e & 0xFF for e in entries])
    table(0x5B80, "... high bytes", [e >> 8 for e in entries])
    table(0x5C00, "Fireball step along x per tick, by direction (256 to a turn)",
          [round(ORB_SPEED * math.cos(angle(a))) & 0xFF for a in range(256)])
    table(0x5D00, "... along y", [round(ORB_SPEED * math.sin(angle(a))) & 0xFF for a in range(256)])
    out.append("\n.org $6000")
    out.append(sprites.rstrip("\n"))
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
; Shoot the imps: when one can see you it throws fireballs, which fly straight
; at where you were (step aside to dodge; a hit costs 10 health), and standing
; next to one hurts too. The arch-imp takes 10 shots, throws three fireballs
; at once, and keeps the exit shut until it dies. Health pickups give 25. You start with {ammo} bullets. Walk into the yellow exit to go to the next level (you keep
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


FIRE_SPRITES = r"""; ============================================================================
; fire: on a new press, if there is ammo, shoot straight ahead: the nearest
; imp drawn across the middle of the view, in front of the wall there, dies
; (the arch-imp takes @BOSS_HP@ hits)
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
  lda #@S2_OPEN@
  jsr show_message2
fi_save:
  lda $3A
  sta $31
  ret

"""

SPRITES = r"""; ============================================================================
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
  lda #@BOSS_HP@
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
  lda #@S_START@
  jsr show_message
  ret
sm_boss:
  lda #@S2_BOSS@
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
  lda #@S2_BAR@
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
  cmp #@BOSS_HP@
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

; pickup: walking onto the health pickup in map cell i: +@HEAL@ health, up to 100
pickup:
  tia
  sta $A4
  lda $36
  cmp #$64
  jcs pk_done           ; full health already: leave it for later
  clc
  adc #@HEAL@
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
