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

    def load_bytes(self, addr, values):
        """Load bytes into mapped writable memory without wrapping addresses."""
        values = bytes(values)
        end_addr = addr + len(values)
        if addr < 0 or end_addr > 0x10000:
            raise ValueError("Program does not fit in the 16-bit address space.")

        banks = []
        for current_addr in range(addr, end_addr):
            bank = next((b for b in self.banks if b.low <= current_addr <= b.high), None)
            if bank is None:
                raise ValueError(f"Address ${current_addr:04X} is not mapped to memory.")
            if bank.mode != 'rw':
                raise ValueError(f"Address ${current_addr:04X} is not writable memory.")
            banks.append(bank)

        for current_addr, value, bank in zip(range(addr, end_addr), values, banks):
            bank.write(current_addr, value)

        return len(values)

    def write16(self, addr, val):
        self.write8(addr, val % 256)
        self.write8((addr + 1) & 0xFFFF, (val // 256) % 256)
