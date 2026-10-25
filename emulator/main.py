import pygame
from memory import Memory
from cpu import CPU
import time
from video_emulation import video_emulation, text_mode_emulation, half_emulation
import os
import sys
from input_checker import get_input_state

VIDEO_WIDTH = 320
VIDEO_HEIGHT = 240
WINDOW_SIZE = (VIDEO_WIDTH * 3, VIDEO_HEIGHT * 3)


def main(program_path=None):
    pygame.init()

    mem = Memory()

    mem.add_bank(0x0000, 0x7FFF, 'rw')
    mem.add_bank(0x8000, 0x895F, 'rw')
    mem.add_bank(0x9000, 0x9009, 'rw')
    mem.add_bank(0xC000, 0xFFFF, 'ro')

    c = CPU(mem)
   
    mem.write8(0, 0x20)
    mem.write8(1, 0x00)
    mem.write8(2, 0x01)
    mem.write8(3, 0x00)
    mem.write8(4, 0x80)

    # Program to run: python main.py breakout_game.bin (default snake.bin),
    # looked up next to this file unless a full path is given
    program = sys.argv[1] if len(sys.argv) > 1 else "doom.bin"
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), program), "rb") as f:
        data = list(f.read())

    for i in range(len(data)):
        mem.write8(0x100 + i, data[i])

    screen = pygame.display.set_mode(WINDOW_SIZE, pygame.RESIZABLE)
    surface = pygame.Surface((VIDEO_WIDTH, VIDEO_HEIGHT))

    running = True
    while running:
        frame_start = time.perf_counter()
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
            elif event.type == pygame.VIDEORESIZE:
                screen = pygame.display.set_mode(event.size, pygame.RESIZABLE)
        while time.perf_counter() - frame_start < 1 / 60:
            instruct_start = time.perf_counter()
            c.cycle()
            while time.perf_counter() - instruct_start < 1 / 1000000:
                continue
        vid_mode = mem.read8(0x9000)
        surface.fill((0, 0, 0))
        if vid_mode % 4 == 0 or vid_mode % 4 == 3:
            text_mode_emulation(surface, mem)
        elif vid_mode % 4 == 1:
            video_emulation(surface, mem)
        else:
            half_emulation(surface, mem)
        inp = get_input_state()
        if inp[0]:
            if inp[1]:                      # arrows, Shift etc. have no character
                mem.write8(0x9003, ord(inp[1]))
            mem.write8(0x9004, 1)
        else:
            mem.write8(0x9004, 0)

        # Joystick 0 ($9005): arrow keys and Ctrl as bits XXXUDLRC
        keys = pygame.key.get_pressed()
        mem.write8(0x9005, (keys[pygame.K_UP] << 4) | (keys[pygame.K_DOWN] << 3)
                   | (keys[pygame.K_LEFT] << 2) | (keys[pygame.K_RIGHT] << 1)
                   | (keys[pygame.K_LCTRL] or keys[pygame.K_RCTRL]))

        mem.write8(0x9001, (mem.read8(0x9001) + 1) & 0xFF)
        screen.fill((0, 0, 0))
        screen_width, screen_height = screen.get_size()
        scale = min(screen_width / VIDEO_WIDTH, screen_height / VIDEO_HEIGHT)
        scaled_size = (max(1, int(VIDEO_WIDTH * scale)),
                       max(1, int(VIDEO_HEIGHT * scale)))
        scaled_surface = pygame.transform.scale(surface, scaled_size)
        screen.blit(scaled_surface, ((screen_width - scaled_size[0]) // 2,
                                     (screen_height - scaled_size[1]) // 2))
        pygame.display.flip()

    pygame.quit()


if __name__ == "__main__":
    if len(sys.argv) > 2:
        sys.exit(f"Usage: python {os.path.basename(__file__)} [program.bin]")
    main(sys.argv[1] if len(sys.argv) == 2 else None)
