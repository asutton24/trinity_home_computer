import pygame

def get_input_state() -> tuple[bool, str]:
    pressed = pygame.key.get_pressed()

    if not any(pressed):
        return (False, "")

    # do stuff here

    ascii_val = ord(key_pressed)
    return (True, chr(ascii_val))
