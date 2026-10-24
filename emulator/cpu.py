from __future__ import annotations

from emulator.memory import Memory


class CPU:
    """Execute Trinity jump, subroutine, return, and halt instructions."""

    def __init__(self, memory: Memory, pc: int = 0, sp: int = 0x7FFF) -> None:
        if not 0 <= pc <= 0xFFFF:
            raise ValueError("Program counter must be between $0000 and $FFFF.")
        if not 0 <= sp <= 0xFFFF:
            raise ValueError("Stack pointer must be between $0000 and $FFFF.")
        self.memory = memory
        self.pc = pc
        self.sp = sp
        self.carry = False
        self.zero = False
        self.halted = False

    def _fetch8(self) -> int:
        value = self.memory.read8(self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        return value

    def _fetch16(self) -> int:
        low = self._fetch8()
        high = self._fetch8()
        return low | (high << 8)

    def _push8(self, value: int) -> None:
        if self.sp == 0:
            raise ValueError("Stack overflow at $0000.")
        self.sp -= 1
        self.memory.load_bytes(self.sp, bytes((value,)))

    def _pop8(self) -> int:
        value = self.memory.read8(self.sp)
        self.sp += 1
        if self.sp > 0xFFFF:
            raise ValueError("Stack underflow at $FFFF.")
        return value

    def step(self) -> None:
        """Execute one instruction; unsupported opcodes raise NotImplementedError."""
        if self.halted:
            return

        opcode_address = self.pc
        opcode = self._fetch8()

        if opcode == 0x00:
            self.halted = True
            return
        if opcode in (0x60, 0x70, 0x40, 0x50, 0x20, 0x80):
            target = self._fetch16()
            should_jump = (
                opcode == 0x20
                or opcode == 0x80
                or (opcode == 0x60 and not self.carry)
                or (opcode == 0x70 and self.carry)
                or (opcode == 0x40 and self.zero)
                or (opcode == 0x50 and not self.zero)
            )
            if should_jump:
                if opcode == 0x80:
                    self._push8((self.pc >> 8) & 0xFF)
                    self._push8(self.pc & 0xFF)
                self.pc = target
            return
        if opcode == 0x30:
            pointer = self._fetch16()
            self.pc = self.memory.read16(pointer)
            return
        if opcode == 0xA0:
            low = self._pop8()
            high = self._pop8()
            self.pc = low | (high << 8)
            return

        raise NotImplementedError(f"Opcode ${opcode:02X} at ${opcode_address:04X} is not implemented.")
