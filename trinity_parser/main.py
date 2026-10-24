from __future__ import annotations

import os
import re
from typing import Protocol


class WritableMemory(Protocol):
    def load_bytes(self, addr: int, values: bytes) -> int: ...


_LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):(.*)$")
_LABEL_OPERAND_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_JUMP_MNEMONICS = {"jcc", "jcs", "jeq", "jne", "jmp", "jsr"}


# Opcode of every instruction for each addressing mode it supports (from specification.txt)
OPCODES = {
    'adc': {'b': '01', 'c': '02', 'imd': '03', 'abs': '04', 'abs,i': '05', '(ind)': '06', '(ind),i': '07'},
    'and': {'b': '21', 'c': '22', 'imd': '23', 'abs': '24', 'abs,i': '25', '(ind)': '26', '(ind),i': '27'},
    'asl': {'a': 'B0', 'b': 'B1', 'c': 'B2', 'abs': 'B4', 'abs,i': 'B5', '(ind)': 'B6', '(ind),i': 'B7'},
    'bit': {'0': '90', '1': '91', '2': '92', '3': '93', '4': '94', '5': '95', '6': '96', '7': '97'},
    'clc': {'imp': '10'},
    'cmp': {'b': 'F1', 'c': 'F2', 'imd': 'F3', 'abs': 'F4', 'abs,i': 'F5', '(ind)': 'F6', '(ind),i': 'F7'},
    'dec': {'a': 'F8', 'b': 'F9', 'c': 'FA', 'i': 'FB', 'abs': 'FC', 'abs,i': 'FD', '(ind)': 'FE', '(ind),i': 'FF'},
    'hlt': {'imp': '00'},
    'inc': {'a': 'E8', 'b': 'E9', 'c': 'EA', 'i': 'EB', 'abs': 'EC', 'abs,i': 'ED', '(ind)': 'EE', '(ind),i': 'EF'},
    'jcc': {'abs': '60'},
    'jcs': {'abs': '70'},
    'jeq': {'abs': '40'},
    'jmp': {'abs': '20', '(ind)': '30'},
    'jne': {'abs': '50'},
    'jsr': {'abs': '80'},
    'lda': {'imd': '33', 'abs': '34', 'abs,i': '35', '(ind)': '36', '(ind),i': '37'},
    'ldb': {'imd': '43', 'abs': '44', 'abs,i': '45', '(ind)': '46', '(ind),i': '47'},
    'ldc': {'imd': '53', 'abs': '54', 'abs,i': '55', '(ind)': '56', '(ind),i': '57'},
    'ldi': {'imd': '63', 'abs': '64', '(ind)': '66'},
    'lds': {'imd': '73'},
    'lsr': {'a': 'C0', 'b': 'C1', 'c': 'C2', 'abs': 'C4', 'abs,i': 'C5', '(ind)': 'C6', '(ind),i': 'C7'},
    'nop': {'imp': '88'},
    'ora': {'b': '81', 'c': '82', 'imd': '83', 'abs': '84', 'abs,i': '85', '(ind)': '86', '(ind),i': '87'},
    'pha': {'imp': '09'},
    'phb': {'imp': '19'},
    'phc': {'imp': '29'},
    'pla': {'imp': '39'},
    'plb': {'imp': '49'},
    'plc': {'imp': '59'},
    'ret': {'imp': 'A0'},
    'rol': {'a': 'D0', 'b': 'D1', 'c': 'D2', 'abs': 'D4', 'abs,i': 'D5', '(ind)': 'D6', '(ind),i': 'D7'},
    'ror': {'a': 'E0', 'b': 'E1', 'c': 'E2', 'abs': 'E4', 'abs,i': 'E5', '(ind)': 'E6', '(ind),i': 'E7'},
    'sbc': {'b': 'A1', 'c': 'A2', 'imd': 'A3', 'abs': 'A4', 'abs,i': 'A5', '(ind)': 'A6', '(ind),i': 'A7'},
    'sec': {'imp': 'F0'},
    'sta': {'abs': 'DC', 'abs,i': 'DD', '(ind)': 'DE', '(ind),i': 'DF'},
    'stb': {'abs': 'CC', 'abs,i': 'CD', '(ind)': 'CE', '(ind),i': 'CF'},
    'stc': {'abs': 'BC', 'abs,i': 'BD', '(ind)': 'BE', '(ind),i': 'BF'},
    'tab': {'imp': '08'},
    'tac': {'imp': '18'},
    'tai': {'imp': '28'},
    'tba': {'imp': '38'},
    'tbc': {'imp': '48'},
    'tca': {'imp': '58'},
    'tcb': {'imp': '68'},
    'tia': {'imp': '78'},
    'xor': {'b': '11', 'c': '12', 'imd': '13', 'abs': '14', 'abs,i': '15', '(ind)': '16', '(ind),i': '17'},
}


