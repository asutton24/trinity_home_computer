import pygame

from memory import Memory
from palette import BLACK, WHITE, make_byte
from video_emulation import text_mode_emulation, TEXT_VRAM_START, TEXT_COLUMNS, TEXT_ROWS

CANVAS_WIDTH = 320
CANVAS_HEIGHT = 240
WINDOW_SCALE = 3


def generate_test_memory() -> Memory:
    memory = Memory()
    memory.add_bank(TEXT_VRAM_START, TEXT_VRAM_START + TEXT_COLUMNS * TEXT_ROWS * 2 - 1, "rw")

    # Checkerboard of cells, each showing its column's last digit in the opposite
    # color, so every row should read 0123456789 four times.
    for cell in range(TEXT_COLUMNS * TEXT_ROWS):
        column, row = cell % TEXT_COLUMNS, cell // TEXT_COLUMNS
        if (column + row) % 2 == 0:
            colors = make_byte(BLACK, WHITE)
        else:
            colors = make_byte(WHITE, BLACK)
        address = TEXT_VRAM_START + cell * 2
        memory.write8(address, colors)
        memory.write8(address + 1, ord("0") + column % 10)

    return memory


def main():
    pygame.init()
    window = pygame.display.set_mode((CANVAS_WIDTH * WINDOW_SCALE, CANVAS_HEIGHT * WINDOW_SCALE))
    pygame.display.set_caption("Text Mode Test")
    canvas = pygame.Surface((CANVAS_WIDTH, CANVAS_HEIGHT))

    text_mode_emulation(canvas, generate_test_memory())

    running = True
    while running:
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False

        window.blit(pygame.transform.scale(canvas, window.get_size()), (0, 0))
        pygame.display.flip()

    pygame.quit()


if __name__ == "__main__":
    main()
