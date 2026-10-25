from pathlib import Path
import sys

import pygame

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT))

from emulator.memory import Memory
from emulator.palette import PALETTE, BLACK, WHITE, RED, make_byte
from emulator.test.viewer import show
from emulator.video_emulation import (
    half_emulation, char_tile, VRAM_START, GRAPHICS_COLUMNS, GRAPHICS_ROWS, HALF_GRAPHICS_ROWS, BLOCK_SIZE,
    BYTES_PER_BLOCK, HALF_TEXT_VRAM_START, HALF_TEXT_FIRST_ROW, HALF_TEXT_ROWS, TEXT_COLUMNS, CHAR_SIZE,
)

CANVAS_WIDTH = GRAPHICS_COLUMNS * BLOCK_SIZE
CANVAS_HEIGHT = GRAPHICS_ROWS * BLOCK_SIZE
GRAPHICS_HEIGHT = HALF_GRAPHICS_ROWS * BLOCK_SIZE

# Canvas is pre-filled with this, so anything half_emulation doesn't draw stays visible
UNDRAWN = RED

TEXT_COLORS = make_byte(BLACK, WHITE)


def cell_code(column: int) -> int:
    """Each text cell shows its column's last digit, so every row reads 0123456789 four times."""
    return ord("0") + column % 10


def generate_test_memory() -> Memory:
    num_text_cells = TEXT_COLUMNS * HALF_TEXT_ROWS
    memory = Memory()
    memory.add_bank(VRAM_START, HALF_TEXT_VRAM_START + num_text_cells * 2 - 1, "rw")

    # Graphics: checkerboard at the subpixel level (see the graphics checker board test)
    for block_index in range(GRAPHICS_COLUMNS * HALF_GRAPHICS_ROWS):
        address = VRAM_START + block_index * BYTES_PER_BLOCK
        memory.write8(address, make_byte(BLACK, WHITE))
        memory.write8(address + 1, make_byte(WHITE, BLACK))

    # Text: digits 0-9 repeated across each row
    for cell in range(num_text_cells):
        address = HALF_TEXT_VRAM_START + cell * 2
        memory.write8(address, TEXT_COLORS)
        memory.write8(address + 1, cell_code(cell % TEXT_COLUMNS))

    return memory


def render() -> pygame.Surface:
    canvas = pygame.Surface((CANVAS_WIDTH, CANVAS_HEIGHT))
    canvas.fill(PALETTE[UNDRAWN])
    half_emulation(canvas, generate_test_memory())
    return canvas


def test_checker_board_on_top_digits_on_bottom():
    canvas = render()

    sub_size = BLOCK_SIZE // 2
    for y in range(GRAPHICS_HEIGHT):
        for x in range(CANVAS_WIDTH):
            expected = PALETTE[WHITE] if (x // sub_size + y // sub_size) % 2 else PALETTE[BLACK]
            assert tuple(canvas.get_at((x, y)))[:3] == expected, f"wrong graphics color at ({x}, {y})"

    for row in range(HALF_TEXT_ROWS):
        for column in range(TEXT_COLUMNS):
            tile = char_tile(cell_code(column), TEXT_COLORS)
            x_start, y_start = column * CHAR_SIZE, (HALF_TEXT_FIRST_ROW + row) * CHAR_SIZE
            for y in range(CHAR_SIZE):
                for x in range(CHAR_SIZE):
                    assert canvas.get_at((x_start + x, y_start + y)) == tile.get_at((x, y)), \
                        f"wrong glyph in text cell ({column}, {row})"


if __name__ == "__main__":
    test_checker_board_on_top_digits_on_bottom()
    print("Half mode test passed")
    pygame.init()
    show(render(), "Half Mode Test")
