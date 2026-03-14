const std = @import("std");

const COM1 = 0x3F8;

pub fn writer(buffer: []u8) std.Io.Writer {
    return .{
        .buffer = buffer,
        .vtable = &.{
            .drain = drain,
        },
    };
}

fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    _ = splat;

    var len: usize = 0;
    const buf = w.buffer[0..w.end];
    sendString(buf);
    len += buf.len;
    w.end = 0;

    for (data) |bytes| {
        sendString(bytes);
        len += bytes.len;
    }

    return len;
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

pub fn setupSerial() void {
    outb(COM1 + 1, 0x00);    // disable interrupts
    outb(COM1 + 3, 0x80);    // enable DLAB
    outb(COM1 + 0, 0x01);    // divisor low  (115200)
    outb(COM1 + 1, 0x00);    // divisor high
    outb(COM1 + 3, 0x03);    // 8 bits, no parity, one stop
    outb(COM1 + 2, 0xC7);    // enable FIFO
    outb(COM1 + 4, 0x0B);    // IRQs enabled, RTS/DSR
}

inline fn sendChar(c: u8) void {
    while ((inb(COM1 + 5) & 0x20) == 0) {}
    outb(COM1, c);
}

pub fn sendString(str: []const u8) void {
    for (str) |c| {
        sendChar(c);
    }
}
