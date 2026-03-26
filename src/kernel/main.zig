const builtin = @import("builtin");
const std = @import("std");
const debug = @import("debug.zig");
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

fn qemuExit(code: u32) noreturn {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            const port: u16 = 0xf4;
            asm volatile ("outl %eax, %dx"
                :
                : [val] "{eax}" (code),
                  [port] "{dx}" (port),
            );
        },
        else => {},
    }

    hcf();
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ra: ?usize) noreturn {
    _ = error_return_trace;
    serial.log("!KERNEL PANIC!\n", .{});
    serial.log("{s}\n", .{msg});

    debug.printStackTrace(ra);

    qemuExit(0x10);
}

export fn _start() noreturn {
    serial.setupSerial();

    main() catch |err| std.debug.panic("failed to run kernel: {any}", .{err});
    hcf();
}

fn verifyEnvironment() !void {
    if (!base_revision.isValid()) {
        @panic("invalid limine boot");
    }

    if (!base_revision.isSupported()) {
        serial.log("Invalid Limine revision. Please use Limine revision 5 or newer.\n", .{});
        return error.errors;
    }
}

fn setupMemory() !void {
    serial.log("HELLO {*}!\n", .{&main});

    const mm_response = memory_map.response orelse return error.errors;
    const entries = mm_response.entries[0..mm_response.entry_count];
    for (entries) |entry| {
        serial.log(" mm entry 0x{x}-0x{x}, {s}\n", .{ entry.base, entry.base + entry.length, @tagName(entry.type) });
    }

    const hhdm_response = hhdm.response orelse return error.errors;
    serial.log("offset: 0x{x}\n", .{hhdm_response.offset});

    const frame_allocator: memory.FrameAllocator = try .init(entries, hhdm_response.offset);
    for (frame_allocator.frames[0..15]) |frame| {
        serial.log(" frame: {*} - {any}\n", .{ @as(*void, @ptrFromInt(frame.address)), frame.free });
    }

    for (frame_allocator.free_list, 0..) |free_frame, i| {
        serial.log(" free frame at rank {}: {any}\n", .{ i, free_frame });
    }
}

fn main() !void {
    try verifyEnvironment();
    try setupMemory();

    serial.log("Finished boot sequence. Ready to run some code!\n", .{});
}
