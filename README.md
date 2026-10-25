# Project Trinity

Project Trinity is a fantasy 8-bit home computer: an imaginary machine with its own CPU, memory map, 16-color video and joystick ports. This repo has everything you need to write programs for it and run them:

- an **emulator** (Python + pygame) that runs Trinity machine code in a window
- an **assembler** that turns Trinity assembly (`.s`) into machine code (`.bin`)
- **Trinity IDE**, an editor for `.s` files with syntax highlighting and a Gemini-powered assistant
- **example games**: Snake, Breakout, Pong and a DOOM-style 3D shooter, all written in Trinity assembly

The full machine and instruction set are described in [`ide/specification.txt`](ide/specification.txt).

## Quick start

You need Python 3.10 or newer.

```
pip install -r requirements.txt
cd emulator
python main.py doom.bin
```

Swap `doom.bin` for `snake.bin` or `breakout_game.bin` to play the others. With no argument, `main.py` runs DOOM.

## The machine

| | |
|---|---|
| CPU | 8-bit: registers `a`, `b`, `c` and index `i`; 16-bit `pc` and `sp`; zero and carry flags; 1 MHz (one million instructions a second) |
| Memory | 32 KB RAM (`$0000`–`$7FFF`), VRAM (`$8000`–`$895F`), I/O (`$9000`–`$9009`), 16 KB ROM (`$C000`–`$FFFF`) |
| Video | 320 × 240, 16 colors, three modes (below) |
| Input | keyboard, plus two joysticks read as `XXXUDLRC` bytes |
| Sound | a bell |

**Video modes** (selected by writing `$9000`):

- **Mode 0, text:** 40 × 30 characters. Each cell is two bytes: a color byte (background in the high nibble, foreground in the low nibble), then the character code.
- **Mode 1, graphics:** 40 × 30 blocks of 8 × 8 pixels, each split into four 4 × 4 subpixels, so the screen is 80 × 60 subpixels. Two bytes per block, one nibble (color) per subpixel.
- **Mode 2, mixed:** 26 rows of graphics on top, 4 rows of text underneath. Most of the games use this mode, with the text rows as a status bar.

**I/O addresses:**

| Address | What it is |
|---|---|
| `$9000` | video mode |
| `$9001` | clock: goes up by one every 1/60 second |
| `$9002` | bell (sounds while non-zero) |
| `$9003` | ASCII code of the last key pressed |
| `$9004` | 1 while any key is held |
| `$9005` / `$9006` | joystick 0 / 1 (`XXXUDLRC`: up, down, left, right, button) |
| `$9007`–`$9009` | tape (byte, counter, motor) |

The 16 colors are defined in [`emulator/palette.py`](emulator/palette.py). The text font is [`emulator/sprites.bin`](emulator/sprites.bin): 128 characters of 8 × 8 pixels, one byte per row, in ASCII order.

## Running programs

```
cd emulator
python main.py <program.bin>
```

The emulator loads the program at `$0100` and jumps there. The program name is looked up next to `main.py` unless you give a full path.

**Controls:** joystick 0 is the arrow keys plus Ctrl. Everything you type goes to `$9003`/`$9004`.

**Speed:** the emulator is plain Python, so it runs well below the spec's 1 MHz (about 300,000 instructions a second on a typical PC). Games that wait on the `$9001` clock keep the right pace anyway; DOOM just draws fewer frames.

## Writing programs

A small program, which writes white `A`s on navy across the first 128 characters of the screen (just over three rows):

```asm
.org $0100

start:
  lds #$7FFF          ; set up the stack
  lda #$00            ; video mode 0: text
  sta $9000
  ldi #$00
loop:
  lda #$1F            ; navy background, white text
  sta $8000,i
  inc i
  lda #$41            ; "A"
  sta $8000,i
  inc i
  jne loop
done:
  jmp done
```

**Assembler notes:**

- `$` means hex and `#` means an immediate value (`lda #$41`).
- `.org $addr` sets where the following code goes. It can only move forward.
- `.bytes $xx, $yy` puts raw data in, two bytes per line.
- Labels (`loop:`) can be used as the target of `jmp`, `jsr`, `jeq`, `jne`, `jcs` and `jcc`.
- `;` starts a comment.

To assemble, run:

```
python assembler/main.py game_examples/pong.s
```

This writes `bin/pong.bin`, which you can then run with:

```
cd emulator
python main.py ../bin/pong.bin
```

## Trinity IDE

```
python ide/main.py
```

The IDE is an editor for `.s` files. It has:

- line numbers and syntax highlighting
- descriptions of each instruction and I/O address as you hover
- search
- a **Run** button that assembles the open file into `bin/`

It also has an assistant panel that can explain code, help debug, and propose edits. Edits are shown as a diff for you to accept. They are checked against the spec and the assembler first.

To use the assistant, copy `.env.example` to `.env` and put your Gemini API key in it. You can get a key at <https://aistudio.google.com/apikey>. The IDE itself needs only Python's built-in Tkinter.

## The games

All the games are in [`game_examples/`](game_examples), with the assembled versions in [`emulator/`](emulator).

| Game | Source | How to play |
|---|---|---|
| **Snake** | `snake.s` | Arrows or WASD. Eat the food to grow and avoid the walls and your tail. SPACE plays again. |
| **Breakout** | `breakout_game.s` | Left/right or A/D move the paddle. SPACE launches the ball. |
| **Pong** | `pong.s` | Two players: W/S and the up/down arrows. First to 5 wins. Assemble it first (see above). |
| **DOOM** | `doom_build.py` → `doom.s` | Arrows or WASD to move and turn, Ctrl or SPACE to shoot. |

`breakout.s` is a small early text-mode test.

### Trinity DOOM

Trinity DOOM is a first-person raycaster in mixed mode. It has:

- shaded walls that fade into fog in the distance
- imps that throw fireballs you can dodge
- an arch-imp boss
- health pickups
- several levels, played in order

The CPU has no multiply or divide, so `doom_build.py` works out all the trigonometry ahead of time as lookup tables and writes the assembly for you.

**Make your own levels:** edit `LEVELS` at the top of [`game_examples/doom_build.py`](game_examples/doom_build.py). Each map is 16 × 16 characters:

| | |
|---|---|
| `#` `G` `T` | walls: stone, green slime, purple tech |
| `.` | floor |
| `I` | imp (up to 9 per level, counting the arch-imp) |
| `A` | arch-imp: a boss that takes 10 shots and throws three fireballs at once; the exit stays shut until it's dead (one per level) |
| `H` | health pickup: +25 health (up to 3 per level) |
| `E` | exit |
| `P` `>` `v` `<` `^` | where you start, facing east/south/west/north (one per map) |

Then rebuild:

```
cd game_examples
python doom_build.py
```

This writes `doom.s` and `emulator/doom.bin`. It also checks every map and tells you what's wrong if one can't be played: an open edge, no exit, an exit you can't reach, too many imps, and so on.

## Project layout

```
assembler/main.py          the assembler (python assembler/main.py file.s)
emulator/main.py           the emulator window
emulator/cpu.py            the CPU
emulator/memory.py         memory banks
emulator/video_emulation.py  the three video modes
emulator/input_checker.py  keyboard input
emulator/palette.py        the 16 colors
emulator/sprites.bin       the text font
emulator/cpu_test.py       CPU tests (python emulator/cpu_test.py)
emulator/*.bin             assembled games
game_examples/             game sources, and the DOOM builder
ide/main.py                Trinity IDE
ide/specification.txt      the machine and instruction set
```

## Tests

```
python emulator/cpu_test.py
```

This checks CPU instructions against the spec.
