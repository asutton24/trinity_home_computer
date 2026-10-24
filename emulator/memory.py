class Memory_Bank:
    
    def __init__(self, low, high, mode):
        self.low = low
        self.high = high
        # rw for ram
        # ro for rom
        self.mode = mode
        self.data = [0] * (high - low + 1)

    def read(self, addr):
        return self.data[addr - self.low]

    def write(self, addr, val):
        if self.mode == 'rw':
            self.data[addr - self.low] = val % 256

    def flash(self, addr, val):
            self.data[addr - self.low] = val % 256

class Memory:

    def __init__(self):
        self.banks = []

    def add_bank(self, low, high, mode):
        self.banks.append(Memory_Bank(low, high, mode))

    def read8(self, addr):
        for b in self.banks:
            if b.low <= addr and b.high >= addr:
                return b.read(addr)
        return 0

    def read16(self, addr):
        return self.read8(addr) + 256 * self.read8((addr + 1) & 0xFFFF)

    def write8(self, addr, val):
        for b in self.banks:
            if b.low <= addr and b.high >= addr:
                return b.write(addr, val)

    def write16(self, addr, val):
        self.write8(addr, val % 256)
        self.write8((addr + 1) & 0xFFFF, (val // 256) % 256)

