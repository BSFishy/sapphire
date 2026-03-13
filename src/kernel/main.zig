const builtin = @import("builtin");

fn hcf() noreturn {
    while (true) {
        switch (builtin.cpu.arch) {
            .x86_64 => asm volatile ("hlt"),
            .aarch64 => asm volatile ("wfi"),
            .riscv64 => asm volatile ("wfi"),
            .loongarch64 => asm volatile ("idle 0"),
            else => unreachable,
        }
    }
}

inline fn outb(port: u16, val: u8) void {
    asm volatile ("outb %al, %dx"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port));
}

inline fn inb(port: u16) u8 {
    return asm volatile ("inb %dx, %al"
        : [ret] "={al}" (-> u8)
        : [port] "{dx}" (port));
}

const COM1 = 0x3F8;

export fn _start() noreturn {
    outb(COM1 + 1, 0x00);    // disable interrupts
    outb(COM1 + 3, 0x80);    // enable DLAB
    outb(COM1 + 0, 0x01);    // divisor low  (115200)
    outb(COM1 + 1, 0x00);    // divisor high
    outb(COM1 + 3, 0x03);    // 8 bits, no parity, one stop
    outb(COM1 + 2, 0xC7);    // enable FIFO
    outb(COM1 + 4, 0x0B);    // IRQs enabled, RTS/DSR

    sendString("Hello world!");
    hcf();
}

inline fn sendChar(c: u8) void {
    outb(COM1, c);
}

fn sendString(str: []const u8) void {
    for (str) |c| {
        sendChar(c);
    }
}
