"""
Project Trinity 16-color palette.

Each color is picked by a 4-bit nibble (0-F), as used by the video modes:
  Mode 0 (text):     attribute byte = background in upper nibble, foreground in lower
  Mode 1 (graphics): each byte = left subpixel in upper nibble, right subpixel in lower

0-5 are dark (good backgrounds), 6-F are bright (good foregrounds).
"""

# Index = nibble value. Colors are (R, G, B), 0-255 per channel.
PALETTE = [
    (0x00, 0x00, 0x00),  # 0  black
    (0x1E, 0x2A, 0x6E),  # 1  navy
    (0x6B, 0x2E, 0x7E),  # 2  plum
    (0x1E, 0x6B, 0x3A),  # 3  forest green
    (0x7A, 0x4A, 0x2A),  # 4  brown
    (0x4A, 0x4E, 0x5A),  # 5  dark gray
    (0xA3, 0xA7, 0xB3),  # 6  light gray
    (0xF5, 0xC8, 0xA0),  # 7  peach
    (0xD8, 0x33, 0x3D),  # 8  red
    (0xF0, 0x8A, 0x24),  # 9  orange
    (0xF7, 0xD8, 0x4A),  # A  yellow
    (0x5C, 0xC9, 0x4E),  # B  green
    (0x4F, 0xA3, 0xE8),  # C  sky blue
    (0x9B, 0x7C, 0xD9),  # D  lavender
    (0xF2, 0x8B, 0xB0),  # E  pink
    (0xFF, 0xFF, 0xFF),  # F  white
]

# Named indices, so code can say BLACK instead of 0.
BLACK, NAVY, PLUM, FOREST, BROWN, DARK_GRAY, LIGHT_GRAY, PEACH, \
    RED, ORANGE, YELLOW, GREEN, SKY_BLUE, LAVENDER, PINK, WHITE = range(16)

# Same colors as "#RRGGBB" strings (for tkinter).
PALETTE_HEX = ["#%02X%02X%02X" % c for c in PALETTE]


def split_byte(value):
    """Split a VRAM color byte into (upper nibble, lower nibble) colors as RGB.

    Text mode:     returns (background, foreground)
    Graphics mode: returns (left subpixel, right subpixel)
    """
    return PALETTE[(value >> 4) & 0xF], PALETTE[value & 0xF]


def make_byte(upper, lower):
    """Build a color byte from two palette indices, e.g. make_byte(BLACK, WHITE) -> 0x0F."""
    return ((upper & 0xF) << 4) | (lower & 0xF)
