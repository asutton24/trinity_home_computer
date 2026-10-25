from pathlib import Path
import sys

PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))

from trinity_parser.main import parse_code
from trinity_parser.main import parse_into_memory
from emulator.cpu import CPU
from emulator.memory import Memory


SOURCE = """\
lda #$2A
sta $1234
hlt
"""
EXPECTED_HEX = "332ADC341200"
LOAD_ADDRESS = 0x0000


def make_ram() -> Memory:
    memory = Memory()
    memory.add_bank(0x0000, 0x7FFF, "rw")
    return memory


def main() -> None:
    actual_hex = parse_code(SOURCE)
    memory = make_ram()
    byte_count = parse_into_memory(SOURCE, memory, LOAD_ADDRESS)
    expected_bytes = bytes.fromhex(EXPECTED_HEX)
    loaded_bytes = bytes(memory.read8(LOAD_ADDRESS + offset) for offset in range(byte_count))

    print("Example Trinity parser test")
    print("Input:")
    print(SOURCE, end="")
    print(f"Expected machine code: {EXPECTED_HEX}")
    print(f"Actual machine code:   {actual_hex}")
    assert actual_hex == EXPECTED_HEX, f"Expected {EXPECTED_HEX}, got {actual_hex}"
    assert byte_count == len(expected_bytes)
    assert loaded_bytes == expected_bytes
    print(f"Loaded {byte_count} bytes at ${LOAD_ADDRESS:04X}")
    print(f"Memory contents:       {loaded_bytes.hex().upper()}")

    branch_cases = (
        ("jcc", "carry", False, True),
        ("jcc", "carry", True, False),
        ("jcs", "carry", True, True),
        ("jcs", "carry", False, False),
        ("jeq", "zero", True, True),
        ("jeq", "zero", False, False),
        ("jne", "zero", False, True),
        ("jne", "zero", True, False),
    )
    for mnemonic, flag_name, flag_value, taken in branch_cases:
        branch_source = f"{mnemonic} target\nhlt\ntarget: hlt\n"
        branch_memory = make_ram()
        parse_into_memory(branch_source, branch_memory)
        branch_cpu = CPU(branch_memory)
        setattr(branch_cpu, flag_name, flag_value)
        branch_cpu.cycle()
        assert branch_cpu.pc == (4 if taken else 3), (mnemonic, flag_value, branch_cpu.pc)
    print("Conditional jumps:         JCC, JCS, JEQ, JNE taken/not-taken passed")

    direct_memory = make_ram()
    parse_into_memory("jmp target\nhlt\ntarget: hlt\n", direct_memory)
    direct_cpu = CPU(direct_memory)
    direct_cpu.cycle()
    assert direct_cpu.pc == 4
    print("Direct JMP:                jumped to label at $0004")

    subroutine_source = "jsr sub\nhlt\nsub: ret\n"
    subroutine_memory = make_ram()
    parse_into_memory(subroutine_source, subroutine_memory)
    subroutine_cpu = CPU(subroutine_memory)
    subroutine_cpu.sp = 0x7FFF
    subroutine_cpu.cycle()
    assert subroutine_cpu.pc == 4
    subroutine_cpu.cycle()
    assert subroutine_cpu.pc == 3
    assert subroutine_cpu.sp == 0x7FFF
    print("JSR/RET:                   called subroutine and returned to $0003")

    indirect_memory = make_ram()
    indirect_memory.load_bytes(0, bytes.fromhex(parse_code("jmp ($0100)\nhlt\n")))
    indirect_memory.write16(0x0100, 4)
    indirect_cpu = CPU(indirect_memory)
    indirect_cpu.cycle()
    assert indirect_cpu.pc == 4
    print("Indirect JMP:              jumped through pointer at $0100 to $0004")
    print("Result: PASS")


if __name__ == "__main__":
    main()