def map_little_endian(input_line: str, num_bytes: int = 2) -> str:
    # Values are written as $ followed by hex digits, or as plain decimal digits
    if input_line.startswith('$'):
        digits = input_line[1:]
        if not digits or any(d not in '0123456789abcdefABCDEF' for d in digits):
            raise ValueError(f"'{input_line}' is not a hex value like $1F")
        value = int(digits, 16)
    else:
        if not input_line or any(d not in '0123456789' for d in input_line):
            raise ValueError(f"'{input_line}' is not a hex value like $1F or a decimal value like 31")
        value = int(input_line)

    if value >= 256 ** num_bytes:
        raise ValueError(f"'{input_line}' does not fit in {num_bytes} byte(s)")

    # Least significant byte first
    return ''.join(f'{(value >> (8 * n)) & 0xFF:02X}' for n in range(num_bytes))


def get_mode(operand: str) -> tuple[str, str | None]:
    # Returns the addressing mode and the value still to be encoded (None if there is no value)
    lowered = operand.lower()
    if operand == '':
        return 'imp', None
    # Registers (a, b, c, i) and bit numbers (0-7)
    if len(lowered) == 1 and lowered in 'abci01234567':
        return lowered, None
    if lowered.startswith('#'):
        return 'imd', operand[1:]
    if lowered.startswith('(') and lowered.endswith('),i'):
        return '(ind),i', operand[1:-3]
    if lowered.startswith('(') and lowered.endswith(')'):
        return '(ind)', operand[1:-1]
    if lowered.endswith(',i'):
        return 'abs,i', operand[:-2]
    return 'abs', operand


def map_line(input_line: list[str]) -> str:
    # Blank line
    if not input_line:
        return ''

    mnemonic = input_line[0].lower()
    if mnemonic not in OPCODES:
        raise ValueError(f"'{input_line[0]}' is not an instruction")
    if len(input_line) > 2:
        raise ValueError(f"'{' '.join(input_line)}' has more than one operand")

    operand = input_line[1] if len(input_line) == 2 else ''
    mode, value = get_mode(operand)
    # A single digit is only a bit number for bit, otherwise it is a decimal address
    if mode.isdigit() and mnemonic != 'bit':
        mode, value = 'abs', operand
    opcodes = OPCODES[mnemonic]
    if mode not in opcodes:
        raise ValueError(f"'{mnemonic}' does not support the {mode} addressing mode "
                         f"(supported: {', '.join(opcodes)})")

    if value is None:
        return opcodes[mode]
    # Immediate values are one byte, except for lds which loads the 16 bit stack pointer
    if mode == 'imd' and mnemonic != 'lds':
        return opcodes[mode] + map_little_endian(value, 1)
    return opcodes[mode] + map_little_endian(value)


