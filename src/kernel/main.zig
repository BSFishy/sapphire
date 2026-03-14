const builtin = @import("builtin");
const serial = @import("serial.zig");
const limine = @import("limine.zig");

export var start_marker: limine.RequestsStartMarker linksection(".limine_requests_start") = .{};
export var end_marker: limine.RequestsEndMarker linksection(".limine_requests_end") = .{};

export var base_revision: limine.BaseRevision linksection(".limine_requests") = .init(5);
export var memory_map: extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*extern struct {
        revision: u64,
        entry_count: u64,
        entries: [*]*extern struct {
            base: u64,
            length: u64,
            type: enum(u64) {
                usable                = 0,
                reserved              = 1,
                acpiReclaimable       = 2,
                acpiNvs               = 3,
                badMemory             = 4,
                bootloaderReclaimable = 5,
                executableAndModules  = 6,
                framebuffer           = 7,
                reservedMapping       = 8,
            },
        },
    },
} linksection(".limine_requests") = .{
    .id = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 },
    .revision = 0,
    .response = null,
};

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


export fn _start() noreturn {
    serial.setupSerial();

    main() catch |err| {
        var writer = serial.writer(&.{});
        defer writer.flush() catch {};

        writer.print("failed to run kernel: {any}\n", .{err}) catch {};
    };

    hcf();
}

fn main() !void {
    var buf: [4096]u8 = undefined;
    var writer = serial.writer(&buf);
    defer writer.flush() catch {};

    try writer.print("HELLO {*}!\n", .{&writer});

    const mm_response = memory_map.response orelse return error.errors;
    for (mm_response.entries[0..mm_response.entry_count]) |entry| {
        try writer.print(" mm entry 0x{x}-0x{x}, {s}\n", .{entry.base, entry.base + entry.length, @tagName(entry.type)});
    }
}
