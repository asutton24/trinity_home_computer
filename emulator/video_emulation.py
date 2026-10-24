import os

import pygame

COLOR_PALETTE = {
    0: (0, 0, 0),        # black
    1: (30, 42, 110),    # navy
    2: (107, 46, 126),   # plum
    3: (30, 107, 58),    # forest green
    4: (122, 74, 42),    # brown
    5: (74, 78, 90),     # dark gray
    6: (163, 167, 179),  # light gray
    7: (245, 200, 160),  # peach
    8: (216, 51, 61),    # red
    9: (240, 138, 36),   # orange
    10: (247, 216, 74),  # yellow
    11: (92, 201, 78),   # green
    12: (79, 163, 232),  # sky blue
    13: (155, 124, 217), # lavender
    14: (242, 139, 176), # pink
    15: (255, 255, 255), # white
}

def block_draw(canvas: pygame.Surface, x_block: int, y_block: int, block_width: int, color1: int, color2: int, color3: int, color4: int) -> None:
    x_start = block_width * x_block
    y_start = block_width * y_block

    # Each block is a 2x2 grid of sub-pixels
    sub_width = block_width // 2
    x_mid = x_start + sub_width
    y_mid = y_start + sub_width

    pygame.draw.rect(canvas, pygame.Color(COLOR_PALETTE[color1]), pygame.Rect(x_start, y_start, sub_width, sub_width))  # upper-left
    pygame.draw.rect(canvas, pygame.Color(COLOR_PALETTE[color2]), pygame.Rect(x_mid, y_start, sub_width, sub_width))    # upper-right
    pygame.draw.rect(canvas, pygame.Color(COLOR_PALETTE[color3]), pygame.Rect(x_start, y_mid, sub_width, sub_width))    # lower-left
    pygame.draw.rect(canvas, pygame.Color(COLOR_PALETTE[color4]), pygame.Rect(x_mid, y_mid, sub_width, sub_width))      # lower-right


def video_emulation(canvas: pygame.Surface, video_memory: [str]) -> None:
    x_grid_size = 80
    y_grid_size = 60

    block_width = 4

    num_blocks = x_grid_size * y_grid_size

    for block_index in range(num_blocks):
        x_block = block_index % x_grid_size
        y_block = block_index // x_grid_size

        block_draw(canvas, x_block, y_block, block_width, int(video_memory[8000+block_index*4])//16, int(video_memory[8000+block_index*4])%16, int(video_memory[8000+block_index*4+1])//16, int(video_memory[8000+block_index*4+1])%16)


# ---------------------------------------------------------------- text mode (mode 0)
# 40 x 30 cells of 8 x 8 pixels, two bytes per cell starting at $8000:
#   byte 0: background color (upper nibble), foreground color (lower nibble)
#   byte 1: character code, drawn from the font in sprites.bin (slot N = ASCII N)

TEXT_VRAM_START = 0x8000
TEXT_COLUMNS = 40
TEXT_ROWS = 30
CHAR_SIZE = 8

FONT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sprites.bin")

_font = None
_char_tiles = {}   # (character code, color byte) -> 8x8 Surface, built once


def load_font(path: str = FONT_PATH) -> list:
    """sprites.bin -> 128 glyphs of 8 row bytes each (bit 7 = leftmost pixel)."""
    with open(path, "rb") as f:
        data = f.read(128 * 8).ljust(128 * 8, b"\x00")
    return [data[i * 8:(i + 1) * 8] for i in range(128)]


def char_draw(canvas: pygame.Surface, column: int, row: int, code: int, colors: int) -> None:
    global _font
    if _font is None:
        _font = load_font()

    tile = _char_tiles.get((code, colors))
    if tile is None:
        tile = pygame.Surface((CHAR_SIZE, CHAR_SIZE))
        tile.fill(COLOR_PALETTE[colors // 16])                  # background
        if code < 128:                                          # codes 128-255 have no glyph
            foreground = COLOR_PALETTE[colors % 16]
            for y, bits in enumerate(_font[code]):
                for x in range(CHAR_SIZE):
                    if bits & (0x80 >> x):
                        tile.set_at((x, y), foreground)
        _char_tiles[(code, colors)] = tile

    canvas.blit(tile, (column * CHAR_SIZE, row * CHAR_SIZE))


def text_mode_emulation(canvas: pygame.Surface, memory) -> None:
    """Draw text-mode VRAM onto a 320x240 canvas. memory is a Memory from memory.py."""
    for cell in range(TEXT_COLUMNS * TEXT_ROWS):
        address = TEXT_VRAM_START + cell * 2
        char_draw(canvas, cell % TEXT_COLUMNS, cell // TEXT_COLUMNS,
                  memory.read8(address + 1), memory.read8(address))
