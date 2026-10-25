import pygame

# Each key, and what it types with Shift held, in the same order
UNSHIFTED = "1234567890-=[]\\;',./`"
SHIFTED   = "!@#$%^&*()_+{}|:\"<>?~"
SHIFT_MAP = {ord(a): ord(b) for a, b in zip(UNSHIFTED, SHIFTED)}

# Every printable key; in pygame each key's constant equals its ASCII code
PRINTABLE_KEYS = [ord(c) for c in " abcdefghijklmnopqrstuvwxyz" + UNSHIFTED]


def get_input_state() -> tuple[bool, str]:
    pressed = pygame.key.get_pressed()

    if not any(pressed):
        return (False, "")

    for key in PRINTABLE_KEYS:
        if pressed[key]:
            ascii_val = key
            break
    else:
        return (True, "")          # a key is down, but not a printable one (e.g. Shift alone)

    if pygame.key.get_mods() & pygame.KMOD_SHIFT:
        ascii_val = SHIFT_MAP.get(ascii_val, ascii_val)
    if ord("a") <= ascii_val <= ord("z"):
        ascii_val -= 32            # letters always come out as capitals

    return (True, chr(ascii_val))