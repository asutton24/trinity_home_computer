from collections import Counter
from pathlib import Path
import sys

import pygame

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT))

from emulator.memory import Memory
from emulator.palette import PALETTE, BLACK, WHITE, make_byte
from emulator.test.viewer import show
from emulator.video_emulation import (
    text_mode_emulation, TEXT_VRAM_START, TEXT_COLUMNS, TEXT_ROWS, CHAR_SIZE,
)

CANVAS_WIDTH = TEXT_COLUMNS * CHAR_SIZE
CANVAS_HEIGHT = TEXT_ROWS * CHAR_SIZE


def cell_colors(column: int, row: int) -> tuple[int, int]:
    """(background, foreground) palette indices for a cell of the test pattern."""
    return (BLACK, WHITE) if (column + row) % 2 == 0 else (WHITE, BLACK)


def generate_test_memory() -> Memory:
    memory = Memory()
    memory.add_bank(TEXT_VRAM_START, TEXT_VRAM_START + TEXT_COLUMNS * TEXT_ROWS * 2 - 1, "rw")

    # Checkerboard of cells, each showing its column's last digit in the opposite
    # color, so every row should read 0123456789 four times.
    for cell in range(TEXT_COLUMNS * TEXT_ROWS):
        column, row = cell % TEXT_COLUMNS, cell // TEXT_COLUMNS
        address = TEXT_VRAM_START + cell * 2
        memory.write8(address, make_byte(*cell_colors(column, row)))
        memory.write8(address + 1, ord("0") + column % 10)

    return memory


def render() -> pygame.Surface:
    canvas = pygame.Surface((CANVAS_WIDTH, CANVAS_HEIGHT))
    text_mode_emulation(canvas, generate_test_memory())
    return canvas


def test_text_cells():
    canvas = render()
    for row in range(TEXT_ROWS):
        for column in range(TEXT_COLUMNS):
            background, foreground = cell_colors(column, row)
            pixels = Counter(tuple(canvas.get_at((column * CHAR_SIZE + x, row * CHAR_SIZE + y)))[:3]
                             for y in range(CHAR_SIZE) for x in range(CHAR_SIZE))
            # Only the cell's two colors appear, the glyph is drawn, and most of the cell is background
            assert set(pixels) == {PALETTE[background], PALETTE[foreground]}, f"bad colors in cell ({column}, {row})"
            assert pixels[PALETTE[background]] > pixels[PALETTE[foreground]], f"bad glyph in cell ({column}, {row})"


if __name__ == "__main__":
    test_text_cells()
    print("Text mode test passed")
    pygame.init()
    show(render(), "Text Mode Test")
