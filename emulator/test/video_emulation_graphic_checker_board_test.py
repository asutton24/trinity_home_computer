from pathlib import Path
import sys

import pygame

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT))

from emulator.memory import Memory
from emulator.palette import PALETTE, BLACK, WHITE, make_byte
from emulator.test.viewer import show
from emulator.video_emulation import (
    video_emulation, VRAM_START, GRAPHICS_COLUMNS, GRAPHICS_ROWS, BLOCK_SIZE, BYTES_PER_BLOCK,
)

NUM_BLOCKS = GRAPHICS_COLUMNS * GRAPHICS_ROWS
CANVAS_WIDTH = GRAPHICS_COLUMNS * BLOCK_SIZE
CANVAS_HEIGHT = GRAPHICS_ROWS * BLOCK_SIZE


def generate_test_memory() -> Memory:
    memory = Memory()
    memory.add_bank(VRAM_START, VRAM_START + NUM_BLOCKS * BYTES_PER_BLOCK - 1, "rw")

    for block_index in range(NUM_BLOCKS):
        # Checkerboard at the subpixel level: each block is a 2x2 grid,
        # so alternating within the block makes neighbouring blocks line up
        # Upper byte: upper-left / upper-right subpixels
        # Lower byte: lower-left / lower-right subpixels
        address = VRAM_START + block_index * BYTES_PER_BLOCK
        memory.write8(address, make_byte(BLACK, WHITE))
        memory.write8(address + 1, make_byte(WHITE, BLACK))

    return memory


def render() -> pygame.Surface:
    canvas = pygame.Surface((CANVAS_WIDTH, CANVAS_HEIGHT))
    video_emulation(canvas, generate_test_memory())
    return canvas


def test_checker_board():
    canvas = render()
    sub_size = BLOCK_SIZE // 2
    for y in range(0, CANVAS_HEIGHT, sub_size):
        for x in range(0, CANVAS_WIDTH, sub_size):
            expected = PALETTE[WHITE] if (x // sub_size + y // sub_size) % 2 else PALETTE[BLACK]
            assert tuple(canvas.get_at((x, y)))[:3] == expected, f"wrong color at ({x}, {y})"


if __name__ == "__main__":
    test_checker_board()
    print("Checker board test passed")
    pygame.init()
    show(render(), "Graphics Mode Test")
