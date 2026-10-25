import os

import pygame

from memory import Memory
from palette import PALETTE

VRAM_START = 0x8000


# ---------------------------------------------------------------- graphics mode (mode 1)
# 40 x 30 blocks of 8 x 8 pixels (the same cells as text mode), each block a
# 2 x 2 grid of 4 x 4 subpixels, giving 80 x 60 subpixels. Each block takes
# 2 bytes of VRAM, laid out in the same order as text mode:
#   byte 0: upper-left (upper nibble), upper-right (lower nibble)
#   byte 1: lower-left (upper nibble), lower-right (lower nibble)

GRAPHICS_COLUMNS = 40
GRAPHICS_ROWS = 30
BLOCK_SIZE = 8
BYTES_PER_BLOCK = 2


def block_draw(canvas: pygame.Surface, x_block: int, y_block: int, upper: int, lower: int) -> None:
    sub_size = BLOCK_SIZE // 2
    x_start = x_block * BLOCK_SIZE
    y_start = y_block * BLOCK_SIZE

    canvas.fill(PALETTE[upper >> 4], (x_start, y_start, sub_size, sub_size))                        # upper-left
    canvas.fill(PALETTE[upper & 0xF], (x_start + sub_size, y_start, sub_size, sub_size))            # upper-right
    canvas.fill(PALETTE[lower >> 4], (x_start, y_start + sub_size, sub_size, sub_size))             # lower-left
    canvas.fill(PALETTE[lower & 0xF], (x_start + sub_size, y_start + sub_size, sub_size, sub_size))  # lower-right


def draw_blocks(canvas: pygame.Surface, memory: Memory, rows: int) -> None:
    """Draw the first `rows` rows of graphics-mode VRAM."""
    for block in range(GRAPHICS_COLUMNS * rows):
        address = VRAM_START + block * BYTES_PER_BLOCK
        block_draw(canvas, block % GRAPHICS_COLUMNS, block // GRAPHICS_COLUMNS,
                   memory.read8(address), memory.read8(address + 1))


def video_emulation(canvas: pygame.Surface, memory: Memory) -> None:
    """Draw graphics-mode VRAM onto a 320x240 canvas."""
    draw_blocks(canvas, memory, GRAPHICS_ROWS)


# ---------------------------------------------------------------- text mode (mode 0)
# 40 x 30 cells of 8 x 8 pixels, two bytes per cell starting at $8000:
#   byte 0: background color (upper nibble), foreground color (lower nibble)
#   byte 1: character code, drawn from the font in sprites.bin (slot N = ASCII N)

TEXT_VRAM_START = VRAM_START
TEXT_COLUMNS = 40
TEXT_ROWS = 30
CHAR_SIZE = 8
GLYPH_COUNT = 128

FONT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sprites.bin")

_font = None
_char_tiles = {}   # (character code, color byte) -> 8x8 Surface, built once


def load_font(path: str = FONT_PATH) -> list[bytes]:
    """sprites.bin -> 128 glyphs of 8 row bytes each (bit 7 = leftmost pixel)."""
    with open(path, "rb") as f:
        data = f.read(GLYPH_COUNT * CHAR_SIZE).ljust(GLYPH_COUNT * CHAR_SIZE, b"\x00")
    return [data[i:i + CHAR_SIZE] for i in range(0, len(data), CHAR_SIZE)]


def char_tile(code: int, colors: int) -> pygame.Surface:
    """Render (and cache) one character cell."""
    global _font
    tile = _char_tiles.get((code, colors))
    if tile is not None:
        return tile

    if _font is None:
        _font = load_font()

    tile = pygame.Surface((CHAR_SIZE, CHAR_SIZE))
    tile.fill(PALETTE[colors >> 4])           # background
    if code < GLYPH_COUNT:                    # codes 128-255 have no glyph
        foreground = PALETTE[colors & 0xF]
        for y, bits in enumerate(_font[code]):
            for x in range(CHAR_SIZE):
                if bits & (0x80 >> x):
                    tile.set_at((x, y), foreground)
    _char_tiles[(code, colors)] = tile
    return tile


def char_draw(canvas: pygame.Surface, column: int, row: int, code: int, colors: int) -> None:
    canvas.blit(char_tile(code, colors), (column * CHAR_SIZE, row * CHAR_SIZE))


def draw_text_rows(canvas: pygame.Surface, memory: Memory, vram_start: int, first_row: int, rows: int) -> None:
    """Draw `rows` rows of text cells read from vram_start, starting at screen text row first_row."""
    for cell in range(TEXT_COLUMNS * rows):
        address = vram_start + cell * 2
        char_draw(canvas, cell % TEXT_COLUMNS, first_row + cell // TEXT_COLUMNS,
                  memory.read8(address + 1), memory.read8(address))


def text_mode_emulation(canvas: pygame.Surface, memory: Memory) -> None:
    """Draw text-mode VRAM onto a 320x240 canvas."""
    draw_text_rows(canvas, memory, TEXT_VRAM_START, 0, TEXT_ROWS)


# ---------------------------------------------------------------- split mode (mode 2)
# Graphics on top (26 block rows = 208 pixels), then 4 rows of text in the
# remaining 32 pixels. Text cells follow the graphics data in VRAM, at $8820.

HALF_GRAPHICS_ROWS = 26
HALF_TEXT_ROWS = 4
HALF_TEXT_VRAM_START = VRAM_START + HALF_GRAPHICS_ROWS * GRAPHICS_COLUMNS * BYTES_PER_BLOCK
HALF_TEXT_FIRST_ROW = HALF_GRAPHICS_ROWS * BLOCK_SIZE // CHAR_SIZE


def half_emulation(canvas: pygame.Surface, memory: Memory) -> None:
    draw_blocks(canvas, memory, HALF_GRAPHICS_ROWS)
    draw_text_rows(canvas, memory, HALF_TEXT_VRAM_START, HALF_TEXT_FIRST_ROW, HALF_TEXT_ROWS)

