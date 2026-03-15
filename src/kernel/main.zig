const builtin = @import("builtin");
const std = @import("std");
const serial = @import("serial.zig");
const limine = @import("limine.zig");
const memory = @import("memory.zig");
const Frame = memory.Frame;

export var start_marker: limine.RequestsStartMarker linksection(".limine_requests_start") = .{};
export var end_marker: limine.RequestsEndMarker linksection(".limine_requests_end") = .{};

export var base_revision: limine.BaseRevision linksection(".limine_requests") = .init(5);
export var memory_map: limine.MemoryMapFeature linksection(".limine_requests") = .{
    .revision = 0,
};

export var hhdm: extern struct {
    id: [4]u64 = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, 0x48dcf1cb8ad2b852, 0x63984e959a98244b },
    revision: u64,
    response: ?*extern struct {
        revision: u64,
        offset: u64,
    } = null,
} linksection(".limine_requests") = .{
    .revision = 0,
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

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ra: ?usize) noreturn {
    _ = ra;
    _ = error_return_trace;
    serial.sendString("!KERNEL PANIC!\n");
    serial.sendString(msg);
    serial.sendChar('\n');

    hcf();
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

fn verifyEnvironment() !void {
    if (!base_revision.isValid()) {
        @panic("invalid limine boot");
    }

    if (!base_revision.isSupported()) {
        serial.sendString("Invalid Limine revision. Please use Limine revision 5 or newer.\n");
        return error.errors;
    }
}

fn setupMemory() !void {
    var writer = serial.writer(&.{});
    defer writer.flush() catch {};

    try writer.print("HELLO {*}!\n", .{&writer});

    const mm_response = memory_map.response orelse return error.errors;
    const entries = mm_response.entries[0..mm_response.entry_count];
    for (entries) |entry| {
        try writer.print(" mm entry 0x{x}-0x{x}, {s}\n", .{entry.base, entry.base + entry.length, @tagName(entry.type)});
    }

    const hhdm_response = hhdm.response orelse return error.errors;
    try writer.print("offset: 0x{x}\n", .{hhdm_response.offset});

    var frame_allocator = try memory.newFrameAllocator(entries, hhdm_response.offset);

    const frame = frame_allocator.allocFrame() orelse return error.errors;
    try writer.print("allocated frame: {}\n", .{frame});
    frame_allocator.free(frame);

    const frame2 = frame_allocator.allocFrame() orelse return error.errors;
    try writer.print("allocated frame: {}\n", .{frame2});
}

fn main() !void {
    try verifyEnvironment();
    try setupMemory();

    serial.sendString("Finished boot sequence. Ready to run some code!\n");
}