def _resolve_jump_label(instruction: str, labels: dict[str, int]) -> str:
    parts = instruction.split()
    if len(parts) != 2 or parts[0].lower() not in _JUMP_MNEMONICS:
        return instruction

    mode, value = get_mode(parts[1])
    if value is None or not _LABEL_OPERAND_RE.fullmatch(value):
        return instruction
    label_address = labels[value.lower()]
    address = f"${label_address:04X}"
    parts[1] = f"({address})" if mode == "(ind)" else address
    return " ".join(parts)


def parse_code(input: str, start_address: int = 0) -> str:
    """Assemble source text to machine-code hex, resolving jump labels."""
    if not 0 <= start_address <= 0xFFFF:
        raise ValueError("Start address must be between $0000 and $FFFF.")

    labels: dict[str, int] = {}
    instructions: list[tuple[int, str]] = []
    current_address = start_address

    for line_number, input_line in enumerate(input.splitlines(), start=1):
        stripped_line = input_line.split(';', 1)[0].strip()
        if not stripped_line:
            continue

        label_match = _LABEL_RE.match(stripped_line)
        if label_match:
            label = label_match.group(1).lower()
            if label in labels:
                raise ValueError(f"Line {line_number}: duplicate label '{label_match.group(1)}'.")
            if current_address > 0xFFFF:
                raise ValueError(f"Line {line_number}: label is outside the 16-bit address space.")
            labels[label] = current_address
            stripped_line = label_match.group(2).strip()
            if not stripped_line:
                continue

        provisional_instruction = stripped_line
        parts = stripped_line.split()
        if len(parts) == 2 and parts[0].lower() in _JUMP_MNEMONICS:
            mode, value = get_mode(parts[1])
            if value is not None and _LABEL_OPERAND_RE.fullmatch(value):
                parts[1] = "($0000)" if mode == "(ind)" else "$0000"
                provisional_instruction = " ".join(parts)

        try:
            instruction_length = len(map_line(provisional_instruction.split())) // 2
        except ValueError as exc:
            raise ValueError(f"Line {line_number}: {exc}") from exc

        instructions.append((line_number, stripped_line))
        current_address += instruction_length
        if current_address > 0x10000:
            raise ValueError(f"Line {line_number}: program exceeds the 16-bit address space.")

    output_lines = []
    for line_number, instruction in instructions:
        try:
            resolved_instruction = _resolve_jump_label(instruction, labels)
            output_lines.append(map_line(resolved_instruction.split()))
        except KeyError as exc:
            label = str(exc.args[0])
            raise ValueError(f"Line {line_number}: undefined label '{label}'.") from exc
        except ValueError as exc:
            raise ValueError(f"Line {line_number}: {exc}") from exc

    return ''.join(output_lines)


def parse_into_memory(input: str, memory: WritableMemory, start_address: int = 0) -> int:
    """Assemble source text and load its machine-code bytes into writable memory."""
    machine_code = bytes.fromhex(parse_code(input, start_address))
    return memory.load_bytes(start_address, machine_code)


def parse_file(source_path: str) -> str:
    """Assemble a source file, write its output in the project bin directory, and return its path."""
    source_path = os.path.abspath(source_path)
    if not os.path.isfile(source_path):
        raise FileNotFoundError(f"Source file not found: {source_path}")

    with open(source_path, encoding='utf-8') as source_file:
        machine_code = parse_code(source_file.read())

    project_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    output_dir = os.path.join(project_dir, 'bin')
    os.makedirs(output_dir, exist_ok=True)
    output_name = os.path.splitext(os.path.basename(source_path))[0] + '.bin'
    output_path = os.path.join(output_dir, output_name)
    with open(output_path, 'wb') as output_file:
        output_file.write(bytes.fromhex(machine_code))

    return output_path


if __name__ == '__main__':
    import sys

    if len(sys.argv) < 2:
        sys.exit(f"Usage: python {os.path.basename(__file__)} <source.s> [more.s ...]")

    for path in sys.argv[1:]:
        try:
            print(f"Assembled {path} -> {parse_file(path)}")
        except (OSError, ValueError) as exc:
            sys.exit(f"Could not assemble {path}: {exc}")
