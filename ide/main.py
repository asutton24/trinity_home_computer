"""Trinity IDE - a lightweight IDE for Project Trinity assembly programs (.s files).

Everything the IDE needs lives in this file: the Tkinter user interface, the
code editor with its line-number gutter, the specification-driven syntax
highlighter, file handling, search, and the Gemini-powered assistant that can
explain code and propose edits the user reviews before they are applied.

The language is defined exclusively by ``specification.txt`` in the project
root (beside this file). The instruction table, categories and colors below
were derived from it, and the assistant receives its full text as context.

Requirements: Python 3.10+ with Tkinter. No third-party packages are needed;
the Gemini API is called over HTTPS with the standard library.
"""

from __future__ import annotations

import difflib
import itertools
import json
import os
import queue
import re
import sys
import tempfile
import threading
import tkinter as tk
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
from tkinter import font as tkfont
from typing import Callable, Mapping, Sequence

sys.path.append(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from assembler.main import parse_code, parse_file

# ============================================================================
# Application constants
# ============================================================================

APP_NAME = "Trinity IDE"
APP_DIR = Path(__file__).resolve().parent

# The single authoritative language specification. No other file is consulted.
SPECIFICATION_PATH = APP_DIR / "specification.txt"
# The .env file lives one level up, in the project root beside .env.example,
# so the API key stays outside the IDE folder.
ENV_PATH = APP_DIR.parent / ".env"

SOURCE_SUFFIX = ".s"
SOURCE_FILETYPES = [("Trinity assembly source", "*.s")]
DEFAULT_FILE_NAME = "untitled.s"
INDENT_WIDTH = 4

# Gemini 3.8 Flash is the most capable model on the Gemini API free tier (Pro models are paid only).
GEMINI_MODEL = "gemini-3.8-flash"
GEMINI_API_ROOT = "https://generativelanguage.googleapis.com/v1beta"
GEMINI_KEY_VARIABLE = "GEMINI_API_KEY"
# Gemini thinks before it replies and sends nothing until it finishes, so long programs can take several minutes.
GEMINI_TIMEOUT_SECONDS = 600.0
# Proposed edits are checked against the specification and the assembler; when either finds a problem,
# the errors are sent back to Gemini for a corrected program, up to this many extra requests per message.
GEMINI_MAX_FIX_ROUNDS = 3

MAX_PROPOSED_SOURCE_CHARS = 500_000

# ============================================================================
# Language definition — derived from specification.txt
# ============================================================================

# Addressing-mode keys use the specification's own notation. Register modes
# are "a", "b", "c" and "i"; the bit instruction uses the bit numbers "0"-"7".
MODE_IMPLIED = "imp"
MODE_IMMEDIATE = "imd"
MODE_ABSOLUTE = "abs"
MODE_ABSOLUTE_INDEXED = "abs,i"
MODE_INDIRECT = "(ind)"
MODE_INDIRECT_INDEXED = "(ind),i"
REGISTER_MODES = ("a", "b", "c", "i")
BIT_MODES = tuple("01234567")

ADDRESSING_MODE_DESCRIPTIONS: dict[str, str] = {
    MODE_IMPLIED: "implied (no operand)",
    "a": "register a",
    "b": "register b",
    "c": "register c",
    "i": "register i",
    MODE_IMMEDIATE: "immediate #$nn",
    MODE_ABSOLUTE: "absolute $nnnn",
    MODE_ABSOLUTE_INDEXED: "absolute indexed $nnnn,i",
    MODE_INDIRECT: "indirect ($nnnn)",
    MODE_INDIRECT_INDEXED: "indirect indexed ($nnnn),i",
    **{bit: f"bit {bit}" for bit in BIT_MODES},
}


@dataclass(frozen=True)
class Instruction:
    """One instruction from the specification and its opcode per addressing mode."""

    mnemonic: str
    name: str
    flags: str
    effect: str
    opcodes: Mapping[str, str]


def _mode_opcode_map(modes: Sequence[str], opcodes: Sequence[str]) -> dict[str, str]:
    if len(modes) != len(opcodes):
        raise ValueError("The number of addressing modes must match the number of opcodes.")
    return dict(zip(modes, opcodes))


def _alu_modes(*opcodes: str) -> dict[str, str]:
    """Map the specification's standard 7-mode operand list (b, c, imd, abs,
    abs,i, (ind), (ind),i) to the given opcodes, in that order."""
    modes = ("b", "c", MODE_IMMEDIATE, MODE_ABSOLUTE, MODE_ABSOLUTE_INDEXED,
             MODE_INDIRECT, MODE_INDIRECT_INDEXED)
    return _mode_opcode_map(modes, opcodes)


def _shift_modes(*opcodes: str) -> dict[str, str]:
    """Map the shift/rotate operand list (a, b, c, abs, abs,i, (ind), (ind),i)."""
    modes = ("a", "b", "c", MODE_ABSOLUTE, MODE_ABSOLUTE_INDEXED,
             MODE_INDIRECT, MODE_INDIRECT_INDEXED)
    return _mode_opcode_map(modes, opcodes)


def _step_modes(*opcodes: str) -> dict[str, str]:
    """Map the inc/dec operand list (a, b, c, i, abs, abs,i, (ind), (ind),i)."""
    modes = ("a", "b", "c", "i", MODE_ABSOLUTE, MODE_ABSOLUTE_INDEXED,
             MODE_INDIRECT, MODE_INDIRECT_INDEXED)
    return _mode_opcode_map(modes, opcodes)


def _load_modes(*opcodes: str) -> dict[str, str]:
    """Map the load operand list (imd, abs, abs,i, (ind), (ind),i)."""
    modes = (MODE_IMMEDIATE, MODE_ABSOLUTE, MODE_ABSOLUTE_INDEXED,
             MODE_INDIRECT, MODE_INDIRECT_INDEXED)
    return _mode_opcode_map(modes, opcodes)


def _store_modes(*opcodes: str) -> dict[str, str]:
    """Map the store operand list (abs, abs,i, (ind), (ind),i)."""
    modes = (MODE_ABSOLUTE, MODE_ABSOLUTE_INDEXED, MODE_INDIRECT, MODE_INDIRECT_INDEXED)
    return _mode_opcode_map(modes, opcodes)


def _implied(opcode: str) -> dict[str, str]:
    return {MODE_IMPLIED: opcode}


# Every instruction in the specification, in the order it lists them.
# Specification notes reproduced faithfully:
#   * The sbc table writes its (ind),i row as "sbd (ind),i A7"; it sits under the
#     sbc heading, so it is recorded as sbc (ind),i. No "sbd" mnemonic exists.
#   * The specification gives sec the same opcode (10) as clc.
INSTRUCTIONS: dict[str, Instruction] = {
    ins.mnemonic: ins
    for ins in (
        Instruction("adc", "add with carry", "ZC", "a = a + op + carry",
                    _alu_modes("01", "02", "03", "04", "05", "06", "07")),
        Instruction("and", "bitwise and", "Z", "a = a & op",
                    _alu_modes("21", "22", "23", "24", "25", "26", "27")),
        Instruction("asl", "arithmetic shift left", "ZC",
                    "reg/mem = reg/mem * 2; carry = bit 7 of reg/mem",
                    _shift_modes("B0", "B1", "B2", "B4", "B5", "B6", "B7")),
        Instruction("bit", "bit test", "C", "carry = bit n of a",
                    {bit: f"9{bit}" for bit in BIT_MODES}),
        Instruction("clc", "clear carry", "C", "carry = 0", _implied("10")),
        Instruction("cmp", "compare", "ZC",
                    "zero is set if a = op; carry is set if a >= op",
                    _alu_modes("F1", "F2", "F3", "F4", "F5", "F6", "F7")),
        Instruction("dec", "decrement", "Z", "reg/mem = reg/mem - 1",
                    _step_modes("F8", "F9", "FA", "FB", "FC", "FD", "FE", "FF")),
        Instruction("hlt", "halt", "", "halts the CPU", _implied("00")),
        Instruction("inc", "increment", "Z", "reg/mem = reg/mem + 1",
                    _step_modes("E8", "E9", "EA", "EB", "EC", "ED", "EE", "EF")),
        Instruction("jcc", "jump if carry clear", "", "pc = op if carry flag is clear",
                    {MODE_ABSOLUTE: "60"}),
        Instruction("jcs", "jump if carry set", "", "pc = op if carry flag is set",
                    {MODE_ABSOLUTE: "70"}),
        Instruction("jeq", "jump if equal", "", "pc = op if zero flag is set",
                    {MODE_ABSOLUTE: "40"}),
        Instruction("jmp", "jump", "", "pc = op",
                    {MODE_ABSOLUTE: "20", MODE_INDIRECT: "30"}),
        Instruction("jne", "jump if not equal", "", "pc = op if zero flag is clear",
                    {MODE_ABSOLUTE: "50"}),
        Instruction("jsr", "jump subroutine", "",
                    "old pc is pushed onto the stack and pc is set to the operand",
                    {MODE_ABSOLUTE: "80"}),
        Instruction("lda", "load accumulator", "Z", "a = op",
                    _load_modes("33", "34", "35", "36", "37")),
        Instruction("ldb", "load register b", "Z", "b = op",
                    _load_modes("43", "44", "45", "46", "47")),
        Instruction("ldc", "load register c", "Z", "c = op",
                    _load_modes("53", "54", "55", "56", "57")),
        Instruction("ldi", "load index register", "Z", "i = op",
                    {MODE_IMMEDIATE: "63", MODE_ABSOLUTE: "64", MODE_INDIRECT: "66"}),
        Instruction("lds", "load stack pointer", "",
                    "s = op (the immediate value is two bytes)",
                    {MODE_IMMEDIATE: "73"}),
        Instruction("lsr", "logical shift right", "ZC",
                    "reg/mem = reg/mem / 2; carry = bit 0 of reg/mem",
                    _shift_modes("C0", "C1", "C2", "C4", "C5", "C6", "C7")),
        Instruction("nop", "no operation", "", "does nothing", _implied("88")),
        Instruction("ora", "bitwise or", "Z", "a = a | op",
                    _alu_modes("81", "82", "83", "84", "85", "86", "87")),
        Instruction("pha", "push a", "", "a is pushed onto the stack", _implied("09")),
        Instruction("phb", "push b", "", "b is pushed onto the stack", _implied("19")),
        Instruction("phc", "push c", "", "c is pushed onto the stack", _implied("29")),
        Instruction("pla", "pull a", "", "a is popped from the stack", _implied("39")),
        Instruction("plb", "pull b", "", "b is popped from the stack", _implied("49")),
        Instruction("plc", "pull c", "", "c is popped from the stack", _implied("59")),
        Instruction("ret", "return", "", "pc is popped off of the stack", _implied("A0")),
        Instruction("rol", "rotate left", "ZC",
                    "bits move one position left; bit 0 = carry; carry = old bit 7",
                    _shift_modes("D0", "D1", "D2", "D4", "D5", "D6", "D7")),
        Instruction("ror", "rotate right", "ZC",
                    "bit 7 = carry; carry = old bit 0",
                    _shift_modes("E0", "E1", "E2", "E4", "E5", "E6", "E7")),
        Instruction("sbc", "subtract with carry", "ZC", "a = a - op - (1 - carry)",
                    _alu_modes("A1", "A2", "A3", "A4", "A5", "A6", "A7")),
        Instruction("sec", "set carry", "", "carry = 1", _implied("10")),
        Instruction("sta", "store a", "", "mem = a", _store_modes("DC", "DD", "DE", "DF")),
        Instruction("stb", "store b", "", "mem = b", _store_modes("CC", "CD", "CE", "CF")),
        Instruction("stc", "store c", "", "mem = c", _store_modes("BC", "BD", "BE", "BF")),
        Instruction("tab", "transfer a to b", "", "b = a", _implied("08")),
        Instruction("tac", "transfer a to c", "", "c = a", _implied("18")),
        Instruction("tai", "transfer a to i", "", "i = a", _implied("28")),
        Instruction("tba", "transfer b to a", "", "a = b", _implied("38")),
        Instruction("tbc", "transfer b to c", "", "c = b", _implied("48")),
        Instruction("tca", "transfer c to a", "", "a = c", _implied("58")),
        Instruction("tcb", "transfer c to b", "", "b = c", _implied("68")),
        Instruction("tia", "transfer i to a", "", "a = i", _implied("78")),
        Instruction("xor", "bitwise exclusive or", "Z", "a = a ^ op",
                    _alu_modes("11", "12", "13", "14", "15", "16", "17")),
    )
}

# Instruction categories. The specification lists instructions alphabetically
# without naming groups, so each instruction is grouped by the operation its
# own specification entry describes (load, store, transfer, push, pull, jump...).
INSTRUCTION_CATEGORIES: dict[str, tuple[str, ...]] = {
    "load_store": ("lda", "ldb", "ldc", "ldi", "lds", "sta", "stb", "stc"),
    "transfer": ("tab", "tac", "tai", "tba", "tbc", "tca", "tcb", "tia"),
    "arithmetic": ("adc", "sbc", "inc", "dec"),
    "logic": ("and", "ora", "xor"),
    "shift_rotate": ("asl", "lsr", "rol", "ror"),
    "compare_test": ("cmp", "bit"),
    "control_flow": ("jmp", "jcc", "jcs", "jeq", "jne", "jsr", "ret"),
    "stack": ("pha", "phb", "phc", "pla", "plb", "plc"),
    "processor_control": ("clc", "sec", "nop", "hlt"),
}

# Operand and lexical categories defined by the specification's operand syntax
# (examples: "lsr a", "xor #$01", "ora $1000", "lda $2002,i", "ldb ($0001)",
# "ldc ($FF00),i", "bit 0").
OPERAND_CATEGORIES: tuple[str, ...] = (
    "register",       # a, b, c, i (including the ",i" index suffix)
    "value",          # immediate values (#$nn) and bit numbers (0-7)
    "address",        # $nnnn memory addresses
    "io_address",     # addresses of the memory-mapped I/O bytes $9000-$9009
    "punctuation",    # # ( ) ,
)
UNRECOGNIZED_CATEGORY = "unrecognized"  # anything the specification does not define

CATEGORY_LABELS: dict[str, str] = {
    "load_store": "Load / store",
    "transfer": "Register transfer",
    "arithmetic": "Arithmetic",
    "logic": "Bitwise logic",
    "shift_rotate": "Shift / rotate",
    "compare_test": "Compare / bit test",
    "control_flow": "Jump / subroutine",
    "stack": "Stack",
    "processor_control": "Processor control",
    "register": "Register operand",
    "value": "Literal value",
    "address": "Memory address",
    "io_address": "I/O address",
    "punctuation": "Operand punctuation",
    UNRECOGNIZED_CATEGORY: "Not defined by the specification",
}

# Category -> color. One color per category; every element in a category uses it.
CATEGORY_COLORS: dict[str, str] = {
    "load_store": "#61afef",
    "transfer": "#4fc1d6",
    "arithmetic": "#ff9e64",
    "logic": "#e5c07b",
    "shift_rotate": "#c792ea",
    "compare_test": "#f472b6",
    "control_flow": "#ff6b81",
    "stack": "#98c379",
    "processor_control": "#eceff4",
    "register": "#a5b4fc",
    "value": "#c3e88d",
    "address": "#d7a37c",
    "io_address": "#5eead4",
    "punctuation": "#7f8794",
    UNRECOGNIZED_CATEGORY: "#ff4d5e",  # used as the underline color
}

# Font style per category: "bold", "italic" or "normal".
CATEGORY_FONT_STYLES: dict[str, str] = {
    **{category: "bold" for category in INSTRUCTION_CATEGORIES},
    "register": "italic",
}


def _build_command_category_map() -> dict[str, str]:
    """Return mnemonic -> category, verifying every instruction is in exactly one category."""
    mapping: dict[str, str] = {}
    for category, mnemonics in INSTRUCTION_CATEGORIES.items():
        for mnemonic in mnemonics:
            if mnemonic not in INSTRUCTIONS:
                raise ValueError(f"Category {category!r} lists unknown instruction {mnemonic!r}")
            if mnemonic in mapping:
                raise ValueError(f"Instruction {mnemonic!r} appears in two categories")
            mapping[mnemonic] = category
    missing = sorted(set(INSTRUCTIONS) - set(mapping))
    if missing:
        raise ValueError(f"Instructions without a category: {', '.join(missing)}")
    return mapping


COMMAND_CATEGORY: dict[str, str] = _build_command_category_map()

# Memory map from the specification (most specific ranges first).
MEMORY_MAP: tuple[tuple[int, int, str], ...] = (
    (0x9000, 0x9000, "Video select byte"),
    (0x9001, 0x9001, "Clock byte (ticks every 1/60 seconds)"),
    (0x9002, 0x9002, "Bell byte (bell sounds while non-zero)"),
    (0x9003, 0x9003, "ASCII code of last key pressed"),
    (0x9004, 0x9004, "Keyboard control byte (1 if any key is pressed)"),
    (0x9005, 0x9005, "Joystick 0 status byte (XXXUDLRC)"),
    (0x9006, 0x9006, "Joystick 1 status byte (XXXUDLRC)"),
    (0x9007, 0x9007, "Byte visible from tape"),
    (0x9008, 0x9008, "Tape counter (increments for every new visible byte)"),
    (0x9009, 0x9009, "Tape player on/off (zero for off)"),
    (0xFFFE, 0xFFFF, "System ROM - execution start address (little endian)"),
    (0x0000, 0x7FFF, "User RAM"),
    (0x8000, 0x895F, "VRAM"),
    (0xC000, 0xFFFF, "System ROM"),
)
IO_ADDRESS_RANGE = range(0x9000, 0x900A)


def describe_address(address: int) -> str | None:
    """Return the memory-map description for an address, if the specification defines one."""
    for start, end, description in MEMORY_MAP:
        if start <= address <= end:
            return description
    return None


# ============================================================================
# Lexical analysis (pure functions, shared by highlighting, hints and AI checks)
# ============================================================================


@dataclass(frozen=True)
class Token:
    """A highlighted span within one line (columns are character offsets)."""

    start: int
    end: int
    category: str


@dataclass(frozen=True)
class LineAnalysis:
    """The result of analyzing one source line against the specification."""

    tokens: tuple[Token, ...] = ()
    mnemonic: str | None = None
    mode: str | None = None
    opcode: str | None = None
    address: int | None = None
    problem: str | None = None


_MNEMONIC_RE = re.compile(r"([A-Za-z]+)(?=\s|$)")
_WORD_RE = re.compile(r"\S+")
_HEX_LITERAL = r"\$[0-9A-Fa-f]+"
# (mode, pattern, category of each group). "@address" is resolved per value.
_OPERAND_FORMS: tuple[tuple[str, re.Pattern[str], tuple[str, ...]], ...] = (
    (MODE_IMMEDIATE, re.compile(rf"(#)({_HEX_LITERAL})"), ("punctuation", "value")),
    (MODE_ABSOLUTE_INDEXED, re.compile(rf"({_HEX_LITERAL})(,)([iI])"),
     ("@address", "punctuation", "register")),
    (MODE_ABSOLUTE, re.compile(rf"({_HEX_LITERAL})"), ("@address",)),
    (MODE_INDIRECT_INDEXED, re.compile(rf"(\()({_HEX_LITERAL})(\))(,)([iI])"),
     ("punctuation", "@address", "punctuation", "punctuation", "register")),
    (MODE_INDIRECT, re.compile(rf"(\()({_HEX_LITERAL})(\))"),
     ("punctuation", "@address", "punctuation")),
)
_REGISTER_RE = re.compile(r"[abciABCI]")
_BIT_RE = re.compile(r"[0-7]")


@dataclass(frozen=True)
class _Operand:
    mode: str | None
    tokens: tuple[Token, ...]
    address: int | None = None
    problem: str | None = None


def _lex_operand(operand: str, offset: int, mnemonic: str | None) -> _Operand:
    """Classify one operand word (no internal whitespace) starting at column ``offset``."""
    end = offset + len(operand)
    if _REGISTER_RE.fullmatch(operand):
        return _Operand(operand.lower(), (Token(offset, end, "register"),))
    if _BIT_RE.fullmatch(operand):
        return _Operand(operand, (Token(offset, end, "value"),))
    for mode, pattern, group_categories in _OPERAND_FORMS:
        match = pattern.fullmatch(operand)
        if not match:
            continue
        tokens: list[Token] = []
        address: int | None = None
        problem: str | None = None
        for group_index, category in enumerate(group_categories, start=1):
            start, stop = match.span(group_index)
            text = match.group(group_index)
            if category == "@address":
                digits = text[1:]
                address = int(digits, 16)
                if len(digits) > 4:
                    problem = "Addresses must be 1-4 hex digits ($0000-$FFFF)."
                category = "io_address" if address in IO_ADDRESS_RANGE else "address"
            elif category == "value" and mode == MODE_IMMEDIATE:
                digits = text[1:]
                limit = 4 if mnemonic == "lds" else 2
                if len(digits) > limit:
                    problem = ("lds takes a two-byte immediate ($0000-$FFFF)." if limit == 4
                               else "Immediate values are one byte (#$00-#$FF).")
            tokens.append(Token(offset + start, offset + stop, category))
        return _Operand(mode, tuple(tokens), address, problem)
    return _Operand(None, (Token(offset, end, UNRECOGNIZED_CATEGORY),),
                    problem=f"'{operand}' is not an operand form defined by the specification.")


def _format_modes(instruction: Instruction) -> str:
    return ", ".join(ADDRESSING_MODE_DESCRIPTIONS.get(mode, mode) for mode in instruction.opcodes)


def analyze_line(line: str) -> LineAnalysis:
    """Tokenize and validate one line: ``mnemonic [operand]``, per the specification."""
    content_end = len(line.rstrip())
    lead = len(line) - len(line.lstrip())
    if lead >= content_end:
        return LineAnalysis()

    match = _MNEMONIC_RE.match(line, lead)
    if not match:
        return LineAnalysis(
            (Token(lead, content_end, UNRECOGNIZED_CATEGORY),),
            problem="This line is not an instruction defined by the specification.",
        )

    word = match.group(1)
    mnemonic = word.lower()
    mnemonic_start, mnemonic_end = match.span(1)
    instruction = INSTRUCTIONS.get(mnemonic)

    # Split the remainder into one operand word plus any unexpected trailing text.
    operand_start = mnemonic_end + (len(line[mnemonic_end:]) - len(line[mnemonic_end:].lstrip()))
    operand = ""
    trailing: tuple[int, int] | None = None
    operand_match = _WORD_RE.match(line, operand_start) if operand_start < content_end else None
    if operand_match:
        operand = operand_match.group(0)
        after = operand_match.end()
        trailing_start = after + (len(line[after:]) - len(line[after:].lstrip()))
        if trailing_start < content_end:
            trailing = (trailing_start, content_end)

    tokens: list[Token] = []
    problem: str | None = None
    mode: str | None = None
    opcode: str | None = None
    address: int | None = None

    if instruction is None:
        tokens.append(Token(mnemonic_start, mnemonic_end, UNRECOGNIZED_CATEGORY))
        problem = f"'{word}' is not an instruction defined by the specification."
        if operand:
            tokens.extend(_lex_operand(operand, operand_start, None).tokens)
    else:
        tokens.append(Token(mnemonic_start, mnemonic_end, COMMAND_CATEGORY[mnemonic]))
        if not operand:
            mode = MODE_IMPLIED
            if MODE_IMPLIED not in instruction.opcodes:
                tokens.append(Token(mnemonic_start, mnemonic_end, UNRECOGNIZED_CATEGORY))
                problem = f"{mnemonic} needs an operand: {_format_modes(instruction)}."
        else:
            lexed = _lex_operand(operand, operand_start, mnemonic)
            tokens.extend(lexed.tokens)
            mode, address, problem = lexed.mode, lexed.address, lexed.problem
            operand_end = operand_start + len(operand)
            if mode is not None and mode not in instruction.opcodes:
                if instruction.opcodes.keys() == {MODE_IMPLIED}:
                    problem = f"{mnemonic} takes no operand."
                else:
                    described = ADDRESSING_MODE_DESCRIPTIONS.get(mode, mode)
                    problem = (f"{mnemonic} does not support {described}. "
                               f"Supported: {_format_modes(instruction)}.")
            if problem and mode is not None:
                tokens.append(Token(operand_start, operand_end, UNRECOGNIZED_CATEGORY))
        if mode is not None and problem is None:
            opcode = instruction.opcodes.get(mode)

    if trailing:
        tokens.append(Token(trailing[0], trailing[1], UNRECOGNIZED_CATEGORY))
        problem = problem or "Unexpected text after the operand (the specification defines one operand per instruction)."

    return LineAnalysis(tuple(tokens), mnemonic if instruction else None, mode, opcode, address, problem)


def describe_line(analysis: LineAnalysis) -> str:
    """Build a one-line status-bar hint for an analyzed line."""
    if analysis.problem:
        return analysis.problem
    if not analysis.mnemonic:
        return ""
    instruction = INSTRUCTIONS[analysis.mnemonic]
    parts = [f"{instruction.mnemonic} - {instruction.name}", instruction.effect]
    if analysis.mode is not None:
        parts.append(f"{ADDRESSING_MODE_DESCRIPTIONS.get(analysis.mode, analysis.mode)}")
    if analysis.opcode is not None:
        parts.append(f"opcode {analysis.opcode}")
    if instruction.flags:
        parts.append(f"flags {instruction.flags}")
    if analysis.address is not None:
        region = describe_address(analysis.address)
        if region:
            parts.append(f"${analysis.address:04X}: {region}")
    return "  ·  ".join(parts)


# ============================================================================
# Pure helpers: text, environment, files, search and diffs
# ============================================================================


def count_lines(text: str) -> int:
    """Number of editor lines (matches the gutter; an empty document has one line)."""
    return text.count("\n") + 1


def parse_env_text(text: str) -> dict[str, str]:
    """Parse KEY=VALUE lines (``export`` prefix, quotes and # comments supported)."""
    values: dict[str, str] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        key, separator, value = line.partition("=")
        key = key.strip()
        if not separator or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        else:
            value = re.split(r"\s+#", value, maxsplit=1)[0].strip()
        values[key] = value
    return values


def load_api_key(env_path: Path = ENV_PATH) -> tuple[str | None, str | None]:
    """Return ``(api_key, problem)``, reading the key only from the .env file.

    The key starts as None and the .env file is re-read on every call, so edits
    take effect without a restart.
    """
    key: str | None = None
    try:
        key = parse_env_text(env_path.read_text(encoding="utf-8-sig")).get(GEMINI_KEY_VARIABLE, "").strip() or None
    except FileNotFoundError:
        return None, (f"No Gemini API key configured. Create {env_path} containing "
                      f"{GEMINI_KEY_VARIABLE}=<your key> (see {env_path.with_name('.env.example')}), then send again.")
    except (OSError, UnicodeDecodeError) as exc:
        return None, f"Could not read {env_path}: {exc.__class__.__name__}. Check the file and try again."
    if key is None:
        return None, (f"{GEMINI_KEY_VARIABLE} is not set. Open {env_path}, set {GEMINI_KEY_VARIABLE} "
                      f"to your Gemini API key, save the file, and send your message again.")
    return key, None


def load_specification(path: Path = SPECIFICATION_PATH) -> tuple[str | None, str | None]:
    """Read the language specification. Returns ``(text, problem)``; never substitutes another file."""
    try:
        text = path.read_text(encoding="utf-8-sig")
    except FileNotFoundError:
        return None, f"The language specification was not found at {path}."
    except (OSError, UnicodeDecodeError) as exc:
        return None, f"The language specification at {path} could not be read ({exc.__class__.__name__})."
    if not text.strip():
        return None, f"The language specification at {path} is empty."
    return text, None


_WINDOWS_RESERVED_NAMES = {"CON", "PRN", "AUX", "NUL", *(f"COM{n}" for n in range(1, 10)),
                           *(f"LPT{n}" for n in range(1, 10))}
_INVALID_FILENAME_CHARS = set('<>:"/\\|?*')


def validate_base_name(stem: str) -> str | None:
    """Return an error message if ``stem`` is not a valid base file name, else None."""
    if not stem:
        return "Enter a file name."
    if stem != stem.strip():
        return "The name cannot start or end with spaces."
    if stem in {".", ".."} or stem.endswith("."):
        return "The name cannot end with a period."
    bad = sorted({ch for ch in stem if ch in _INVALID_FILENAME_CHARS or ord(ch) < 32})
    if bad:
        shown = " ".join(repr(ch)[1:-1] for ch in bad)
        return f"The name contains characters that are not allowed in file names: {shown}"
    if stem.split(".")[0].upper() in _WINDOWS_RESERVED_NAMES:
        return f"'{stem}' is a reserved system name."
    if stem.lower().endswith(SOURCE_SUFFIX):
        return f"Leave out the {SOURCE_SUFFIX} extension; it is kept automatically."
    if len(stem) + len(SOURCE_SUFFIX) > 255:
        return "The name is too long."
    return None


def is_source_path(path: Path) -> bool:
    return path.suffix.lower() == SOURCE_SUFFIX


def with_source_suffix(path: Path) -> Path:
    """Ensure a save path uses the .s extension (appending it when missing)."""
    return path if is_source_path(path) else path.with_name(path.name + SOURCE_SUFFIX)


def read_source_file(path: Path) -> tuple[str, str]:
    """Read a source file. Returns ``(text_with_lf_newlines, newline_style)``."""
    with open(path, "r", encoding="utf-8-sig", newline="") as handle:
        raw = handle.read()
    newline = "\r\n" if "\r\n" in raw else "\n"
    return raw.replace("\r\n", "\n").replace("\r", "\n"), newline


def write_source_file(path: Path, text: str, newline: str = "\n") -> None:
    """Write a source file atomically (temp file + replace) so a failed save never truncates it."""
    data = text.replace("\n", newline) if newline != "\n" else text
    descriptor, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
    except BaseException:
        try:
            os.unlink(temp_name)
        except OSError:
            pass
        raise


def rename_source_file(old: Path, new: Path) -> None:
    """Rename ``old`` to ``new`` without overwriting a different existing file."""
    if new.exists() and not os.path.samefile(old, new):
        raise FileExistsError(f"A file named '{new.name}' already exists in this folder.")
    os.rename(old, new)


def find_matches(text: str, query: str, match_case: bool) -> list[tuple[int, int, int]]:
    """Find plain-text occurrences of ``query``. Returns ``(line, start_col, end_col)`` tuples."""
    if not query:
        return []
    pattern = re.compile(re.escape(query), 0 if match_case else re.IGNORECASE)
    matches: list[tuple[int, int, int]] = []
    for line_number, line in enumerate(text.split("\n"), start=1):
        for match in pattern.finditer(line):
            matches.append((line_number, match.start(), match.end()))
    return matches


@dataclass(frozen=True)
class DiffRow:
    """One row of a rendered diff: kind is 'hunk', 'context', 'added' or 'removed'."""

    kind: str
    old_line: int | None
    new_line: int | None
    text: str


@dataclass(frozen=True)
class ChangeSummary:
    added: int
    removed: int
    modified: int

    def describe(self) -> str:
        parts = []
        if self.modified:
            parts.append(f"{self.modified} modified")
        if self.added:
            parts.append(f"{self.added} added")
        if self.removed:
            parts.append(f"{self.removed} removed")
        if not parts:
            return "no line changes"
        return ", ".join(parts) + " line(s)"


def summarize_changes(old: str, new: str) -> ChangeSummary:
    """Count added, removed and modified lines between two versions."""
    matcher = difflib.SequenceMatcher(None, old.split("\n"), new.split("\n"), autojunk=False)
    added = removed = modified = 0
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "insert":
            added += j2 - j1
        elif tag == "delete":
            removed += i2 - i1
        elif tag == "replace":
            old_count, new_count = i2 - i1, j2 - j1
            modified += min(old_count, new_count)
            added += max(0, new_count - old_count)
            removed += max(0, old_count - new_count)
    return ChangeSummary(added, removed, modified)


def build_diff_rows(old: str, new: str, context: int = 3) -> list[DiffRow]:
    """Build unified-diff style rows with old/new line numbers."""
    old_lines, new_lines = old.split("\n"), new.split("\n")
    matcher = difflib.SequenceMatcher(None, old_lines, new_lines, autojunk=False)
    rows: list[DiffRow] = []
    for group in matcher.get_grouped_opcodes(context):
        first, last = group[0], group[-1]
        old_start, old_end = first[1], last[2]
        new_start, new_end = first[3], last[4]
        rows.append(DiffRow("hunk", None, None,
                            f"@@ -{old_start + 1},{old_end - old_start} +{new_start + 1},{new_end - new_start} @@"))
        for tag, i1, i2, j1, j2 in group:
            if tag == "equal":
                for offset in range(i2 - i1):
                    rows.append(DiffRow("context", i1 + offset + 1, j1 + offset + 1, old_lines[i1 + offset]))
                continue
            if tag in ("delete", "replace"):
                for index in range(i1, i2):
                    rows.append(DiffRow("removed", index + 1, None, old_lines[index]))
            if tag in ("insert", "replace"):
                for index in range(j1, j2):
                    rows.append(DiffRow("added", None, index + 1, new_lines[index]))
    return rows


def find_spec_problems(source: str, limit: int = 6) -> tuple[list[str], int]:
    """List lines that use syntax the specification does not define. Returns (examples, total)."""
    examples: list[str] = []
    total = 0
    for number, line in enumerate(source.split("\n"), start=1):
        problem = analyze_line(line).problem
        if problem:
            total += 1
            if len(examples) < limit:
                examples.append(f"Line {number}: {problem}")
    return examples, total


# ============================================================================
# Gemini API client (stdlib HTTPS) and response handling
# ============================================================================


class GeminiError(Exception):
    """A user-presentable Gemini failure. ``title`` is short; ``detail`` explains what to do."""

    def __init__(self, title: str, detail: str) -> None:
        super().__init__(f"{title}: {detail}")
        self.title = title
        self.detail = detail


def redact_secret(text: str, secret: str | None) -> str:
    """Remove an API key (and anything resembling a Google API key) from text."""
    if secret:
        text = text.replace(secret, "[redacted]")
    return re.sub(r"AIza[0-9A-Za-z_\-]{20,}", "[redacted]", text)


def gemini_error_from_http(status: int, body: str, retry_after: str | None, model: str) -> GeminiError:
    """Translate an HTTP error from the Gemini API into a helpful message."""
    message, api_status = "", ""
    try:
        error = json.loads(body).get("error", {})
        message = str(error.get("message", "")).strip()
        api_status = str(error.get("status", ""))
    except (ValueError, AttributeError):
        pass
    message = message[:400]
    key_hint = f"Check {GEMINI_KEY_VARIABLE} in {ENV_PATH.name}."
    if status == 400 and ("api key" in message.lower() or "API_KEY" in body):
        return GeminiError("API key rejected", f"Gemini did not accept the API key. {key_hint}")
    if status in (401, 403):
        return GeminiError("Not authorized",
                           f"Gemini refused the request ({api_status or status}). The API key may be invalid, "
                           f"restricted, or lack access to {model}. {key_hint}"
                           + (f"\nDetails: {message}" if message else ""))
    if status == 404:
        return GeminiError("Model unavailable",
                           f"The model '{model}' was not found or is not available to this API key. "
                           "The IDE does not switch to a different model automatically; confirm that your "
                           f"key has access to {model}." + (f"\nDetails: {message}" if message else ""))
    if status == 429:
        wait = f" Try again in about {retry_after} seconds." if retry_after else " Wait a moment and try again."
        return GeminiError("Rate limit reached", "Gemini's rate limit or quota for this key was exceeded." + wait)
    if status >= 500:
        return GeminiError("Gemini service error",
                           f"The Gemini service returned HTTP {status}. This is usually temporary; try again shortly.")
    return GeminiError(f"Request rejected (HTTP {status})", message or "Gemini rejected the request.")


_BLOCKING_FINISH_REASONS = {"SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII",
                            "IMAGE_SAFETY", "LANGUAGE"}


def extract_response_text(payload: object) -> str:
    """Pull the answer text out of a generateContent response, rejecting unusable responses."""
    if not isinstance(payload, dict):
        raise GeminiError("Malformed response", "Gemini returned data in an unexpected format.")
    feedback = payload.get("promptFeedback")
    if isinstance(feedback, dict) and feedback.get("blockReason"):
        raise GeminiError("Request blocked", f"Gemini blocked the request ({feedback['blockReason']}). "
                                             "Try rephrasing your message.")
    candidates = payload.get("candidates")
    if not isinstance(candidates, list) or not candidates or not isinstance(candidates[0], dict):
        raise GeminiError("Empty response", "Gemini returned no answer. Try sending the message again.")
    candidate = candidates[0]
    finish_reason = str(candidate.get("finishReason", ""))
    content = candidate.get("content")
    parts = content.get("parts") if isinstance(content, dict) else None
    texts = []
    if isinstance(parts, list):
        texts = [part["text"] for part in parts
                 if isinstance(part, dict) and isinstance(part.get("text"), str) and not part.get("thought")]
    text = "".join(texts).strip()
    if finish_reason == "MAX_TOKENS":
        raise GeminiError("Response cut off", "Gemini's answer exceeded the output limit. "
                                              "Try asking for a smaller change.")
    if not text:
        if finish_reason in _BLOCKING_FINISH_REASONS:
            raise GeminiError("Response blocked", f"Gemini withheld its answer ({finish_reason}).")
        raise GeminiError("Empty response", "Gemini returned an empty answer. Try sending the message again.")
    return text


class GeminiClient:
    """Minimal client for the Gemini ``generateContent`` REST endpoint."""

    def __init__(self, model: str = GEMINI_MODEL, timeout: float = GEMINI_TIMEOUT_SECONDS) -> None:
        self.model = model
        self.timeout = timeout

    def generate(self, api_key: str, system_instruction: str, contents: list[dict],
                 response_schema: dict) -> str:
        """Send one request and return the response text. Raises GeminiError on failure.

        The key is sent in the ``x-goog-api-key`` header (never in the URL) so it
        cannot leak through error messages that include the request URL.
        """
        body = {
            "systemInstruction": {"parts": [{"text": system_instruction}]},
            "contents": contents,
            "generationConfig": {
                "responseMimeType": "application/json",
                "responseJsonSchema": response_schema,
            },
        }
        request = urllib.request.Request(
            f"{GEMINI_API_ROOT}/models/{self.model}:generateContent",
            data=json.dumps(body).encode("utf-8"),
            method="POST",
            headers={"Content-Type": "application/json", "x-goog-api-key": api_key},
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                raw = response.read()
        except urllib.error.HTTPError as exc:
            try:
                error_body = exc.read().decode("utf-8", errors="replace")
            except OSError:
                error_body = ""
            error = gemini_error_from_http(exc.code, error_body, exc.headers.get("Retry-After"), self.model)
            raise GeminiError(error.title, redact_secret(error.detail, api_key)) from None
        except urllib.error.URLError as exc:
            reason = redact_secret(str(exc.reason), api_key)
            raise GeminiError("Network error", f"Could not reach the Gemini API ({reason}). "
                                               "Check your internet connection.") from None
        except TimeoutError:
            raise GeminiError("Request timed out", f"Gemini did not respond within "
                                                   f"{int(self.timeout)} seconds. Try again.") from None
        except OSError as exc:
            raise GeminiError("Network error", redact_secret(str(exc), api_key)) from None
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise GeminiError("Malformed response", "Gemini returned a response that is not valid JSON.") from None
        return extract_response_text(payload)


ASSISTANT_RESPONSE_SCHEMA: dict = {
    "type": "object",
    "properties": {
        "kind": {
            "type": "string",
            "enum": ["answer", "edit"],
            "description": "'edit' only when the user asked to change the current file; otherwise 'answer'.",
        },
        "message": {
            "type": "string",
            "description": "The reply shown to the user. For edits, a concise explanation of the changes.",
        },
        "source": {
            "type": "string",
            "description": "For 'edit': the COMPLETE new file content. For 'answer': an empty string.",
        },
    },
    "required": ["kind", "message", "source"],
}


@dataclass(frozen=True)
class AssistantReply:
    kind: str  # "answer" or "edit"
    message: str
    source: str | None = None


_CONTROL_CHARS_RE = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")
_FENCED_RE = re.compile(r"\A```[^\n]*\n(?P<body>.*?)\n?```\s*\Z", re.DOTALL)


def parse_assistant_reply(text: str) -> AssistantReply:
    """Validate the model's structured reply. Raises ValueError with a user-facing reason."""
    candidate = text.strip()
    fenced = _FENCED_RE.match(candidate)
    if fenced:
        candidate = fenced.group("body")
    try:
        data = json.loads(candidate)
    except ValueError:
        raise ValueError("The assistant's reply was not valid JSON.") from None
    if not isinstance(data, dict):
        raise ValueError("The assistant's reply was not a JSON object.")
    kind, message, source = data.get("kind"), data.get("message"), data.get("source", "")
    if kind not in ("answer", "edit"):
        raise ValueError("The assistant's reply had an unknown kind.")
    if not isinstance(message, str):
        raise ValueError("The assistant's reply had no message.")
    message = message.strip()
    if kind == "answer":
        return AssistantReply("answer", message or "(The assistant returned an empty answer.)")
    if not isinstance(source, str):
        raise ValueError("The proposed edit did not contain the file source as text.")
    source = source.replace("\r\n", "\n").replace("\r", "\n")
    fenced_source = _FENCED_RE.match(source.strip())
    if fenced_source:
        source = fenced_source.group("body") + ("\n" if source.endswith("\n") else "")
    if not source.strip():
        raise ValueError("The proposed edit was empty, so it was rejected.")
    if len(source) > MAX_PROPOSED_SOURCE_CHARS:
        raise ValueError("The proposed edit was unreasonably large, so it was rejected.")
    if _CONTROL_CHARS_RE.search(source):
        raise ValueError("The proposed edit contained control characters, so it was rejected.")
    return AssistantReply("edit", message or "Proposed changes to the current file.", source)


# ============================================================================
# Iterative fixing: proposed edits are checked locally and sent back to Gemini until they assemble
# ============================================================================


def find_program_errors(source: str, limit: int = 20) -> list[str]:
    """Problems that stop a proposed program from being valid: specification violations, then assembler errors."""
    examples, total = find_spec_problems(source, limit)
    if total > len(examples):
        examples.append(f"...and {total - len(examples)} more lines with the same kinds of problems.")
    if examples:
        return examples
    try:
        parse_code(source)
    except ValueError as exc:
        return [f"Assembler: {exc}"]
    return []


def build_fix_message(errors: Sequence[str]) -> str:
    listed = "\n".join(f"- {error}" for error in errors)
    return ("[Automatic check by the IDE, not written by the user] Your proposed program has these problems:\n"
            f"{listed}\n\n"
            "Fix every one of them and reply with kind \"edit\" and the COMPLETE corrected file. Use only what the "
            "specification defines, recompute any jump or subroutine addresses that move, and keep everything "
            "else that already works. In \"message\", explain the original change as well as these fixes.")


def build_system_instruction(spec_text: str) -> str:
    """The assistant's standing instructions, including the full language specification."""
    return f"""You are the coding assistant built into {APP_NAME}, a desktop editor for programs written in the
Project Trinity assembly language. Users write programs, usually games, in .s files and ask you to explain
instructions, write programs, debug syntax and logic, and improve their games.

The specification between the <specification> tags is the ONLY authoritative definition of the language and
hardware. Never invent instructions, addressing modes, registers, flags, directives, labels, comment syntax,
data definitions or hardware features it does not define. If a request cannot be expressed with what the
specification defines, say so and suggest the closest valid approach.

How the IDE reads source files (derived from the specification's examples):
- One instruction per line: a mnemonic optionally followed by exactly one operand, separated by whitespace.
- Operand forms: a, b, c or i (register); #$hh (immediate, one byte; lds takes two bytes, #$hhhh);
  $hhhh (abs); $hhhh,i (abs,i); ($hhhh) ((ind)); ($hhhh),i ((ind),i); 0-7 (bit number for bit).
- Use only the addressing modes the specification lists for each instruction. Hex values use a $ prefix.
- The specification defines no comments, labels or directives, so programs use literal addresses and the
  IDE flags anything else as undefined. Put explanations in your message, never inside the source.
- The specification writes the sbc (ind),i row as "sbd (ind),i A7"; treat it as sbc. It also gives sec the
  same opcode as clc; mention this if it matters to the user's question.

<specification>
{spec_text.strip()}
</specification>

Reply with a JSON object containing "kind", "message" and "source":
- kind "answer": explanations, questions, reviews, advice and short snippets. "source" must be "".
  Use this whenever the user did not ask you to change the file, and when a request is ambiguous
  (ask a clarifying question instead of editing).
- kind "edit": only when the user asks you to change, fix, write or extend the current file. "source" must be
  the COMPLETE new content of the file (not a diff or fragment, no markdown fences). Keep everything the user
  did not ask to change. "message" briefly explains what changed and why. The user reviews a diff before
  anything is applied.
In "message" you may use ``` fences for code and `backticks` for inline code."""


@dataclass
class ChatTurn:
    role: str  # "user" or "model"
    text: str
    attached_source: str | None = None
    attachment_label: str = ""


@dataclass
class AssistantRequest:
    """Everything a background worker needs for one Gemini call (an immutable snapshot)."""

    system_instruction: str
    contents: list[dict]
    user_turn: ChatTurn
    base_source: str
    document_id: int


class AssistantSession:
    """Conversation history and request construction for the Gemini assistant.

    To avoid resending redundant context, the editor source is attached only when
    it changed since it was last shared, and only the newest attached copy is kept
    verbatim in the history sent to the API.
    """

    MAX_TURNS = 16
    MAX_HISTORY_CHARS = 150_000

    def __init__(self) -> None:
        self.turns: list[ChatTurn] = []

    def prepare(self, message: str, source: str, file_label: str, has_unsaved_changes: bool,
                spec_text: str, document_id: int) -> AssistantRequest:
        latest_attachment = next((turn.attached_source for turn in reversed(self.turns)
                                  if turn.attached_source is not None), None)
        state = "unsaved changes" if has_unsaved_changes else "saved"
        label = f"{file_label} ({count_lines(source)} lines, {state})"
        attached = None if latest_attachment == source else source
        user_turn = ChatTurn("user", message, attached, label)
        contents = self._render([*self.turns, user_turn])
        return AssistantRequest(build_system_instruction(spec_text), contents, user_turn, source, document_id)

    def commit(self, user_turn: ChatTurn, model_text: str) -> None:
        """Record a successful exchange and trim old history."""
        self.turns.extend([user_turn, ChatTurn("model", model_text)])
        while len(self.turns) > self.MAX_TURNS or (
                len(self.turns) > 2 and sum(len(t.text) + len(t.attached_source or "") for t in self.turns)
                > self.MAX_HISTORY_CHARS):
            del self.turns[:2]

    @staticmethod
    def _render(turns: Sequence[ChatTurn]) -> list[dict]:
        newest_attachment = max((index for index, turn in enumerate(turns) if turn.attached_source is not None),
                                default=-1)
        contents = []
        for index, turn in enumerate(turns):
            text = turn.text
            if turn.role == "user":
                if index == newest_attachment:
                    text += (f"\n\n[Current editor file: {turn.attachment_label}]\n"
                             f"<current_source>\n{turn.attached_source}\n</current_source>")
                elif turn.attached_source is not None:
                    text += f"\n\n[Editor file {turn.attachment_label} was attached here; superseded by a newer copy.]"
                elif index == len(turns) - 1:
                    text += (f"\n\n[Current editor file: {turn.attachment_label}. Its content is unchanged "
                             "since the copy shared earlier in this conversation.]")
            contents.append({"role": turn.role, "parts": [{"text": text}]})
        return contents


@dataclass
class EditProposal:
    """An AI-proposed edit awaiting the user's review."""

    base_source: str
    proposed_source: str
    message: str
    document_id: int
    summary: ChangeSummary = field(init=False)
    rows: list[DiffRow] = field(init=False)
    problems: list[str] = field(init=False)
    problem_count: int = field(init=False)
    state: str = "pending"  # "pending", "applied" or "discarded"

    def __post_init__(self) -> None:
        self.summary = summarize_changes(self.base_source, self.proposed_source)
        self.rows = build_diff_rows(self.base_source, self.proposed_source)
        self.problems, self.problem_count = find_spec_problems(self.proposed_source)


# ============================================================================
# Theme, fonts and small reusable widgets
# ============================================================================

THEME: dict[str, str] = {
    "window": "#16181d",
    "toolbar": "#1b1e24",
    "panel": "#1b1e24",
    "border": "#2a2f38",
    "editor_bg": "#1f2329",
    "editor_fg": "#d4d8df",
    "gutter_fg": "#4f5663",
    "gutter_active": "#b4bac4",
    "current_line": "#252a32",
    "selection": "#2e4a6e",
    "selection_inactive": "#29323f",
    "cursor": "#e6e9ef",
    "text": "#d4d8df",
    "text_muted": "#8a919e",
    "text_faint": "#5d6470",
    "button_bg": "#262a32",
    "button_hover": "#30353f",
    "button_pressed": "#3a404b",
    "button_disabled_fg": "#596070",
    "button_disabled_bg": "#21252b",
    "accent": "#3d7cf0",
    "accent_hover": "#5590ff",
    "accent_pressed": "#2f68d1",
    "accent_fg": "#ffffff",
    "warning": "#e8a948",
    "error": "#ff6b6b",
    "success": "#6fd08c",
    "input_bg": "#14161a",
    "search_match": "#4d4120",
    "search_current": "#9a7714",
    "code_bg": "#15171b",
    "inline_code_bg": "#2a2e36",
    "diff_add_bg": "#1c3426",
    "diff_add_fg": "#b9f0c8",
    "diff_del_bg": "#3a1e24",
    "diff_del_fg": "#ffbac3",
    "diff_hunk_bg": "#1f2738",
    "diff_hunk_fg": "#8fb4ff",
}


def pick_font_family(root: tk.Misc, candidates: Sequence[str], fallback: str) -> str:
    available = {name.lower(): name for name in tkfont.families(root)}
    for candidate in candidates:
        if candidate.lower() in available:
            return available[candidate.lower()]
    return fallback


@dataclass
class Fonts:
    ui: tkfont.Font
    ui_bold: tkfont.Font
    ui_small: tkfont.Font
    ui_title: tkfont.Font
    toggle: tkfont.Font
    code: tkfont.Font
    code_bold: tkfont.Font
    code_italic: tkfont.Font
    code_small: tkfont.Font

    @classmethod
    def create(cls, root: tk.Misc) -> Fonts:
        ui_family = pick_font_family(root, ("Segoe UI", "SF Pro Text", "Helvetica Neue", "Cantarell",
                                            "Ubuntu", "DejaVu Sans"),
                                     tkfont.nametofont("TkDefaultFont").actual("family"))
        code_family = pick_font_family(root, ("Cascadia Mono", "Cascadia Code", "Consolas", "JetBrains Mono",
                                              "SF Mono", "Menlo", "DejaVu Sans Mono", "Liberation Mono"),
                                       tkfont.nametofont("TkFixedFont").actual("family"))
        return cls(
            ui=tkfont.Font(root, family=ui_family, size=10),
            ui_bold=tkfont.Font(root, family=ui_family, size=10, weight="bold"),
            ui_small=tkfont.Font(root, family=ui_family, size=9),
            ui_title=tkfont.Font(root, family=ui_family, size=11, weight="bold"),
            toggle=tkfont.Font(root, family=ui_family, size=13),
            code=tkfont.Font(root, family=code_family, size=11),
            code_bold=tkfont.Font(root, family=code_family, size=11, weight="bold"),
            code_italic=tkfont.Font(root, family=code_family, size=11, slant="italic"),
            code_small=tkfont.Font(root, family=code_family, size=10),
        )


class Tooltip:
    """A small delayed tooltip for a widget."""

    def __init__(self, widget: tk.Widget, text: str, font: tkfont.Font) -> None:
        self.widget, self.text, self.font = widget, text, font
        self._after_id: str | None = None
        self._window: tk.Toplevel | None = None
        widget.bind("<Enter>", self._schedule, add="+")
        widget.bind("<Leave>", self._hide, add="+")
        widget.bind("<ButtonPress-1>", self._hide, add="+")

    def _schedule(self, _event: tk.Event | None = None) -> None:
        self._cancel()
        self._after_id = self.widget.after(600, self._show)

    def _cancel(self) -> None:
        if self._after_id:
            self.widget.after_cancel(self._after_id)
            self._after_id = None

    def _show(self) -> None:
        self._after_id = None
        if self._window or not self.widget.winfo_viewable():
            return
        self._window = tk.Toplevel(self.widget)
        self._window.wm_overrideredirect(True)
        tk.Label(self._window, text=self.text, font=self.font, bg="#0f1115", fg=THEME["text"],
                 padx=8, pady=4, bd=1, relief="solid", highlightthickness=0).pack()
        self._window.update_idletasks()
        x = self.widget.winfo_rootx() + self.widget.winfo_width() // 2 - self._window.winfo_reqwidth() // 2
        y = self.widget.winfo_rooty() + self.widget.winfo_height() + 6
        x = max(0, min(x, self.widget.winfo_screenwidth() - self._window.winfo_reqwidth() - 4))
        self._window.wm_geometry(f"+{x}+{y}")

    def _hide(self, _event: tk.Event | None = None) -> None:
        self._cancel()
        if self._window:
            self._window.destroy()
            self._window = None


class FlatButton(tk.Label):
    """A flat, keyboard-accessible button with hover, pressed, focus and disabled states."""

    VARIANTS = {
        "default": ("button_bg", "button_hover", "button_pressed", "text"),
        "primary": ("accent", "accent_hover", "accent_pressed", "accent_fg"),
        "ghost": ("panel", "button_hover", "button_pressed", "text_muted"),
    }

    def __init__(self, master: tk.Misc, text: str, command: Callable[[], object], fonts: Fonts,
                 variant: str = "default", tooltip: str | None = None, padx: int = 12, pady: int = 4,
                 surface: str = "toolbar", font: tkfont.Font | None = None) -> None:
        bg_key, self._hover_key, self._pressed_key, fg_key = self.VARIANTS[variant]
        if variant == "ghost":
            bg_key = surface
        self._bg_key, self._fg_key = bg_key, fg_key
        self._variant = variant
        self._command = command
        self._enabled = True
        self._hover = False
        self._pressed = False
        super().__init__(master, text=text, font=font or fonts.ui, padx=padx, pady=pady, bd=0, cursor="hand2",
                         takefocus=1, highlightthickness=1, highlightcolor=THEME["accent"],
                         highlightbackground=THEME[surface])
        self.bind("<Enter>", lambda _e: self._set_hover(True), add="+")
        self.bind("<Leave>", lambda _e: self._set_hover(False), add="+")
        self.bind("<ButtonPress-1>", self._on_press)
        self.bind("<ButtonRelease-1>", self._on_release)
        self.bind("<Return>", lambda _e: self.invoke())
        self.bind("<space>", lambda _e: self.invoke())
        self._tooltip = Tooltip(self, tooltip, fonts.ui_small) if tooltip else None
        self._refresh()

    @property
    def enabled(self) -> bool:
        return self._enabled

    def set_enabled(self, enabled: bool) -> None:
        if enabled != self._enabled:
            self._enabled = enabled
            self._pressed = False
            self._refresh()

    def set_text(self, text: str, tooltip: str | None = None) -> None:
        self.configure(text=text)
        if tooltip is not None and self._tooltip:
            self._tooltip.text = tooltip

    def invoke(self) -> str:
        if self._enabled:
            self._command()
        return "break"

    def _set_hover(self, hover: bool) -> None:
        self._hover = hover
        if not hover:
            self._pressed = False
        self._refresh()

    def _on_press(self, _event: tk.Event) -> None:
        if self._enabled:
            self._pressed = True
            self._refresh()

    def _on_release(self, event: tk.Event) -> None:
        was_pressed = self._pressed
        self._pressed = False
        self._refresh()
        inside = 0 <= event.x < self.winfo_width() and 0 <= event.y < self.winfo_height()
        if was_pressed and inside and self._enabled:
            self._command()

    def _refresh(self) -> None:
        if not self._enabled:
            disabled_bg = THEME[self._bg_key] if self._variant == "ghost" else THEME["button_disabled_bg"]
            self.configure(bg=disabled_bg, fg=THEME["button_disabled_fg"], cursor="arrow")
            return
        key = self._pressed_key if self._pressed else self._hover_key if self._hover else self._bg_key
        fg = THEME["text"] if self._variant == "ghost" and self._hover else THEME[self._fg_key]
        self.configure(bg=THEME[key], fg=fg, cursor="hand2")


def configure_ttk_styles(root: tk.Misc) -> None:
    """Dark, arrowless scrollbars that match the editor."""
    style = ttk.Style(root)
    try:
        style.theme_use("clam")
    except tk.TclError:
        return
    for orient in ("Vertical", "Horizontal"):
        name = f"Trinity.{orient}.TScrollbar"
        style.layout(name, [(f"{orient}.Scrollbar.trough", {
            "sticky": "ns" if orient == "Vertical" else "ew",
            "children": [(f"{orient}.Scrollbar.thumb", {"expand": "1", "sticky": "nswe"})],
        })])
        style.configure(name, troughcolor=THEME["editor_bg"], background="#363c47", bordercolor=THEME["editor_bg"],
                        lightcolor="#363c47", darkcolor="#363c47", gripcount=0, arrowsize=10, relief="flat")
        style.map(name, background=[("active", "#464e5b"), ("pressed", "#525b6a")],
                  lightcolor=[("active", "#464e5b")], darkcolor=[("active", "#464e5b")])


# ============================================================================
# Code editor: text widget with change tracking, gutter and highlighting
# ============================================================================

# Tcl proxy wrapped around the text widget's command. It reports the first line
# and number of inserted newlines of every insert/delete/replace (including those
# made by undo/redo), so highlighting can be updated incrementally. Errors from
# the real widget propagate normally and other subcommands pass straight through.
_TEXT_PROXY_PROC = "::trinity_text_proxy"
_TEXT_PROXY_BODY = r"""
    set op [lindex $args 0]
    if {$op ni {insert delete replace}} {
        return [uplevel 1 [list $orig {*}$args]]
    }
    set first [lindex [split [$orig index [lindex $args 1]] .] 0]
    set last_line [lindex [split [$orig index end-1c] .] 0]
    if {$first > $last_line} { set first $last_line }
    set result [uplevel 1 [list $orig {*}$args]]
    set newlines 0
    if {$op eq "insert"} {
        foreach {chars tags} [lrange $args 2 end] { incr newlines [regexp -all {\n} $chars] }
    } elseif {$op eq "replace"} {
        foreach {chars tags} [lrange $args 3 end] { incr newlines [regexp -all {\n} $chars] }
    }
    $callback $first $newlines
    return $result
"""


class CodeText(tk.Text):
    """A Text widget that notifies listeners which lines each edit touched."""

    def __init__(self, master: tk.Misc, **options: object) -> None:
        super().__init__(master, **options)
        self._edit_listeners: list[Callable[[int, int], None]] = []
        if not self.tk.call("info", "procs", _TEXT_PROXY_PROC):
            self.tk.call("proc", _TEXT_PROXY_PROC, "orig callback args", _TEXT_PROXY_BODY)
        self._original_command = self._w + "_original"
        self.tk.call("rename", self._w, self._original_command)
        callback = self.register(self._on_edit)
        self.tk.call("interp", "alias", "", self._w, "", _TEXT_PROXY_PROC, self._original_command, callback)

    def add_edit_listener(self, listener: Callable[[int, int], None]) -> None:
        self._edit_listeners.append(listener)

    def _on_edit(self, first_line: str, newlines: str) -> None:
        first, count = int(first_line), int(newlines)
        for listener in self._edit_listeners:
            listener(first, first + count)

    def destroy(self) -> None:
        try:
            self.tk.call("rename", self._w, "")
        except tk.TclError:
            pass
        super().destroy()


class LineNumberGutter(tk.Canvas):
    """Line numbers drawn beside the visible lines of a text widget."""

    PADDING = 12

    def __init__(self, master: tk.Misc, text: tk.Text, font: tkfont.Font) -> None:
        super().__init__(master, width=40, bg=THEME["editor_bg"], highlightthickness=0, bd=0, takefocus=0)
        self.text = text
        self.font = font
        self._width = 0

    def redraw(self) -> None:
        self.delete("all")
        last_line = int(self.text.index("end-1c").split(".")[0])
        width = self.font.measure("9" * max(3, len(str(last_line)))) + 2 * self.PADDING
        if width != self._width:
            self._width = width
            self.configure(width=width)
        current_line = int(self.text.index("insert").split(".")[0])
        ascent = self.font.metrics("ascent")
        index = self.text.index("@0,0")
        while True:
            info = self.text.dlineinfo(index)
            if info is None:
                break
            line_number = int(index.split(".")[0])
            top = info[1] + info[4] - ascent
            self.create_text(width - self.PADDING, top, anchor="ne", text=str(line_number), font=self.font,
                             fill=THEME["gutter_active"] if line_number == current_line else THEME["gutter_fg"])
            next_index = self.text.index(f"{line_number + 1}.0")
            if int(next_index.split(".")[0]) <= line_number:
                break
            index = next_index


class SyntaxHighlighter:
    """Applies the specification-driven token categories to the editor incrementally.

    The grammar is line-based, so only lines touched by an edit are re-tokenized.
    Large batches (file loads, big pastes) are processed in idle-time chunks.
    """

    CHUNK_LINES = 400

    def __init__(self, text: tk.Text, fonts: Fonts) -> None:
        self.text = text
        self._dirty: set[int] = set()
        self._full_pass_next = 0
        self._full_pass_end = 0
        self._after_id: str | None = None
        self.tag_names = {category: f"syntax.{category}" for category in CATEGORY_COLORS}
        for category, tag in self.tag_names.items():
            if category == UNRECOGNIZED_CATEGORY:
                text.tag_configure(tag, underline=True, underlinefg=CATEGORY_COLORS[category])
                continue
            style = CATEGORY_FONT_STYLES.get(category, "normal")
            font = {"bold": fonts.code_bold, "italic": fonts.code_italic}.get(style, fonts.code)
            text.tag_configure(tag, foreground=CATEGORY_COLORS[category], font=font)

    def mark_dirty(self, first_line: int, last_line: int) -> None:
        self._dirty.update(range(max(1, first_line), last_line + 1))
        self._schedule()

    def rehighlight_all(self) -> None:
        """Re-tokenize the whole document (used after loading a file)."""
        for tag in self.tag_names.values():
            self.text.tag_remove(tag, "1.0", "end")
        self._dirty.clear()
        self._full_pass_next = 1
        self._full_pass_end = int(self.text.index("end-1c").split(".")[0])
        self._schedule()

    def _schedule(self) -> None:
        if self._after_id is None:
            self._after_id = self.text.after_idle(self._process)

    def _process(self) -> None:
        self._after_id = None
        last_line = int(self.text.index("end-1c").split(".")[0])
        budget = self.CHUNK_LINES
        if self._dirty:
            for line_number in sorted(self._dirty)[:budget]:
                self._dirty.discard(line_number)
                if line_number <= last_line:
                    self._highlight_line(line_number, clear=True)
                budget -= 1
        while budget > 0 and self._full_pass_next and self._full_pass_next <= min(self._full_pass_end, last_line):
            self._highlight_line(self._full_pass_next, clear=False)
            self._full_pass_next += 1
            budget -= 1
        if self._full_pass_next > min(self._full_pass_end, last_line):
            self._full_pass_next = 0
        if self._dirty or self._full_pass_next:
            self._after_id = self.text.after(1, self._process)

    def _highlight_line(self, line_number: int, clear: bool) -> None:
        start, end = f"{line_number}.0", f"{line_number}.end"
        if clear:
            for tag in self.tag_names.values():
                self.text.tag_remove(tag, start, end)
        for token in analyze_line(self.text.get(start, end)).tokens:
            self.text.tag_add(self.tag_names[token.category],
                              f"{line_number}.{token.start}", f"{line_number}.{token.end}")


class CodeEditor(tk.Frame):
    """The editor area: line-number gutter, code text, scrollbars and highlighting."""

    def __init__(self, master: tk.Misc, fonts: Fonts) -> None:
        super().__init__(master, bg=THEME["editor_bg"])
        self.fonts = fonts
        self._change_listeners: list[Callable[[], None]] = []
        self._cursor_listeners: list[Callable[[], None]] = []
        self._change_pending = False
        self._cursor_pending = False

        self.text = CodeText(
            self, wrap="none", undo=True, maxundo=-1, autoseparators=True, font=fonts.code,
            bg=THEME["editor_bg"], fg=THEME["editor_fg"], insertbackground=THEME["cursor"], insertwidth=2,
            selectbackground=THEME["selection"], inactiveselectbackground=THEME["selection_inactive"],
            bd=0, highlightthickness=0, padx=10, pady=8, relief="flat",
            tabs=(fonts.code.measure(" " * INDENT_WIDTH),), exportselection=True,
        )
        self.gutter = LineNumberGutter(self, self.text, fonts.code)
        self.vscroll = ttk.Scrollbar(self, orient="vertical", command=self.text.yview,
                                     style="Trinity.Vertical.TScrollbar")
        self.hscroll = ttk.Scrollbar(self, orient="horizontal", command=self.text.xview,
                                     style="Trinity.Horizontal.TScrollbar")
        self.text.configure(yscrollcommand=self._on_yscroll, xscrollcommand=self.hscroll.set)

        self.gutter.grid(row=0, column=0, sticky="ns")
        self.text.grid(row=0, column=1, sticky="nsew")
        self.vscroll.grid(row=0, column=2, sticky="ns")
        self.hscroll.grid(row=1, column=1, sticky="ew")
        self.grid_rowconfigure(0, weight=1)
        self.grid_columnconfigure(1, weight=1)

        self.text.tag_configure("current_line", background=THEME["current_line"])
        self.highlighter = SyntaxHighlighter(self.text, fonts)
        self.text.tag_configure("search.match", background=THEME["search_match"])
        self.text.tag_configure("search.current", background=THEME["search_current"], foreground="#ffffff")
        self.text.tag_lower("current_line")
        self.text.tag_raise("sel")
        self.text.tag_configure("sel", foreground="")

        self.text.add_edit_listener(self._on_edit)
        self.text.bind("<Configure>", lambda _e: self.schedule_cursor_update(), add="+")
        for sequence in ("<KeyPress>", "<ButtonPress-1>", "<B1-Motion>", "<ButtonRelease-1>",
                         "<MouseWheel>", "<Button-4>", "<Button-5>"):
            self.text.bind(sequence, lambda _e: self.schedule_cursor_update(), add="+")
        self.text.bind("<Tab>", self._on_tab)
        self.text.bind("<Shift-Tab>", self._on_shift_tab)
        if self.tk.call("tk", "windowingsystem") == "x11":
            self.text.bind("<ISO_Left_Tab>", self._on_shift_tab)
        self.text.bind("<Return>", self._on_return)
        self.text.bind("<KP_Enter>", self._on_return)
        self.schedule_cursor_update()

    # --- content -----------------------------------------------------------

    def get_content(self) -> str:
        return self.text.get("1.0", "end-1c")

    def load_content(self, content: str) -> None:
        """Replace everything (e.g. when opening a file) and reset undo history."""
        self.text.delete("1.0", "end")
        self.text.insert("1.0", content)
        self.text.edit_reset()
        self.text.mark_set("insert", "1.0")
        self.text.see("1.0")
        self.highlighter.rehighlight_all()

    def replace_content_undoably(self, content: str) -> None:
        """Replace everything as a single undoable step (used for accepted AI edits)."""
        cursor_line = int(self.text.index("insert").split(".")[0])
        top_fraction = self.text.yview()[0]
        self.text.configure(autoseparators=False)
        try:
            self.text.edit_separator()
            self.text.delete("1.0", "end-1c")
            self.text.insert("1.0", content)
            self.text.edit_separator()
        finally:
            self.text.configure(autoseparators=True)
        self.text.mark_set("insert", f"{min(cursor_line, count_lines(content))}.0")
        self.text.yview_moveto(top_fraction)
        self.highlighter.rehighlight_all()

    def line_count(self) -> int:
        return int(self.text.index("end-1c").split(".")[0])

    def cursor_position(self) -> tuple[int, int]:
        line, column = self.text.index("insert").split(".")
        return int(line), int(column)

    def current_line_text(self) -> str:
        return self.text.get("insert linestart", "insert lineend")

    def focus_editor(self) -> None:
        self.text.focus_set()

    # --- listeners -----------------------------------------------------------

    def add_change_listener(self, listener: Callable[[], None]) -> None:
        """Called once (at idle time) after any batch of content changes."""
        self._change_listeners.append(listener)

    def add_cursor_listener(self, listener: Callable[[], None]) -> None:
        """Called once (at idle time) after cursor movement, scrolling or edits."""
        self._cursor_listeners.append(listener)

    def _on_edit(self, first_line: int, last_line: int) -> None:
        self.highlighter.mark_dirty(first_line, last_line)
        if not self._change_pending:
            self._change_pending = True
            self.after_idle(self._notify_change)
        self.schedule_cursor_update()

    def _notify_change(self) -> None:
        self._change_pending = False
        for listener in self._change_listeners:
            listener()

    def schedule_cursor_update(self) -> None:
        """Refresh the current-line highlight, gutter and cursor listeners at idle time."""
        if not self._cursor_pending:
            self._cursor_pending = True
            self.after_idle(self._notify_cursor)

    def _notify_cursor(self) -> None:
        self._cursor_pending = False
        self.text.tag_remove("current_line", "1.0", "end")
        self.text.tag_add("current_line", "insert linestart", "insert lineend+1c")
        self.gutter.redraw()
        for listener in self._cursor_listeners:
            listener()

    def _on_yscroll(self, first: str, last: str) -> None:
        self.vscroll.set(first, last)
        self.schedule_cursor_update()

    # --- indentation -------------------------------------------------------

    def _selected_lines(self) -> tuple[int, int] | None:
        ranges = self.text.tag_ranges("sel")
        if not ranges:
            return None
        first = int(self.text.index(ranges[0]).split(".")[0])
        last_index = self.text.index(ranges[1])
        last = int(last_index.split(".")[0])
        if last_index.endswith(".0") and last > first:
            last -= 1
        return first, last

    def _on_tab(self, _event: tk.Event) -> str:
        lines = self._selected_lines()
        if lines and lines[0] != lines[1]:
            for line in range(lines[0], lines[1] + 1):
                self.text.insert(f"{line}.0", " " * INDENT_WIDTH)
        else:
            if lines:
                self.text.delete("sel.first", "sel.last")
            column = int(self.text.index("insert").split(".")[1])
            self.text.insert("insert", " " * (INDENT_WIDTH - column % INDENT_WIDTH))
        self.text.see("insert")
        return "break"

    def _on_shift_tab(self, _event: tk.Event) -> str:
        lines = self._selected_lines()
        first, last = lines if lines else (self.cursor_position()[0],) * 2
        for line in range(first, last + 1):
            leading = self.text.get(f"{line}.0", f"{line}.{INDENT_WIDTH}")
            remove = len(leading) - len(leading.lstrip(" "))
            if leading.startswith("\t"):
                remove = 1
            if remove:
                self.text.delete(f"{line}.0", f"{line}.{remove}")
        return "break"

    def _on_return(self, _event: tk.Event) -> str:
        if self.text.tag_ranges("sel"):
            self.text.delete("sel.first", "sel.last")
        line_before_cursor = self.text.get("insert linestart", "insert")
        indent = line_before_cursor[: len(line_before_cursor) - len(line_before_cursor.lstrip(" \t"))]
        self.text.insert("insert", "\n" + indent)
        self.text.see("insert")
        return "break"


# ============================================================================
# Search bar
# ============================================================================


class SearchBar(tk.Frame):
    """Find-in-document bar: highlights every match and navigates between them."""

    MAX_HIGHLIGHTS = 20_000

    def __init__(self, master: tk.Misc, editor: CodeEditor, fonts: Fonts) -> None:
        super().__init__(master, bg=THEME["toolbar"], padx=10, pady=6)
        self.editor = editor
        self.fonts = fonts
        self.visible = False
        self.matches: list[tuple[int, int, int]] = []
        self.current = -1
        self._refresh_after: str | None = None
        self.query = tk.StringVar(self)
        self.match_case = False

        tk.Label(self, text="Find", font=fonts.ui, bg=THEME["toolbar"], fg=THEME["text_muted"]).pack(side="left")
        entry_frame = tk.Frame(self, bg=THEME["input_bg"], highlightthickness=1,
                               highlightbackground=THEME["border"], highlightcolor=THEME["accent"])
        entry_frame.pack(side="left", padx=(8, 6))
        self.entry = tk.Entry(entry_frame, textvariable=self.query, width=32, font=fonts.code_small, bd=0,
                              bg=THEME["input_bg"], fg=THEME["text"], insertbackground=THEME["cursor"],
                              selectbackground=THEME["selection"], highlightthickness=0, relief="flat")
        self.entry.pack(padx=6, pady=3)
        self.case_button = FlatButton(self, "Aa", self._toggle_case, fonts, variant="ghost", padx=6,
                                      tooltip="Match case", surface="toolbar")
        self.case_button.pack(side="left")
        self.count_label = tk.Label(self, text="", font=fonts.ui_small, bg=THEME["toolbar"], fg=THEME["text_muted"],
                                    width=14, anchor="w")
        self.count_label.pack(side="left", padx=(6, 4))
        self.prev_button = FlatButton(self, "↑", self.previous_match, fonts, variant="ghost", padx=8,
                                      tooltip="Previous match (Shift+Enter)", surface="toolbar")
        self.next_button = FlatButton(self, "↓", self.next_match, fonts, variant="ghost", padx=8,
                                      tooltip="Next match (Enter)", surface="toolbar")
        self.prev_button.pack(side="left")
        self.next_button.pack(side="left")
        FlatButton(self, "✕", self.hide, fonts, variant="ghost", padx=8, tooltip="Close (Esc)",
                   surface="toolbar").pack(side="right")

        self.query.trace_add("write", lambda *_: self.schedule_refresh(reset_position=True))
        self.entry.bind("<Return>", lambda _e: (self.next_match(), "break")[1])
        self.entry.bind("<KP_Enter>", lambda _e: (self.next_match(), "break")[1])
        self.entry.bind("<Shift-Return>", lambda _e: (self.previous_match(), "break")[1])
        self.entry.bind("<Escape>", lambda _e: (self.hide(), "break")[1])
        editor.text.bind("<Escape>", lambda _e: self.hide() if self.visible else None, add="+")
        self._update_controls()

    def show(self, before: tk.Widget) -> None:
        selection = self.editor.text.tag_ranges("sel")
        if selection:
            selected = self.editor.text.get(selection[0], selection[1])
            if selected and "\n" not in selected:
                self.query.set(selected)
        if not self.visible:
            self.pack(side="top", fill="x", before=before)
            self.visible = True
            self.schedule_refresh(reset_position=True)
        self.entry.focus_set()
        self.entry.select_range(0, "end")
        self.entry.icursor("end")

    def hide(self) -> None:
        if not self.visible:
            return
        self.visible = False
        if self._refresh_after:
            self.after_cancel(self._refresh_after)
            self._refresh_after = None
        self.pack_forget()
        self._clear_tags()
        self.matches, self.current = [], -1
        self.editor.focus_editor()

    def schedule_refresh(self, reset_position: bool = False) -> None:
        """Recompute matches shortly (debounced) after the query or document changes."""
        if not self.visible:
            return
        if self._refresh_after:
            self.after_cancel(self._refresh_after)
        self._refresh_after = self.after(120, lambda: self._refresh(reset_position))

    def _toggle_case(self) -> None:
        self.match_case = not self.match_case
        self.case_button.configure(fg=THEME["accent_hover"] if self.match_case else THEME["text_muted"])
        self.schedule_refresh(reset_position=True)

    def _clear_tags(self) -> None:
        self.editor.text.tag_remove("search.match", "1.0", "end")
        self.editor.text.tag_remove("search.current", "1.0", "end")

    def _refresh(self, reset_position: bool) -> None:
        """Recompute matches. The current match stays anchored where the previous one started
        (or at the cursor), so typing more of a query refines the match instead of skipping it."""
        self._refresh_after = None
        previous = self.matches[self.current] if 0 <= self.current < len(self.matches) else None
        anchor = previous[:2] if previous else self.editor.cursor_position()
        self.matches = find_matches(self.editor.get_content(), self.query.get(), self.match_case)
        self._clear_tags()
        text = self.editor.text
        for line, start, end in self.matches[: self.MAX_HIGHLIGHTS]:
            text.tag_add("search.match", f"{line}.{start}", f"{line}.{end}")
        self.current = next((i for i, match in enumerate(self.matches) if match[:2] >= anchor),
                            0 if self.matches else -1)
        self._show_current(move_cursor=reset_position)
        self._update_controls()

    def next_match(self) -> None:
        self._step(1)

    def previous_match(self) -> None:
        self._step(-1)

    def _step(self, delta: int) -> None:
        if self._refresh_after:  # apply a pending query change first
            self.after_cancel(self._refresh_after)
            self._refresh(reset_position=True)
            if delta > 0:
                return
        if not self.matches:
            self._update_controls()
            return
        self.current = (self.current + delta) % len(self.matches)
        self._show_current(move_cursor=True)
        self._update_controls()

    def _show_current(self, move_cursor: bool) -> None:
        text = self.editor.text
        text.tag_remove("search.current", "1.0", "end")
        if not 0 <= self.current < len(self.matches):
            return
        line, start, end = self.matches[self.current]
        text.tag_add("search.current", f"{line}.{start}", f"{line}.{end}")
        if move_cursor:
            text.mark_set("insert", f"{line}.{end}")
            text.see(f"{line}.{start}")
            self.editor.schedule_cursor_update()

    def _update_controls(self) -> None:
        has_query = bool(self.query.get())
        if not has_query:
            self.count_label.configure(text="", fg=THEME["text_muted"])
        elif not self.matches:
            self.count_label.configure(text="No matches", fg=THEME["error"])
        else:
            self.count_label.configure(text=f"{self.current + 1} of {len(self.matches)}", fg=THEME["text_muted"])
        for button in (self.prev_button, self.next_button):
            button.set_enabled(bool(self.matches))


# ============================================================================
# AI chat sidebar
# ============================================================================


class ChatSidebar(tk.Frame):
    """The collapsible assistant panel: transcript, multiline input and Send button."""

    def __init__(self, master: tk.Misc, fonts: Fonts, on_send: Callable[[str], None]) -> None:
        super().__init__(master, bg=THEME["panel"])
        self.fonts = fonts
        self._on_send = on_send
        self._busy = False
        self._busy_step = 0
        self._busy_after: str | None = None
        self._busy_text = "Waiting for Gemini"
        self._link_count = 0

        header = tk.Frame(self, bg=THEME["panel"], padx=12, pady=8)
        header.pack(side="top", fill="x")
        titles = tk.Frame(header, bg=THEME["panel"])
        titles.pack(side="left", fill="x", expand=True)
        tk.Label(titles, text="AI Assistant", font=fonts.ui_title, bg=THEME["panel"],
                 fg=THEME["text"], anchor="w").pack(fill="x")
        tk.Label(titles, text=GEMINI_MODEL, font=fonts.ui_small, bg=THEME["panel"],
                 fg=THEME["text_faint"], anchor="w").pack(fill="x")
        tk.Frame(self, bg=THEME["border"], height=1).pack(side="top", fill="x")

        # Input area (packed before the transcript so it keeps its height).
        composer = tk.Frame(self, bg=THEME["panel"], padx=10, pady=10)
        composer.pack(side="bottom", fill="x")
        self.busy_label = tk.Label(composer, text="", font=fonts.ui_small, bg=THEME["panel"],
                                   fg=THEME["accent_hover"], anchor="w")
        self.busy_label.pack(side="top", fill="x", pady=(0, 6))
        input_frame = tk.Frame(composer, bg=THEME["input_bg"], highlightthickness=1,
                               highlightbackground=THEME["border"], highlightcolor=THEME["accent"])
        input_frame.pack(side="top", fill="x")
        self.input = tk.Text(input_frame, height=4, wrap="word", font=fonts.ui, bd=0, padx=8, pady=6,
                             bg=THEME["input_bg"], fg=THEME["text"], insertbackground=THEME["cursor"],
                             selectbackground=THEME["selection"], highlightthickness=0, undo=True)
        self.input.pack(fill="x")
        footer = tk.Frame(composer, bg=THEME["panel"])
        footer.pack(side="top", fill="x", pady=(8, 0))
        tk.Label(footer, text="Enter to send · Shift+Enter for a new line", font=fonts.ui_small,
                 bg=THEME["panel"], fg=THEME["text_faint"]).pack(side="left")
        self.send_button = FlatButton(footer, "Send", self._submit, fonts, variant="primary", surface="panel")
        self.send_button.pack(side="right")
        tk.Frame(self, bg=THEME["border"], height=1).pack(side="bottom", fill="x")

        transcript_frame = tk.Frame(self, bg=THEME["panel"])
        transcript_frame.pack(side="top", fill="both", expand=True)
        self.transcript = tk.Text(transcript_frame, wrap="word", font=fonts.ui, bd=0, padx=12, pady=10,
                                  bg=THEME["panel"], fg=THEME["text"], highlightthickness=0, cursor="arrow",
                                  selectbackground=THEME["selection"], state="disabled", takefocus=0,
                                  spacing3=2)
        scrollbar = ttk.Scrollbar(transcript_frame, orient="vertical", command=self.transcript.yview,
                                  style="Trinity.Vertical.TScrollbar")
        self.transcript.configure(yscrollcommand=scrollbar.set)
        scrollbar.pack(side="right", fill="y")
        self.transcript.pack(side="left", fill="both", expand=True)
        self._configure_transcript_tags()

        self.input.bind("<Return>", self._on_return)
        self.input.bind("<KP_Enter>", self._on_return)
        self.input.bind("<Shift-Return>", self._on_shift_return)

    def _configure_transcript_tags(self) -> None:
        t, f = self.transcript, self.fonts
        t.tag_configure("speaker", font=f.ui_bold, spacing1=12, spacing3=3)
        t.tag_configure("speaker.user", foreground=THEME["accent_hover"])
        t.tag_configure("speaker.assistant", foreground=THEME["success"])
        t.tag_configure("speaker.error", foreground=THEME["error"])
        t.tag_configure("speaker.notice", foreground=THEME["text_muted"])
        t.tag_configure("body.user", foreground="#eef1f5")
        t.tag_configure("body.assistant", foreground=THEME["text"])
        t.tag_configure("body.error", foreground="#ffb4b4")
        t.tag_configure("body.notice", foreground=THEME["text_muted"], font=f.ui_small)
        t.tag_configure("code", font=f.code_small, background=THEME["code_bg"], lmargin1=8, lmargin2=8,
                        rmargin=8, spacing1=0, spacing3=0)
        t.tag_configure("inline_code", font=f.code_small, background=THEME["inline_code_bg"])
        t.tag_configure("bold", font=f.ui_bold)
        t.tag_configure("card", font=f.ui_small, foreground=THEME["text_muted"], spacing1=6)
        t.tag_configure("link", font=f.ui_bold, foreground=THEME["accent_hover"], underline=True)

    # --- input ---------------------------------------------------------------

    def _on_return(self, _event: tk.Event) -> str:
        self._submit()
        return "break"

    def _on_shift_return(self, _event: tk.Event) -> str:
        self.input.insert("insert", "\n")
        self.input.see("insert")
        return "break"

    def _submit(self) -> None:
        if self._busy:
            return
        message = self.input.get("1.0", "end-1c").strip()
        if not message:
            return
        self.input.delete("1.0", "end")
        self._on_send(message)

    def restore_input(self, message: str) -> None:
        """Put an unsent message back into the input box (after a failed request)."""
        if not self.input.get("1.0", "end-1c").strip():
            self.input.insert("1.0", message)

    def focus_input(self) -> None:
        self.input.focus_set()

    def set_busy(self, busy: bool) -> None:
        self._busy = busy
        self.send_button.set_enabled(not busy)
        if self._busy_after:
            self.after_cancel(self._busy_after)
            self._busy_after = None
        if busy:
            self._busy_step = 0
            self._busy_text = "Waiting for Gemini"
            self._animate_busy()
        else:
            self.busy_label.configure(text="")

    def set_busy_text(self, text: str) -> None:
        self._busy_text = text

    def _animate_busy(self) -> None:
        dots = "." * (self._busy_step % 4)
        self.busy_label.configure(text=f"●  {self._busy_text}{dots}")
        self._busy_step += 1
        self._busy_after = self.after(400, self._animate_busy)

    # --- transcript ----------------------------------------------------------

    def add_message(self, role: str, text: str, speaker: str | None = None) -> None:
        """Append a message. ``role`` is 'user', 'assistant', 'error' or 'notice'."""
        label = speaker or {"user": "You", "assistant": "Assistant", "error": "Error", "notice": "IDE"}[role]
        self._write(lambda: self._insert_message(role, label, text))

    def add_edit_card(self, summary: str, on_review: Callable[[], None]) -> None:
        """Append a 'Review proposed changes' link for an AI edit."""
        self._link_count += 1
        tag = f"link{self._link_count}"

        def insert() -> None:
            t = self.transcript
            t.insert("end", f"Proposed edit: {summary}.  ", ("card",))
            t.insert("end", "Review changes", ("card", "link", tag))
            t.insert("end", "\n", ("card",))

        self._write(insert)
        self.transcript.tag_bind(tag, "<Button-1>", lambda _e: on_review())
        self.transcript.tag_bind(tag, "<Enter>", lambda _e: self.transcript.configure(cursor="hand2"))
        self.transcript.tag_bind(tag, "<Leave>", lambda _e: self.transcript.configure(cursor="arrow"))

    def _write(self, action: Callable[[], None]) -> None:
        self.transcript.configure(state="normal")
        try:
            action()
        finally:
            self.transcript.configure(state="disabled")
        self.transcript.see("end")

    def _insert_message(self, role: str, speaker: str, text: str) -> None:
        t = self.transcript
        t.insert("end", speaker + "\n", ("speaker", f"speaker.{role}"))
        body = f"body.{role}"
        segments = re.split(r"```[^\n]*\n?(.*?)```", text, flags=re.DOTALL) if role == "assistant" else [text]
        for index, segment in enumerate(segments):
            if index % 2 == 1:
                code = segment.rstrip("\n")
                if code:
                    t.insert("end", code + "\n", (body, "code"))
                continue
            segment = segment.strip("\n")
            if not segment:
                continue
            if role != "assistant":
                t.insert("end", segment + "\n", (body,))
                continue
            for piece_index, piece in enumerate(re.split(r"(`[^`\n]+`|\*\*[^*\n]+\*\*)", segment)):
                if piece_index % 2 == 1 and piece.startswith("`"):
                    t.insert("end", piece[1:-1], (body, "inline_code"))
                elif piece_index % 2 == 1:
                    t.insert("end", piece[2:-2], (body, "bold"))
                elif piece:
                    t.insert("end", piece, (body,))
            t.insert("end", "\n", (body,))


# ============================================================================
# Dialogs: AI edit review and rename
# ============================================================================


class EditReviewDialog(tk.Toplevel):
    """Shows an AI edit as a diff so the user can apply or discard it."""

    def __init__(self, master: tk.Misc, proposal: EditProposal, fonts: Fonts,
                 on_apply: Callable[[EditProposal], bool], on_discard: Callable[[EditProposal], None]) -> None:
        super().__init__(master, bg=THEME["panel"])
        self.proposal = proposal
        self._on_apply = on_apply
        self._on_discard = on_discard
        self.title("Review proposed changes")
        self.geometry("920x620")
        self.minsize(560, 360)
        self.transient(master)

        header = tk.Frame(self, bg=THEME["panel"], padx=16, pady=12)
        header.pack(side="top", fill="x")
        tk.Label(header, text="Review proposed changes", font=fonts.ui_title, bg=THEME["panel"],
                 fg=THEME["text"], anchor="w").pack(fill="x")
        summary = proposal.summary
        chips = tk.Frame(header, bg=THEME["panel"])
        chips.pack(fill="x", pady=(6, 0))
        for count, label, color in ((summary.modified, "modified", THEME["warning"]),
                                    (summary.added, "added", THEME["success"]),
                                    (summary.removed, "removed", THEME["error"])):
            tk.Label(chips, text=f"{count} {label}", font=fonts.ui_small, bg=THEME["button_bg"], fg=color,
                     padx=8, pady=2).pack(side="left", padx=(0, 6))
        tk.Label(chips, text="lines  ·  Nothing changes until you apply, and nothing is saved automatically.",
                 font=fonts.ui_small, bg=THEME["panel"], fg=THEME["text_faint"]).pack(side="left", padx=(4, 0))

        message = tk.Text(header, height=min(6, max(2, proposal.message.count("\n") + 2)), wrap="word",
                          font=fonts.ui, bg=THEME["panel"], fg=THEME["text"], bd=0, highlightthickness=0,
                          padx=0, pady=8)
        message.insert("1.0", proposal.message)
        message.configure(state="disabled")
        message.pack(fill="x")
        if proposal.problem_count:
            more = proposal.problem_count - len(proposal.problems)
            warning = ("Warning: the proposed code contains syntax the specification does not define:\n  "
                       + "\n  ".join(proposal.problems) + (f"\n  …and {more} more line(s)." if more > 0 else ""))
            tk.Label(header, text=warning, font=fonts.ui_small, bg=THEME["panel"], fg=THEME["warning"],
                     justify="left", anchor="w").pack(fill="x")

        footer = tk.Frame(self, bg=THEME["panel"], padx=16, pady=12)
        footer.pack(side="bottom", fill="x")
        tk.Frame(self, bg=THEME["border"], height=1).pack(side="bottom", fill="x")
        if proposal.state == "pending":
            self.apply_button = FlatButton(footer, "Apply to editor", self._apply, fonts, variant="primary",
                                           surface="panel", tooltip="Replace the editor content (Ctrl+Z undoes)")
            self.apply_button.pack(side="right")
            FlatButton(footer, "Discard", self._discard, fonts, surface="panel").pack(side="right", padx=(0, 8))
        else:
            tk.Label(footer, text=f"This proposal was {proposal.state}.", font=fonts.ui, bg=THEME["panel"],
                     fg=THEME["text_muted"]).pack(side="left")
            FlatButton(footer, "Close", self.destroy, fonts, surface="panel").pack(side="right")

        body = tk.Frame(self, bg=THEME["editor_bg"])
        body.pack(side="top", fill="both", expand=True)
        diff = tk.Text(body, wrap="none", font=fonts.code_small, bg=THEME["editor_bg"], fg=THEME["text_muted"],
                       bd=0, highlightthickness=0, padx=8, pady=6, selectbackground=THEME["selection"])
        vscroll = ttk.Scrollbar(body, orient="vertical", command=diff.yview, style="Trinity.Vertical.TScrollbar")
        hscroll = ttk.Scrollbar(body, orient="horizontal", command=diff.xview, style="Trinity.Horizontal.TScrollbar")
        diff.configure(yscrollcommand=vscroll.set, xscrollcommand=hscroll.set)
        diff.grid(row=0, column=0, sticky="nsew")
        vscroll.grid(row=0, column=1, sticky="ns")
        hscroll.grid(row=1, column=0, sticky="ew")
        body.grid_rowconfigure(0, weight=1)
        body.grid_columnconfigure(0, weight=1)
        diff.tag_configure("added", background=THEME["diff_add_bg"], foreground=THEME["diff_add_fg"])
        diff.tag_configure("removed", background=THEME["diff_del_bg"], foreground=THEME["diff_del_fg"])
        diff.tag_configure("hunk", background=THEME["diff_hunk_bg"], foreground=THEME["diff_hunk_fg"],
                           spacing1=4, spacing3=4)
        diff.tag_configure("context", foreground=THEME["text_muted"])
        for row in proposal.rows:
            if row.kind == "hunk":
                diff.insert("end", row.text + "\n", ("hunk",))
                continue
            old = "" if row.old_line is None else str(row.old_line)
            new = "" if row.new_line is None else str(row.new_line)
            sign = {"added": "+", "removed": "-", "context": " "}[row.kind]
            diff.insert("end", f"{old:>5} {new:>5}  {sign} {row.text}\n", (row.kind,))
        if not proposal.rows:
            diff.insert("end", "The proposal is identical to the current file.\n")
        diff.configure(state="disabled")

        self.bind("<Escape>", lambda _e: self._close())
        self.protocol("WM_DELETE_WINDOW", self._close)
        self.after_idle(self._center_and_grab)

    def _center_and_grab(self) -> None:
        master = self.master
        self.update_idletasks()
        x = master.winfo_rootx() + (master.winfo_width() - self.winfo_width()) // 2
        y = master.winfo_rooty() + (master.winfo_height() - self.winfo_height()) // 3
        self.geometry(f"+{max(0, x)}+{max(0, y)}")
        try:
            self.grab_set()
        except tk.TclError:
            pass
        self.focus_set()

    def _apply(self) -> None:
        if self._on_apply(self.proposal):
            self.destroy()

    def _discard(self) -> None:
        self._on_discard(self.proposal)
        self.destroy()

    def _close(self) -> None:
        # Closing leaves a pending proposal pending; it can be reopened from the chat.
        self.destroy()


class RenameDialog(tk.Toplevel):
    """Modal dialog for editing the base name of the current file (the extension is fixed)."""

    def __init__(self, master: tk.Misc, current: Path, fonts: Fonts) -> None:
        super().__init__(master, bg=THEME["panel"], padx=18, pady=16)
        self.result: str | None = None
        self._current = current
        self.title("Rename file")
        self.resizable(False, False)
        self.transient(master)

        tk.Label(self, text=f"Rename “{current.name}”", font=fonts.ui_title, bg=THEME["panel"],
                 fg=THEME["text"], anchor="w").pack(fill="x")
        tk.Label(self, text="The extension stays the same.", font=fonts.ui_small, bg=THEME["panel"],
                 fg=THEME["text_faint"], anchor="w").pack(fill="x", pady=(2, 10))
        row = tk.Frame(self, bg=THEME["input_bg"], highlightthickness=1, highlightbackground=THEME["border"],
                       highlightcolor=THEME["accent"])
        row.pack(fill="x")
        self.name_var = tk.StringVar(self, value=current.stem)
        self.entry = tk.Entry(row, textvariable=self.name_var, width=36, font=fonts.code_small, bd=0,
                              bg=THEME["input_bg"], fg=THEME["text"], insertbackground=THEME["cursor"],
                              selectbackground=THEME["selection"], highlightthickness=0)
        self.entry.pack(side="left", fill="x", expand=True, padx=(8, 0), pady=5)
        tk.Label(row, text=current.suffix, font=fonts.code_small, bg=THEME["input_bg"],
                 fg=THEME["text_muted"]).pack(side="left", padx=(0, 8))
        self.error_label = tk.Label(self, text="", font=fonts.ui_small, bg=THEME["panel"], fg=THEME["error"],
                                    anchor="w", justify="left", wraplength=360)
        self.error_label.pack(fill="x", pady=(6, 10))
        buttons = tk.Frame(self, bg=THEME["panel"])
        buttons.pack(fill="x")
        self.rename_button = FlatButton(buttons, "Rename", self._confirm, fonts, variant="primary", surface="panel")
        self.rename_button.pack(side="right")
        FlatButton(buttons, "Cancel", self.destroy, fonts, surface="panel").pack(side="right", padx=(0, 8))

        self.name_var.trace_add("write", lambda *_: self._validate())
        self.entry.bind("<Return>", lambda _e: self._confirm())
        self.bind("<Escape>", lambda _e: self.destroy())
        self._validate()
        self.entry.select_range(0, "end")
        self.entry.icursor("end")
        self.update_idletasks()
        x = master.winfo_rootx() + (master.winfo_width() - self.winfo_reqwidth()) // 2
        y = master.winfo_rooty() + (master.winfo_height() - self.winfo_reqheight()) // 3
        self.geometry(f"+{max(0, x)}+{max(0, y)}")
        self.entry.focus_set()
        try:
            self.grab_set()
        except tk.TclError:
            pass

    def _problem(self) -> str | None:
        stem = self.name_var.get()
        problem = validate_base_name(stem)
        if problem or stem == self._current.stem:
            return problem
        target = self._current.with_name(stem + self._current.suffix)
        try:
            if target.exists() and not os.path.samefile(self._current, target):
                return f"“{target.name}” already exists in this folder."
        except OSError:
            pass
        return None

    def _validate(self) -> None:
        problem = self._problem()
        self.error_label.configure(text=problem or "")
        self.rename_button.set_enabled(problem is None)

    def _confirm(self) -> None:
        if self._problem() is None:
            self.result = self.name_var.get()
            self.destroy()


# ============================================================================
# Document state
# ============================================================================


_document_serials = itertools.count(1)


@dataclass
class DocumentState:
    """The file behind the editor. ``saved_text`` is the content last read from or written to disk."""

    path: Path | None = None
    saved_text: str = ""
    newline: str = "\n"
    serial: int = field(default_factory=lambda: next(_document_serials))

    @property
    def display_name(self) -> str:
        return self.path.name if self.path else DEFAULT_FILE_NAME

    def is_modified(self, current_text: str) -> bool:
        return current_text != self.saved_text


# ============================================================================
# Main application window
# ============================================================================


class TrinityIDE(tk.Tk):
    """Main window: toolbar, collapsible assistant, editor, search and status bar."""

    DEFAULT_SIDEBAR_WIDTH = 380
    MIN_SIDEBAR_WIDTH = 260

    def __init__(self) -> None:
        super().__init__()
        self.title(APP_NAME)
        self.geometry("1240x780")
        self.minsize(820, 500)
        self.configure(bg=THEME["window"])
        self.fonts = Fonts.create(self)
        configure_ttk_styles(self)
        self.option_add("*Font", self.fonts.ui)

        self.document = DocumentState()
        self._modified = False
        self._status_after: str | None = None
        self._status_message: tuple[str, str] | None = None
        self._sidebar_width = self.DEFAULT_SIDEBAR_WIDTH
        self.spec_text, self.spec_error = load_specification()

        self.assistant = AssistantSession()
        self.gemini = GeminiClient()
        self._assistant_busy = False
        self._results: queue.Queue[tuple] = queue.Queue()
        self._review_dialog: EditReviewDialog | None = None

        self._build_toolbar()
        self._build_status_bar()
        self._build_workspace()
        self._bind_shortcuts()
        self.protocol("WM_DELETE_WINDOW", self.close_window)

        self.editor.add_change_listener(self._on_content_changed)
        self.editor.add_cursor_listener(self._update_status)
        self._refresh_document_ui()
        self._post_startup_notices()
        self.editor.focus_editor()

    # --- layout --------------------------------------------------------------

    def _build_toolbar(self) -> None:
        toolbar = tk.Frame(self, bg=THEME["toolbar"], padx=12, pady=8)
        toolbar.pack(side="top", fill="x")
        tk.Frame(self, bg=THEME["border"], height=1).pack(side="top", fill="x")

        # Buttons are packed first so they keep their space when the window is narrow.
        buttons = tk.Frame(toolbar, bg=THEME["toolbar"])
        buttons.pack(side="right")
        file_area = tk.Frame(toolbar, bg=THEME["toolbar"])
        file_area.pack(side="left", fill="x", expand=True)
        self.file_label = tk.Label(file_area, text="", font=self.fonts.ui_title, bg=THEME["toolbar"],
                                   fg=THEME["text"], anchor="w")
        self.file_label.pack(side="left")
        self.modified_label = tk.Label(file_area, text="", font=self.fonts.ui_small, bg=THEME["toolbar"],
                                       fg=THEME["warning"])
        self.modified_label.pack(side="left", padx=(10, 0))
        self.path_label = tk.Label(file_area, text="", font=self.fonts.ui_small, bg=THEME["toolbar"],
                                   fg=THEME["text_faint"], anchor="w")
        self.path_label.pack(side="left", padx=(12, 0), fill="x", expand=True)

        mod ="Cmd" if sys.platform == "darwin" else "Ctrl"
        self.open_button = FlatButton(buttons, "Open", self.open_document, self.fonts,
                                      tooltip=f"Open a .s file ({mod}+O)")
        self.rename_button = FlatButton(buttons, "Rename", self.rename_document, self.fonts,
                                        tooltip="Rename the current file")
        self.save_button = FlatButton(buttons, "Save", self.save_document, self.fonts,
                                      tooltip=f"Save changes ({mod}+S)")
        self.run_button = FlatButton(buttons, "▶  Run", self.run_current_file, self.fonts, variant="primary",
                                     tooltip="Save, then run this program")
        self.sidebar_button = FlatButton(buttons, "+", self.toggle_sidebar, self.fonts, padx=10, pady=0,
                                         tooltip="Open the AI assistant", font=self.fonts.toggle)
        for button in (self.open_button, self.rename_button, self.save_button, self.run_button,
                       self.sidebar_button):
            button.pack(side="left", padx=(6, 0))

    def _build_status_bar(self) -> None:
        bar = tk.Frame(self, bg=THEME["toolbar"], padx=12, pady=3)
        bar.pack(side="bottom", fill="x")
        tk.Frame(self, bg=THEME["border"], height=1).pack(side="bottom", fill="x")
        self.status_labels: dict[str, tk.Label] = {}
        for key in ("format", "newline", "lines", "cursor"):
            label = tk.Label(bar, text="", font=self.fonts.ui_small, bg=THEME["toolbar"], fg=THEME["text_muted"],
                             padx=8)
            label.pack(side="right")
            self.status_labels[key] = label
        self.status_labels["format"].configure(text="Trinity assembly")
        self.status_hint = tk.Label(bar, text="", font=self.fonts.ui_small, bg=THEME["toolbar"],
                                    fg=THEME["text_muted"], anchor="w")
        self.status_hint.pack(side="left", fill="x", expand=True)

    def _build_workspace(self) -> None:
        self.paned = tk.PanedWindow(self, orient="horizontal", bd=0, sashwidth=5, sashpad=0,
                                    bg=THEME["border"], sashrelief="flat", opaqueresize=True,
                                    sashcursor="sb_h_double_arrow")
        self.paned.pack(side="top", fill="both", expand=True)
        self.sidebar = ChatSidebar(self.paned, self.fonts, on_send=self.send_chat_message)
        self.editor_area = tk.Frame(self.paned, bg=THEME["editor_bg"])
        self.editor = CodeEditor(self.editor_area, self.fonts)
        self.search_bar = SearchBar(self.editor_area, self.editor, self.fonts)
        self.editor.pack(side="top", fill="both", expand=True)
        self.paned.add(self.editor_area, minsize=360, stretch="always")
        self.editor.add_change_listener(lambda: self.search_bar.schedule_refresh())

    # --- sidebar -------------------------------------------------------------

    def sidebar_is_open(self) -> bool:
        return str(self.sidebar) in {str(pane) for pane in self.paned.panes()}

    def toggle_sidebar(self) -> None:
        if self.sidebar_is_open():
            self.collapse_sidebar()
        else:
            self.open_sidebar()

    def open_sidebar(self) -> None:
        if not self.sidebar_is_open():
            self.paned.add(self.sidebar, after=self.editor_area, width=self._sidebar_width,
                           minsize=self.MIN_SIDEBAR_WIDTH, stretch="never")
        self.sidebar_button.set_text("−", tooltip="Collapse the AI assistant")
        self.sidebar.focus_input()

    def collapse_sidebar(self) -> None:
        if self.sidebar_is_open():
            width = self.sidebar.winfo_width()
            if width >= self.MIN_SIDEBAR_WIDTH:
                self._sidebar_width = width
            self.paned.forget(self.sidebar)  # the conversation lives on in the widget
        self.sidebar_button.set_text("+", tooltip="Open the AI assistant")
        self.editor.focus_editor()

    # --- shortcuts -----------------------------------------------------------

    def _bind_shortcuts(self) -> None:
        mod = "Command" if sys.platform == "darwin" else "Control"

        def command(action: Callable[[], object]) -> Callable[[tk.Event], str]:
            def handler(event: tk.Event) -> str:
                if not self._event_in_main_window(event):
                    return ""  # ignore app shortcuts typed into dialogs
                action()
                return "break"
            return handler

        app_actions: dict[str, Callable[[], object]] = {
            "s": self.save_document,
            "o": self.open_document,
            "f": self.show_search,
        }
        for key, action in app_actions.items():
            for keysym in (key, key.upper()):
                sequence = f"<{mod}-{keysym}>"
                self.bind_all(sequence, command(action))
                # Override class bindings (e.g. Text's Ctrl+O "open line") so shortcuts work everywhere.
                for widget_class in ("Text", "Entry"):
                    self.bind_class(widget_class, sequence, command(action))

        def select_all(event: tk.Event) -> str:
            widget = event.widget
            if isinstance(widget, tk.Text):
                widget.tag_add("sel", "1.0", "end-1c")
                widget.mark_set("insert", "end-1c")
            elif isinstance(widget, tk.Entry):
                widget.select_range(0, "end")
                widget.icursor("end")
            return "break"

        def undo(event: tk.Event) -> str:
            return self._edit_history(event.widget, "undo")

        def redo(event: tk.Event) -> str:
            return self._edit_history(event.widget, "redo")

        for keysym in ("a", "A"):
            for widget_class in ("Text", "Entry"):
                self.bind_class(widget_class, f"<{mod}-{keysym}>", select_all)
        for keysym in ("z", "Z"):
            self.bind_class("Text", f"<{mod}-{keysym}>", undo)
        for keysym in ("y", "Y"):
            self.bind_class("Text", f"<{mod}-{keysym}>", redo)
        self.bind_class("Text", f"<{mod}-Shift-Z>", redo)
        self.bind_class("Text", f"<{mod}-Shift-z>", redo)

    def _event_in_main_window(self, event: tk.Event) -> bool:
        try:
            return event.widget.winfo_toplevel() is self
        except (AttributeError, KeyError, tk.TclError):
            return False

    @staticmethod
    def _edit_history(widget: tk.Misc, action: str) -> str:
        if isinstance(widget, tk.Text) and str(widget.cget("state")) == "normal":
            try:
                if action == "undo":
                    widget.edit_undo()
                else:
                    widget.edit_redo()
            except tk.TclError:
                pass  # nothing to undo / redo
            widget.see("insert")
        return "break"

    def show_search(self) -> None:
        self.search_bar.show(before=self.editor)

    # --- document state ----------------------------------------------------

    def is_modified(self) -> bool:
        return self.document.is_modified(self.editor.get_content())

    def _on_content_changed(self) -> None:
        modified = self.is_modified()
        if modified != self._modified:
            self._modified = modified
            self._refresh_document_ui()
        self._update_status()

    def _refresh_document_ui(self) -> None:
        self._modified = self.is_modified()
        name = self.document.display_name
        self.file_label.configure(text=name)
        self.modified_label.configure(text="●  Unsaved changes" if self._modified else "")
        self.path_label.configure(text=str(self.document.path.parent) if self.document.path else "Not saved yet")
        # A file that has never been saved can always be saved, even before it is edited.
        self.save_button.set_enabled(self._modified or self.document.path is None)
        self.rename_button.set_enabled(self.document.path is not None)
        self.title(f"{'● ' if self._modified else ''}{name} — {APP_NAME}")
        self.status_labels["newline"].configure(text="CRLF" if self.document.newline == "\r\n" else "LF")
        self._update_status()

    def _update_status(self) -> None:
        line, column = self.editor.cursor_position()
        total = self.editor.line_count()
        self.status_labels["cursor"].configure(text=f"Ln {line}, Col {column + 1}")
        self.status_labels["lines"].configure(text=f"{total} line{'s' if total != 1 else ''}")
        if self._status_message:
            text, kind = self._status_message
            self.status_hint.configure(text=text, fg=THEME.get(kind, THEME["text_muted"]))
            return
        analysis = analyze_line(self.editor.current_line_text())
        self.status_hint.configure(text=describe_line(analysis),
                                   fg=THEME["warning"] if analysis.problem else THEME["text_muted"])

    def flash_status(self, text: str, kind: str = "text", seconds: float = 4.0) -> None:
        """Show a transient status message, then return to the cursor-line hint."""
        if self._status_after:
            self.after_cancel(self._status_after)
        self._status_message = (text, kind)
        self._update_status()

        def clear() -> None:
            self._status_after = None
            self._status_message = None
            self._update_status()

        self._status_after = self.after(int(seconds * 1000), clear)

    # --- file operations ---------------------------------------------------

    def confirm_unsaved_changes(self, action: str) -> bool:
        """Ask to save, discard or cancel when there are unsaved edits. Returns True to proceed."""
        if not self.is_modified():
            return True
        answer = messagebox.askyesnocancel(
            "Unsaved changes",
            f"“{self.document.display_name}” has unsaved changes.\n\nSave them before {action}?",
            icon="warning", parent=self)
        if answer is None:
            return False
        if answer:
            return self.save_document()
        return True

    def open_document(self) -> None:
        if not self.confirm_unsaved_changes("opening another file"):
            return
        initial_dir = str(self.document.path.parent) if self.document.path else str(APP_DIR)
        selected = filedialog.askopenfilename(parent=self, title="Open Trinity program",
                                              filetypes=SOURCE_FILETYPES, initialdir=initial_dir)
        if not selected:
            return
        path = Path(selected)
        if not is_source_path(path):
            messagebox.showerror("Open", f"Only {SOURCE_SUFFIX} files can be opened.\n\n{path.name}", parent=self)
            return
        try:
            content, newline = read_source_file(path)
        except UnicodeDecodeError:
            messagebox.showerror("Open", f"“{path.name}” is not a UTF-8 text file.", parent=self)
            return
        except OSError as exc:
            messagebox.showerror("Open", f"Could not read “{path.name}”.\n\n{exc.strerror or exc}", parent=self)
            return
        self.search_bar.hide()
        self.document = DocumentState(path=path, saved_text=content, newline=newline)
        self.editor.load_content(content)
        self._refresh_document_ui()
        self.editor.focus_editor()
        self.flash_status(f"Opened {path.name}")

    def save_document(self) -> bool:
        """Save to the current path (or ask for one). Returns True only if the content is on disk."""
        if self.document.path is None:
            return self.save_document_as()
        if not self.is_modified():
            return True
        return self._write_document(self.document.path)

    def save_document_as(self) -> bool:
        initial_dir = str(self.document.path.parent) if self.document.path else str(APP_DIR)
        selected = filedialog.asksaveasfilename(parent=self, title="Save Trinity program",
                                                filetypes=SOURCE_FILETYPES, defaultextension=SOURCE_SUFFIX,
                                                initialdir=initial_dir, initialfile=self.document.display_name)
        if not selected:
            return False
        path = with_source_suffix(Path(selected))
        if str(path) != selected and path.exists():
            if not messagebox.askyesno("Save", f"“{path.name}” already exists. Replace it?", icon="warning",
                                       parent=self):
                return False
        return self._write_document(path)

    def _write_document(self, path: Path) -> bool:
        content = self.editor.get_content()
        try:
            write_source_file(path, content, self.document.newline)
        except OSError as exc:
            messagebox.showerror("Save failed", f"Could not save “{path.name}”.\n\n{exc.strerror or exc}",
                                 parent=self)
            return False
        self.document.path = path
        self.document.saved_text = content
        self._refresh_document_ui()
        self.flash_status(f"Saved {path.name}", "success")
        return True

    def rename_document(self) -> None:
        path = self.document.path
        if path is None:
            messagebox.showinfo("Rename", "This program has not been saved yet.\n\n"
                                          "Save it first to give it a file name.", parent=self)
            return
        if not path.exists():
            messagebox.showerror("Rename", f"“{path.name}” no longer exists on disk.\n\n"
                                           "Save the program again before renaming it.", parent=self)
            return
        dialog = RenameDialog(self, path, self.fonts)
        self.wait_window(dialog)
        if dialog.result is None or dialog.result == path.stem:
            return
        new_path = path.with_name(dialog.result + path.suffix)
        try:
            rename_source_file(path, new_path)
        except FileExistsError as exc:
            messagebox.showerror("Rename", str(exc), parent=self)
            return
        except OSError as exc:
            messagebox.showerror("Rename", f"Could not rename “{path.name}”.\n\n{exc.strerror or exc}",
                                 parent=self)
            return
        self.document.path = new_path
        self._refresh_document_ui()
        self.flash_status(f"Renamed to {new_path.name}", "success")

    def close_window(self) -> None:
        if self.confirm_unsaved_changes("closing"):
            self.destroy()

    # --- run / assemble ------------------------------------------------------

    def run_current_file(self) -> None:
        """Save the current .s file, then ask the parser to write its .bin output."""
        if self.document.path is None:
            if not messagebox.askokcancel("Run", "This program has not been saved yet.\n\n"
                                                 "Save it as a .s file and run it?", parent=self):
                return
            if not self.save_document():
                return
        elif self.is_modified():
            if not messagebox.askokcancel(
                    "Run", f"“{self.document.display_name}” has unsaved changes.\n\n"
                           "The program must be saved before it can run. Save and run?", parent=self):
                return
            if not self.save_document():
                return

        path = self.document.path
        if path is None or self.is_modified():
            return
        if not is_source_path(path) or not path.is_file():
            messagebox.showerror("Run", f"“{path.name}” is not a saved {SOURCE_SUFFIX} file.", parent=self)
            return

        current_file_path = str(path)
        try:
            output_path = parse_file(current_file_path)
            self.flash_status(f"Assembled {Path(output_path).name}")
        except Exception as exc:  # assembly and file I/O errors are shown to the user
            self.flash_status(f"Run failed: {exc.__class__.__name__}", "error", seconds=8)
            messagebox.showerror("Assembly failed", f"Could not assemble “{path.name}”.\n\n{exc}", parent=self)

    # --- assistant -----------------------------------------------------------

    def _post_startup_notices(self) -> None:
        self.sidebar.add_message(
            "notice",
            "Ask about Trinity instructions, debug your program, or ask for changes to the open file. "
            "Proposed edits are shown as a diff for you to review before anything changes, and nothing "
            f"is saved automatically. Messages are sent to Google's Gemini API ({GEMINI_MODEL}) over the internet. "
            "Proposed edits are checked against the specification and the assembler, and Gemini is asked to "
            "fix any errors before you see them.")
        if self.spec_error:
            self.sidebar.add_message("error", self.spec_error + " The assistant needs it to understand the "
                                              "language. Restore the file and send your message again.")
            self.flash_status(self.spec_error, "error", seconds=12)
        _key, key_problem = load_api_key()
        if key_problem:
            self.sidebar.add_message("notice", key_problem, speaker="Setup")

    def send_chat_message(self, message: str) -> None:
        if self._assistant_busy:
            return
        self.sidebar.add_message("user", message)
        if self.spec_text is None:
            self.spec_text, self.spec_error = load_specification()
        if self.spec_text is None:
            self.sidebar.add_message("error", f"{self.spec_error} The assistant cannot help without it.")
            return
        api_key, key_problem = load_api_key()
        if api_key is None:
            self.sidebar.add_message("error", key_problem or "The Gemini API key is not configured.")
            self.sidebar.restore_input(message)
            return
        request = self.assistant.prepare(message, self.editor.get_content(), self.document.display_name,
                                         self.is_modified(), self.spec_text, self.document.serial)
        self._assistant_busy = True
        self.sidebar.set_busy(True)
        worker = threading.Thread(target=self._assistant_worker, args=(request, api_key, message), daemon=True)
        worker.start()
        self.after(80, self._poll_assistant)

    def _assistant_worker(self, request: AssistantRequest, api_key: str, message: str) -> None:
        """Runs off the Tk thread. Only touches the result queue, never widgets."""
        try:
            text = self.gemini.generate(api_key, request.system_instruction, request.contents,
                                        ASSISTANT_RESPONSE_SCHEMA)
            reply = parse_assistant_reply(text)
            if reply.kind == "edit":
                text, reply = self._fix_edit_iteratively(request, api_key, text, reply)
        except GeminiError as exc:
            self._results.put(("error", request, message, exc.title, exc.detail))
        except ValueError as exc:
            self._results.put(("error", request, message, "Unusable response",
                               f"{exc} The editor was not changed. Try sending the message again."))
        except Exception as exc:  # defensive: never let a worker die silently
            self._results.put(("error", request, message, "Unexpected error",
                               redact_secret(f"{exc.__class__.__name__}: {exc}", api_key)))
        else:
            self._results.put(("ok", request, message, text, reply))

    def _fix_edit_iteratively(self, request: AssistantRequest, api_key: str, text: str,
                              reply: AssistantReply) -> tuple[str, AssistantReply]:
        """Send a proposed edit's errors back to Gemini until it is clean or the rounds run out.

        Returns the raw model text (recorded in the history so later turns build on it) and the reply to show.
        A failed repair request keeps the last proposal rather than discarding it.
        """
        contents = list(request.contents)
        errors = find_program_errors(reply.source or "")
        rounds = 0
        while errors and rounds < GEMINI_MAX_FIX_ROUNDS:
            rounds += 1
            self._results.put(("progress", f"Gemini is fixing {len(errors)} problem(s), "
                                           f"pass {rounds}/{GEMINI_MAX_FIX_ROUNDS}"))
            contents += [{"role": "model", "parts": [{"text": text}]},
                         {"role": "user", "parts": [{"text": build_fix_message(errors)}]}]
            try:
                fixed_text = self.gemini.generate(api_key, request.system_instruction, contents,
                                                  ASSISTANT_RESPONSE_SCHEMA)
                fixed = parse_assistant_reply(fixed_text)
            except (GeminiError, ValueError) as exc:
                reason = f"{exc.title}: {exc.detail}" if isinstance(exc, GeminiError) else str(exc)
                note = f"Automatic fixing stopped ({reason}); the last proposal is shown with its problems."
                return text, AssistantReply("edit", f"{reply.message}\n\n{note}", reply.source)
            if fixed.kind != "edit":
                break
            text, reply = fixed_text, fixed
            errors = find_program_errors(reply.source or "")
        if rounds == 0:
            return text, reply
        if errors:
            note = (f"Gemini could not fix every problem in {rounds} automatic pass(es). Remaining:\n"
                    + "\n".join(f"- {error}" for error in errors))
        else:
            note = f"The IDE found errors in the first draft; Gemini fixed them in {rounds} automatic pass(es)."
        return text, AssistantReply("edit", f"{reply.message}\n\n{note}", reply.source)

    def _poll_assistant(self) -> None:
        try:
            result = self._results.get_nowait()
        except queue.Empty:
            self.after(80, self._poll_assistant)
            return
        if result[0] == "progress":
            self.sidebar.set_busy_text(result[1])
            self.after(80, self._poll_assistant)
            return
        self._assistant_busy = False
        self.sidebar.set_busy(False)
        status, request, message = result[0], result[1], result[2]
        if status == "error":
            title, detail = result[3], result[4]
            self.sidebar.add_message("error", f"{title}. {detail}")
            self.sidebar.restore_input(message)
            return
        raw_text, reply = result[3], result[4]
        self.assistant.commit(request.user_turn, raw_text)
        if reply.kind == "answer":
            self.sidebar.add_message("assistant", reply.message)
            return
        proposal = EditProposal(request.base_source, reply.source, reply.message, request.document_id)
        if not proposal.rows:
            self.sidebar.add_message("assistant", reply.message + "\n\n(The proposed file is identical to the "
                                                                  "current one, so there is nothing to apply.)")
            return
        self.sidebar.add_message("assistant", reply.message)
        self.sidebar.add_edit_card(proposal.summary.describe(), lambda: self.review_proposal(proposal))
        self.review_proposal(proposal)

    def review_proposal(self, proposal: EditProposal) -> None:
        if self._review_dialog is not None and self._review_dialog.winfo_exists():
            self._review_dialog.destroy()
        self._review_dialog = EditReviewDialog(self, proposal, self.fonts, self._apply_proposal,
                                               self._discard_proposal)

    def _apply_proposal(self, proposal: EditProposal) -> bool:
        if proposal.document_id != self.document.serial or self.editor.get_content() != proposal.base_source:
            messagebox.showwarning(
                "Cannot apply", "The editor has changed since this edit was proposed, so applying it could "
                                "overwrite your newer work.\n\nAsk the assistant again to get a proposal based "
                                "on the current code.", parent=self._review_dialog or self)
            return False
        self.editor.replace_content_undoably(proposal.proposed_source)
        proposal.state = "applied"
        self._on_content_changed()
        self.editor.focus_editor()
        self.flash_status("AI edit applied — review it, then save when ready (Ctrl+Z undoes it).", "success", 8)
        return True

    def _discard_proposal(self, proposal: EditProposal) -> None:
        proposal.state = "discarded"
        self.flash_status("AI edit discarded; the editor was not changed.")


def _enable_windows_dpi_awareness() -> None:
    """Render crisply on high-DPI Windows displays (no effect elsewhere)."""
    if sys.platform != "win32":
        return
    try:
        import ctypes
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except (AttributeError, OSError):
        pass


def main() -> None:
    _enable_windows_dpi_awareness()
    app = TrinityIDE()
    app.mainloop()


if __name__ == "__main__":
    main()
