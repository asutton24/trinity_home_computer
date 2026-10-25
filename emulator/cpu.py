class CPU:
    
    def __init__(self, mem):
        self.a = 0
        self.b = 0
        self.c = 0
        self.i = 0
        self.pc = 0
        self.sp = 0
        self.carry = 0
        self.zero = 0
        self.mem = mem
        self.halted = False

    def reset(self):
        self.pc = self.mem.read16(0xFFFE)
        self.halted = False

    def add_flags(self, op):
        new_carry = 0
        if self.a + op + self.carry > 0xFF:
            new_carry = 1
        self.a = (self.a + op + self.carry) % 256
        self.zero = 1 if self.a == 0 else 0
        self.carry = new_carry

    def and_flags(self, op):
        self.a = self.a & op
        self.zero = 1 if self.a == 0 else 0

    def ora_flags(self, op):
        self.a = self.a | op
        self.zero = 1 if self.a == 0 else 0
   
    def xor_flags(self, op):
        self.a = self.a ^ op
        self.zero = 1 if self.a == 0 else 0
    
    def sbc_flags(self, op):
        self.add_flags(op ^ 0xFF)

    def fetch_immediate(self):
        self.pc = (self.pc + 1) & 0xFFFF
        return self.mem.read8(self.pc)

    def fetch_abs(self):
        self.pc = (self.pc + 1) & 0xFFFF
        ptr = self.mem.read16(self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        return self.mem.read8(ptr)

    def write_abs(self, val):
        self.pc = (self.pc + 1) & 0xFFFF
        ptr = self.mem.read16(self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        return self.mem.write8(ptr, val)

    def fetch_abs_i(self):
        self.pc = (self.pc + 1) & 0xFFFF
        ptr = self.mem.read16(self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        return self.mem.read8((ptr + self.i) & 0xFFFF)

    def write_abs_i(self, val):
        self.pc = (self.pc + 1) & 0xFFFF
        ptr = self.mem.read16(self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        return self.mem.write8((ptr + self.i) & 0xFFFF, val)

    def fetch_ind(self):
        self.pc = (self.pc + 1) & 0xFFFF
        ptr = self.mem.read16(self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        ptr_2 = self.mem.read16(ptr)
        return self.mem.read8(ptr)

    def write_ind(self, val):
        self.pc = (self.pc + 1) & 0xFFFF
        ptr = self.mem.read16(self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        ptr_2 = self.mem.read16(ptr)
        return self.mem.write8(ptr, val)
    
    def fetch_ind_i(self):
        self.pc = (self.pc + 1) & 0xFFFF
        ptr = self.mem.read16(self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        ptr_2 = self.mem.read16(ptr)
        return self.mem.read8((ptr + self.i) & 0xFFFF)
    
    def write_ind_i(self, val):
        self.pc = (self.pc + 1) & 0xFFFF
        ptr = self.mem.read16(self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        ptr_2 = self.mem.read16(ptr)
        return self.mem.write8((ptr + self.i) & 0xFFFF, val)
    
    def cycle(self):
        if self.halted:
            return
        opcode = self.mem.read8(self.pc)
        match opcode:
            case 0x00:
                self.halted = True
            case 0x01:
                self.add_flags(self.b)
            case 0x02:
                self.add_flags(self.c)
            case 0x03:
                self.add_flags(self.fetch_immediate())
            case 0x04:
                self.add_flags(self.fetch_abs())
            case 0x05:
                self.add_flags(self.fetch_abs_i())
            case 0x06:
                self.add_flags(self.fetch_ind())
            case 0x07:
                self.add_flags(self.fetch_ind_i())
            case 0x08:
                self.b = self.a
            case 0x09:
                self.sp = (self.sp - 1) & 0xFFFF
                self.mem.write8(self.sp, self.a)
            case 0x10:
                carry = 0
            case 0x11:
                self.xor_flags(self.b)
            case 0x12:
                self.xor_flags(self.c)
            case 0x13:
                self.xor_flags(self.fetch_immediate())
            case 0x14:
                self.xor_flags(self.fetch_abs())
            case 0x15:
                self.xor_flags(self.fetch_abs_i())
            case 0x16:
                self.xor_flags(self.fetch_ind())
            case 0x17:
                self.xor_flags(self.fetch_ind_i())
            case 0x18:
                self.c = self.a
            case 0x19:
                self.sp = (self.sp - 1) & 0xFFFF
                self.mem.write8(self.sp, self.b)
            case 0x20:
                self.pc = self.mem.read16((self.pc + 1) & 0xFFFF)
                return
            case 0x21:
                self.and_flags(self.b)
            case 0x22:
                self.and_flags(self.c)
            case 0x23:
                self.and_flags(self.fetch_immediate())
            case 0x24:
                self.and_flags(self.fetch_abs())
            case 0x25:
                self.and_flags(self.fetch_abs_i())
            case 0x26:
                self.and_flags(self.fetch_ind())
            case 0x27:
                self.and_flags(self.fetch_ind_i())
            case 0x28:
                self.i = self.a
            case 0x29:
                self.sp = (self.sp - 1) & 0xFFFF
                self.mem.write8(self.sp, self.c)
            case 0x30:
                self.pc = self.mem.read16(self.mem.read16((self.pc + 1) & 0xFFFF))
                return
            case 0x33:
                self.a = self.fetch_immediate()
                self.zero = 1 if self.a == 0 else 0
            case 0x34:
                self.a = self.fetch_abs()
                self.zero = 1 if self.a == 0 else 0
            case 0x35:
                self.a = self.fetch_abs_i()
                self.zero = 1 if self.a == 0 else 0
            case 0x36:
                self.a = self.fetch_ind()
                self.zero = 1 if self.a == 0 else 0
            case 0x37:
                self.a = self.fetch_ind_i()
                self.zero = 1 if self.a == 0 else 0
            case 0x38:
                self.a = self.b
            case 0x39:
                self.a = self.mem.read8(self.sp)
                self.sp = (self.sp + 1) & 0xFFFF
                self.zero = 1 if self.a == 0 else 0
            case 0x40:
                if self.zero:
                    self.pc = self.mem.read16((self.pc + 1) & 0xFFFF)
                    return
                self.pc = (self.pc + 2) & 0xFFFF
            case 0x43:
                self.b = self.fetch_immediate()
                self.zero = 1 if self.b == 0 else 0
            case 0x44:
                self.b = self.fetch_abs()
                self.zero = 1 if self.b == 0 else 0
            case 0x45:
                self.b = self.fetch_abs_i()
                self.zero = 1 if self.b == 0 else 0
            case 0x46:
                self.b = self.fetch_ind()
                self.zero = 1 if self.b == 0 else 0
            case 0x47:
                self.b = self.fetch_ind_i()
                self.zero = 1 if self.b == 0 else 0
            case 0x48:
                self.c = self.b
            case 0x49:
                self.b = self.mem.read8(self.sp)
                self.sp = (self.sp + 1) & 0xFFFF
                self.zero = 1 if self.b == 0 else 0
            case 0x50:
                if not self.zero:
                    self.pc = self.mem.read16((self.pc + 1) & 0xFFFF)
                    return
                self.pc = (self.pc + 2) & 0xFFFF
            case 0x53:
                self.c = self.fetch_immediate()
                self.zero = 1 if self.c == 0 else 0
            case 0x54:
                self.c = self.fetch_abs()
                self.zero = 1 if self.c == 0 else 0
            case 0x55:
                self.c = self.fetch_abs_i()
                self.zero = 1 if self.c == 0 else 0
            case 0x56:
                self.c = self.fetch_ind()
            case 0x57:
                self.c = self.fetch_ind_i()
                self.zero = 1 if self.c == 0 else 0
            case 0x58:
                self.a = self.c
            case 0x59:
                self.c = self.mem.read8(self.sp)
                self.sp = (self.sp + 1) & 0xFFFF
                self.zero = 1 if self.c == 0 else 0
            case 0x60:
                if not self.carry:
                    self.pc = self.mem.read16((self.pc + 1) & 0xFFFF)
                    return
                self.pc = (self.pc + 2) & 0xFFFF
            case 0x63:
                self.i = self.fetch_immediate()
                self.zero = 1 if self.i == 0 else 0
            case 0x64:
                self.i = self.fetch_abs()
                self.zero = 1 if self.i == 0 else 0
            case 0x66:
                self.i = self.fetch_ind()
                self.zero = 1 if self.i == 0 else 0
            case 0x68:
                self.b = self.c
            case 0x70:
                if self.carry:
                    self.pc = self.mem.read16((self.pc + 1) & 0xFFFF)
                    return
                self.pc = (self.pc + 2) & 0xFFFF
            case 0x73:
                self.sp = self.fetch_immediate() + 256 * self.fetch_immediate()
            case 0x78:
                self.a = self.i
            case 0x80:
                self.sp = (self.sp - 2) & 0xFFFF
                self.mem.write16(self.sp, (self.pc + 3) & 0xFFFF)
                self.pc = self.mem.read16((self.pc + 1) & 0xFFFF)
                return
            case 0x81:
                self.ora_flags(self.b)
            case 0x82:
                self.ora_flags(self.c)
            case 0x83:
                self.ora_flags(self.fetch_immediate())
            case 0x84:
                self.ora_flags(self.fetch_abs())
            case 0x85:
                self.ora_flags(self.fetch_abs_i())
            case 0x86:
                self.ora_flags(self.fetch_ind())
            case 0x87:
                self.ora_flags(self.fetch_ind_i())
            case 0x88:
                pass
            case 0x90:
                self.carry = self.a & 1
            case 0x91:
                self.carry = (self.a >> 1) & 1
            case 0x92:
                self.carry = (self.a >> 2) & 1
            case 0x93:
                self.carry = (self.a >> 3) & 1
            case 0x94:
                self.carry = (self.a >> 4) & 1
            case 0x95:
                self.carry = (self.a >> 5) & 1
            case 0x96:
                self.carry = (self.a >> 6) & 1
            case 0x97:
                self.carry = (self.a >> 7) & 1
            case 0xA0:
                self.pc = self.mem.read16(self.sp)
                self.sp = (self.sp + 2) & 0xFFFF
                return
            case 0xA1:
                self.sbc_flags(self.b)
            case 0xA2:
                self.sbc_flags(self.c)
            case 0xA3:
                self.sbc_flags(self.fetch_immediate())
            case 0xA4:
                self.sbc_flags(self.fetch_abs())
            case 0xA5:
                self.sbc_flags(self.fetch_abs_i())
            case 0xA6:
                self.sbc_flags(self.fetch_ind())
            case 0xA7:
                self.sbc_flags(self.fetch_ind_i())
            case 0xB0:
                self.a = self.a << 1
                if self.a > 0xFF:
                    self.carry = 1
                    self.a = self.a & 0xFF
                else:
                    self.carry = 0
                self.zero = 1 if self.a == 0 else 0
            case 0xB1:
                self.b = self.b << 1
                if self.b > 0xFF:
                    self.carry = 1
                    self.b = self.b & 0xFF
                else:
                    self.carry = 0
                self.zero = 1 if self.b == 0 else 0
            case 0xB2:
                self.c = self.c << 1
                if self.c > 0xFF:
                    self.carry = 1
                    self.c = self.c & 0xFF
                else:
                    self.carry = 0
                self.zero = 1 if self.c == 0 else 0
            case 0xB4:
                val = self.fetch_abs()
                val = val << 1
                if val > 0xFF:
                    self.carry = 1
                    val = val & 0xFF
                else:
                    self.carry = 0
                self.zero = 1 if val == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_abs(val)
            case 0xB5:
                val = self.fetch_abs_i()
                val = val << 1
                if val > 0xFF:
                    self.carry = 1
                    val = val & 0xFF
                else:
                    self.carry = 0
                self.zero = 1 if val == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_abs_i(val)
            case 0xB6:
                val = self.fetch_ind()
                val = val << 1
                if val > 0xFF:
                    self.carry = 1
                    val = val & 0xFF
                else:
                    self.carry = 0
                self.zero = 1 if val == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_ind(val)
            case 0xB7:
                val = self.fetch_ind_i()
                val = val << 1
                if val > 0xFF:
                    self.carry = 1
                    val = val & 0xFF
                else:
                    self.carry = 0
                self.zero = 1 if val == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_ind_i(val)
            case 0xBC:
                self.write_abs(self.c)
            case 0xBD:
                self.write_abs_i(self.c)
            case 0xBE:
                self.write_ind(self.c)
            case 0xBF:
                self.write_ind_i(self.c)
            case 0xC0:
                if self.a & 1:
                    self.carry = 1
                else:
                    self.carry = 0
                self.a = self.a >> 1
                self.zero = 1 if self.a == 0 else 0
            case 0xC1:
                if self.b & 1:
                    self.carry = 1
                else:
                    self.carry = 0
                self.b = self.b >> 1
                self.zero = 1 if self.b == 0 else 0
            case 0xC2:
                if self.c & 1:
                    self.carry = 1
                else:
                    self.carry = 0
                self.c = self.c >> 1
                self.zero = 1 if self.c == 0 else 0
            case 0xC4:
                val = self.fetch_abs()
                if val & 1:
                    self.carry = 1
                else:
                    self.carry = 0
                val = val >> 1
                self.zero = 1 if val == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_abs(val)
            case 0xC5:
                val = self.fetch_abs_i()
                if val & 1:
                    self.carry = 1
                else:
                    self.carry = 0
                val = val >> 1
                self.zero = 1 if val == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_abs_i(val)
            case 0xC6:
                val = self.fetch_ind()
                if val & 1:
                    self.carry = 1
                else:
                    self.carry = 0
                val = val >> 1
                self.zero = 1 if val == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_ind(val)
            case 0xC7:
                val = self.fetch_ind_i()
                if val & 1:
                    self.carry = 1
                else:
                    self.carry = 0
                val = val >> 1
                self.zero = 1 if val == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_ind_i(val)
            case 0xCC:
                self.write_abs(self.b)
            case 0xCD:
                self.write_abs_i(self.b)
            case 0xCE:
                self.write_ind(self.b)
            case 0xCF:
                self.write_ind_i(self.b)
            case 0xD0:
                self.a = self.a << 1 + self.carry
                if self.a > 0xFF:
                    self.a = self.a & 0xFF
                    self.carry = 1
                else:
                    self.carry = 0
                self.zero = 1 if self.a == 0 else 0
            case 0xD1:
                self.b = self.b << 1 + self.carry
                if self.b > 0xFF:
                    self.b = self.b & 0xFF
                    self.carry = 1
                else:
                    self.carry = 0
                self.zero = 1 if self.b == 0 else 0
            case 0xD2:
                self.c = self.c << 1 + self.carry
                if self.c > 0xFF:
                    self.c = self.c & 0xFF
                    self.carry = 1
                else:
                    self.carry = 0
                self.zero = 1 if self.c == 0 else 0
            case 0xD4:
                val = self.fetch_abs()
                val = val << 1 + self.carry
                if val > 0xFF:
                    val = val & 0xFF
                    self.carry = 1
                else:
                    self.carry = 0
                self.zero = 1 if val == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_abs(val)
            case 0xD5:
                val = self.fetch_abs_i()
                val = val << 1 + self.carry
                if val > 0xFF:
                    val = val & 0xFF
                    self.carry = 1
                else:
                    self.carry = 0
                self.zero = 1 if val == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_abs_i(val)
            case 0xD6:
                val = self.fetch_ind()
                val = val << 1 + self.carry
                if val > 0xFF:
                    val = val & 0xFF
                    self.carry = 1
                else:
                    self.carry = 0
                self.zero = 1 if val == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_ind(val)
            case 0xD7:
                val = self.fetch_ind_i()
                val = val << 1 + self.carry
                if val > 0xFF:
                    val = val & 0xFF
                    self.carry = 1
                else:
                    self.carry = 0
                self.zero = 1 if val == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_ind_i(val)
            case 0xDC:
                self.write_abs(self.a)
            case 0xDD:
                self.write_abs_i(self.a)
            case 0xDE:
                self.write_ind(self.a)
            case 0xDF:
                self.write_ind_i(self.a)
            case 0xE0:
                new_carry = 0
                if self.a & 1:
                    new_carry = 1
                self.a = self.carry * 128 + (self.a >> 1)
                self.carry = new_carry
                self.zero = 1 if self.a == 0 else 0
            case 0xE1:
                new_carry = 0
                if self.b & 1:
                    new_carry = 1
                self.b = self.carry * 128 + (self.b >> 1)
                self.carry = new_carry
                self.zero = 1 if self.b == 0 else 0
            case 0xE2:
                new_carry = 0
                if self.c & 1:
                    new_carry = 1
                self.a = self.carry * 128 + (self.c >> 1)
                self.carry = new_carry
                self.zero = 1 if self.c == 0 else 0
            case 0xE4:
                val = self.fetch_abs()
                new_carry = 0
                if val & 1:
                    new_carry = 1
                val = self.carry * 128 + (val >> 1)
                self.carry = new_carry
                self.zero = 1 if self.c == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_abs(val) 
            case 0xE5:
                val = self.fetch_abs_i()
                new_carry = 0
                if val & 1:
                    new_carry = 1
                val = self.carry * 128 + (val >> 1)
                self.carry = new_carry
                self.zero = 1 if self.c == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_abs_i(val) 
            case 0xE6:
                val = self.fetch_ind()
                new_carry = 0
                if val & 1:
                    new_carry = 1
                val = self.carry * 128 + (val >> 1)
                self.carry = new_carry
                self.zero = 1 if self.c == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_ind(val) 
            case 0xE7:
                val = self.fetch_ind_i()
                new_carry = 0
                if val & 1:
                    new_carry = 1
                val = self.carry * 128 + (val >> 1)
                self.carry = new_carry
                self.zero = 1 if self.c == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_ind_i(val) 
            case 0xE8:
                self.a = (self.a + 1) & 0xFF
                self.zero = 1 if self.a == 0 else 0
            case 0xE9:
                self.b = (self.b + 1) & 0xFF
                self.zero = 1 if self.b == 0 else 0
            case 0xEA:
                self.c = (self.c + 1) & 0xFF
                self.zero = 1 if self.c == 0 else 0
            case 0xEB:
                self.i = (self.i + 1) & 0xFF
                self.zero = 1 if self.i == 0 else 0
            case 0xEC:
                val = self.fetch_abs()
                val = (val + 1) & 0xFF
                self.zero = 1 if val == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_abs(val)
            case 0xED:
                val = self.fetch_abs_i()
                val = (val + 1) & 0xFF
                self.zero = 1 if val == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_abs_i(val)
            case 0xEE:
                val = self.fetch_ind()
                val = (val + 1) & 0xFF
                self.zero = 1 if val == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_ind(val)
            case 0xEF:
                val = self.fetch_ind_i()
                val = (val + 1) & 0xFF
                self.zero = 1 if val == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_ind_i(val)
            case 0xF0:
                self.carry = 1
            case 0xF1:
                self.zero = 1 if self.a == self.b else 0
                self.carry = 1 if self.a >= self.b else 0
            case 0xF2: 
                self.zero = 1 if self.a == self.c else 0
                self.carry = 1 if self.a >= self.c else 0
            case 0xF3:
                val = self.fetch_immediate()
                self.zero = 1 if self.a == val else 0
                self.carry = 1 if self.a >= val else 0
            case 0xF4:
                val = self.fetch_abs()
                self.zero = 1 if self.a == val else 0
                self.carry = 1 if self.a >= val else 0
            case 0xF5:
                val = self.fetch_abs_i()
                self.zero = 1 if self.a == val else 0
                self.carry = 1 if self.a >= val else 0
            case 0xF6:
                val = self.fetch_ind()
                self.zero = 1 if self.a == val else 0
                self.carry = 1 if self.a >= val else 0
            case 0xF7:
                val = self.fetch_ind_i()
                self.zero = 1 if self.a == val else 0
                self.carry = 1 if self.a >= val else 0
            case 0xF8:
                self.a = (self.a - 1) & 0xFF
                self.zero = 1 if self.a == 0 else 0
            case 0xF9:
                self.b = (self.b - 1) & 0xFF
                self.zero = 1 if self.b == 0 else 0
            case 0xFA:
                self.c = (self.c - 1) & 0xFF
                self.zero = 1 if self.c == 0 else 0
            case 0xFB:
                self.i = (self.i - 1) & 0xFF
                self.zero = 1 if self.i == 0 else 0
            case 0xFC:
                val = self.fetch_abs()
                val = (val - 1) & 0xFF
                self.zero = 1 if val == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_abs(val)
            case 0xFD:
                val = self.fetch_abs_i()
                val = (val - 1) & 0xFF
                self.zero = 1 if val == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_abs_i(val)
            case 0xFE:
                val = self.fetch_ind()
                val = (val - 1) & 0xFF
                self.zero = 1 if val == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_ind(val)
            case 0xFF:
                val = self.fetch_ind_i()
                val = (val - 1) & 0xFF
                self.zero = 1 if val == 0 else 0
                self.pc = (self.pc - 2) & 0xFFFF
                self.write_ind_i(val)
        self.pc = (self.pc + 1) & 0xFFFF
