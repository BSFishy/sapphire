const builtin = @import("builtin");
const std = @import("std");
const serial = @import("serial.zig");
const limine = @import("limine.zig");
const Page = @import("memory.zig").Page;

export var start_marker: limine.RequestsStartMarker linksection(".limine_requests_start") = .{};
export var end_marker: limine.RequestsEndMarker linksection(".limine_requests_end") = .{};

export var base_revision: limine.BaseRevision linksection(".limine_requests") = .init(5);
export var memory_map: extern struct {
    id: [4]u64 = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 },
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
    } = null,
} linksection(".limine_requests") = .{
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

fn main() !void {
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

    var total_memory: usize = 0;
    var page_count: usize = 0;
    var page_table_size: usize = @sizeOf(usize);
    for (entries) |entry| {
        switch (entry.type) {
            .usable,
            .bootloaderReclaimable,
            .reservedMapping,
            .executableAndModules => {
                total_memory += entry.length;
            },
            else => {},
        }

        if (entry.type != .usable) {
            continue;
        }

        // NOTE: assuming 4KiB pages here
        const pages = entry.length / 4096;
        page_count += pages;
        page_table_size += pages * @sizeOf(Page);
    }

    try writer.print("total pages: {}\n", .{page_count});
    try writer.print("total system memory: {Bi}\n", .{total_memory});
    try writer.print("usable system memory: {Bi}\n", .{page_count*4096});
    try writer.print("need at least {Bi}\n", .{page_table_size});

    var region: ?struct {
        base: u64,
        length: u64,
    } = null;
    for (entries) |entry| {
        if (entry.type != .usable) continue;
        if (entry.length < page_table_size) continue;

        const r = region orelse {
            region = .{ .base = entry.base, .length = entry.length };
            continue;
        };

        if (entry.length < r.length) {
            region = .{ .base = entry.base, .length = entry.length };
        }
    }

    var region_val = region orelse unreachable;
    region_val.base += hhdm_response.offset;

    const page_count_ptr: *usize = @ptrFromInt(region_val.base);
    page_count_ptr.* = page_count;

    const pages: [*]Page = @ptrFromInt(region_val.base + @sizeOf(usize));
    var page_entry: usize = 0;
    for (entries) |entry| {
        if (entry.type != .usable) {
            continue;
        }

        const entry_page_count = entry.length / 4096;
        for (0..entry_page_count) |idx| {
            pages[page_entry] = .{
                .flags = .initEmpty(),
                .order = 0,
                .address = entry.base + idx * 4096,
            };

            page_entry += 1;
        }
    }

    for (0..15) |i| {
        const page = pages[i];
        try writer.print(" page {any}\n", .{page});
    }
}
