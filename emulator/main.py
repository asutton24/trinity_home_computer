import pygame
from memory import Memory
from cpu import CPU
import time
from video_emulation import video_emulation, text_mode_emulation, half_emulation
import os
from input_checker import get_input_state

def main():
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

    with open("snake.bin", "rb") as f:
        data = list(f.read())

    for i in range(len(data)):
        mem.write8(0x100 + i, data[i])

    screen = pygame.display.set_mode((320, 240))
    surface = pygame.Surface((320, 240))

    running = True
    while running:
        frame_start = time.perf_counter()
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                running = False
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
            mem.write8(0x9003, ord(inp[1]))
            mem.write8(0x9004, 1)
        else:
            mem.write8(0x9004, 0)

        mem.write8(0x9001, (mem.read8(0x9001) + 1) & 0xFF)
        screen.blit(surface, (0, 0))
        pygame.display.flip()

    pygame.quit()


if __name__ == "__main__":
    main()

