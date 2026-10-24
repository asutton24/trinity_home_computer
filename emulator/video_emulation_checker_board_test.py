import pygame

from palette import BLACK, WHITE, make_byte
from video_emulation import video_emulation

# Must match the layout video_emulation reads from
VRAM_START = 8000
X_GRID_SIZE = 80
Y_GRID_SIZE = 60
NUM_BLOCKS = X_GRID_SIZE * Y_GRID_SIZE
BYTES_PER_BLOCK = 4

CANVAS_WIDTH = X_GRID_SIZE * 4
CANVAS_HEIGHT = Y_GRID_SIZE * 4
WINDOW_SCALE = 1


def generate_test_memory() -> [str]:
    # Everything below VRAM_START is filler so the list indexes line up
    memory = ["0"] * (VRAM_START + NUM_BLOCKS * BYTES_PER_BLOCK)

    for block_index in range(NUM_BLOCKS):
        # Checkerboard at the subpixel level: each block is a 2x2 grid,
        # so alternating within the block makes neighbouring blocks line up
        # Upper byte: upper-left / upper-right subpixels
        # Lower byte: lower-left / lower-right subpixels
        address = VRAM_START + block_index * BYTES_PER_BLOCK
        memory[address] = str(make_byte(BLACK, WHITE))
        memory[address + 1] = str(make_byte(WHITE, BLACK))

    return memory


def main():
    pygame.init()
    window = pygame.display.set_mode((CANVAS_WIDTH * WINDOW_SCALE, CANVAS_HEIGHT * WINDOW_SCALE))
    pygame.display.set_caption("Video Emulation Test")
    canvas = pygame.Surface((CANVAS_WIDTH, CANVAS_HEIGHT))
    print(f"Canvas size: {canvas.get_width()}x{canvas.get_height()}")

    memory = generate_test_memory()
    print(f"Generated {len(memory)} memory elements")

    video_emulation(canvas, memory)

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
