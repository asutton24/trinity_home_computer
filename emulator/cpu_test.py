"""Checks CPU instructions against the spec. Run: python emulator/cpu_test.py"""
from pathlib import Path
import sys

PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))

from emulator.cpu import CPU
from emulator.memory import Memory
from assembler.main import parse_into_memory


def run(source: str, setup=None) -> CPU:
    """Assemble source at $0000, run it until hlt, and return the CPU."""
    memory = Memory()
    memory.add_bank(0x0000, 0x7FFF, "rw")
    parse_into_memory(source, memory)
    if setup:
        setup(memory)
    cpu = CPU(memory)
    cpu.sp = 0x7FFF
    for _ in range(1000):
        if cpu.halted:
            return cpu
        cpu.cycle()
    raise AssertionError("program did not reach hlt")


def test_clc_clears_carry():
    cpu = run("sec\nclc\nhlt\n")
    assert cpu.carry == 0
    cpu = run("sec\nclc\nlda #$01\nadc #$01\nhlt\n")
    assert cpu.a == 0x02, "adc after clc must not add a carry"


def test_indirect_reads_through_the_pointer():
    def setup(memory):
        memory.write16(0x0100, 0x0200)   # pointer at $0100 -> $0200
        memory.write8(0x0200, 0x11)
        memory.write8(0x0203, 0x33)
    assert run("lda ($0100)\nhlt\n", setup).a == 0x11
    assert run("ldi #$03\nlda ($0100),i\nhlt\n", setup).a == 0x33
    assert run("ldb ($0100)\nhlt\n", setup).b == 0x11
    cpu = run("ldc ($0100)\nhlt\n", setup)
    assert cpu.c == 0x11 and cpu.zero == 0


def test_indirect_writes_through_the_pointer():
    def setup(memory):
        memory.write16(0x0100, 0x0200)
    cpu = run("lda #$42\nsta ($0100)\nldi #$05\nsta ($0100),i\ninc ($0100)\nhlt\n", setup)
    assert cpu.mem.read8(0x0200) == 0x43
    assert cpu.mem.read8(0x0205) == 0x42
    assert cpu.mem.read16(0x0100) == 0x0200, "the pointer itself must not change"


def test_ldc_indirect_sets_zero():
    def setup(memory):
        memory.write16(0x0100, 0x0200)   # $0200 holds 0
    assert run("ldc #$01\nldc ($0100)\nhlt\n", setup).zero == 1


def test_rol_shifts_one_place_and_brings_in_carry():
    cpu = run("lda #$81\nsec\nrol a\nhlt\n")
    assert cpu.a == 0x03 and cpu.carry == 1
    cpu = run("lda #$40\nclc\nrol a\nhlt\n")
    assert cpu.a == 0x80 and cpu.carry == 0
    cpu = run("ldb #$01\nsec\nrol b\nhlt\n")
    assert cpu.b == 0x03
    cpu = run("lda #$C0\nsta $0300\nsec\nrol $0300\nhlt\n")
    assert cpu.mem.read8(0x0300) == 0x81 and cpu.carry == 1


def test_ror():
    cpu = run("lda #$01\nsec\nror a\nhlt\n")
    assert cpu.a == 0x80 and cpu.carry == 1
    cpu = run("lda #$55\nldc #$02\nclc\nror c\nhlt\n")
    assert cpu.c == 0x01 and cpu.a == 0x55, "ror c must change c, not a"
    cpu = run("lda #$01\nsta $0300\nldc #$07\nclc\nror $0300\nhlt\n")
    assert cpu.mem.read8(0x0300) == 0x00 and cpu.zero == 1 and cpu.carry == 1


def test_16_bit_add_and_shift():
    # $01F0 + $0020 = $0210, then shifted right once = $0108
    cpu = run("clc\nlda #$F0\nadc #$20\nsta $0300\nlda #$01\nadc #$00\nsta $0301\n"
              "lsr $0301\nror $0300\nhlt\n")
    assert cpu.mem.read8(0x0300) == 0x08 and cpu.mem.read8(0x0301) == 0x01


def test_jmp_indirect():
    # jmp ($0100) is at $0000, "lda #$01" at $0003, hlt at $0005, "lda #$02" at $0006
    def setup(memory):
        memory.write16(0x0100, 0x0006)
    assert run("jmp ($0100)\nlda #$01\nhlt\nlda #$02\nhlt\n", setup).a == 0x02


if __name__ == "__main__":
    for name, test in list(globals().items()):
        if name.startswith("test_"):
            test()
            print("passed", name)
    print("CPU tests passed")
